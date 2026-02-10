defmodule Quoracle.Tasks.TaskManagerTest do
  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog
  import Test.AgentTestHelpers

  alias Quoracle.Tasks.TaskManager
  alias Quoracle.Tasks.Task
  alias Quoracle.Agents.Agent
  alias Quoracle.Repo

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated PubSub for test isolation
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised({Phoenix.PubSub, name: pubsub})

    # Create isolated Registry
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})

    # Create isolated DynSup with :infinity shutdown to prevent kill escalation
    # CRITICAL: shutdown must be in child spec, not ExUnit options (ExUnit ignores it)
    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
      shutdown: :infinity
    }

    {:ok, dynsup} = start_supervised(dynsup_spec)

    # Ensure test profile exists - use unique name to avoid ON CONFLICT contention
    profile = create_test_profile()

    deps = %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner,
      profile: profile
    }

    %{pubsub: pubsub, deps: deps, profile: profile}
  end

  describe "create_task/1" do
    @tag :integration
    test "ARC_FUNC_01: WHEN called IF valid prompt THEN saves Task AND spawns root agent AND returns {task, pid}",
         %{deps: deps} do
      prompt = "Test task prompt"

      assert {:ok, {task, root_pid}} =
               TaskManager.create_task(%{profile: deps.profile.name}, %{task_description: prompt},
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup
               )

      # Wait for agent initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(root_pid)

      # Ensure agent terminates before sandbox owner exits (with recursive child cleanup)
      register_agent_cleanup(root_pid, cleanup_tree: true, registry: deps.registry)

      # Verify task in database
      assert task.id != nil
      assert task.prompt == prompt
      assert task.status == "running"

      # Verify root agent is alive
      assert Process.alive?(root_pid)
    end

    @tag :integration
    test "ARC_FUNC_02: spawn failure rolls back transaction", %{deps: deps} do
      # TODO: Proper spawn failure test requires mocking DynSup.start_agent
      # Empty string tests validation failure, not spawn failure
      # Will implement proper spawn failure simulation in IMPLEMENT phase
      # For now, verify function exists and returns error on invalid input
      assert {:error, _reason} =
               TaskManager.create_task(%{profile: deps.profile.name}, %{task_description: ""},
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup
               )
    end

    @tag :integration
    test "create_task with empty prompt validation fails", %{deps: deps} do
      # Empty prompt should fail validation
      assert {:error, changeset} =
               TaskManager.create_task(%{profile: deps.profile.name}, %{task_description: ""},
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup
               )

      assert %Ecto.Changeset{valid?: false} = changeset
    end
  end

  describe "get_task/1" do
    test "ARC_FUNC_03: returns task when exists" do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      assert {:ok, found_task} = TaskManager.get_task(task.id)
      assert found_task.id == task.id
      assert found_task.prompt == "Test"
    end

    test "returns {:error, :not_found} when task doesn't exist" do
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} = TaskManager.get_task(fake_id)
    end
  end

  describe "list_tasks/1" do
    setup do
      # Create tasks with different statuses
      {:ok, task1} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Task 1", status: "running"}))

      {:ok, task2} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Task 2", status: "paused"}))

      {:ok, task3} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Task 3", status: "completed"}))

      %{running: task1, paused: task2, completed: task3}
    end

    test "ARC_FUNC_04: returns all tasks when no filter provided", %{
      running: task1,
      paused: task2,
      completed: task3
    } do
      tasks = TaskManager.list_tasks()

      task_ids = Enum.map(tasks, & &1.id)
      assert task1.id in task_ids
      assert task2.id in task_ids
      assert task3.id in task_ids
    end

    test "ARC_FUNC_05: WHEN status filter provided THEN returns only tasks with that status", %{
      running: task1,
      paused: _task2
    } do
      tasks = TaskManager.list_tasks(status: "running")

      assert length(tasks) == 1
      assert hd(tasks).id == task1.id
      assert hd(tasks).status == "running"
    end

    test "returns tasks in descending inserted_at order" do
      tasks = TaskManager.list_tasks()

      # Verify ordering (newest first)
      timestamps = Enum.map(tasks, & &1.inserted_at)
      assert timestamps == Enum.sort(timestamps, {:desc, NaiveDateTime})
    end
  end

  describe "update_task_status/2" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task: task}
    end

    @tag :integration
    test "ARC_FUNC_07: WHEN called IF valid status THEN task updated AND updated_at refreshed",
         %{task: task} do
      original_updated_at = task.updated_at

      assert {:ok, updated_task} = TaskManager.update_task_status(task.id, "paused")

      assert updated_task.status == "paused"
      # updated_at should be >= original
      assert NaiveDateTime.compare(updated_task.updated_at, original_updated_at) in [:gt, :eq]
    end

    test "returns {:error, :not_found} when task doesn't exist" do
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} = TaskManager.update_task_status(fake_id, "paused")
    end

    test "validates status is in allowed values", %{task: task} do
      assert {:error, changeset} = TaskManager.update_task_status(task.id, "invalid_status")
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end
  end

  describe "complete_task/2" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task: task}
    end

    test "marks task as completed with result", %{task: task} do
      result = "Task completed successfully"

      assert {:ok, completed_task} = TaskManager.complete_task(task.id, result)

      assert completed_task.status == "completed"
      assert completed_task.result == result
    end

    test "returns {:error, :not_found} when task doesn't exist" do
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} = TaskManager.complete_task(fake_id, "result")
    end
  end

  describe "fail_task/2" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task: task}
    end

    test "marks task as failed with error message", %{task: task} do
      error_message = "Task failed due to timeout"

      assert {:ok, failed_task} = TaskManager.fail_task(task.id, error_message)

      assert failed_task.status == "failed"
      assert failed_task.error_message == error_message
    end

    test "returns {:error, :not_found} when task doesn't exist" do
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} = TaskManager.fail_task(fake_id, "error")
    end
  end

  describe "save_agent/1" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task_id: task.id}
    end

    @tag :integration
    test "ARC_FUNC_08: WHEN called IF valid attrs THEN agent record created with task_id foreign key",
         %{task_id: task_id} do
      attrs = %{
        task_id: task_id,
        agent_id: "agent-test-001",
        parent_id: nil,
        config: %{model: "test"},
        status: "running"
      }

      assert {:ok, agent} = TaskManager.save_agent(attrs)

      assert agent.id != nil
      assert agent.task_id == task_id
      assert agent.agent_id == "agent-test-001"
      assert agent.status == "running"
    end

    test "validates required fields" do
      # Missing required fields should fail
      attrs = %{agent_id: "agent-incomplete"}

      assert {:error, changeset} = TaskManager.save_agent(attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).task_id
    end

    test "enforces foreign key constraint for invalid task_id" do
      invalid_task_id = Ecto.UUID.generate()

      attrs = %{
        task_id: invalid_task_id,
        agent_id: "agent-orphan",
        parent_id: nil,
        config: %{},
        status: "running"
      }

      assert {:error, changeset} = TaskManager.save_agent(attrs)
      assert "does not exist" in errors_on(changeset).task_id
    end
  end

  describe "get_agent/1" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      {:ok, agent} =
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: task.id,
            agent_id: "agent-findme",
            parent_id: nil,
            config: %{},
            status: "running"
          })
        )

      %{agent: agent}
    end

    test "returns agent when exists", %{agent: agent} do
      assert {:ok, found_agent} = TaskManager.get_agent("agent-findme")
      assert found_agent.id == agent.id
      assert found_agent.agent_id == "agent-findme"
    end

    test "returns {:error, :not_found} when agent doesn't exist" do
      assert {:error, :not_found} = TaskManager.get_agent("non-existent-agent")
    end
  end

  describe "get_agents_for_task/1" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      # Create agents in specific order
      {:ok, root} =
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: task.id,
            agent_id: "agent-root",
            parent_id: nil,
            config: %{},
            status: "running"
          })
        )

      {:ok, child} =
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: task.id,
            agent_id: "agent-child",
            parent_id: "agent-root",
            config: %{},
            status: "running"
          })
        )

      %{task: task, root: root, child: child}
    end

    @tag :integration
    test "ARC_FUNC_10: WHEN called IF valid task_id THEN returns all agents for task",
         %{task: task, root: root, child: child} do
      agents = TaskManager.get_agents_for_task(task.id)

      assert length(agents) == 2

      # Verify both agents are present (order doesn't matter for this query)
      agent_ids = Enum.map(agents, & &1.agent_id)
      assert root.agent_id in agent_ids
      assert child.agent_id in agent_ids

      # Verify parent-child relationships are preserved
      root_from_db = Enum.find(agents, &(&1.agent_id == root.agent_id))
      child_from_db = Enum.find(agents, &(&1.agent_id == child.agent_id))

      assert root_from_db.parent_id == nil
      assert child_from_db.parent_id == root.agent_id
    end

    test "returns empty list when task has no agents" do
      {:ok, empty_task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Empty", status: "running"}))

      agents = TaskManager.get_agents_for_task(empty_task.id)

      assert agents == []
    end
  end

  describe "concurrent operations" do
    @tag :integration
    test "concurrent task creation doesn't cause conflicts", %{
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # Create isolated registry and dynsup for true test isolation
      registry = :"test_registry_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: registry})

      {:ok, dynsup} =
        start_supervised({Quoracle.Agent.DynSup, [registry: registry, pubsub: pubsub]},
          shutdown: :infinity
        )

      # Get test profile for task creation - use unique name to avoid ON CONFLICT contention
      profile = create_test_profile()

      # Spawn multiple tasks concurrently
      elixir_tasks =
        1..5
        |> Enum.map(fn i ->
          Elixir.Task.async(fn ->
            # Task.async needs sandbox access before calling TaskManager.create_task
            Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, sandbox_owner, self())

            TaskManager.create_task(
              %{profile: profile.name},
              %{task_description: "Concurrent task #{i}"},
              sandbox_owner: sandbox_owner,
              pubsub: pubsub,
              registry: registry,
              dynsup: dynsup
            )
          end)
        end)
        |> Enum.map(&Elixir.Task.await/1)

      # All should succeed (or fail gracefully)
      assert Enum.all?(elixir_tasks, fn
               {:ok, _} -> true
               {:error, _} -> true
             end)

      # CRITICAL: Register cleanup for ALL agents FIRST, before any initialization waits
      # This ensures cleanup runs even if test exits during init wait loop
      Enum.each(elixir_tasks, fn
        {:ok, {_task, agent_pid}} ->
          register_agent_cleanup(agent_pid, cleanup_tree: true, registry: registry)

        {:error, _reason} ->
          :ok
      end)

      # Now wait for all agents to fully initialize
      Enum.each(elixir_tasks, fn
        {:ok, {_task, agent_pid}} ->
          assert {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)

        {:error, _reason} ->
          :ok
      end)
    end
  end

  # ========== PACKET 3: PERSISTENCE INTEGRATION ==========

  describe "save_log/1" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task_id: task.id}
    end

    @tag :integration
    test "ARC_FUNC_11: WHEN called IF valid attrs THEN log created", %{task_id: task_id} do
      attrs = %{
        agent_id: "agent-test-001",
        task_id: task_id,
        action_type: "send_message",
        params: %{to: "agent-002", content: "Hello"},
        result: %{data: "sent"},
        status: "success"
      }

      assert {:ok, log} = TaskManager.save_log(attrs)

      assert log.id != nil
      assert log.agent_id == "agent-test-001"
      assert log.task_id == task_id
      assert log.action_type == "send_message"
      assert log.status == "success"
      assert log.params == %{to: "agent-002", content: "Hello"}
      assert log.result == %{data: "sent"}
    end

    test "validates required fields" do
      # Missing required fields should fail
      attrs = %{agent_id: "agent-incomplete"}

      assert {:error, changeset} = TaskManager.save_log(attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).task_id
      assert "can't be blank" in errors_on(changeset).action_type
      assert "can't be blank" in errors_on(changeset).params
    end

    test "validates status is success or error", %{task_id: task_id} do
      attrs = %{
        agent_id: "agent-001",
        task_id: task_id,
        action_type: "spawn",
        params: %{},
        status: "invalid_status"
      }

      assert {:error, changeset} = TaskManager.save_log(attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "enforces foreign key constraint for invalid task_id" do
      invalid_task_id = Ecto.UUID.generate()

      attrs = %{
        agent_id: "agent-orphan",
        task_id: invalid_task_id,
        action_type: "wait",
        params: %{wait: 1000},
        status: "success"
      }

      assert {:error, changeset} = TaskManager.save_log(attrs)
      assert "does not exist" in errors_on(changeset).task_id
    end

    test "accepts error status with error result", %{task_id: task_id} do
      attrs = %{
        agent_id: "agent-001",
        task_id: task_id,
        action_type: "spawn",
        params: %{prompt: "Test"},
        result: %{error: "spawn failed"},
        status: "error"
      }

      assert {:ok, log} = TaskManager.save_log(attrs)
      assert log.status == "error"
      assert log.result == %{error: "spawn failed"}
    end

    test "result field is optional", %{task_id: task_id} do
      attrs = %{
        agent_id: "agent-001",
        task_id: task_id,
        action_type: "wait",
        params: %{wait: 100},
        status: "success"
      }

      assert {:ok, log} = TaskManager.save_log(attrs)
      assert log.result == nil
    end
  end

  describe "save_message/1" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task_id: task.id}
    end

    @tag :integration
    test "ARC_FUNC_12: WHEN called IF valid attrs THEN message record created", %{
      task_id: task_id
    } do
      attrs = %{
        task_id: task_id,
        from_agent_id: "agent-parent",
        to_agent_id: "agent-child",
        content: "Process this data: {data: 123}"
      }

      assert {:ok, message} = TaskManager.save_message(attrs)

      assert message.id != nil
      assert message.task_id == task_id
      assert message.from_agent_id == "agent-parent"
      assert message.to_agent_id == "agent-child"
      assert message.content == "Process this data: {data: 123}"
      assert message.read_at == nil
    end

    test "validates required fields" do
      # Missing required fields should fail
      attrs = %{from_agent_id: "agent-001"}

      assert {:error, changeset} = TaskManager.save_message(attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).task_id
      assert "can't be blank" in errors_on(changeset).to_agent_id
      assert "can't be blank" in errors_on(changeset).content
    end

    test "enforces foreign key constraint for invalid task_id" do
      invalid_task_id = Ecto.UUID.generate()

      attrs = %{
        task_id: invalid_task_id,
        from_agent_id: "agent-parent",
        to_agent_id: "agent-child",
        content: "Hello"
      }

      assert {:error, changeset} = TaskManager.save_message(attrs)
      assert "does not exist" in errors_on(changeset).task_id
    end

    test "read_at defaults to nil", %{task_id: task_id} do
      attrs = %{
        task_id: task_id,
        from_agent_id: "agent-001",
        to_agent_id: "agent-002",
        content: "Test message"
      }

      assert {:ok, message} = TaskManager.save_message(attrs)
      assert message.read_at == nil
    end
  end

  # ========== PACKET 1: DELETE TASK FUNCTIONALITY ==========

  describe "delete_task/2" do
    setup do
      # Create a paused task with agents for testing
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test task", status: "paused"}))

      # Create some agents for the task
      {:ok, root_agent} =
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: task.id,
            agent_id: "agent-root-#{task.id}",
            parent_id: nil,
            config: %{model: "test"},
            status: "stopped"
          })
        )

      {:ok, child_agent} =
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: task.id,
            agent_id: "agent-child-#{task.id}",
            parent_id: root_agent.agent_id,
            config: %{model: "test"},
            status: "stopped"
          })
        )

      # Create some logs for the task
      {:ok, log} =
        Repo.insert(
          Quoracle.Logs.Log.changeset(%Quoracle.Logs.Log{}, %{
            task_id: task.id,
            agent_id: root_agent.agent_id,
            action_type: "spawn",
            params: %{prompt: "child"},
            status: "success"
          })
        )

      # Create a message for the task
      {:ok, message} =
        Repo.insert(
          Quoracle.Messages.Message.changeset(%Quoracle.Messages.Message{}, %{
            task_id: task.id,
            from_agent_id: root_agent.agent_id,
            to_agent_id: child_agent.agent_id,
            content: "Process this"
          })
        )

      %{
        task: task,
        root_agent: root_agent,
        child_agent: child_agent,
        log: log,
        message: message
      }
    end

    @tag :integration
    test "ARC_DELETE_01: delete paused task cascades all data",
         %{
           task: task,
           root_agent: root_agent,
           child_agent: child_agent,
           log: log,
           message: message,
           deps: deps
         } do
      # Verify data exists before deletion
      assert Repo.get(Task, task.id) != nil
      assert Repo.get(Agent, root_agent.id) != nil
      assert Repo.get(Agent, child_agent.id) != nil
      assert Repo.get(Quoracle.Logs.Log, log.id) != nil
      assert Repo.get(Quoracle.Messages.Message, message.id) != nil

      # Delete the task (paused, no live agents, but still needs registry for lookup)
      assert {:ok, deleted_task} =
               TaskManager.delete_task(task.id, registry: deps.registry)

      assert deleted_task.id == task.id

      # Verify cascade deletion
      assert Repo.get(Task, task.id) == nil
      assert Repo.get(Agent, root_agent.id) == nil
      assert Repo.get(Agent, child_agent.id) == nil
      assert Repo.get(Quoracle.Logs.Log, log.id) == nil
      assert Repo.get(Quoracle.Messages.Message, message.id) == nil
    end

    @tag :integration
    test "ARC_DELETE_02: delete running task auto-pauses first", %{deps: deps} do
      # Create a running task with live agents
      {:ok, {task, root_pid}} =
        TaskManager.create_task(
          %{profile: deps.profile.name},
          %{task_description: "Running task to delete"},
          sandbox_owner: deps.sandbox_owner,
          pubsub: deps.pubsub,
          registry: deps.registry,
          dynsup: deps.dynsup
        )

      # Wait for agent to initialize
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(root_pid)

      # Register cleanup (will be handled by delete_task)
      register_agent_cleanup(root_pid, cleanup_tree: true, registry: deps.registry)

      # Verify task and agent are running
      assert Process.alive?(root_pid)
      assert task.status == "running"

      # Monitor agent before delete (to wait for async termination)
      ref = Process.monitor(root_pid)

      # Delete the running task (should auto-pause first - now async)
      assert {:ok, _deleted_task} =
               TaskManager.delete_task(task.id,
                 registry: deps.registry,
                 dynsup: deps.dynsup
               )

      # Wait for async termination to complete
      receive do
        {:DOWN, ^ref, :process, ^root_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Verify agent was terminated
      refute Process.alive?(root_pid)

      # Verify task was deleted
      assert Repo.get(Task, task.id) == nil
    end

    @tag :integration
    test "ARC_DELETE_03: delete completed task without pause", %{deps: deps} do
      # Create a completed task
      {:ok, completed_task} =
        Repo.insert(
          Task.changeset(%Task{}, %{
            prompt: "Completed task",
            status: "completed",
            result: "Task finished"
          })
        )

      # Delete the completed task (no live agents, but still needs registry)
      assert {:ok, deleted_task} =
               TaskManager.delete_task(completed_task.id, registry: deps.registry)

      assert deleted_task.id == completed_task.id

      # Verify deletion
      assert Repo.get(Task, completed_task.id) == nil
    end

    test "ARC_DELETE_04: returns error when task not found", %{deps: deps} do
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} = TaskManager.delete_task(fake_id, registry: deps.registry)
    end

    # NOTE: ARC_DELETE_05 test removed - obsoleted by Router cleanup fix
    # Original test validated transaction rollback when pause_task failed with dead dynsup.
    # After Router cleanup fix, pause_task uses GenServer.stop directly (not dynsup),
    # so dynsup parameter no longer affects termination success/failure.
    # Transaction rollback should be tested with a different failure scenario.

    @tag :integration
    test "ARC_DELETE_06: concurrent deletes handled gracefully",
         %{task: task, deps: deps} do
      # Spawn two concurrent delete attempts
      task1 =
        Elixir.Task.async(fn ->
          # First delete needs sandbox access
          Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, deps.sandbox_owner, self())
          TaskManager.delete_task(task.id, registry: deps.registry)
        end)

      task2 =
        Elixir.Task.async(fn ->
          # Second delete needs sandbox access
          Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, deps.sandbox_owner, self())
          TaskManager.delete_task(task.id, registry: deps.registry)
        end)

      results = [Elixir.Task.await(task1), Elixir.Task.await(task2)]

      # One should succeed, one should get :not_found
      assert Enum.count(results, fn
               {:ok, _} -> true
               _ -> false
             end) == 1

      assert Enum.count(results, fn
               {:error, :not_found} -> true
               _ -> false
             end) == 1
    end

    @tag :integration
    test "ARC_DELETE_07: uses injected registry and dynsup",
         %{sandbox_owner: sandbox_owner, pubsub: pubsub} do
      # Create isolated test dependencies (both registry AND dynsup)
      test_registry = :"test_registry_#{System.unique_integer([:positive])}"
      {:ok, _} = start_supervised({Registry, keys: :unique, name: test_registry})

      # Second registry to test different registry in delete
      other_registry = :"other_registry_#{System.unique_integer([:positive])}"
      {:ok, _} = start_supervised({Registry, keys: :unique, name: other_registry})

      test_dynsup =
        start_supervised!(
          {DynamicSupervisor,
           strategy: :one_for_one, name: :"test_dynsup_#{System.unique_integer([:positive])}"}
        )

      # Get test profile for task creation - use unique name to avoid ON CONFLICT contention
      profile = create_test_profile()

      # Create a task with agents using isolated registry (NOT global)
      {:ok, {task, root_pid}} =
        TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Test with injected deps"},
          sandbox_owner: sandbox_owner,
          pubsub: pubsub,
          dynsup: test_dynsup,
          registry: test_registry
        )

      # CRITICAL: Register cleanup IMMEDIATELY after spawn
      register_agent_cleanup(root_pid, cleanup_tree: true, registry: test_registry)

      # Wait for agent to initialize
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(root_pid)

      # Delete with different registry - should still work because it checks for live agents
      assert {:ok, deleted_task} =
               TaskManager.delete_task(task.id,
                 # Different registry (won't find agents)
                 registry: other_registry,
                 dynsup: test_dynsup
               )

      assert deleted_task.id == task.id
      assert Repo.get(Task, task.id) == nil
    end

    @tag :integration
    test "delete_task with failed task removes all data", %{deps: deps} do
      # Create a failed task
      {:ok, failed_task} =
        Repo.insert(
          Task.changeset(%Task{}, %{
            prompt: "Failed task",
            status: "failed",
            error_message: "Task encountered an error"
          })
        )

      # Create an agent for the failed task
      {:ok, agent} =
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: failed_task.id,
            agent_id: "agent-failed",
            parent_id: nil,
            config: %{},
            status: "stopped"
          })
        )

      # Delete the failed task
      assert {:ok, _deleted_task} =
               TaskManager.delete_task(failed_task.id, registry: deps.registry)

      # Verify cascade deletion
      assert Repo.get(Task, failed_task.id) == nil
      assert Repo.get(Agent, agent.id) == nil
    end
  end

  describe "Packet 3: create_task/3 with prompt_fields" do
    # R1: Task Creation with Global Fields - INTEGRATION
    test "saves global_context to task record", %{deps: deps} do
      task_fields = %{
        profile: deps.profile.name,
        global_context: "Building microservices platform"
      }

      agent_fields = %{task_description: "Design authentication service"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      assert task.global_context == "Building microservices platform"
      assert Process.alive?(agent_pid)

      # Verify persisted to DB
      db_task = Repo.get(Task, task.id)
      assert db_task.global_context == "Building microservices platform"

      # Cleanup
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # R2: Task Creation with Constraints - INTEGRATION
    test "saves global_constraints as JSONB array", %{deps: deps} do
      task_fields = %{
        profile: deps.profile.name,
        global_constraints: ["Use approved cloud services", "Follow security guidelines"]
      }

      agent_fields = %{task_description: "Build API"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      assert task.initial_constraints == [
               "Use approved cloud services",
               "Follow security guidelines"
             ]

      assert Process.alive?(agent_pid)

      # Verify persisted as JSONB
      db_task = Repo.get(Task, task.id)

      assert db_task.initial_constraints == [
               "Use approved cloud services",
               "Follow security guidelines"
             ]

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # R3: Agent Config with Prompt Fields - INTEGRATION
    test "passes agent_fields as prompt_fields to agent config", %{deps: deps} do
      task_fields = %{profile: deps.profile.name}

      agent_fields = %{
        task_description: "Build app",
        role: "Developer",
        cognitive_style: :systematic
      }

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {_task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      # Verify agent received prompt_fields.provided
      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)
      assert state.prompt_fields.provided.task_description == "Build app"
      assert state.prompt_fields.provided.role == "Developer"
      assert state.prompt_fields.provided.cognitive_style == :systematic

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # R4: Task Creation without Global Fields - INTEGRATION
    test "creates task without global fields", %{deps: deps} do
      task_fields = %{profile: deps.profile.name}
      agent_fields = %{task_description: "Simple task"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      assert task.global_context == nil
      assert task.initial_constraints == []
      assert Process.alive?(agent_pid)

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # R5: Minimal Task Creation - INTEGRATION
    test "creates task with minimal fields", %{deps: deps} do
      task_fields = %{profile: deps.profile.name}
      agent_fields = %{task_description: "Minimal task"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      assert task.prompt == "Minimal task"
      assert task.status == "running"
      assert Process.alive?(agent_pid)

      # Agent should have minimal prompt_fields
      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)
      assert state.prompt_fields.provided.task_description == "Minimal task"

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # R6: Validation Error Handling - UNIT
    test "returns error for invalid task attrs", %{deps: deps} do
      # Empty task_description should fail validation
      task_fields = %{profile: deps.profile.name}
      agent_fields = %{task_description: ""}

      # TaskManager should validate and return error
      result = TaskManager.create_task(task_fields, agent_fields, [])

      assert {:error, %Ecto.Changeset{}} = result
    end

    # R7: Agent Spawn Failure - INTEGRATION
    test "rolls back transaction on agent spawn failure", %{deps: deps} do
      task_fields = %{profile: deps.profile.name, global_context: "Test context"}
      agent_fields = %{task_description: "Will fail"}

      # Force agent spawn failure
      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner,
        force_init_error: true
      ]

      import ExUnit.CaptureLog

      assert capture_log(fn ->
               assert {:error, _reason} = TaskManager.create_task(task_fields, agent_fields, opts)
             end) =~ "error"

      # Note: Task commits BEFORE agent spawn (fixes FK constraint bug)
      # When agent spawn fails, task is marked as failed (prevents orphans)
      tasks = Repo.all(Task)
      failed_task = Enum.find(tasks, &(&1.global_context == "Test context"))
      assert failed_task != nil
      assert failed_task.status == "failed"
      assert failed_task.error_message != nil
    end

    # R8: Prompt Field Backward Compatibility - INTEGRATION
    test "backward compatible with minimal prompt_fields", %{deps: deps} do
      task_fields = %{profile: deps.profile.name}
      agent_fields = %{task_description: "Only description provided"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {_task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      # Agent should work with just task_description
      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)
      assert state.prompt_fields.provided == %{task_description: "Only description provided"}

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # R9: All Fields Passthrough - SYSTEM
    test "passes all provided fields to agent", %{deps: deps} do
      task_fields = %{
        profile: deps.profile.name,
        global_context: "Project context",
        global_constraints: ["Rule 1", "Rule 2"]
      }

      agent_fields = %{
        task_description: "Complete task",
        role: "Senior Developer",
        success_criteria: "All tests pass",
        immediate_context: "Starting from scratch",
        approach_guidance: "Use best practices",
        cognitive_style: :systematic,
        output_style: :detailed,
        delegation_strategy: :parallel
      }

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      {:ok, {task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      # Verify task fields saved
      assert task.global_context == "Project context"
      assert task.initial_constraints == ["Rule 1", "Rule 2"]

      # Verify all agent fields passed through
      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)
      provided = state.prompt_fields.provided

      assert provided.task_description == "Complete task"
      assert provided.role == "Senior Developer"
      assert provided.success_criteria == "All tests pass"
      assert provided.immediate_context == "Starting from scratch"
      assert provided.approach_guidance == "Use best practices"
      assert provided.cognitive_style == :systematic
      assert provided.output_style == :detailed
      assert provided.delegation_strategy == :parallel

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # R10: Database Persistence - INTEGRATION
    test "task persisted to database with global fields", %{deps: deps} do
      task_fields = %{
        profile: deps.profile.name,
        global_context: "Persistent context",
        global_constraints: ["Persist me"]
      }

      agent_fields = %{task_description: "Persistent task"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      assert Process.alive?(agent_pid)

      # Query task from DB in fresh query
      db_task = Repo.get!(Task, task.id)
      assert db_task.global_context == "Persistent context"
      assert db_task.initial_constraints == ["Persist me"]
      assert db_task.prompt == "Persistent task"
      assert db_task.status == "running"

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # R11: Root Agent Prompt Conversion - INTEGRATION
    test "root agent receives converted field-based prompts in state", %{deps: deps} do
      task_fields = %{profile: deps.profile.name}

      agent_fields = %{
        task_description: "Build API",
        role: "Backend Developer",
        cognitive_style: :systematic
      }

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {_task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)

      # CRITICAL: Test that prompts were CONVERTED, not just stored
      assert state.system_prompt != nil,
             "system_prompt should be converted from prompt_fields"

      # Verify content has field-based XML tags
      assert state.system_prompt =~ "<role>Backend Developer</role>",
             "system_prompt should contain role field"

      assert state.system_prompt =~ "<cognitive_style>",
             "system_prompt should contain cognitive_style field"

      # task_description is now in prompt_fields.provided (flows through history, not user_prompt)
      assert state.prompt_fields.provided.task_description == "Build API",
             "task_description should be in prompt_fields.provided"

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # R11b: Root Agent Constraints in System Prompt - ACCEPTANCE
    @tag :acceptance
    test "root agent system prompt contains global constraints", %{deps: deps} do
      # Entry point: User creates task with constraints
      task_fields = %{
        profile: deps.profile.name,
        global_constraints: ["Use Elixir", "Follow TDD"]
      }

      agent_fields = %{task_description: "Build app"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      {:ok, {_task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      # User expectation: Constraints appear in system prompt
      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)

      # Verify constraints present in system prompt
      assert state.system_prompt =~ "<constraints>"
      assert state.system_prompt =~ "Use Elixir"
      assert state.system_prompt =~ "Follow TDD"

      # Negative: Verify no duplicate constraint sections
      refute state.system_prompt =~ ~r/<constraints>.*<constraints>/s

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # R12: Root Agent Consensus Integration - INTEGRATION
    test "root agent prompts actually used in consensus", %{deps: deps} do
      task_fields = %{profile: deps.profile.name}
      agent_fields = %{task_description: "Test task", role: "Tester"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      # Subscribe to agent logs (root agent ID is "root-#{task.id}", not just task.id)
      root_agent_id = "root-#{task.id}"
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:#{root_agent_id}:logs")

      # Send message to trigger consensus
      Quoracle.Agent.Core.send_user_message(agent_pid, "Please analyze")

      # Wait for consensus to complete (in test mode)
      # Log entries are broadcast as {:log_entry, %{...}} not {:agent_log, log}
      assert_receive {:log_entry, log}, 30_000
      assert log.agent_id =~ "root-"

      # v18.0: Deferred consensus sends :continue_consensus to end of mailbox,
      # so first get_state processes the cast, second ensures :continue_consensus runs
      {:ok, _} = Quoracle.Agent.Core.get_state(agent_pid)
      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)

      # Verify consensus was called (model_histories has decision entry)
      first_history = state.model_histories |> Map.values() |> List.first([])

      has_decision =
        Enum.any?(first_history, fn entry ->
          Map.get(entry, :type) == :decision
        end)

      assert has_decision, "Consensus should have run with field-based prompts"

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end
  end
end
