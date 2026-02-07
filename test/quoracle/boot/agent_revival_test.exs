defmodule Quoracle.Boot.AgentRevivalTest do
  @moduledoc """
  Tests for boot-time agent revival.

  WorkGroupID: wip-20251229-boot-revival
  Packet: 1 (Boot-Time Revival)

  ARC Verification Criteria: R1-R10
  """
  # Tests behavior (task restoration, registry state) not Logger output
  use Quoracle.DataCase, async: true

  alias Quoracle.Boot.AgentRevival
  alias Quoracle.Tasks.TaskManager
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers

  # Suppress Logger output from AgentRevival (it logs at :info level)
  @moduletag capture_log: true

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()

    %{
      registry: deps.registry,
      dynsup: deps.dynsup,
      pubsub: deps.pubsub,
      sandbox_owner: sandbox_owner
    }
  end

  describe "empty database" do
    # R1: WHEN restore_running_tasks called IF no tasks with status "running"
    #     THEN logs "No running tasks to restore" and returns :ok
    test "R1: returns ok when no running tasks exist", %{
      registry: registry,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      result =
        AgentRevival.restore_running_tasks(
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      assert result == :ok
    end
  end

  describe "single task restoration" do
    # R2: WHEN restore_running_tasks called IF one task with status "running" exists
    #     THEN task is restored with live agents
    test "R2: restores single running task with agents", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create a task with "running" status (simulating pre-restart state)
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Test task for revival",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Stop the agent to simulate application restart
      # (task remains "running" in DB, but no live agent)
      GenServer.stop(task_pid, :normal, :infinity)
      refute Process.alive?(task_pid)

      # Verify task still has "running" status in DB
      {:ok, task_before} = TaskManager.get_task(task.id)
      assert task_before.status == "running"

      # Now call restore_running_tasks - should restore the task
      result =
        AgentRevival.restore_running_tasks(
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      assert result == :ok

      # Verify agent is now alive in registry
      root_agent_id = "root-#{task.id}"
      [{restored_pid, _}] = Registry.lookup(registry, {:agent, root_agent_id})
      assert Process.alive?(restored_pid)

      # Cleanup restored agent
      on_exit(fn ->
        if Process.alive?(restored_pid) do
          try do
            GenServer.stop(restored_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)
    end
  end

  describe "multiple task restoration" do
    # R3: WHEN restore_running_tasks called IF multiple tasks with status "running" exist
    #     THEN all tasks restored sequentially
    test "R3: restores multiple running tasks sequentially", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create two tasks with "running" status
      {:ok, {task1, task1_pid}} =
        create_task_with_cleanup("Task 1 for revival",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, {task2, task2_pid}} =
        create_task_with_cleanup("Task 2 for revival",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Stop both agents to simulate application restart
      GenServer.stop(task1_pid, :normal, :infinity)
      GenServer.stop(task2_pid, :normal, :infinity)
      refute Process.alive?(task1_pid)
      refute Process.alive?(task2_pid)

      # Verify both tasks still have "running" status in DB
      {:ok, task1_before} = TaskManager.get_task(task1.id)
      {:ok, task2_before} = TaskManager.get_task(task2.id)
      assert task1_before.status == "running"
      assert task2_before.status == "running"

      # Now call restore_running_tasks - should restore both tasks
      result =
        AgentRevival.restore_running_tasks(
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      assert result == :ok

      # Verify both agents are now alive in registry
      root1_agent_id = "root-#{task1.id}"
      root2_agent_id = "root-#{task2.id}"

      [{restored1_pid, _}] = Registry.lookup(registry, {:agent, root1_agent_id})
      [{restored2_pid, _}] = Registry.lookup(registry, {:agent, root2_agent_id})

      assert Process.alive?(restored1_pid)
      assert Process.alive?(restored2_pid)

      # Cleanup restored agents
      on_exit(fn ->
        for pid <- [restored1_pid, restored2_pid] do
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end
      end)
    end
  end

  describe "task failure isolation" do
    # R4: WHEN one task fails to restore IF other tasks exist
    #     THEN other tasks still restored successfully
    test "R4: continues restoring other tasks when one fails", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create two tasks - one will succeed, one will fail
      {:ok, {good_task, good_task_pid}} =
        create_task_with_cleanup("Good task for revival",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, {bad_task, bad_task_pid}} =
        create_task_with_cleanup("Bad task for revival",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Stop both agents
      GenServer.stop(good_task_pid, :normal, :infinity)
      GenServer.stop(bad_task_pid, :normal, :infinity)

      # Delete ALL agents for bad_task from DB to cause restoration failure
      # (TaskRestorer.restore_task returns {:error, :no_agents_found})
      alias Quoracle.Agents.Agent, as: AgentSchema
      import Ecto.Query
      Repo.delete_all(from(a in AgentSchema, where: a.task_id == ^bad_task.id))

      # Now call restore_running_tasks
      result =
        AgentRevival.restore_running_tasks(
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      # Should still return :ok even with partial failure
      assert result == :ok

      # Verify good task was restored
      good_root_id = "root-#{good_task.id}"
      [{restored_pid, _}] = Registry.lookup(registry, {:agent, good_root_id})
      assert Process.alive?(restored_pid)

      # Cleanup
      on_exit(fn ->
        if Process.alive?(restored_pid) do
          try do
            GenServer.stop(restored_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)
    end

    # R5: WHEN task restoration fails THEN task status remains "running" (no state mutation)
    test "R5: failed task status remains running", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create a task
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Task that will fail revival",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Stop the agent
      GenServer.stop(task_pid, :normal, :infinity)

      # Delete ALL agents from DB to cause restoration failure
      alias Quoracle.Agents.Agent, as: AgentSchema
      import Ecto.Query
      Repo.delete_all(from(a in AgentSchema, where: a.task_id == ^task.id))

      # Verify task status before restore attempt
      {:ok, task_before} = TaskManager.get_task(task.id)
      assert task_before.status == "running"

      # Attempt restoration (will fail)
      result =
        AgentRevival.restore_running_tasks(
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      assert result == :ok

      # CRITICAL: Task status must remain "running" - no state mutation on failure
      {:ok, task_after} = TaskManager.get_task(task.id)

      assert task_after.status == "running",
             "Task status should remain 'running' after failed restoration, got '#{task_after.status}'"
    end
  end

  # NOTE: R6, R7 (logging tests) removed - they tested implementation details
  # (Logger output format) rather than behavior. The actual restoration behavior
  # is already verified by R1-R5, R8-R10.

  describe "dependency injection" do
    # R8: WHEN restore_running_tasks/1 called with opts THEN uses injected registry/pubsub
    test "R8: uses injected dependencies for test isolation", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create a task with our isolated registry/pubsub
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Task for DI test",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Stop the agent
      GenServer.stop(task_pid, :normal, :infinity)

      # Call with explicit dependencies
      result =
        AgentRevival.restore_running_tasks(
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      assert result == :ok

      # Verify agent was registered in OUR isolated registry (not global)
      root_agent_id = "root-#{task.id}"
      [{restored_pid, _}] = Registry.lookup(registry, {:agent, root_agent_id})
      assert Process.alive?(restored_pid)

      # Verify NOT in global registry (if it exists)
      global_lookup = Registry.lookup(Quoracle.AgentRegistry, {:agent, root_agent_id})
      assert global_lookup == [], "Agent should NOT be in global registry"

      # Cleanup
      on_exit(fn ->
        if Process.alive?(restored_pid) do
          try do
            GenServer.stop(restored_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)
    end
  end

  describe "stale pausing tasks" do
    test "finalizes tasks stuck in pausing status to paused on boot", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create a task and stop its agent (simulates pre-restart state)
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Pausing task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      GenServer.stop(task_pid, :normal, :infinity)

      # Manually set to "pausing" — simulates server dying mid-pause
      {:ok, _} = TaskManager.update_task_status(task.id, "pausing")

      # Boot revival should finalize it to "paused", not try to restore it
      result =
        AgentRevival.restore_running_tasks(
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      assert result == :ok

      {:ok, updated_task} = TaskManager.get_task(task.id)
      assert updated_task.status == "paused"
    end

    test "does not restore pausing tasks as running agents", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Pausing task 2",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      GenServer.stop(task_pid, :normal, :infinity)
      {:ok, _} = TaskManager.update_task_status(task.id, "pausing")

      AgentRevival.restore_running_tasks(
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner
      )

      # No agent should be alive — task was pausing, not running
      root_agent_id = "root-#{task.id}"
      assert Registry.lookup(registry, {:agent, root_agent_id}) == []
    end
  end

  describe "exception safety" do
    # R9: WHEN restoration raises exception THEN catches, logs, and continues
    # Note: Tests failure isolation via error returns. The try/rescue/catch
    # in restore_task_safely handles both {:error, reason} and raised exceptions.
    test "R9: catches exceptions and continues with other tasks", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create two tasks - one will succeed, one will fail
      {:ok, {good_task, good_task_pid}} =
        create_task_with_cleanup("Good task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      {:ok, {bad_task, bad_task_pid}} =
        create_task_with_cleanup("Bad task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Stop both agents
      GenServer.stop(good_task_pid, :normal, :infinity)
      GenServer.stop(bad_task_pid, :normal, :infinity)

      # Delete agents for bad_task to cause restoration failure
      # TaskRestorer.restore_task returns {:error, :no_agents_found}
      alias Quoracle.Agents.Agent, as: AgentSchema
      import Ecto.Query
      Repo.delete_all(from(a in AgentSchema, where: a.task_id == ^bad_task.id))

      # Call restore - should NOT raise, should continue with good task
      result =
        AgentRevival.restore_running_tasks(
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      # Should still return :ok
      assert result == :ok

      # Good task should still be restored
      good_root_id = "root-#{good_task.id}"
      [{restored_pid, _}] = Registry.lookup(registry, {:agent, good_root_id})
      assert Process.alive?(restored_pid)

      on_exit(fn ->
        if Process.alive?(restored_pid) do
          try do
            GenServer.stop(restored_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)
    end

    # R10: WHEN restore_running_tasks called THEN always returns :ok regardless of failures
    test "R10: always returns ok even when all tasks fail", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create a task that will fail to restore
      {:ok, {task, task_pid}} =
        create_task_with_cleanup("Task that will fail",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Stop the agent
      GenServer.stop(task_pid, :normal, :infinity)

      # Delete ALL agents from DB to cause restoration failure
      alias Quoracle.Agents.Agent, as: AgentSchema
      import Ecto.Query
      Repo.delete_all(from(a in AgentSchema, where: a.task_id == ^task.id))

      # Call restore - MUST return :ok even when all fail
      result =
        AgentRevival.restore_running_tasks(
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      assert result == :ok,
             "restore_running_tasks must always return :ok, got: #{inspect(result)}"
    end
  end
end
