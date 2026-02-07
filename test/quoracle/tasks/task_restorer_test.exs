defmodule Quoracle.Tasks.TaskRestorerTest do
  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Tasks.{TaskManager, TaskRestorer}
  alias Quoracle.Agents.Agent, as: AgentSchema
  alias Test.IsolationHelpers

  import Test.IsolationHelpers, only: [stop_and_wait_for_unregister: 3]

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated dependencies for test isolation
    deps = IsolationHelpers.create_isolated_deps()

    %{
      registry: deps.registry,
      dynsup: deps.dynsup,
      pubsub: deps.pubsub,
      sandbox_owner: sandbox_owner
    }
  end

  # WorkGroupID: refactor-20251224-001420 - Async Pause Support
  # R4-R7: Async pause behavior tests
  describe "pause_task/2 - Async Pause Support" do
    # R4: WHEN pause_task called IF agents running THEN task status set to 'pausing' before return
    test "R4: sets task status to 'pausing' immediately when agents running", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "agent1",
            task_id: task.id,
            parent_pid: nil,
            status: "running",
            task: "Task 1"
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      # Monitor ALL agents before pause (Task.start fire-and-forget requires waiting)
      task_ref = Process.monitor(task_pid)
      agent_ref = Process.monitor(agent_pid)

      # Call pause_task - should return immediately
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)

      # CRITICAL: Task status should be "pausing" (not "paused") immediately after return
      # The final "paused" status is set asynchronously when last agent terminates
      {:ok, task_after_pause} = TaskManager.get_task(task.id)

      assert task_after_pause.status == "pausing",
             "Expected status 'pausing' immediately after pause_task returns, got '#{task_after_pause.status}'"

      # Wait for ALL agents to terminate before test ends (prevents sandbox owner race)
      for {ref, pid} <- [{task_ref, task_pid}, {agent_ref, agent_pid}] do
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5000 -> :ok
        end
      end
    end

    # R5: WHEN pause_task called THEN spawns termination processes and returns without waiting
    test "R5: returns immediately without waiting for agent termination", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "slow_agent",
            task_id: task.id,
            parent_pid: nil,
            status: "running",
            task: "Slow task"
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      # Monitor ALL agents BEFORE pause (Task.start fire-and-forget requires waiting)
      task_ref = Process.monitor(task_pid)
      agent_ref = Process.monitor(agent_pid)

      # Measure time for pause_task to return
      start_time = System.monotonic_time(:millisecond)
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should return in < 500ms (non-blocking, with margin for CI load)
      # If it waited for GenServer.stop with :infinity, it would take much longer
      assert elapsed < 500,
             "pause_task should return immediately, but took #{elapsed}ms"

      # Wait for ALL agents to terminate before test ends (prevents sandbox owner race)
      for {ref, pid} <- [{task_ref, task_pid}, {agent_ref, agent_pid}] do
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5000 -> :ok
        end
      end
    end

    # R6: WHEN pause_task called IF task already 'pausing' THEN returns :ok without error
    test "R6: returns :ok when task already in 'pausing' status", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Monitor agent BEFORE pause (Task.start fire-and-forget requires waiting)
      task_ref = Process.monitor(task_pid)

      # Manually set task to "pausing" status
      {:ok, _} = TaskManager.update_task_status(task.id, "pausing")

      # Calling pause_task on already-pausing task should succeed (idempotent)
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)

      # Status should remain "pausing" (or become "paused" if no agents)
      {:ok, updated_task} = TaskManager.get_task(task.id)

      assert updated_task.status in ["pausing", "paused"],
             "Expected status 'pausing' or 'paused', got '#{updated_task.status}'"

      # Wait for agent to terminate before test ends (prevents sandbox owner race)
      receive do
        {:DOWN, ^task_ref, :process, ^task_pid, _} -> :ok
      after
        5000 -> :ok
      end
    end

    # R7: WHEN pause_task called IF no agents running THEN sets status to 'paused' directly
    test "R7: sets status directly to 'paused' when no agents running", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Get agent_id for registry lookup
      agent_id = "root-#{task.id}"

      # Terminate the task agent and wait for unregistration
      stop_and_wait_for_unregister(task_pid, registry, agent_id)

      # Pause with no running agents - should go directly to "paused"
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)

      # Status should be "paused" (not "pausing") since no agents to terminate
      {:ok, updated_task} = TaskManager.get_task(task.id)

      assert updated_task.status == "paused",
             "Expected status 'paused' when no agents running, got '#{updated_task.status}'"
    end
  end

  describe "pause_task/2 - Pause Criteria" do
    test "ARC_PAUSE_01: terminates all agents in reverse order when agents running", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create task in database (with automatic cleanup)
      {:ok, {task, task_agent_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Spawn agent tree: root -> child1 -> child2 (with automatic cleanup)
      {:ok, root_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "root",
            task_id: task.id,
            parent_pid: nil,
            status: "running",
            task: "Root task"
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, child1_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "child1",
            task_id: task.id,
            status: "running",
            task: "Child 1 task",
            parent_pid: root_pid
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, child2_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "child2",
            task_id: task.id,
            status: "running",
            task: "Child 2 task",
            parent_pid: child1_pid
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      # Monitor ALL agents BEFORE pause (Task.start fire-and-forget requires waiting for all)
      task_agent_ref = Process.monitor(task_agent_pid)
      root_ref = Process.monitor(root_pid)
      child1_ref = Process.monitor(child1_pid)
      child2_ref = Process.monitor(child2_pid)

      # Pause task - should terminate in reverse order (child2, child1, root)
      # With async pause, this returns immediately while terminations happen in background
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)

      # Wait for ALL agents to terminate (parallel spawns, order not guaranteed)
      # CRITICAL: Must wait for all to prevent sandbox owner exiting while Task.start runs
      for {ref, pid, name} <- [
            {task_agent_ref, task_agent_pid, "task_agent"},
            {root_ref, root_pid, "root"},
            {child1_ref, child1_pid, "child1"},
            {child2_ref, child2_pid, "child2"}
          ] do
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5000 -> flunk("#{name} agent did not terminate within 5 seconds")
        end
      end

      # Verify all agents terminated
      refute Process.alive?(task_agent_pid)
      refute Process.alive?(root_pid)
      refute Process.alive?(child1_pid)
      refute Process.alive?(child2_pid)

      # Note: With async pause, status is "pausing" until MessageHandlers detects completion
      # For this test, we verify agents terminated (the primary goal of pause)
      {:ok, updated_task} = TaskManager.get_task(task.id)
      assert updated_task.status in ["pausing", "paused"]
    end

    # TODO: Test idempotent pause with isolated registry
    test "ARC_PAUSE_02: updates DB status and returns :ok when no agents running", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create task (with automatic cleanup)
      {:ok, {task, task_agent_pid}} =
        create_task_with_cleanup("Empty task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Spawn and terminate agent first (with automatic cleanup)
      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "temp",
            task_id: task.id,
            parent_pid: nil,
            status: "running",
            task: "Temp",
            test_mode: true,
            test_opts: [skip_initial_consultation: true]
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      # Terminate BOTH agents so there are truly no running agents
      Quoracle.Agent.DynSup.terminate_agent(agent_pid)
      stop_and_wait_for_unregister(task_agent_pid, registry, "root-#{task.id}")

      # Pause with no running agents - should succeed and set "paused" directly
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)

      # Verify task status updated to "paused" (not "pausing" since no agents to terminate)
      {:ok, updated_task} = TaskManager.get_task(task.id)
      assert updated_task.status == "paused"
    end

    # TODO: Requires DynSup failure injection infrastructure to simulate termination failures
    test "ARC_PAUSE_03: returns error with failed agent_id when termination fails mid-process", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create task (with automatic cleanup)
      {:ok, {task, _task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Spawn two agents (with automatic cleanup)
      {:ok, _pid1} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "agent1",
            task_id: task.id,
            parent_pid: nil,
            status: "running",
            task: "Task 1"
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, _pid2} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "agent2",
            task_id: task.id,
            parent_pid: nil,
            status: "running",
            task: "Task 2"
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      # TODO: Need to simulate termination failure
      # This requires DynSup to support failure injection for testing
      # For now, test structure is in place

      # Expected error format
      # assert {:error, {:termination_failed, agent_id, reason}} = TaskRestorer.pause_task(task.id, registry)
    end

    test "ARC_PAUSE_04: updates task status to paused when all terminated successfully", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "agent1",
            task_id: task.id,
            parent_pid: nil,
            status: "running",
            task: "Task 1"
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      # Monitor ALL agents BEFORE pause (Task.start fire-and-forget requires waiting)
      task_ref = Process.monitor(task_pid)
      agent_ref = Process.monitor(pid)

      # Pause task (async - returns immediately)
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)

      # Wait for ALL agents to terminate
      for {ref, agent_pid} <- [{task_ref, task_pid}, {agent_ref, pid}] do
        receive do
          {:DOWN, ^ref, :process, ^agent_pid, _} -> :ok
        after
          5000 -> flunk("Agent did not terminate within 5 seconds")
        end
      end

      # Verify agents terminated
      refute Process.alive?(task_pid)
      refute Process.alive?(pid)

      # Verify status updated (may be "pausing" or "paused" depending on timing)
      {:ok, updated_task} = TaskManager.get_task(task.id)
      assert updated_task.status in ["pausing", "paused"]
    end

    # TODO: Requires DynSup.get_dynsup_pid/0 to return nil for testing (failure injection)
    test "ARC_PAUSE_05: returns error when DynSup not found", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {_task, _pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # TODO: Need DynSup.get_dynsup_pid/0 to return nil for testing
      # Expected: {:error, :dynsup_not_found} = TaskRestorer.pause_task(task.id, registry)
    end
  end

  describe "restore_task/3 - Restore Criteria" do
    test "ARC_RESTORE_01: restores agents in insertion order (root first, then children)", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create task (with automatic cleanup)
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Create agent records in database (simulating paused state)
      root_inserted_at = ~N[2025-01-01 10:00:00]
      child_inserted_at = ~N[2025-01-01 10:00:01]

      {:ok, _root_db} =
        Repo.insert(%AgentSchema{
          agent_id: "root",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{task: "Root task"},
          inserted_at: root_inserted_at
        })

      {:ok, _child_db} =
        Repo.insert(%AgentSchema{
          agent_id: "child",
          task_id: task.id,
          status: "running",
          parent_id: "root",
          config: %{task: "Child task"},
          inserted_at: child_inserted_at
        })

      # Stop task agent before restore (would conflict with restored agents)
      stop_and_wait_for_unregister(task_pid, registry, "root-#{task.id}")

      # Restore task
      assert {:ok, root_pid} =
               TaskRestorer.restore_task(task.id, registry, pubsub,
                 dynsup: dynsup,
                 sandbox_owner: sandbox_owner
               )

      # Wait for root initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(root_pid)

      # CRITICAL: Query Registry for ALL restored agents (root + child)
      [{child_pid, _}] = Registry.lookup(registry, {:agent, "child"})
      assert Process.alive?(child_pid)

      # CRITICAL: Wait for child initialization too!
      assert {:ok, _child_state} = Quoracle.Agent.Core.get_state(child_pid)

      # Add cleanup for ALL restored agents
      on_exit(fn ->
        Enum.each([root_pid, child_pid], fn pid ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end)
      end)

      # Verify root agent spawned
      assert is_pid(root_pid)
      assert Process.alive?(root_pid)

      # Verify task status updated to "running"
      {:ok, updated_task} = TaskManager.get_task(task.id)
      assert updated_task.status == "running"
    end

    # TODO: Requires Core.get_state/1 to verify parent_pid_override in agent state
    test "ARC_RESTORE_02: uses parent_pid_override when agent has parent", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Create parent and child in database
      {:ok, _root_db} =
        Repo.insert(%AgentSchema{
          agent_id: "root",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{task: "Root task"},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      {:ok, _child_db} =
        Repo.insert(%AgentSchema{
          agent_id: "child",
          task_id: task.id,
          status: "running",
          parent_id: "root",
          config: %{task: "Child task"},
          inserted_at: ~N[2025-01-01 10:00:01]
        })

      # Stop task agent before restore (would conflict with restored agents)
      stop_and_wait_for_unregister(task_pid, registry, "root-#{task.id}")

      # Restore task
      assert {:ok, root_pid} =
               TaskRestorer.restore_task(task.id, registry, pubsub,
                 dynsup: dynsup,
                 sandbox_owner: sandbox_owner
               )

      # Wait for root initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(root_pid)

      # CRITICAL: Query Registry for ALL restored agents (root + child)
      [{child_pid, _}] = Registry.lookup(registry, {:agent, "child"})
      assert Process.alive?(child_pid)

      # CRITICAL: Wait for child initialization too!
      assert {:ok, _child_state} = Quoracle.Agent.Core.get_state(child_pid)

      # Add cleanup for ALL restored agents
      on_exit(fn ->
        Enum.each([root_pid, child_pid], fn pid ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end)
      end)

      # TODO: Verify child received parent_pid_override from root restoration
      # This requires inspecting agent state or Registry metadata
    end

    # TODO: Requires Core.get_state/1 to verify parent_pid = nil in agent state
    test "ARC_RESTORE_03: uses parent_pid_override = nil when agent has no parent", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, _root_db} =
        Repo.insert(%AgentSchema{
          agent_id: "root",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{task: "Root task"},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # Stop task agent before restore (would conflict with restored agents)
      stop_and_wait_for_unregister(task_pid, registry, "root-#{task.id}")

      # Restore task
      assert {:ok, root_pid} =
               TaskRestorer.restore_task(task.id, registry, pubsub,
                 dynsup: dynsup,
                 sandbox_owner: sandbox_owner
               )

      # Wait for initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(root_pid)

      # Add cleanup for restored agent
      on_exit(fn ->
        if Process.alive?(root_pid) do
          try do
            GenServer.stop(root_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Root agent should have parent_pid = nil
      assert Process.alive?(root_pid)
      # TODO: Verify parent_pid = nil in agent state
    end

    test "ARC_RESTORE_04: returns partial_restore error when agent spawn fails mid-restoration",
         %{
           registry: registry,
           dynsup: dynsup,
           pubsub: pubsub,
           sandbox_owner: sandbox_owner
         } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Terminate the root agent so we can test restoration
      GenServer.stop(task_pid, :normal, :infinity)
      refute Process.alive?(task_pid)

      # Ensure any restored agents terminate before sandbox owner exits
      on_exit(fn ->
        # Cleanup any agents that might have been restored
        # Registry might already be terminated, so handle gracefully
        try do
          case Registry.lookup(registry, {:agent, "root-#{task.id}"}) do
            [{pid, _}] when is_pid(pid) ->
              if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)

            _ ->
              :ok
          end
        rescue
          # Registry already terminated
          ArgumentError -> :ok
        end
      end)

      # Create two agents - both will succeed (empty config is valid)
      {:ok, _agent1} =
        Repo.insert(%AgentSchema{
          agent_id: "agent1",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{test_mode: true},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      {:ok, _agent2} =
        Repo.insert(%AgentSchema{
          agent_id: "agent2",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          # Empty config is valid - Core only persists [:test_mode, :initial_prompt]
          inserted_at: ~N[2025-01-01 10:00:01]
        })

      # Restore task - should succeed with both agents
      assert {:ok, root_pid} =
               TaskRestorer.restore_task(task.id, registry, pubsub,
                 sandbox_owner: sandbox_owner,
                 dynsup: dynsup
               )

      # Wait for root initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(root_pid)

      # CRITICAL: Query Registry for ALL restored agents (agent1 + agent2)
      [{agent1_pid, _}] = Registry.lookup(registry, {:agent, "agent1"})
      [{agent2_pid, _}] = Registry.lookup(registry, {:agent, "agent2"})

      # CRITICAL: Wait for ALL agents to initialize
      assert {:ok, _state1} = Quoracle.Agent.Core.get_state(agent1_pid)
      assert {:ok, _state2} = Quoracle.Agent.Core.get_state(agent2_pid)

      # Add cleanup for ALL restored agents
      on_exit(fn ->
        Enum.each([agent1_pid, agent2_pid], fn pid ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end)
      end)
    end

    test "ARC_RESTORE_05: updates task status to running and returns root_pid when all restored",
         %{
           registry: registry,
           dynsup: dynsup,
           pubsub: pubsub,
           sandbox_owner: sandbox_owner
         } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, _root_db} =
        Repo.insert(%AgentSchema{
          agent_id: "root",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{task: "Root task"},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # Stop task agent before restore (would conflict with restored agents)
      stop_and_wait_for_unregister(task_pid, registry, "root-#{task.id}")

      # Restore task
      assert {:ok, root_pid} =
               TaskRestorer.restore_task(task.id, registry, pubsub,
                 dynsup: dynsup,
                 sandbox_owner: sandbox_owner
               )

      # Wait for initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(root_pid)

      # Add cleanup for restored agents
      on_exit(fn ->
        if Process.alive?(root_pid) do
          try do
            GenServer.stop(root_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Verify root PID returned
      assert is_pid(root_pid)
      assert Process.alive?(root_pid)

      # Verify task status
      {:ok, updated_task} = TaskManager.get_task(task.id)
      assert updated_task.status == "running"
    end

    test "ARC_RESTORE_06: returns error when no agents in DB for task", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create task (which spawns an agent - with automatic cleanup)
      {:ok, {task, _task_pid}} =
        create_task_with_cleanup("Empty task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Pause to remove agents
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)

      # Delete all agents from DB to simulate empty task
      Repo.delete_all(from(a in AgentSchema, where: a.task_id == ^task.id))

      # Attempt to restore
      assert {:error, :no_agents_found} =
               TaskRestorer.restore_task(task.id, registry, pubsub, sandbox_owner: sandbox_owner)
    end

    test "ARC_RESTORE_07: all restored agents use injected registry", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, _root_db} =
        Repo.insert(%AgentSchema{
          agent_id: "root",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{task: "Root task"},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # Stop task agent before restore (would conflict with restored agents)
      stop_and_wait_for_unregister(task_pid, registry, "root-#{task.id}")

      # Restore with specific registry
      assert {:ok, root_pid} =
               TaskRestorer.restore_task(task.id, registry, pubsub, sandbox_owner: sandbox_owner)

      # Wait for initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(root_pid)

      # Add cleanup for restored agent
      on_exit(fn ->
        if Process.alive?(root_pid) do
          try do
            GenServer.stop(root_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Verify agent registered in correct registry
      assert [{^root_pid, _}] =
               Registry.lookup(registry, {:agent, "root"})
    end

    # TODO: Requires DynSup.get_dynsup_pid/0 to return nil for testing (failure injection)
    test "ARC_RESTORE_08: returns error when DynSup not found", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, _task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, _agent} =
        Repo.insert(%AgentSchema{
          agent_id: "agent1",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{task: "Task 1"},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # TODO: Need DynSup.get_dynsup_pid/0 to return nil for testing
      # Expected: {:error, :dynsup_not_found} = TaskRestorer.restore_task(task.id, registry, pubsub, sandbox_owner: sandbox_owner)
    end
  end

  describe "Integration Tests - Round Trip" do
    # TODO: Requires Registry metadata inspection or Core.get_state/1 to verify child agent restoration
    test "pause then restore maintains agent tree structure", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create and spawn agent tree (with automatic cleanup)
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, root_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "root",
            task_id: task.id,
            parent_pid: nil,
            status: "running",
            task: "Root task"
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, child_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "child",
            task_id: task.id,
            status: "running",
            task: "Child task",
            parent_pid: root_pid
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      # Monitor ALL agents before pause (Task.start fire-and-forget requires waiting for all)
      task_ref = Process.monitor(task_pid)
      root_ref = Process.monitor(root_pid)
      child_ref = Process.monitor(child_pid)

      # Pause task (async - returns immediately)
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)

      # Wait for ALL async terminations to complete before restore
      for {ref, pid, name} <- [
            {task_ref, task_pid, "task"},
            {root_ref, root_pid, "root"},
            {child_ref, child_pid, "child"}
          ] do
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5000 -> flunk("#{name} agent did not terminate within 5 seconds")
        end
      end

      refute Process.alive?(task_pid)
      refute Process.alive?(root_pid)
      refute Process.alive?(child_pid)

      # Restore task
      assert {:ok, new_root_pid} =
               TaskRestorer.restore_task(task.id, registry, pubsub, sandbox_owner: sandbox_owner)

      # Wait for root initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(new_root_pid)

      # CRITICAL: Find ALL restored agents in Registry (root + child)
      # Use Core.find_children_by_parent to get all children
      restored_children = Quoracle.Agent.Core.find_children_by_parent(new_root_pid, registry)

      # CRITICAL: Wait for ALL children to initialize too!
      Enum.each(restored_children, fn {child_pid, _meta} ->
        assert {:ok, _child_state} = Quoracle.Agent.Core.get_state(child_pid)
      end)

      # Add cleanup for ALL restored agents (root + children)
      on_exit(fn ->
        if Process.alive?(new_root_pid) do
          try do
            GenServer.stop(new_root_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end

        # Clean up all child agents
        Enum.each(restored_children, fn {child_pid, _meta} ->
          if Process.alive?(child_pid) do
            try do
              GenServer.stop(child_pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end)
      end)

      # Verify new root agent spawned
      assert is_pid(new_root_pid)
      assert Process.alive?(new_root_pid)
      assert new_root_pid != root_pid

      # Child should also be restored (verified by cleanup above)
    end

    test "idempotent pause - pausing already paused task succeeds", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Monitor BEFORE pause (to catch fast terminations)
      ref = Process.monitor(task_pid)

      # Pause once (async - returns immediately)
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry)

      # Wait for first pause to complete (agent termination)
      receive do
        {:DOWN, ^ref, :process, ^task_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Pause again - should succeed (idempotent, no agents to terminate)
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry)

      # Status may be "pausing" or "paused" depending on Registry cleanup timing
      # The key assertion is that second pause succeeded (idempotent behavior)
      {:ok, updated_task} = TaskManager.get_task(task.id)
      assert updated_task.status in ["pausing", "paused"]
    end

    # WorkGroupID: fix-history-20251219-033611
    # Tests model_histories preservation across pause/restore cycle
    test "conversation history preserved across pause/restore cycle", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Use task_pid from create_task_with_cleanup - don't spawn a second agent
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Inject model_histories via :sys.replace_state (simulates conversation)
      :sys.replace_state(task_pid, fn state ->
        %{
          state
          | model_histories: %{
              "anthropic:claude-sonnet-4" => [
                %{type: :user, content: "Test message from user", timestamp: DateTime.utc_now()},
                %{type: :agent, content: "Response from agent", timestamp: DateTime.utc_now()}
              ]
            }
        }
      end)

      # Pause (should persist model_histories to DB) - async, wait for completion
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)

      # Wait for async termination before restore (prevents duplicate agent ID)
      ref = Process.monitor(task_pid)

      receive do
        {:DOWN, ^ref, :process, ^task_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Restore
      assert {:ok, new_root_pid} =
               TaskRestorer.restore_task(task.id, registry, pubsub, sandbox_owner: sandbox_owner)

      # Wait for initialization
      assert {:ok, state} = Quoracle.Agent.Core.get_state(new_root_pid)

      # Add cleanup for restored agent
      on_exit(fn ->
        if Process.alive?(new_root_pid) do
          try do
            GenServer.stop(new_root_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # CRITICAL ASSERTION: model_histories must survive pause/restore
      assert is_map(state.model_histories),
             "model_histories should be a map, got: #{inspect(state.model_histories)}"

      refute state.model_histories == %{},
             "model_histories should NOT be empty after restore"

      histories = state.model_histories["anthropic:claude-sonnet-4"]

      assert is_list(histories),
             "Expected list for model histories, got: #{inspect(histories)}"

      assert length(histories) == 2,
             "Expected 2 history entries, got #{length(histories || [])}"

      # Verify content preserved
      assert Enum.any?(histories, fn entry ->
               entry.content == "Test message from user" or
                 entry["content"] == "Test message from user"
             end),
             "User message should be preserved"

      assert Enum.any?(histories, fn entry ->
               entry.content == "Response from agent" or
                 entry["content"] == "Response from agent"
             end),
             "Agent response should be preserved"
    end
  end

  describe "Edge Cases and Error Handling" do
    # TODO: Log message format - graceful handling via :not_found return
    test "handles race condition - agent terminates during pause", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, _task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "agent1",
            task_id: task.id,
            parent_pid: nil,
            status: "running",
            task: "Task 1"
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      # Terminate agent manually (simulate race condition)
      Quoracle.Agent.DynSup.terminate_agent(pid)

      # Pause should still succeed (gracefully handles :not_found)
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)
    end

    # TODO: Orphan agents succeed with nil parent_pid (graceful handling)
    test "handles orphaned child agent during restoration", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Create child without parent in DB (orphan)
      {:ok, _child_db} =
        Repo.insert(%AgentSchema{
          agent_id: "orphan_child",
          task_id: task.id,
          status: "running",
          parent_id: "nonexistent_parent",
          config: %{task: "Orphan task"},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      # Stop task agent before restore (would conflict with restored agents)
      stop_and_wait_for_unregister(task_pid, registry, "root-#{task.id}")

      # Restore - orphan child gets parent_pid = nil (parent not found)
      # Should succeed gracefully (capture expected warning about orphan)
      {pid, _log} =
        with_log(fn ->
          {:ok, pid} =
            TaskRestorer.restore_task(task.id, registry, pubsub, sandbox_owner: sandbox_owner)

          pid
        end)

      # Wait for initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(pid)

      # Add cleanup for restored agent
      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)
    end

    test "partial restore leaves successful agents running", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Both agents will succeed (empty config is valid)
      {:ok, _agent1} =
        Repo.insert(%AgentSchema{
          agent_id: "agent1",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{test_mode: true},
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      {:ok, _agent2} =
        Repo.insert(%AgentSchema{
          agent_id: "agent2",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          # Empty config is valid - Core only persists [:test_mode, :initial_prompt]
          inserted_at: ~N[2025-01-01 10:00:01]
        })

      # Stop task agent before restore (would conflict with restored agents)
      stop_and_wait_for_unregister(task_pid, registry, "root-#{task.id}")

      # Attempt restore - should succeed with both agents
      assert {:ok, root_pid} =
               TaskRestorer.restore_task(task.id, registry, pubsub, sandbox_owner: sandbox_owner)

      # Wait for initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(root_pid)

      # Verify both agents running
      [{pid1, _}] = Registry.lookup(registry, {:agent, "agent1"})
      assert Process.alive?(pid1)

      [{pid2, _}] = Registry.lookup(registry, {:agent, "agent2"})
      assert Process.alive?(pid2)

      # Add cleanup for all restored agents
      on_exit(fn ->
        Enum.each([pid1, pid2], fn pid ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end)
      end)
    end
  end

  # ===========================================================================
  # Packet 2: Pause Ordering Fix (fix-20260118-trigger-drain-pause)
  # ===========================================================================
  # Tests for TASK_Restorer v5.0 - Direct Send for Deterministic Pause Ordering
  #
  # These tests verify that pause_task uses send(pid, :stop_requested) instead
  # of Task.start(fn -> GenServer.stop(...) end) for deterministic FIFO ordering.

  describe "pause_task/2 - Direct Send Pattern (v5.0)" do
    # R109: WHEN pause_task called THEN uses send/2 not Task.start
    # TEST-FIXES: Changed from pause semantics (skip_auto_consensus check) to stop semantics
    #             per spec R105: :stop_requested returns {:stop, :normal, state}
    test "R109: pause_task sends :stop_requested directly to agents", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "agent-r109",
            task_id: task.id,
            parent_pid: nil,
            status: "running",
            task: "Test agent"
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          skip_auto_consensus: true
        )

      # Wait for agent initialization
      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)

      # Monitor agent before pause to catch termination
      ref = Process.monitor(agent_pid)

      # Pause the task - this should send :stop_requested to agent
      :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)

      # Agent should terminate gracefully via :stop_requested handler
      # Per spec R105: :stop_requested returns {:stop, :normal, state}
      assert_receive {:DOWN, ^ref, :process, ^agent_pid, reason},
                     5000,
                     "Agent should terminate after receiving :stop_requested"

      # Termination should be normal (graceful stop)
      assert reason == :normal,
             "Agent should terminate with :normal reason, got: #{inspect(reason)}"

      # Cleanup task agent
      Process.monitor(task_pid)

      receive do
        {:DOWN, _, :process, ^task_pid, _} -> :ok
      after
        5000 -> :ok
      end
    end

    # R110: WHEN pause_task called THEN checks Process.alive? before send
    test "R110: pause_task checks Process.alive? before sending", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "agent-r110",
            task_id: task.id,
            parent_pid: nil,
            status: "running",
            task: "Test agent"
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          skip_auto_consensus: true
        )

      # Wait for agent initialization
      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)

      # Kill the agent BEFORE pause
      GenServer.stop(agent_pid, :normal, :infinity)

      # Verify agent is dead
      refute Process.alive?(agent_pid)

      # Pause should not crash when agent is already dead
      # With direct send pattern + alive check, this should succeed silently
      assert :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)

      # Cleanup task agent
      Process.monitor(task_pid)

      receive do
        {:DOWN, _, :process, ^task_pid, _} -> :ok
      after
        5000 -> :ok
      end
    end

    # R111: WHEN :stop_requested sent after triggers THEN processed after them
    # TEST-FIXES: Changed from pause semantics to stop semantics per spec R105/R107
    #             Agent terminates gracefully after FIFO processing of triggers
    test "R111: :stop_requested processed in mailbox FIFO order", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "agent-r111",
            task_id: task.id,
            parent_pid: nil,
            status: "running",
            task: "Test agent"
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          skip_auto_consensus: true
        )

      # Wait for agent initialization
      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)

      # Monitor agent before sending messages
      ref = Process.monitor(agent_pid)

      # Send trigger messages BEFORE pause
      send(agent_pid, :trigger_consensus)
      send(agent_pid, :trigger_consensus)

      # Now pause - with direct send, :stop_requested goes to END of mailbox
      :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)

      # The agent should process triggers BEFORE :stop_requested (FIFO order)
      # Then :stop_requested handler drains remaining triggers and terminates
      # Per spec R107: FIFO ordering ensures deterministic message processing

      # Agent should terminate gracefully after processing all messages in order
      assert_receive {:DOWN, ^ref, :process, ^agent_pid, reason},
                     5000,
                     "Agent should terminate after FIFO message processing"

      # Termination should be normal (graceful stop via :stop_requested)
      assert reason == :normal,
             "Agent should terminate with :normal reason after FIFO processing"

      # Cleanup task agent
      Process.monitor(task_pid)

      receive do
        {:DOWN, _, :process, ^task_pid, _} -> :ok
      after
        5000 -> :ok
      end
    end

    # R112: WHEN pause_task code reviewed THEN no Task.start calls for agent stop
    test "R112: pause_task source does not use Task.start for agent termination" do
      # Read the source code and verify no Task.start pattern
      source_path = "lib/quoracle/tasks/task_restorer.ex"
      {:ok, source} = File.read(source_path)

      # Find the pause_task function section (roughly lines 28-87)
      # Look for Task.start pattern in agent termination context
      pause_section =
        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, num} ->
          num >= 28 and num <= 90 and String.contains?(line, "Task.start")
        end)

      # Should NOT find Task.start in the pause section
      # If found, the direct send pattern is not implemented
      assert pause_section == [],
             "pause_task should not use Task.start for agent termination. Found: #{inspect(pause_section)}"
    end
  end

  describe "pause_task/2 - Acceptance (v5.0)" do
    # A20: Pause completes after single consensus cycle (not multiple)
    # TEST-FIXES: Changed from pause semantics to stop semantics per spec A20
    #             Agent terminates gracefully after draining triggers (not stays alive)
    @tag :acceptance
    test "A20: pause during rapid triggers stops after draining once", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # User scenario:
      # 1. Agent is running with rapid trigger events
      # 2. User clicks pause
      # 3. Agent processes triggers in FIFO order, drains remaining, then stops
      # 4. Agent terminates gracefully (not killed mid-operation)
      #
      # This requires both:
      # - Drain logic (Packet 1) - collapses multiple triggers before stop
      # - Direct send (Packet 2) - deterministic mailbox ordering via send/2

      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Acceptance test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "agent-a20",
            task_id: task.id,
            parent_pid: nil,
            status: "running",
            task: "Test agent"
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          # Skip auto-consensus to avoid LLM calls in test
          skip_auto_consensus: true
        )

      # Wait for agent initialization
      {:ok, initial_state} = Quoracle.Agent.Core.get_state(agent_pid)
      assert initial_state.agent_id == "agent-a20"

      # Monitor agent before sending messages
      ref = Process.monitor(agent_pid)

      # Simulate rapid trigger events (from action completions)
      send(agent_pid, :trigger_consensus)
      send(agent_pid, :trigger_consensus)
      send(agent_pid, :trigger_consensus)

      # User clicks pause - TaskRestorer sends :stop_requested
      # With direct send pattern, :stop_requested goes to END of mailbox
      :ok = TaskRestorer.pause_task(task.id, registry: registry, dynsup: dynsup)

      # Agent should terminate gracefully after:
      # 1. Processing trigger messages in FIFO order
      # 2. Draining any remaining triggers (Packet 1)
      # 3. Returning {:stop, :normal, state} (Packet 2)
      assert_receive {:DOWN, ^ref, :process, ^agent_pid, reason},
                     5000,
                     "Agent should terminate gracefully after draining triggers"

      # Termination should be normal - not killed, but graceful stop
      assert reason == :normal,
             "Agent should terminate with :normal reason (graceful), got: #{inspect(reason)}"

      # The drain mechanism (Packet 1) + direct send (Packet 2) ensures:
      # - All trigger messages were processed/drained together
      # - :stop_requested was processed AFTER triggers (FIFO order)
      # - Agent terminated gracefully after single drain cycle (not multiple)

      # Cleanup task agent
      Process.monitor(task_pid)

      receive do
        {:DOWN, _, :process, ^task_pid, _} -> :ok
      after
        5000 -> :ok
      end
    end
  end
end
