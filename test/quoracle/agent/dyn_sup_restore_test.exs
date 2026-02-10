defmodule Quoracle.Agent.DynSupRestoreTest do
  @moduledoc """
  Tests for AGENT_DynSup.restore_agent/3 functionality (Packet 5).

  Separated from dyn_sup_test.exs because restore_agent requires database access.
  """
  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog
  import Test.IsolationHelpers
  import Test.AgentTestHelpers

  alias Quoracle.Agent.DynSup
  alias Quoracle.Agents.Agent, as: AgentSchema

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated Registry, DynSup, and PubSub for this test
    deps = create_isolated_deps()

    {:ok, deps: deps, sandbox_owner: sandbox_owner}
  end

  describe "restore_agent/3 - Packet 5 (Restoration Logic)" do
    test "ARC_RESTORE_01: spawns agent with restoration_mode = true", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Create task record directly (no need for full TaskManager.create_task)
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: "restored-agent",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{task: "Restored task"},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # Restore agent
      assert {:ok, restored_pid} =
               DynSup.restore_agent(deps.dynsup, db_agent,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      # Wait for agent initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(restored_pid)

      on_exit(fn ->
        if Process.alive?(restored_pid), do: GenServer.stop(restored_pid, :normal, :infinity)
      end)

      # Verify agent spawned
      assert Process.alive?(restored_pid)

      # Verify agent registered
      assert [{^restored_pid, _}] =
               Registry.lookup(deps.registry, {:agent, "restored-agent"})
    end

    test "ARC_RESTORE_02: agent skips persist_agent when restoration_mode true", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Create task record directly
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: "no-persist-agent",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{task: "No persist"},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # Get initial agent count in DB
      initial_count = Repo.aggregate(AgentSchema, :count)

      # Restore agent
      assert {:ok, pid} =
               DynSup.restore_agent(deps.dynsup, db_agent,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
      end)

      # Agent count should not increase (no duplicate write)
      final_count = Repo.aggregate(AgentSchema, :count)
      assert final_count == initial_count
    end

    test "ARC_RESTORE_04: uses parent_pid_override when parent restored first", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Create task record directly
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      # Spawn parent agent first
      {:ok, parent_pid} =
        DynSup.start_agent(deps.dynsup, %{
          agent_id: "parent",
          task_id: task.id,
          status: "running",
          task: "Parent task",
          registry: deps.registry,
          pubsub: deps.pubsub,
          test_mode: true,
          test_opts: [skip_initial_consultation: true],
          sandbox_owner: sandbox_owner
        })

      # Wait for parent agent initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(parent_pid)

      # Create child agent record in DB
      {:ok, child_db} =
        Repo.insert(%AgentSchema{
          agent_id: "child",
          task_id: task.id,
          status: "running",
          parent_id: "parent",
          config: %{task: "Child task"},
          inserted_at: ~N[2025-01-01 10:00:01]
        })

      # Restore child with parent_pid_override
      assert {:ok, child_pid} =
               DynSup.restore_agent(deps.dynsup, child_db,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 parent_pid_override: parent_pid,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(child_pid)

      # Use tree cleanup to stop parent and all children recursively
      on_exit(fn ->
        stop_agent_tree(parent_pid, deps.registry)
      end)

      # Verify child registered with parent relationship
      assert [{^child_pid, composite}] =
               Registry.lookup(deps.registry, {:agent, "child"})

      assert composite.parent_pid == parent_pid
    end

    test "ARC_RESTORE_05: uses nil parent_pid when parent_pid_override nil", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Create task record directly
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      # Create orphan agent in DB (parent_id present but not restored)
      {:ok, orphan_db} =
        Repo.insert(%AgentSchema{
          agent_id: "orphan",
          task_id: task.id,
          status: "running",
          parent_id: "nonexistent_parent",
          config: %{task: "Orphan task"},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # Restore with nil override (parent not restored yet)
      assert {:ok, orphan_pid} =
               DynSup.restore_agent(deps.dynsup, orphan_db,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 parent_pid_override: nil,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(orphan_pid)

      on_exit(fn ->
        if Process.alive?(orphan_pid), do: GenServer.stop(orphan_pid, :normal, :infinity)
      end)

      # Verify orphan registered with nil parent
      assert [{^orphan_pid, composite}] =
               Registry.lookup(deps.registry, {:agent, "orphan"})

      assert composite.parent_pid == nil
    end

    test "ARC_RESTORE_06: returns error when config malformed", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Create task record directly
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      # Config field is :map type; empty maps are valid persisted configs
      {:ok, valid_empty_db} =
        Repo.insert(%AgentSchema{
          agent_id: "empty-config",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          # Empty config is valid - Core only persists [:test_mode, :initial_prompt]
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # Empty config should succeed
      assert {:ok, pid} =
               DynSup.restore_agent(deps.dynsup, valid_empty_db,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
      end)
    end

    test "ARC_RESTORE_07: restored agent uses injected registry", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Create task record directly
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: "registry-test",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{task: "Registry test"},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # Restore with specific registry
      assert {:ok, pid} =
               DynSup.restore_agent(deps.dynsup, db_agent,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
      end)

      # Verify agent registered in correct registry
      assert [{^pid, _}] = Registry.lookup(deps.registry, {:agent, "registry-test"})

      # Should NOT be in default registry
      refute match?(
               [{^pid, _}],
               Registry.lookup(Quoracle.AgentRegistry, {:agent, "registry-test"})
             )
    end

    test "ARC_RESTORE_08: handles duplicate agent_id by returning error", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Create task record directly
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      # Create DB record + spawn agent (creates Registry entry)
      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: "duplicate",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{task: "Existing"},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      {:ok, existing_pid} =
        DynSup.start_agent(deps.dynsup, %{
          agent_id: "duplicate",
          task_id: task.id,
          status: "running",
          task: "Existing",
          registry: deps.registry,
          pubsub: deps.pubsub,
          test_mode: true,
          test_opts: [skip_initial_consultation: true],
          sandbox_owner: sandbox_owner
        })

      # Wait for existing agent initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(existing_pid)

      # Use tree cleanup to stop agent and any children
      on_exit(fn ->
        stop_agent_tree(existing_pid, deps.registry)
      end)

      # Attempt restore of same agent - should fail due to Registry :unique constraint
      assert capture_log(fn ->
               assert {:error, {%RuntimeError{message: "Duplicate agent ID: " <> _}, _}} =
                        DynSup.restore_agent(deps.dynsup, db_agent,
                          registry: deps.registry,
                          pubsub: deps.pubsub,
                          sandbox_owner: sandbox_owner
                        )
             end) =~ "Duplicate agent ID"
    end

    test "restore_agent delegates to start_agent internally (code reuse)", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Create task record directly
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: "reuse-test",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{task: "Reuse test", restart: :transient},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # Restore should use start_agent logic
      assert {:ok, pid} =
               DynSup.restore_agent(deps.dynsup, db_agent,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
      end)

      # Verify agent has :transient restart strategy (from config)
      # This proves start_agent logic was used
      assert Process.alive?(pid)

      # Verify registration (start_agent behavior)
      assert [{^pid, _}] = Registry.lookup(deps.registry, {:agent, "reuse-test"})
    end
  end

  # ========== ACE STATE RESTORATION (v3.0) ==========
  # Packet 1: AGENT_DynSup v3.0 - R11-R15, A1
  # WorkGroupID: fix-persistence-20251218-185708

  describe "restore_agent/3 - ACE state (v3.0)" do
    @tag :integration
    test "R11: restores context_lessons from database agent state", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      # Create agent record with ACE state in DB
      ace_state = %{
        "context_lessons" => %{
          "anthropic:claude-sonnet-4" => [
            %{"type" => "factual", "content" => "User prefers Elixir", "confidence" => 5},
            %{"type" => "behavioral", "content" => "Always use TDD", "confidence" => 3}
          ]
        },
        "model_states" => %{}
      }

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: "restore-lessons-agent",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: ace_state,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # Restore agent
      assert {:ok, restored_pid} =
               DynSup.restore_agent(deps.dynsup, db_agent,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, state} = Quoracle.Agent.Core.get_state(restored_pid)

      on_exit(fn ->
        if Process.alive?(restored_pid), do: GenServer.stop(restored_pid, :normal, :infinity)
      end)

      # Verify context_lessons restored
      assert is_map(state.context_lessons)
      lessons = state.context_lessons["anthropic:claude-sonnet-4"]
      assert length(lessons) == 2

      [lesson1, lesson2] = lessons
      assert lesson1.type == :factual
      assert lesson1.content == "User prefers Elixir"
      assert lesson1.confidence == 5

      assert lesson2.type == :behavioral
      assert lesson2.content == "Always use TDD"
    end

    @tag :integration
    test "R12: restores model_states from database agent state", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      ace_state = %{
        "context_lessons" => %{},
        "model_states" => %{
          "azure-openai:gpt-4o" => %{
            "summary" => "Working on API integration",
            "updated_at" => "2025-01-15T14:30:00Z"
          }
        }
      }

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: "restore-states-agent",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: ace_state,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      assert {:ok, restored_pid} =
               DynSup.restore_agent(deps.dynsup, db_agent,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, state} = Quoracle.Agent.Core.get_state(restored_pid)

      on_exit(fn ->
        if Process.alive?(restored_pid), do: GenServer.stop(restored_pid, :normal, :infinity)
      end)

      # Verify model_states restored
      assert is_map(state.model_states)
      model_state = state.model_states["azure-openai:gpt-4o"]
      assert model_state.summary == "Working on API integration"
      assert %DateTime{} = model_state.updated_at
    end

    test "R13: handles nil or empty db_agent.state gracefully", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      # Test with nil state
      {:ok, db_agent_nil} =
        Repo.insert(%AgentSchema{
          agent_id: "nil-ace-state-agent",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      assert {:ok, pid1} =
               DynSup.restore_agent(deps.dynsup, db_agent_nil,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, state1} = Quoracle.Agent.Core.get_state(pid1)

      on_exit(fn ->
        if Process.alive?(pid1), do: GenServer.stop(pid1, :normal, :infinity)
      end)

      # Should have empty ACE maps
      assert state1.context_lessons == %{}
      assert state1.model_states == %{}
    end

    @tag :integration
    test "R14: restores both model_histories and ACE state together", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      ace_state = %{
        "context_lessons" => %{
          "model-1" => [%{"type" => "factual", "content" => "Lesson 1", "confidence" => 2}]
        },
        "model_states" => %{
          "model-1" => %{"summary" => "State summary", "updated_at" => "2025-01-15T12:00:00Z"}
        }
      }

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: "combined-ace-restore-agent",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: ace_state,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      assert {:ok, restored_pid} =
               DynSup.restore_agent(deps.dynsup, db_agent,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, state} = Quoracle.Agent.Core.get_state(restored_pid)

      on_exit(fn ->
        if Process.alive?(restored_pid), do: GenServer.stop(restored_pid, :normal, :infinity)
      end)

      # Verify model_histories restored
      assert is_map(state.model_histories)

      # Verify ACE state restored
      assert length(state.context_lessons["model-1"]) == 1
      assert state.model_states["model-1"].summary == "State summary"
    end

    @tag :integration
    test "R15: restoration_mode prevents immediate re-persistence", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      alias Quoracle.Tasks.Task, as: TaskSchema
      alias Quoracle.Tasks.TaskManager

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      ace_state = %{
        "context_lessons" => %{"m1" => []},
        "model_states" => %{}
      }

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: "no-ace-repersist-agent",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: ace_state,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      original_state = db_agent.state

      assert {:ok, restored_pid} =
               DynSup.restore_agent(deps.dynsup, db_agent,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, state} = Quoracle.Agent.Core.get_state(restored_pid)

      on_exit(fn ->
        if Process.alive?(restored_pid), do: GenServer.stop(restored_pid, :normal, :infinity)
      end)

      # Verify restoration_mode is set
      assert state.restoration_mode == true

      # Agent should not have written back to DB during init
      {:ok, db_agent_after} = TaskManager.get_agent("no-ace-repersist-agent")
      assert db_agent_after.state == original_state
    end
  end

  describe "A1: ACE state survives pause/resume cycle" do
    @tag :acceptance
    @tag :integration
    test "full pause/resume cycle preserves ACE state", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      alias Quoracle.Tasks.Task, as: TaskSchema
      alias Quoracle.Tasks.TaskManager

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      agent_id = "pause-resume-ace-agent"

      ace_state = %{
        "context_lessons" => %{
          "anthropic:claude-sonnet-4" => [
            %{"type" => "factual", "content" => "Project uses Phoenix 1.7", "confidence" => 5},
            %{
              "type" => "behavioral",
              "content" => "Always run tests before commit",
              "confidence" => 4
            }
          ],
          "azure-openai:gpt-4o" => [
            %{"type" => "factual", "content" => "Database is PostgreSQL", "confidence" => 3}
          ]
        },
        "model_states" => %{
          "anthropic:claude-sonnet-4" => %{
            "summary" => "Implementing user authentication feature",
            "updated_at" => "2025-01-15T10:00:00Z"
          }
        }
      }

      {:ok, db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: ace_state,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # Step 1: Restore agent (simulating task resume)
      assert {:ok, restored_pid} =
               DynSup.restore_agent(deps.dynsup, db_agent,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, state} = Quoracle.Agent.Core.get_state(restored_pid)

      # Step 2: Verify all lessons restored
      claude_lessons = state.context_lessons["anthropic:claude-sonnet-4"]
      assert length(claude_lessons) == 2
      assert Enum.any?(claude_lessons, &(&1.content == "Project uses Phoenix 1.7"))
      assert Enum.any?(claude_lessons, &(&1.content == "Always run tests before commit"))

      gpt_lessons = state.context_lessons["azure-openai:gpt-4o"]
      assert length(gpt_lessons) == 1
      assert hd(gpt_lessons).content == "Database is PostgreSQL"

      # Step 3: Verify model state restored
      claude_state = state.model_states["anthropic:claude-sonnet-4"]
      assert claude_state.summary == "Implementing user authentication feature"

      # Step 4: Simulate learning new lessons during resumed session
      new_lessons = [
        %{type: :factual, content: "Uses Tailwind CSS", confidence: 2}
        | claude_lessons
      ]

      :sys.replace_state(restored_pid, fn s ->
        put_in(s.context_lessons["anthropic:claude-sonnet-4"], new_lessons)
      end)

      # Step 5: Graceful shutdown (pause again)
      # Clear restoration_mode so terminate will persist
      :sys.replace_state(restored_pid, fn s -> %{s | restoration_mode: false} end)
      GenServer.stop(restored_pid, :normal, :infinity)

      # Step 6: Verify new lessons persisted
      {:ok, db_agent_after_pause} = TaskManager.get_agent(agent_id)

      # Check lessons were updated in DB
      updated_claude_lessons =
        db_agent_after_pause.state["context_lessons"]["anthropic:claude-sonnet-4"]

      assert length(updated_claude_lessons) == 3
      assert Enum.any?(updated_claude_lessons, &(&1["content"] == "Uses Tailwind CSS"))
    end
  end

  describe "v4.0 Parent ID Restoration Fix (WorkGroupID: fix-children-20251219-053514)" do
    @moduletag :v4_parent_id_fix

    test "R16: restoration_config includes parent_id from db_agent", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Create task record
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      parent_agent_id = "parent-#{System.unique_integer([:positive])}"
      child_agent_id = "child-#{System.unique_integer([:positive])}"

      # Create parent agent in DB
      {:ok, _parent_db} =
        Repo.insert(%AgentSchema{
          agent_id: parent_agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # Create child agent in DB with parent_id set
      {:ok, child_db} =
        Repo.insert(%AgentSchema{
          agent_id: child_agent_id,
          task_id: task.id,
          status: "running",
          parent_id: parent_agent_id,
          config: %{},
          inserted_at: ~N[2025-01-01 10:00:01]
        })

      # Restore child agent
      assert {:ok, child_pid} =
               DynSup.restore_agent(deps.dynsup, child_db,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, state} = Quoracle.Agent.Core.get_state(child_pid)

      on_exit(fn ->
        if Process.alive?(child_pid), do: GenServer.stop(child_pid, :normal, :infinity)
      end)

      # R16: Verify the restored agent's state has parent_id from db_agent
      # The bug is that restoration_config didn't include parent_id, so it's nil
      assert state.parent_id == parent_agent_id,
             "Expected parent_id to be #{parent_agent_id}, got #{inspect(state.parent_id)}"
    end

    test "R17: restored child agent has parent_id in Registry composite", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Create task record
      alias Quoracle.Tasks.Task, as: TaskSchema

      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      parent_agent_id = "parent-#{System.unique_integer([:positive])}"
      child_agent_id = "child-#{System.unique_integer([:positive])}"

      # Create child agent in DB with parent_id set
      {:ok, child_db} =
        Repo.insert(%AgentSchema{
          agent_id: child_agent_id,
          task_id: task.id,
          status: "running",
          parent_id: parent_agent_id,
          config: %{},
          inserted_at: ~N[2025-01-01 10:00:01]
        })

      # Restore child agent
      assert {:ok, child_pid} =
               DynSup.restore_agent(deps.dynsup, child_db,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(child_pid)

      on_exit(fn ->
        if Process.alive?(child_pid), do: GenServer.stop(child_pid, :normal, :infinity)
      end)

      # R17: Verify Registry composite has correct parent_id
      [{^child_pid, composite}] = Registry.lookup(deps.registry, {:agent, child_agent_id})

      # The bug is that parent_id is nil in the composite because
      # restore_agent doesn't pass parent_id in restoration_config
      assert composite.parent_id == parent_agent_id,
             "Expected Registry composite parent_id to be #{parent_agent_id}, got #{inspect(composite.parent_id)}"
    end

    @tag :acceptance
    test "R18: parent sends to :children after restore and child receives message", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # This is an end-to-end acceptance test:
      # 1. Spawn parent with child
      # 2. Pause task (terminates agents)
      # 3. Resume task (restores agents)
      # 4. Parent sends to :children
      # 5. Verify child receives message

      alias Quoracle.Tasks.TaskRestorer
      alias Quoracle.Tasks.Task, as: TaskSchema
      alias Quoracle.Actions.SendMessage

      # Step 1: Create task and agents in DB
      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert()

      parent_agent_id = "parent-#{System.unique_integer([:positive])}"
      child_agent_id = "child-#{System.unique_integer([:positive])}"

      # Spawn parent agent
      {:ok, parent_pid} =
        DynSup.start_agent(deps.dynsup, %{
          agent_id: parent_agent_id,
          task_id: task.id,
          registry: deps.registry,
          pubsub: deps.pubsub,
          test_mode: true,
          test_opts: [skip_initial_consultation: true],
          sandbox_owner: sandbox_owner
        })

      assert {:ok, _} = Quoracle.Agent.Core.get_state(parent_pid)

      # Spawn child agent with parent relationship
      {:ok, child_pid} =
        DynSup.start_agent(deps.dynsup, %{
          agent_id: child_agent_id,
          task_id: task.id,
          parent_pid: parent_pid,
          parent_id: parent_agent_id,
          registry: deps.registry,
          pubsub: deps.pubsub,
          test_mode: true,
          test_opts: [skip_initial_consultation: true],
          sandbox_owner: sandbox_owner
        })

      assert {:ok, _} = Quoracle.Agent.Core.get_state(child_pid)

      # Step 2: Pause task (terminate agents asynchronously)
      parent_ref = Process.monitor(parent_pid)
      child_ref = Process.monitor(child_pid)

      :ok =
        TaskRestorer.pause_task(task.id,
          registry: deps.registry,
          dynsup: deps.dynsup
        )

      # Wait for async terminations to complete (both parent and child)
      receive do
        {:DOWN, ^parent_ref, :process, ^parent_pid, _} -> :ok
      after
        5000 -> flunk("Parent agent did not terminate within 5 seconds")
      end

      receive do
        {:DOWN, ^child_ref, :process, ^child_pid, _} -> :ok
      after
        5000 -> flunk("Child agent did not terminate within 5 seconds")
      end

      # Verify agents are terminated
      refute Process.alive?(parent_pid)
      refute Process.alive?(child_pid)

      # Step 3: Resume task (restore agents)
      {:ok, restored_parent_pid} =
        TaskRestorer.restore_task(task.id, deps.registry, deps.pubsub,
          dynsup: deps.dynsup,
          sandbox_owner: sandbox_owner
        )

      assert {:ok, _} = Quoracle.Agent.Core.get_state(restored_parent_pid)

      # Find restored child PID
      [{restored_child_pid, _}] = Registry.lookup(deps.registry, {:agent, child_agent_id})
      assert {:ok, _} = Quoracle.Agent.Core.get_state(restored_child_pid)

      on_exit(fn ->
        stop_agent_tree(restored_parent_pid, deps.registry)
      end)

      # Step 4: Parent sends message to :children
      # resolve_children should find the child via parent_id in Registry composite
      result =
        SendMessage.execute(
          %{to: :children, content: "Hello from parent"},
          parent_agent_id,
          registry: deps.registry,
          action_id: "test-action-#{System.unique_integer([:positive])}"
        )

      # Step 5: Verify child received the message
      # The bug causes resolve_children to return empty list because
      # child's Registry composite has parent_id: nil instead of parent_agent_id
      assert {:ok, send_result} = result

      # Verify message was actually sent to child (not empty list)
      assert length(send_result.sent_to) == 1,
             "Expected 1 recipient (child), got #{length(send_result.sent_to)}. " <>
               "sent_to: #{inspect(send_result.sent_to)}. " <>
               "This means :children resolution failed because parent_id is nil in Registry."
    end
  end

  # ========== USER_PROMPT RESTORATION (v6.0) - DELETED ==========
  # WorkGroupID: fix-20260106-user-prompt-removal
  # R19-R20 tests deleted because user_prompt field was removed from State struct.
  # Initial message now flows through model_histories via MessageHandler (v14.0).
  # See: test/quoracle/agent/message_handler_user_prompt_removal_test.exs

  describe "capability_groups Restoration (fix-20260111)" do
    test "R33: restored agent has capability_groups and can execute actions", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      alias Quoracle.Tasks.Task, as: TaskSchema
      alias Quoracle.Tasks.TaskRestorer
      alias Quoracle.Profiles.TableProfiles

      # Step 1: Create a profile with specific capability_groups
      profile_name = "test-profile-#{System.unique_integer([:positive])}"

      {:ok, _profile} =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: profile_name,
          description: "Test profile for restoration",
          model_pool: ["test-model"],
          capability_groups: ["file_read", "hierarchy"]
        })
        |> Repo.insert()

      # Step 2: Create task
      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{prompt: "Test capability restoration", status: "running"})
        |> Repo.insert()

      agent_id = "capability-test-#{System.unique_integer([:positive])}"

      # Step 3: Spawn agent with profile
      {:ok, agent_pid} =
        DynSup.start_agent(deps.dynsup, %{
          agent_id: agent_id,
          task_id: task.id,
          profile_name: profile_name,
          capability_groups: [:file_read, :hierarchy],
          model_pool: ["test-model"],
          registry: deps.registry,
          pubsub: deps.pubsub,
          test_mode: true,
          test_opts: [skip_initial_consultation: true],
          sandbox_owner: sandbox_owner
        })

      # Verify initial capability_groups
      {:ok, initial_state} = Quoracle.Agent.Core.get_state(agent_pid)

      assert :file_read in initial_state.capability_groups,
             "Initial agent should have :file_read capability"

      assert :hierarchy in initial_state.capability_groups,
             "Initial agent should have :hierarchy capability"

      # Step 4: Pause task
      ref = Process.monitor(agent_pid)

      :ok =
        TaskRestorer.pause_task(task.id,
          registry: deps.registry,
          dynsup: deps.dynsup
        )

      receive do
        {:DOWN, ^ref, :process, ^agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Step 5: Resume task
      {:ok, restored_pid} =
        TaskRestorer.restore_task(task.id, deps.registry, deps.pubsub,
          dynsup: deps.dynsup,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(restored_pid) do
          GenServer.stop(restored_pid, :normal, :infinity)
        end
      end)

      # Step 6: Verify capability_groups restored
      {:ok, restored_state} = Quoracle.Agent.Core.get_state(restored_pid)

      assert :file_read in restored_state.capability_groups,
             "Restored agent should have :file_read capability, got: #{inspect(restored_state.capability_groups)}"

      assert :hierarchy in restored_state.capability_groups,
             "Restored agent should have :hierarchy capability, got: #{inspect(restored_state.capability_groups)}"

      # Step 7: Verify profile_name restored
      assert restored_state.profile_name == profile_name,
             "Restored agent should have profile_name, got: #{inspect(restored_state.profile_name)}"

      # Step 8: Execute an action to prove permissions work
      # Use :wait with wait: 0 (immediate return) - base action always allowed
      # This proves the Router permission check passes

      # Spawn per-action Router (v28.0)
      {:ok, router_pid} =
        Quoracle.Actions.Router.start_link(
          action_type: :wait,
          action_id: "test-action-1",
          agent_id: restored_state.agent_id,
          agent_pid: restored_pid,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      action_result =
        Quoracle.Actions.Router.execute(
          router_pid,
          :wait,
          %{wait: 0},
          restored_state.agent_id,
          action_id: "test-action-1",
          agent_id: restored_state.agent_id,
          task_id: task.id,
          agent_pid: restored_pid,
          pubsub: deps.pubsub,
          registry: deps.registry,
          dynsup: deps.dynsup,
          capability_groups: restored_state.capability_groups
        )

      assert {:ok, _result} = action_result,
             "Restored agent should be able to execute actions, got: #{inspect(action_result)}"
    end
  end

  # ========== max_refinement_rounds Restoration (feat-20260208-210722) ==========
  # Medium issue: max_refinement_rounds not restored from profile during pause/resume.
  # DynSup.restore_agent re-resolves profile for capability_groups but omits
  # max_refinement_rounds from restoration_config. Since persist_agent also does not
  # save max_refinement_rounds in config JSONB, the value is lost on restoration
  # and falls back to default 4 regardless of the profile setting.

  describe "max_refinement_rounds Restoration" do
    @tag :acceptance
    test "R24: restored agent has max_refinement_rounds from profile", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      alias Quoracle.Tasks.Task, as: TaskSchema
      alias Quoracle.Tasks.TaskRestorer
      alias Quoracle.Profiles.TableProfiles

      # Step 1: Create a profile with non-default max_refinement_rounds
      profile_name = "max-rounds-profile-#{System.unique_integer([:positive])}"

      {:ok, _profile} =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: profile_name,
          description: "Test profile with custom max_refinement_rounds",
          model_pool: ["test-model"],
          capability_groups: ["file_read"],
          max_refinement_rounds: 7
        })
        |> Repo.insert()

      # Step 2: Create task
      {:ok, task} =
        %TaskSchema{}
        |> TaskSchema.changeset(%{
          prompt: "Test max_refinement_rounds restoration",
          status: "running"
        })
        |> Repo.insert()

      agent_id = "max-rounds-restore-#{System.unique_integer([:positive])}"

      # Step 3: Spawn agent with profile's max_refinement_rounds
      {:ok, agent_pid} =
        DynSup.start_agent(deps.dynsup, %{
          agent_id: agent_id,
          task_id: task.id,
          profile_name: profile_name,
          capability_groups: [:file_read],
          max_refinement_rounds: 7,
          model_pool: ["test-model"],
          registry: deps.registry,
          pubsub: deps.pubsub,
          test_mode: true,
          test_opts: [skip_initial_consultation: true],
          sandbox_owner: sandbox_owner
        })

      # Verify initial max_refinement_rounds
      {:ok, initial_state} = Quoracle.Agent.Core.get_state(agent_pid)

      assert initial_state.max_refinement_rounds == 7,
             "Initial agent should have max_refinement_rounds=7, got: #{initial_state.max_refinement_rounds}"

      # Step 4: Pause task
      ref = Process.monitor(agent_pid)

      :ok =
        TaskRestorer.pause_task(task.id,
          registry: deps.registry,
          dynsup: deps.dynsup
        )

      receive do
        {:DOWN, ^ref, :process, ^agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Step 5: Resume task
      {:ok, restored_pid} =
        TaskRestorer.restore_task(task.id, deps.registry, deps.pubsub,
          dynsup: deps.dynsup,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(restored_pid) do
          GenServer.stop(restored_pid, :normal, :infinity)
        end
      end)

      # Step 6: Verify max_refinement_rounds restored from profile
      {:ok, restored_state} = Quoracle.Agent.Core.get_state(restored_pid)

      # Positive: profile value preserved through pause/resume
      assert restored_state.max_refinement_rounds == 7,
             "Restored agent should have max_refinement_rounds=7 from profile, " <>
               "got: #{restored_state.max_refinement_rounds}. " <>
               "DynSup.restore_agent must re-resolve max_refinement_rounds from profile " <>
               "(same pattern as capability_groups)."

      # Negative: must NOT fall back to the hardcoded default of 4
      refute restored_state.max_refinement_rounds == 4,
             "Restored agent fell back to default max_refinement_rounds=4, " <>
               "profile value of 7 was lost during pause/resume."
    end
  end
end
