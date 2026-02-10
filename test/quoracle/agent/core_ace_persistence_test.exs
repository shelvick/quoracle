defmodule Quoracle.Agent.CoreACEPersistenceTest do
  @moduledoc """
  Tests for AGENT_Core ACE state persistence on terminate.

  Packet 1: AGENT_Core v17.0 - R12-R15, A2
  WorkGroupID: fix-persistence-20251218-185708
  """
  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog
  import Test.IsolationHelpers
  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core
  alias Quoracle.Agent.Core.Persistence
  alias Quoracle.Tasks.TaskManager
  alias Quoracle.Tasks.Task
  alias Quoracle.Repo

  # ========== TERMINATE PERSISTENCE (R12-R15) ==========

  describe "terminate/2 - ACE persistence" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      agent_id = "terminate-ace-agent-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        task_id: task.id,
        initial_prompt: "Test agent for ACE persistence",
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      [
        task_id: task.id,
        agent_id: agent_id,
        agent_pid: pid,
        deps: deps,
        sandbox_owner: sandbox_owner
      ]
    end

    @tag :integration
    test "R12: persists ACE state on graceful terminate", %{
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      # Set up ACE state in the agent
      {:ok, state} = Core.get_state(agent_pid)

      # Manually add ACE state (simulating what would happen after condensation)
      # This would normally be done by the consensus condensation process
      updated_state = %{
        state
        | context_lessons: %{
            "test-model" => [%{type: :factual, content: "Test lesson", confidence: 2}]
          },
          model_states: %{
            "test-model" => %{summary: "Test state", updated_at: DateTime.utc_now()}
          }
      }

      # Update agent state directly (for test setup)
      :sys.replace_state(agent_pid, fn _old -> updated_state end)

      # Stop agent gracefully (triggers terminate/2)
      GenServer.stop(agent_pid, :normal, :infinity)

      # Verify ACE state was persisted to database
      {:ok, db_agent} = TaskManager.get_agent(agent_id)

      # The state column should now have ACE data
      assert is_map(db_agent.state)
      assert Map.has_key?(db_agent.state, "context_lessons")
      assert Map.has_key?(db_agent.state, "model_states")

      # Verify content
      lessons = db_agent.state["context_lessons"]["test-model"]
      assert length(lessons) == 1
      assert hd(lessons)["content"] == "Test lesson"
    end

    @tag :integration
    test "R13: persists ACE state on terminate even in restoration mode", %{
      deps: deps,
      task_id: task_id,
      sandbox_owner: sandbox_owner
    } do
      # Note: restoration_mode only prevents initial persist_agent (INSERT).
      # Terminate should still persist ACE state (UPDATE) to preserve learned context.
      agent_id = "restored-terminate-agent-#{System.unique_integer([:positive])}"

      # Create agent record manually (simulating restore scenario)
      alias Quoracle.Agents.Agent, as: AgentSchema

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task_id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil
        })

      # Spawn with restoration_mode
      config = %{
        agent_id: agent_id,
        task_id: task_id,
        restoration_mode: true,
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Add ACE state
      :sys.replace_state(pid, fn state ->
        %{
          state
          | context_lessons: %{"m1" => [%{type: :factual, content: "x", confidence: 1}]},
            model_states: %{}
        }
      end)

      # Stop agent
      GenServer.stop(pid, :normal, :infinity)

      # Verify ACE state WAS persisted (restoration_mode doesn't block terminate persistence)
      {:ok, db_agent} = TaskManager.get_agent(agent_id)
      assert Map.has_key?(db_agent.state, "context_lessons")
    end

    @tag :integration
    test "R14: skips persistence on terminate without task_id", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "no-task-terminate-agent-#{System.unique_integer([:positive])}"

      # Spawn agent without task_id
      config = %{
        agent_id: agent_id,
        task_id: nil,
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Add ACE state
      :sys.replace_state(pid, fn state ->
        %{
          state
          | context_lessons: %{"m1" => []},
            model_states: %{}
        }
      end)

      # Stop agent - should not crash trying to persist
      GenServer.stop(pid, :normal, :infinity)

      # Verify agent is stopped (no crash)
      refute Process.alive?(pid)
    end

    @tag :integration
    test "R15: termination continues even if persistence fails", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Use a non-existent task_id to trigger persistence failure
      fake_task_id = Ecto.UUID.generate()
      agent_id = "fail-persist-terminate-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        task_id: fake_task_id,
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      log =
        capture_log(fn ->
          {:ok, pid} =
            spawn_agent_with_cleanup(deps.dynsup, config,
              registry: deps.registry,
              pubsub: deps.pubsub
            )

          # Add ACE state
          :sys.replace_state(pid, fn state ->
            %{state | context_lessons: %{"m1" => []}, model_states: %{}}
          end)

          # Stop agent - should complete without crash despite persistence failure
          GenServer.stop(pid, :normal, :infinity)

          # Agent should be stopped
          refute Process.alive?(pid)
        end)

      # May log error about persistence failure, but should not crash
      # The log could be empty if error is silently handled
      assert is_binary(log)
    end
  end

  # ========== ACCEPTANCE TEST (A2) ==========

  describe "A2: ACE state survives graceful shutdown" do
    @tag :acceptance
    @tag :integration
    test "graceful shutdown preserves ACE state for later restoration", %{
      sandbox_owner: sandbox_owner
    } do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      agent_id = "ace-survive-agent-#{System.unique_integer([:positive])}"

      # Step 1: Create agent with initial state
      config = %{
        agent_id: agent_id,
        task_id: task.id,
        initial_prompt: "ACE survival test",
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          skip_cleanup: true
        )

      # Step 2: Simulate learned lessons (normally from condensation)
      original_lessons = [
        %{type: :factual, content: "User is working on Elixir project", confidence: 5},
        %{type: :behavioral, content: "Prefers TDD approach", confidence: 3}
      ]

      original_state = %{
        summary: "Implementing authentication module",
        updated_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn state ->
        %{
          state
          | context_lessons: %{"anthropic:claude-sonnet-4" => original_lessons},
            model_states: %{"anthropic:claude-sonnet-4" => original_state}
        }
      end)

      # Step 3: Graceful shutdown (simulates task pause)
      GenServer.stop(pid, :normal, :infinity)

      # Step 4: Verify ACE state was persisted
      {:ok, db_agent} = TaskManager.get_agent(agent_id)
      assert is_map(db_agent.state), "ACE state should be persisted to database"

      # Negative assertions - verify absence of broken states
      refute db_agent.state == %{}, "State should not be empty after persistence"
      refute is_nil(db_agent.state["context_lessons"]), "context_lessons should not be nil"
      refute is_nil(db_agent.state["model_states"]), "model_states should not be nil"

      # Step 5: Restore ACE state (simulating task resume)
      restored_ace = Persistence.restore_ace_state(db_agent)

      # Negative assertions - verify restoration produced valid structures
      refute is_nil(restored_ace.context_lessons), "Restored lessons should not be nil"
      refute is_nil(restored_ace.model_states), "Restored states should not be nil"

      # Step 6: Verify lessons preserved
      restored_lessons = restored_ace.context_lessons["anthropic:claude-sonnet-4"]
      refute is_nil(restored_lessons), "Lessons for model should not be nil"
      refute restored_lessons == [], "Lessons should not be empty"
      assert length(restored_lessons) == 2, "Should have 2 lessons"
      assert Enum.any?(restored_lessons, &(&1.content == "User is working on Elixir project"))
      assert Enum.any?(restored_lessons, &(&1.content == "Prefers TDD approach"))

      # Step 7: Verify state preserved
      restored_state = restored_ace.model_states["anthropic:claude-sonnet-4"]
      refute is_nil(restored_state), "Model state should not be nil"
      assert restored_state.summary == "Implementing authentication module"
    end
  end
end
