defmodule Quoracle.PersistenceResilienceTest do
  @moduledoc """
  Comprehensive persistence resilience tests.

  Packet 3: TEST_PersistenceResilience - R1-R22
  WorkGroupID: fix-persistence-20251218-185708

  Verifies ACE state survives agent lifecycle events and restored
  children are visible in UI.
  """
  use Quoracle.DataCase, async: true
  use ExUnitProperties

  import Test.IsolationHelpers
  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core
  alias Quoracle.Agent.Core.Persistence
  alias Quoracle.Tasks.{Task, TaskRestorer}
  alias Quoracle.Agents.Agent, as: AgentSchema
  alias Quoracle.Repo

  # ========== CATEGORY 1: ACE STATE ROUND-TRIP (R1-R4) ==========

  describe "ACE State Round-Trip" do
    test "R1: context_lessons survive serialization round-trip" do
      original_lessons = %{
        "anthropic:claude-sonnet-4" => [
          %{type: :factual, content: "User prefers Elixir", confidence: 5},
          %{type: :behavioral, content: "Always use TDD", confidence: 3}
        ],
        "azure-openai:gpt-4o" => [
          %{type: :factual, content: "Database is PostgreSQL", confidence: 4}
        ]
      }

      state = %{
        context_lessons: original_lessons,
        model_states: %{}
      }

      serialized = Persistence.serialize_ace_state(state)
      deserialized = Persistence.deserialize_ace_state(serialized)

      # Verify all lessons preserved
      for {model_id, lessons} <- original_lessons do
        restored_lessons = deserialized.context_lessons[model_id]
        assert length(restored_lessons) == length(lessons)

        for {orig, restored} <- Enum.zip(lessons, restored_lessons) do
          assert restored.type == orig.type
          assert restored.content == orig.content
          assert restored.confidence == orig.confidence
        end
      end
    end

    test "R2: model_states survive serialization round-trip" do
      timestamp = ~U[2025-01-15 10:30:00Z]

      original_states = %{
        "anthropic:claude-sonnet-4" => %{
          summary: "Implementing authentication module",
          updated_at: timestamp
        },
        "azure-openai:gpt-4o" => nil
      }

      state = %{
        context_lessons: %{},
        model_states: original_states
      }

      serialized = Persistence.serialize_ace_state(state)
      deserialized = Persistence.deserialize_ace_state(serialized)

      # Verify non-nil state preserved
      claude_state = deserialized.model_states["anthropic:claude-sonnet-4"]
      assert claude_state.summary == "Implementing authentication module"
      assert DateTime.compare(claude_state.updated_at, timestamp) == :eq

      # Verify nil preserved
      assert deserialized.model_states["azure-openai:gpt-4o"] == nil
    end

    @tag :property
    test "R3: property - arbitrary ACE states survive round-trip" do
      check all(
              lessons <- list_of(lesson_generator(), max_length: 10),
              model_state <- model_state_generator(),
              max_runs: 50
            ) do
        original = %{
          context_lessons: %{"test_model" => lessons},
          model_states: %{"test_model" => model_state}
        }

        serialized = Persistence.serialize_ace_state(original)
        deserialized = Persistence.deserialize_ace_state(serialized)

        # Structure preserved
        assert Map.keys(deserialized.context_lessons) == Map.keys(original.context_lessons)
        assert length(deserialized.context_lessons["test_model"]) == length(lessons)
      end
    end

    @tag :property
    test "R4: property - lesson types preserved as atoms after round-trip" do
      check all(
              type <- member_of([:factual, :behavioral]),
              content <- string(:printable, min_length: 1, max_length: 100),
              confidence <- positive_integer(),
              max_runs: 50
            ) do
        lesson = %{type: type, content: content, confidence: confidence}

        state = %{
          context_lessons: %{"model" => [lesson]},
          model_states: %{}
        }

        serialized = Persistence.serialize_ace_state(state)
        deserialized = Persistence.deserialize_ace_state(serialized)

        [restored_lesson] = deserialized.context_lessons["model"]
        assert is_atom(restored_lesson.type)
        assert restored_lesson.type == type
      end
    end
  end

  # ========== CATEGORY 2: PAUSE/RESUME ACE PRESERVATION (R5-R8) ==========

  describe "Pause/Resume ACE Preservation" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()

      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Test task", status: "running"}))

      [
        deps: deps,
        task: task,
        sandbox_owner: sandbox_owner
      ]
    end

    @tag :integration
    test "R5: ACE state persisted after condensation event", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "condense-ace-agent-#{System.unique_integer([:positive])}"

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil
        })

      config = %{
        agent_id: agent_id,
        task_id: task.id,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup
      }

      {:ok, pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Simulate learned lessons (normally from condensation)
      :sys.replace_state(pid, fn state ->
        %{
          state
          | context_lessons: %{
              "model-1" => [%{type: :factual, content: "Learned fact", confidence: 2}]
            },
            model_states: %{
              "model-1" => %{summary: "Current state", updated_at: DateTime.utc_now()}
            }
        }
      end)

      # Persist ACE state
      {:ok, agent_state} = Core.get_state(pid)
      :ok = Persistence.persist_ace_state(agent_state)

      # Verify persisted to DB
      {:ok, db_agent} = Quoracle.Tasks.TaskManager.get_agent(agent_id)
      assert is_map(db_agent.state)
      assert Map.has_key?(db_agent.state, "context_lessons")
    end

    @tag :integration
    test "R6: ACE state persisted on agent termination", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "terminate-ace-agent-#{System.unique_integer([:positive])}"

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil
        })

      config = %{
        agent_id: agent_id,
        task_id: task.id,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup
      }

      # Spawn agent with cleanup (cleanup is safe - checks Process.alive? first)
      {:ok, pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Add ACE state
      :sys.replace_state(pid, fn state ->
        %{
          state
          | context_lessons: %{"model-1" => [%{type: :factual, content: "Test", confidence: 1}]},
            model_states: %{}
        }
      end)

      # Stop agent gracefully (triggers terminate/2)
      # on_exit cleanup will be no-op since agent is already stopped
      GenServer.stop(pid, :normal, :infinity)

      # Verify ACE state persisted
      {:ok, db_agent} = Quoracle.Tasks.TaskManager.get_agent(agent_id)
      assert is_map(db_agent.state)
      assert Map.has_key?(db_agent.state, "context_lessons")
    end

    @tag :integration
    test "R7: ACE state restored when task resumed", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "resume-ace-agent-#{System.unique_integer([:positive])}"

      # Create agent with ACE state in DB
      ace_state = %{
        "context_lessons" => %{
          "model-1" => [
            %{"type" => "factual", "content" => "Stored lesson", "confidence" => 5}
          ]
        },
        "model_states" => %{
          "model-1" => %{"summary" => "Stored state", "updated_at" => "2025-01-15T10:00:00Z"}
        }
      }

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: ace_state
        })

      # Restore agent
      {:ok, restored_pid} =
        restore_agent_with_cleanup(deps.dynsup, db_agent,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Verify ACE state restored
      {:ok, state} = Core.get_state(restored_pid)
      assert is_map(state.context_lessons)
      lessons = state.context_lessons["model-1"]
      assert length(lessons) == 1
      assert hd(lessons).content == "Stored lesson"
    end

    @tag :integration
    test "R8: full pause/resume cycle preserves ACE state", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "pause-resume-ace-#{System.unique_integer([:positive])}"

      # Create agent with ACE state
      ace_state = %{
        "context_lessons" => %{
          "anthropic:claude-sonnet-4" => [
            %{
              "type" => "factual",
              "content" => "User works on Elixir project",
              "confidence" => 5
            },
            %{"type" => "behavioral", "content" => "Prefers TDD approach", "confidence" => 3}
          ]
        },
        "model_states" => %{
          "anthropic:claude-sonnet-4" => %{
            "summary" => "Implementing auth module",
            "updated_at" => "2025-01-15T10:00:00Z"
          }
        }
      }

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: ace_state
        })

      # Step 1: Spawn agent (cleanup is safe - checks Process.alive? first)
      config = %{
        agent_id: agent_id,
        task_id: task.id,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup
      }

      {:ok, pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Step 2: Update ACE state (simulate learning)
      :sys.replace_state(pid, fn state ->
        new_lessons =
          (state.context_lessons["anthropic:claude-sonnet-4"] || []) ++
            [%{type: :factual, content: "New lesson learned", confidence: 2}]

        put_in(state.context_lessons["anthropic:claude-sonnet-4"], new_lessons)
      end)

      # Step 3: Pause (graceful shutdown persists state)
      GenServer.stop(pid, :normal, :infinity)

      # Step 4: Verify pause persisted updated state
      {:ok, db_after_pause} = Quoracle.Tasks.TaskManager.get_agent(agent_id)
      pause_lessons = db_after_pause.state["context_lessons"]["anthropic:claude-sonnet-4"]
      assert length(pause_lessons) >= 2, "Expected at least 2 lessons after pause"

      # Step 5: Resume via TaskRestorer (returns {:ok, root_pid})
      {:ok, resumed_pid} =
        TaskRestorer.restore_task(task.id, deps.registry, deps.pubsub,
          sandbox_owner: sandbox_owner,
          dynsup: deps.dynsup
        )

      on_exit(fn ->
        if Process.alive?(resumed_pid), do: GenServer.stop(resumed_pid, :normal, :infinity)
      end)

      # Step 6: Verify ACE state preserved after resume
      {:ok, resumed_state} = Core.get_state(resumed_pid)
      resumed_lessons = resumed_state.context_lessons["anthropic:claude-sonnet-4"]

      assert length(resumed_lessons) >= 2,
             "Expected at least 2 lessons after resume, got #{length(resumed_lessons)}"

      assert Enum.any?(resumed_lessons, &(&1.content == "New lesson learned")),
             "New lesson should survive pause/resume cycle"

      # Negative assertion: no corrupted lessons
      refute Enum.any?(resumed_lessons, fn l ->
               is_nil(l.content) or l.content == ""
             end),
             "No corrupted lessons should exist after pause/resume"
    end
  end

  # ========== CATEGORY 3: RESTORED CHILD VISIBILITY (R9-R12) ==========

  describe "Restored Child Visibility" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()

      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Test task", status: "running"}))

      Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

      [
        deps: deps,
        task: task,
        sandbox_owner: sandbox_owner
      ]
    end

    @tag :integration
    test "R9: restored root agent broadcasts spawn event", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "restored-root-#{System.unique_integer([:positive])}"

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{}
        })

      {:ok, _pid} =
        restore_agent_with_cleanup(deps.dynsup, db_agent,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      assert_receive {:agent_spawned, payload}, 30_000
      assert payload.agent_id == agent_id
    end

    @tag :integration
    test "R10: restored child agents broadcast spawn events", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      parent_id = "parent-#{System.unique_integer([:positive])}"
      child_id = "child-#{System.unique_integer([:positive])}"

      {:ok, _parent_db} =
        Repo.insert(%AgentSchema{
          agent_id: parent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{}
        })

      {:ok, child_db} =
        Repo.insert(%AgentSchema{
          agent_id: child_id,
          task_id: task.id,
          status: "running",
          parent_id: parent_id,
          config: %{},
          state: %{}
        })

      {:ok, _pid} =
        restore_agent_with_cleanup(deps.dynsup, child_db,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Child should broadcast (this is the fix from Packet 2!)
      assert_receive {:agent_spawned, payload}, 30_000
      assert payload.agent_id == child_id
    end

    @tag :integration
    test "R11: UI receives spawn events for all restored agents", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      # Create parent and child in DB
      parent_id = "ui-parent-#{System.unique_integer([:positive])}"
      child_id = "ui-child-#{System.unique_integer([:positive])}"

      {:ok, _parent_db} =
        Repo.insert(%AgentSchema{
          agent_id: parent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{}
        })

      {:ok, _child_db} =
        Repo.insert(%AgentSchema{
          agent_id: child_id,
          task_id: task.id,
          status: "running",
          parent_id: parent_id,
          config: %{},
          state: %{}
        })

      # Restore via TaskRestorer (simulates UI resume action)
      # Returns {:ok, root_pid} - root PID only
      {:ok, root_pid} =
        TaskRestorer.restore_task(task.id, deps.registry, deps.pubsub,
          sandbox_owner: sandbox_owner,
          dynsup: deps.dynsup
        )

      on_exit(fn ->
        # Cleanup root (children terminate via supervision)
        if Process.alive?(root_pid), do: GenServer.stop(root_pid, :normal, :infinity)
      end)

      # UI should receive spawn events for BOTH agents
      agent_ids_received =
        receive_all_spawns(2, 2000)
        |> Enum.map(& &1.agent_id)
        |> Enum.sort()

      expected_ids = Enum.sort([parent_id, child_id])
      assert agent_ids_received == expected_ids, "UI should receive spawn events for all agents"

      # Negative assertion: no duplicate spawn events
      assert length(agent_ids_received) == length(Enum.uniq(agent_ids_received)),
             "No duplicate spawn events should be received"
    end

    @tag :integration
    test "R12: spawn broadcasts received in correct order (root first)", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      # Create parent and child in DB
      parent_id = "order-parent-#{System.unique_integer([:positive])}"
      child_id = "order-child-#{System.unique_integer([:positive])}"

      {:ok, _parent_db} =
        Repo.insert(%AgentSchema{
          agent_id: parent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{}
        })

      {:ok, _child_db} =
        Repo.insert(%AgentSchema{
          agent_id: child_id,
          task_id: task.id,
          status: "running",
          parent_id: parent_id,
          config: %{},
          state: %{}
        })

      # Restore via TaskRestorer (returns {:ok, root_pid})
      {:ok, root_pid} =
        TaskRestorer.restore_task(task.id, deps.registry, deps.pubsub,
          sandbox_owner: sandbox_owner,
          dynsup: deps.dynsup
        )

      on_exit(fn ->
        if Process.alive?(root_pid), do: GenServer.stop(root_pid, :normal, :infinity)
      end)

      # Verify order: root should be broadcast BEFORE child
      spawns = receive_all_spawns(2, 2000)
      spawn_order = Enum.map(spawns, & &1.agent_id)

      assert hd(spawn_order) == parent_id,
             "Root agent should broadcast first, got order: #{inspect(spawn_order)}"
    end
  end

  # ========== CATEGORY 4: EDGE CASES (R13-R19) ==========

  describe "Edge Cases" do
    test "R13: handles agents with no ACE data" do
      # Empty ACE state
      db_agent = %{state: nil}
      result = Persistence.restore_ace_state(db_agent)

      # v5.0: Now includes model_histories in restored ACE state
      assert result == %{context_lessons: %{}, model_states: %{}, model_histories: %{}}
    end

    test "R14: handles partial ACE state (lessons only)" do
      db_agent = %{
        state: %{
          "context_lessons" => %{"model" => []}
          # No model_states key
        }
      }

      result = Persistence.restore_ace_state(db_agent)

      assert result.context_lessons == %{"model" => []}
      assert result.model_states == %{}
    end

    test "R15: gracefully handles unknown lesson type (forward compatibility)" do
      # Unknown types are accepted gracefully - allows forward compatibility
      # when new lesson types are added without requiring code updates
      stored_data = %{
        "context_lessons" => %{
          "model" => [
            %{"type" => "unknown_type_xyz", "content" => "test", "confidence" => 1}
          ]
        },
        "model_states" => %{}
      }

      # Unknown types are converted to atoms gracefully (no crash)
      result = Persistence.deserialize_ace_state(stored_data)
      assert [lesson] = result.context_lessons["model"]
      assert lesson.type == :unknown_type_xyz
      assert lesson.content == "test"
    end

    test "R16: handles model_state with missing timestamp" do
      stored_data = %{
        "context_lessons" => %{},
        "model_states" => %{
          "model" => %{
            "summary" => "Test summary"
            # No updated_at key
          }
        }
      }

      # Should handle gracefully (not crash)
      result = Persistence.deserialize_ace_state(stored_data)

      assert result.model_states["model"].summary == "Test summary"
      # updated_at may be nil or default
    end

    @tag :integration
    test "R17: concurrent pause/restore operations don't corrupt state", %{
      sandbox_owner: sandbox_owner
    } do
      deps = create_isolated_deps()

      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Concurrent test", status: "running"}))

      agent_id = "concurrent-#{System.unique_integer([:positive])}"

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{
            "context_lessons" => %{
              "model" => [%{"type" => "factual", "content" => "Original", "confidence" => 1}]
            },
            "model_states" => %{}
          }
        })

      # Spawn initial agent (cleanup is safe - checks Process.alive? first)
      config = %{
        agent_id: agent_id,
        task_id: task.id,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup
      }

      {:ok, pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Concurrently: pause (stop agent) and attempt restore
      # Use Elixir.Task to avoid conflict with Quoracle.Tasks.Task alias
      # No artificial delays - let operations race naturally
      # Capture log to suppress expected "Duplicate agent ID" errors from race
      import ExUnit.CaptureLog

      {restore_result, _log} =
        with_log(fn ->
          pause_task =
            Elixir.Task.async(fn ->
              GenServer.stop(pid, :normal, :infinity)
            end)

          restore_task =
            Elixir.Task.async(fn ->
              TaskRestorer.restore_task(task.id, deps.registry, deps.pubsub,
                sandbox_owner: sandbox_owner,
                dynsup: deps.dynsup
              )
            end)

          # Wait for both to complete (order may vary due to race)
          Elixir.Task.await(pause_task, 5000)
          Elixir.Task.await(restore_task, 5000)
        end)

      # Clean up any restored agents (restore_task returns {:ok, root_pid})
      case restore_result do
        {:ok, root_pid} when is_pid(root_pid) ->
          if Process.alive?(root_pid), do: GenServer.stop(root_pid, :normal, :infinity)

        _ ->
          :ok
      end

      # Verify DB state not corrupted - state should be nil or a valid map
      {:ok, db_agent} = Quoracle.Tasks.TaskManager.get_agent(agent_id)

      # Explicit type check without `or` in assertion
      state_is_valid = is_nil(db_agent.state) or is_map(db_agent.state)
      assert state_is_valid, "State should be nil or map, got: #{inspect(db_agent.state)}"

      # If state exists, verify structure is not corrupted
      if is_map(db_agent.state) do
        refute Map.has_key?(db_agent.state, "corrupted")
      end
    end

    @tag :integration
    test "R18: handles large ACE state (100 lessons per model)", %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()

      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Large state test", status: "running"}))

      agent_id = "large-state-#{System.unique_integer([:positive])}"

      # Create 100 lessons per model
      large_lessons =
        for i <- 1..100 do
          %{
            "type" => "factual",
            "content" => "Lesson #{i} with some content",
            "confidence" => rem(i, 5) + 1
          }
        end

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{
            "context_lessons" => %{
              "model-1" => large_lessons,
              "model-2" => large_lessons
            },
            "model_states" => %{}
          }
        })

      # Restore should succeed
      {:ok, restored_pid} =
        restore_agent_with_cleanup(deps.dynsup, db_agent,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, state} = Core.get_state(restored_pid)

      assert length(state.context_lessons["model-1"]) == 100
      assert length(state.context_lessons["model-2"]) == 100
    end

    @tag :integration
    test "R19: preserves ACE state across multiple models", %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()

      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Multi-model test", status: "running"}))

      agent_id = "multi-model-#{System.unique_integer([:positive])}"

      # Create state for 5 different models
      models = [
        "anthropic:claude-sonnet-4",
        "azure-openai:gpt-4o",
        "google:gemini-2.0-flash",
        "bedrock:claude-sonnet",
        "openai:gpt-4"
      ]

      context_lessons =
        Enum.into(models, %{}, fn model ->
          {model, [%{"type" => "factual", "content" => "Lesson for #{model}", "confidence" => 3}]}
        end)

      model_states =
        Enum.into(models, %{}, fn model ->
          {model, %{"summary" => "State for #{model}", "updated_at" => "2025-01-15T10:00:00Z"}}
        end)

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{
            "context_lessons" => context_lessons,
            "model_states" => model_states
          }
        })

      {:ok, restored_pid} =
        restore_agent_with_cleanup(deps.dynsup, db_agent,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, state} = Core.get_state(restored_pid)

      # All 5 models should have their data
      for model <- models do
        assert Map.has_key?(state.context_lessons, model), "Missing lessons for #{model}"
        assert Map.has_key?(state.model_states, model), "Missing state for #{model}"
      end
    end
  end

  # ========== CATEGORY 5: PROPERTY TESTS (R20-R22) ==========

  describe "Property Tests" do
    @tag :property
    test "R20: property - confidence values preserved exactly" do
      check all(
              confidence <- positive_integer(),
              max_runs: 50
            ) do
        lesson = %{type: :factual, content: "test", confidence: confidence}

        state = %{
          context_lessons: %{"model" => [lesson]},
          model_states: %{}
        }

        serialized = Persistence.serialize_ace_state(state)
        deserialized = Persistence.deserialize_ace_state(serialized)

        [restored] = deserialized.context_lessons["model"]
        assert restored.confidence == confidence
      end
    end

    @tag :property
    test "R21: property - unicode lesson content preserved" do
      check all(
              content <- string(:printable, min_length: 1, max_length: 500),
              max_runs: 50
            ) do
        lesson = %{type: :factual, content: content, confidence: 1}

        state = %{
          context_lessons: %{"model" => [lesson]},
          model_states: %{}
        }

        serialized = Persistence.serialize_ace_state(state)
        deserialized = Persistence.deserialize_ace_state(serialized)

        [restored] = deserialized.context_lessons["model"]
        assert restored.content == content
      end
    end

    @tag :property
    test "R22: property - lesson list order preserved" do
      check all(
              lessons <- list_of(lesson_generator(), min_length: 2, max_length: 10),
              max_runs: 50
            ) do
        state = %{
          context_lessons: %{"model" => lessons},
          model_states: %{}
        }

        serialized = Persistence.serialize_ace_state(state)
        deserialized = Persistence.deserialize_ace_state(serialized)

        restored = deserialized.context_lessons["model"]

        # Order preserved
        assert length(restored) == length(lessons)

        for {orig, rest} <- Enum.zip(lessons, restored) do
          assert rest.content == orig.content
        end
      end
    end
  end

  # ========== CATEGORY 6: MODEL HISTORIES PRESERVATION (R23-R31) ==========
  # WorkGroupID: fix-history-20251219-033611
  # These tests verify model_histories (conversation history) survives pause/resume.

  describe "Model Histories Round-Trip (R23)" do
    test "R23: model_histories survive serialization round-trip" do
      original_histories = %{
        "anthropic:claude-sonnet-4" => [
          %{type: :user, content: "Hello, how are you?", timestamp: ~U[2025-01-15 10:00:00Z]},
          %{
            type: :agent,
            content: "I'm doing well, thank you!",
            timestamp: ~U[2025-01-15 10:00:05Z]
          },
          %{type: :decision, content: "Use TDD approach", timestamp: ~U[2025-01-15 10:00:10Z]}
        ],
        "azure-openai:gpt-4o" => [
          %{type: :user, content: "Start the project", timestamp: ~U[2025-01-15 10:01:00Z]},
          %{
            type: :result,
            content: {"action-123", {:ok, "completed"}},
            timestamp: ~U[2025-01-15 10:01:05Z]
          }
        ]
      }

      state = %{
        model_histories: original_histories,
        context_lessons: %{},
        model_states: %{}
      }

      serialized = Persistence.serialize_ace_state(state)
      deserialized = Persistence.deserialize_ace_state(serialized)

      # Verify all histories preserved
      for {model_id, entries} <- original_histories do
        restored_entries = deserialized.model_histories[model_id]

        assert length(restored_entries) == length(entries),
               "Expected #{length(entries)} entries for #{model_id}, got #{length(restored_entries || [])}"

        for {orig, restored} <- Enum.zip(entries, restored_entries) do
          assert restored.type == orig.type
          assert restored.content == orig.content
        end
      end
    end
  end

  describe "Model Histories Pause/Resume (R24)" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()

      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "History test", status: "running"}))

      [
        deps: deps,
        task: task,
        sandbox_owner: sandbox_owner
      ]
    end

    @tag :integration
    test "R24: model_histories preserved across pause/resume cycle", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "history-pause-resume-#{System.unique_integer([:positive])}"

      # Create agent with model_histories in DB (simulates agent that has conversation)
      stored_histories = %{
        "anthropic:claude-sonnet-4" => [
          %{
            "type" => "user",
            "content" => "Hello from user",
            "timestamp" => "2025-01-15T10:00:00Z"
          },
          %{
            "type" => "agent",
            "content" => "Hello! I'm ready to help.",
            "timestamp" => "2025-01-15T10:00:05Z"
          },
          %{
            "type" => "decision",
            "content" => "Will use TDD approach",
            "timestamp" => "2025-01-15T10:00:10Z"
          }
        ]
      }

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{
            "context_lessons" => %{},
            "model_states" => %{},
            "model_histories" => stored_histories
          }
        })

      # Restore agent (simulates resume after pause)
      {:ok, restored_pid} =
        restore_agent_with_cleanup(deps.dynsup, db_agent,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # CRITICAL ASSERTION: model_histories must survive restoration
      {:ok, state} = Core.get_state(restored_pid)

      assert is_map(state.model_histories),
             "model_histories should be a map, got: #{inspect(state.model_histories)}"

      refute state.model_histories == %{},
             "model_histories should NOT be empty after restore"

      histories = state.model_histories["anthropic:claude-sonnet-4"]

      assert is_list(histories),
             "Expected list for model histories, got: #{inspect(histories)}"

      assert length(histories) == 3,
             "Expected 3 history entries, got #{length(histories || [])}"

      # Verify content preserved
      assert Enum.any?(histories, fn entry ->
               entry.content == "Hello from user" or entry["content"] == "Hello from user"
             end),
             "User message should be preserved in history"

      assert Enum.any?(histories, fn entry ->
               entry.content == "Hello! I'm ready to help." or
                 entry["content"] == "Hello! I'm ready to help."
             end),
             "Agent response should be preserved in history"
    end
  end

  describe "Model Histories Property Tests (R26-R27)" do
    @tag :property
    test "R26: property - arbitrary model_histories survive round-trip" do
      check all(
              entries <- list_of(history_entry_generator(), max_length: 10),
              model_count <- integer(1..3),
              max_runs: 50
            ) do
        model_ids = Enum.map(1..model_count, &"test-model-#{&1}")
        histories = Map.new(model_ids, fn id -> {id, entries} end)

        original = %{
          model_histories: histories,
          context_lessons: %{},
          model_states: %{}
        }

        serialized = Persistence.serialize_ace_state(original)
        deserialized = Persistence.deserialize_ace_state(serialized)

        # Structure preserved
        assert Map.keys(deserialized.model_histories) |> Enum.sort() ==
                 Map.keys(original.model_histories) |> Enum.sort()

        for model_id <- model_ids do
          assert length(deserialized.model_histories[model_id]) == length(entries)
        end
      end
    end

    @tag :property
    test "R27: property - history entry types preserved as atoms after round-trip" do
      check all(
              type <- member_of([:user, :agent, :decision, :result, :event, :system]),
              content <- string(:printable, min_length: 1, max_length: 100),
              max_runs: 50
            ) do
        entry = %{type: type, content: content, timestamp: DateTime.utc_now()}

        state = %{
          model_histories: %{"model" => [entry]},
          context_lessons: %{},
          model_states: %{}
        }

        serialized = Persistence.serialize_ace_state(state)
        deserialized = Persistence.deserialize_ace_state(serialized)

        [restored_entry] = deserialized.model_histories["model"]
        assert is_atom(restored_entry.type)
        assert restored_entry.type == type
      end
    end
  end

  describe "Model Histories Edge Cases (R28-R31)" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()

      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Edge case test", status: "running"}))

      [
        deps: deps,
        task: task,
        sandbox_owner: sandbox_owner
      ]
    end

    @tag :integration
    test "R28: preserves model_histories across multiple models", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "multi-model-history-#{System.unique_integer([:positive])}"

      models = [
        "anthropic:claude-sonnet-4",
        "azure-openai:gpt-4o",
        "google:gemini-2.0-flash"
      ]

      stored_histories =
        Enum.into(models, %{}, fn model ->
          {model,
           [
             %{
               "type" => "user",
               "content" => "Message for #{model}",
               "timestamp" => "2025-01-15T10:00:00Z"
             }
           ]}
        end)

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{
            "context_lessons" => %{},
            "model_states" => %{},
            "model_histories" => stored_histories
          }
        })

      {:ok, restored_pid} =
        restore_agent_with_cleanup(deps.dynsup, db_agent,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, state} = Core.get_state(restored_pid)

      # All 3 models should have their histories
      for model <- models do
        assert Map.has_key?(state.model_histories, model),
               "Missing histories for #{model}"

        assert length(state.model_histories[model]) == 1,
               "Expected 1 entry for #{model}"
      end
    end

    @tag :integration
    test "R29: handles large model_histories (100+ entries per model)", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "large-history-#{System.unique_integer([:positive])}"

      # Create 100 history entries
      large_history =
        for i <- 1..100 do
          %{
            "type" => if(rem(i, 2) == 0, do: "user", else: "agent"),
            "content" => "Message #{i} with some content to make it realistic",
            "timestamp" => "2025-01-15T10:#{String.pad_leading("#{rem(i, 60)}", 2, "0")}:00Z"
          }
        end

      stored_histories = %{
        "anthropic:claude-sonnet-4" => large_history,
        "azure-openai:gpt-4o" => large_history
      }

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{
            "context_lessons" => %{},
            "model_states" => %{},
            "model_histories" => stored_histories
          }
        })

      {:ok, restored_pid} =
        restore_agent_with_cleanup(deps.dynsup, db_agent,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, state} = Core.get_state(restored_pid)

      assert length(state.model_histories["anthropic:claude-sonnet-4"]) == 100
      assert length(state.model_histories["azure-openai:gpt-4o"]) == 100
    end

    test "R30: handles agents with empty model_histories" do
      # Empty model_histories
      db_agent = %{state: %{"model_histories" => %{}}}
      result = Persistence.restore_ace_state(db_agent)

      assert result.model_histories == %{}
    end

    test "R31: result entry tuples preserved through serialization" do
      # Result entries have tuple content: {action_id, {:ok, data} | {:error, reason}}
      original_histories = %{
        "model-1" => [
          %{
            type: :result,
            content: {"action-abc-123", {:ok, "Task completed successfully"}},
            timestamp: ~U[2025-01-15 10:00:00Z]
          },
          %{
            type: :result,
            content: {"action-def-456", {:error, "Network timeout"}},
            timestamp: ~U[2025-01-15 10:01:00Z]
          }
        ]
      }

      state = %{
        model_histories: original_histories,
        context_lessons: %{},
        model_states: %{}
      }

      serialized = Persistence.serialize_ace_state(state)
      deserialized = Persistence.deserialize_ace_state(serialized)

      [ok_result, error_result] = deserialized.model_histories["model-1"]

      # Verify tuple structure preserved
      assert ok_result.type == :result
      {action_id_1, outcome_1} = ok_result.content
      assert action_id_1 == "action-abc-123"
      assert outcome_1 == {:ok, "Task completed successfully"}

      assert error_result.type == :result
      {action_id_2, outcome_2} = error_result.content
      assert action_id_2 == "action-def-456"
      assert outcome_2 == {:error, "Network timeout"}
    end
  end

  # ========== CATEGORY 9: CHILDREN LIST RESTORATION (R38-R41) ==========
  # WorkGroupID: fix-20260104-children-restore

  describe "Children List Restoration (v4.0)" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()

      {:ok, task} =
        Repo.insert(
          Task.changeset(%Task{}, %{prompt: "Children restore test", status: "running"})
        )

      {:ok, deps: deps, task: task, sandbox_owner: sandbox_owner}
    end

    @tag :acceptance
    @tag :integration
    test "R38: children list restored after pause/resume cycle", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      # Setup: Create parent and child in DB (simulating existing agent tree)
      parent_id = "parent-#{System.unique_integer([:positive])}"
      child_id = "child-#{System.unique_integer([:positive])}"

      {:ok, _parent_db} =
        Repo.insert(%AgentSchema{
          agent_id: parent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{}
        })

      {:ok, _child_db} =
        Repo.insert(%AgentSchema{
          agent_id: child_id,
          task_id: task.id,
          status: "running",
          parent_id: parent_id,
          config: %{},
          state: %{}
        })

      # Restore task (simulates resume after pause/restart)
      {:ok, restored_parent_pid} =
        TaskRestorer.restore_task(task.id, deps.registry, deps.pubsub,
          sandbox_owner: sandbox_owner,
          dynsup: deps.dynsup
        )

      on_exit(fn ->
        if Process.alive?(restored_parent_pid) do
          GenServer.stop(restored_parent_pid, :normal, :infinity)
        end
      end)

      # CRITICAL ASSERTION: Parent's children list should contain the child
      {:ok, parent_state} = Core.get_state(restored_parent_pid)

      assert length(parent_state.children) == 1,
             "Expected 1 child in parent's children list after restore, got #{length(parent_state.children)}"

      assert hd(parent_state.children).agent_id == child_id,
             "Expected child_id #{child_id} in parent's children list"
    end

    @tag :integration
    test "R39: child budget_allocated preserved after restoration", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      parent_id = "parent-budget-#{System.unique_integer([:positive])}"
      child_id = "child-budget-#{System.unique_integer([:positive])}"

      {:ok, _parent_db} =
        Repo.insert(%AgentSchema{
          agent_id: parent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{}
        })

      # Child has budget allocation stored in state
      {:ok, _child_db} =
        Repo.insert(%AgentSchema{
          agent_id: child_id,
          task_id: task.id,
          status: "running",
          parent_id: parent_id,
          config: %{},
          state: %{"budget" => %{"limit" => "100.00"}}
        })

      {:ok, restored_parent_pid} =
        TaskRestorer.restore_task(task.id, deps.registry, deps.pubsub,
          sandbox_owner: sandbox_owner,
          dynsup: deps.dynsup
        )

      on_exit(fn ->
        if Process.alive?(restored_parent_pid) do
          GenServer.stop(restored_parent_pid, :normal, :infinity)
        end
      end)

      {:ok, parent_state} = Core.get_state(restored_parent_pid)

      assert length(parent_state.children) == 1

      child_entry = hd(parent_state.children)
      assert child_entry.agent_id == child_id

      # Budget should be preserved
      assert child_entry.budget_allocated != nil,
             "Expected budget_allocated to be set, got nil"

      assert Decimal.equal?(child_entry.budget_allocated, Decimal.new("100.00")),
             "Expected budget 100.00, got #{inspect(child_entry.budget_allocated)}"
    end

    @tag :integration
    test "R40: multiple children restored to parent", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      parent_id = "parent-multi-#{System.unique_integer([:positive])}"
      child_ids = for i <- 1..3, do: "child-#{i}-#{System.unique_integer([:positive])}"

      {:ok, _parent_db} =
        Repo.insert(%AgentSchema{
          agent_id: parent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{}
        })

      # Insert 3 children
      for child_id <- child_ids do
        {:ok, _} =
          Repo.insert(%AgentSchema{
            agent_id: child_id,
            task_id: task.id,
            status: "running",
            parent_id: parent_id,
            config: %{},
            state: %{}
          })
      end

      {:ok, restored_parent_pid} =
        TaskRestorer.restore_task(task.id, deps.registry, deps.pubsub,
          sandbox_owner: sandbox_owner,
          dynsup: deps.dynsup
        )

      on_exit(fn ->
        if Process.alive?(restored_parent_pid) do
          GenServer.stop(restored_parent_pid, :normal, :infinity)
        end
      end)

      {:ok, parent_state} = Core.get_state(restored_parent_pid)

      assert length(parent_state.children) == 3,
             "Expected 3 children in parent's list, got #{length(parent_state.children)}"

      restored_child_ids = Enum.map(parent_state.children, & &1.agent_id)

      for child_id <- child_ids do
        assert child_id in restored_child_ids,
               "Expected #{child_id} in restored children list"
      end
    end

    @tag :unit
    test "R41: orphan child logs warning but doesn't crash restoration", %{
      deps: deps,
      task: task,
      sandbox_owner: sandbox_owner
    } do
      # Create only a child with non-existent parent (orphan scenario)
      orphan_id = "orphan-#{System.unique_integer([:positive])}"
      fake_parent_id = "non-existent-parent-#{System.unique_integer([:positive])}"

      {:ok, _orphan_db} =
        Repo.insert(%AgentSchema{
          agent_id: orphan_id,
          task_id: task.id,
          status: "running",
          parent_id: fake_parent_id,
          config: %{},
          state: %{}
        })

      # Restoration should succeed (not crash) despite orphan child
      # The warning is logged but not captured here due to Logger level in test env
      # See rebuild_children_lists/2 for the Logger.warning call
      result =
        TaskRestorer.restore_task(task.id, deps.registry, deps.pubsub,
          sandbox_owner: sandbox_owner,
          dynsup: deps.dynsup
        )

      # Restoration should complete successfully
      assert {:ok, _pid} = result,
             "Restoration should succeed despite orphan child"

      # Cleanup
      case result do
        {:ok, pid} when is_pid(pid) ->
          on_exit(fn ->
            if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
          end)

        _ ->
          :ok
      end

      # Negative assertion: no error tuple returned
      refute match?({:error, _}, result),
             "Orphan child should not cause error, got: #{inspect(result)}"
    end
  end

  # ========== HELPERS ==========

  defp history_entry_generator do
    gen all(
          type <- member_of([:user, :agent, :decision, :event, :system]),
          content <- string(:printable, min_length: 1, max_length: 200),
          timestamp <- constant(DateTime.utc_now())
        ) do
      %{type: type, content: content, timestamp: timestamp}
    end
  end

  defp lesson_generator do
    gen all(
          type <- member_of([:factual, :behavioral]),
          content <- string(:printable, min_length: 1, max_length: 200),
          confidence <- positive_integer()
        ) do
      %{type: type, content: content, confidence: confidence}
    end
  end

  defp model_state_generator do
    gen all(summary <- string(:printable, max_length: 500)) do
      %{summary: summary, updated_at: DateTime.utc_now()}
    end
  end

  defp receive_all_spawns(count, timeout) do
    receive_all_spawns(count, timeout, [])
  end

  defp receive_all_spawns(0, _timeout, acc), do: Enum.reverse(acc)

  defp receive_all_spawns(count, timeout, acc) do
    receive do
      {:agent_spawned, payload} ->
        receive_all_spawns(count - 1, timeout, [payload | acc])
    after
      timeout ->
        Enum.reverse(acc)
    end
  end

  # ========== CATEGORY 8: BINARY DATA PERSISTENCE (R32-R36) ==========

  describe "Binary Data Persistence" do
    # Valid 1x1 PNG for testing (raw bytes, not base64)
    @png_bytes <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0,
                 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 8, 215, 99,
                 248, 207, 192, 0, 0, 0, 3, 0, 1, 0, 5, 39, 217, 196, 0, 0, 0, 0, 73, 69, 78, 68,
                 174, 66, 96, 130>>

    test "R32: non-UTF-8 binary is base64-encoded with marker" do
      # PNG bytes are not valid UTF-8
      refute String.valid?(@png_bytes)

      state = %{model_histories: %{"model-1" => [%{type: :image, content: @png_bytes}]}}
      serialized = Persistence.serialize_ace_state(state)

      # Binary should be wrapped in marker map
      [entry] = serialized["model_histories"]["model-1"]
      content = entry["content"]
      assert is_map(content)
      assert Map.has_key?(content, "__binary__")
      assert is_binary(content["__binary__"])
    end

    test "R33: valid UTF-8 string passes through unchanged" do
      utf8_string = "Hello, 世界! 🎉"
      assert String.valid?(utf8_string)

      state = %{model_histories: %{"model-1" => [%{type: :result, content: utf8_string}]}}
      serialized = Persistence.serialize_ace_state(state)

      [entry] = serialized["model_histories"]["model-1"]
      assert entry["content"] == utf8_string
    end

    test "R34: binary data survives serialize/deserialize round-trip" do
      image_content = [
        %{type: :text, text: "Image result"},
        %{type: :image, data: @png_bytes, media_type: "image/png"}
      ]

      state = %{
        context_lessons: %{},
        model_states: %{},
        model_histories: %{
          "model-1" => [%{type: :image, content: image_content, timestamp: DateTime.utc_now()}]
        }
      }

      serialized = Persistence.serialize_ace_state(state)

      # Verify it can be JSON-encoded (this was the original crash)
      assert {:ok, json} = Jason.encode(serialized)
      assert is_binary(json)

      # Verify round-trip restores binary
      deserialized = Persistence.deserialize_ace_state(serialized)
      [restored_entry] = deserialized.model_histories["model-1"]
      [_text_part, image_part] = restored_entry.content

      # Keys become strings after JSON serialization
      assert image_part["data"] == @png_bytes
      assert image_part["media_type"] == "image/png"
    end

    test "R35: nested binary in complex structure survives round-trip" do
      complex_content = %{
        result: %{
          images: [@png_bytes, @png_bytes],
          metadata: %{format: "png", raw: @png_bytes}
        },
        text: "Some text"
      }

      state = %{
        context_lessons: %{},
        model_states: %{},
        model_histories: %{
          "model-1" => [%{type: :result, content: complex_content, timestamp: DateTime.utc_now()}]
        }
      }

      serialized = Persistence.serialize_ace_state(state)
      assert {:ok, _json} = Jason.encode(serialized)

      deserialized = Persistence.deserialize_ace_state(serialized)
      [restored] = deserialized.model_histories["model-1"]

      # Keys become strings after JSON serialization
      assert restored.content["result"]["images"] == [@png_bytes, @png_bytes]
      assert restored.content["result"]["metadata"]["raw"] == @png_bytes
      assert restored.content["text"] == "Some text"
    end

    test "R36: malformed base64 in __binary__ marker handled gracefully" do
      # Simulate corrupted DB data
      corrupted = %{"__binary__" => "not-valid-base64!!!"}

      state = %{
        "context_lessons" => %{},
        "model_states" => %{},
        "model_histories" => %{
          "model-1" => [%{"type" => "result", "content" => corrupted}]
        }
      }

      # Should not crash, returns original encoded string
      deserialized = Persistence.deserialize_ace_state(state)
      [entry] = deserialized.model_histories["model-1"]
      # Falls back to encoded string on decode failure
      assert entry.content == "not-valid-base64!!!"
    end
  end
end
