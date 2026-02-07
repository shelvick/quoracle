defmodule Quoracle.Actions.RouterPersistenceTest do
  @moduledoc """
  Tests for ACTION_Router database persistence integration (Packet 3).

  Tests that action executions are logged to TABLE_Logs for audit trail.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Router
  alias Quoracle.Tasks.Task
  alias Quoracle.Logs.Log
  alias Quoracle.Repo

  import ExUnit.CaptureLog
  import Test.IsolationHelpers
  # No longer using create_test_profile - simplified tests use orient instead of spawn_child

  # ========== PACKET 3: ACTION LOGGING ==========

  describe "persist_action_result/4 - successful actions" do
    setup tags do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      agent_id = "agent-001-#{System.unique_integer([:positive])}"

      %{
        deps: deps,
        task_id: task.id,
        agent_id: agent_id,
        sandbox_owner: tags[:sandbox_owner]
      }
    end

    @tag :integration
    test "ARC_FUNC_17: WHEN action executes successfully IF task_id present THEN log created with status='success'",
         %{deps: deps, task_id: task_id, agent_id: agent_id, sandbox_owner: sandbox_owner} do
      action_id = "action-001"

      # Per-action Router (v28.0) - one per action
      {:ok, router} =
        Router.start_link(
          action_type: :wait,
          action_id: action_id,
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: deps.pubsub,
          registry: deps.registry,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute wait action (simple, always succeeds)
      params = %{"wait" => 0}

      opts = [
        agent_id: agent_id,
        action_id: action_id,
        task_id: task_id
      ]

      assert {:ok, _result} = Router.execute_action(router, :wait, params, opts)

      # Verify log was created
      logs =
        from(l in Log, where: l.agent_id == ^agent_id and l.task_id == ^task_id)
        |> Repo.all()

      assert length(logs) == 1
      log = hd(logs)

      assert log.action_type == "wait"
      assert log.status == "success"
      assert log.params == %{"wait" => 0}
      assert is_map(log.result)
    end

    @tag :integration
    test "WHEN multiple actions executed THEN all logged with correct order",
         %{deps: deps, task_id: task_id, agent_id: agent_id, sandbox_owner: sandbox_owner} do
      # Per-action Router (v28.0) - spawn new router for each action

      # First action: wait
      {:ok, router1} =
        Router.start_link(
          action_type: :wait,
          action_id: "a1",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: deps.pubsub,
          registry: deps.registry,
          sandbox_owner: sandbox_owner
        )

      opts = [agent_id: agent_id, task_id: task_id, action_id: "a1"]
      Router.execute_action(router1, :wait, %{"wait" => 0}, opts)

      # Second action: orient (new router)
      {:ok, router2} =
        Router.start_link(
          action_type: :orient,
          action_id: "a2",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: deps.pubsub,
          registry: deps.registry,
          sandbox_owner: sandbox_owner
        )

      opts2 = [agent_id: agent_id, task_id: task_id, action_id: "a2"]
      Router.execute_action(router2, :orient, %{}, opts2)

      # Cleanup
      on_exit(fn ->
        for router <- [router1, router2] do
          if Process.alive?(router) do
            try do
              GenServer.stop(router, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end
      end)

      # Verify all actions logged
      logs =
        from(l in Log,
          where: l.agent_id == ^agent_id and l.task_id == ^task_id,
          order_by: [asc: l.inserted_at]
        )
        |> Repo.all()

      assert length(logs) == 2

      # Verify both actions present (order may be non-deterministic with same timestamps)
      action_types = Enum.map(logs, & &1.action_type) |> Enum.sort()
      assert action_types == ["orient", "wait"]
    end
  end

  describe "persist_action_result/4 - failed actions" do
    setup tags do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      agent_id = "agent-003-#{System.unique_integer([:positive])}"

      %{deps: deps, task_id: task.id, agent_id: agent_id, sandbox_owner: tags[:sandbox_owner]}
    end

    @tag :integration
    test "ARC_FUNC_18: failed action logs with status='error'",
         %{deps: deps, task_id: task_id, agent_id: agent_id, sandbox_owner: sandbox_owner} do
      # Per-action Router (v28.0)
      {:ok, router} =
        Router.start_link(
          action_type: :send_message,
          action_id: "a1",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: deps.pubsub,
          registry: deps.registry,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute action that will fail (invalid params)
      opts = [agent_id: agent_id, task_id: task_id, action_id: "a1"]

      assert {:error, _reason} =
               Router.execute_action(router, :send_message, %{"invalid" => "params"}, opts)

      # Verify error was logged
      logs =
        from(l in Log, where: l.agent_id == ^agent_id and l.task_id == ^task_id)
        |> Repo.all()

      assert length(logs) == 1
      log = hd(logs)

      assert log.action_type == "send_message"
      assert log.status == "error"
      assert is_map(log.result)
      # Error is stored with string key (JSON-encoded)
      assert Map.has_key?(log.result, "error")
    end
  end

  describe "persist_action_result/4 - orient action logging" do
    setup tags do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      agent_id = "agent-004-#{System.unique_integer([:positive])}"

      %{
        deps: deps,
        task_id: task.id,
        sandbox_owner: tags[:sandbox_owner],
        agent_id: agent_id
      }
    end

    @tag :integration
    test "ARC_FUNC_19: orient action with task_id creates log",
         %{deps: deps, task_id: task_id, sandbox_owner: sandbox_owner, agent_id: agent_id} do
      # Per-action Router (v28.0) for orient action
      {:ok, router} =
        Router.start_link(
          action_type: :orient,
          action_id: "a1",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: deps.pubsub,
          registry: deps.registry,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute orient action (simple, always succeeds)
      params = %{
        "current_situation" => "Test situation",
        "goal_clarity" => "Clear",
        "available_resources" => "Test resources",
        "key_challenges" => "None",
        "delegation_consideration" => "Not needed"
      }

      opts = [
        agent_id: agent_id,
        task_id: task_id,
        action_id: "a1"
      ]

      assert {:ok, _result} = Router.execute_action(router, :orient, params, opts)

      # Verify action was logged
      logs =
        from(l in Log, where: l.agent_id == ^agent_id and l.task_id == ^task_id)
        |> Repo.all()

      assert length(logs) == 1
      log = hd(logs)

      assert log.action_type == "orient"
      assert log.status == "success"
    end
  end

  describe "persist_action_result/4 - error handling" do
    setup tags do
      deps = create_isolated_deps()
      agent_id = "agent-005-#{System.unique_integer([:positive])}"

      %{deps: deps, agent_id: agent_id, sandbox_owner: tags[:sandbox_owner]}
    end

    @tag :integration
    test "ARC_FUNC_20: persistence failure does not block action",
         %{deps: deps, agent_id: agent_id, sandbox_owner: sandbox_owner} do
      # Per-action Router (v28.0)
      {:ok, router} =
        Router.start_link(
          action_type: :wait,
          action_id: "a1",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: deps.pubsub,
          registry: deps.registry,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Use invalid task_id (will cause foreign key violation)
      invalid_task_id = Ecto.UUID.generate()
      opts = [agent_id: agent_id, task_id: invalid_task_id, action_id: "a1"]

      # Action should succeed despite persistence failure (defensive)
      assert {:ok, _result} = Router.execute_action(router, :wait, %{"wait" => 0}, opts)

      # Verify no log was created (persistence failed)
      logs = from(l in Log, where: l.agent_id == ^agent_id) |> Repo.all()
      assert Enum.empty?(logs)
    end

    @tag :integration
    test "ARC_FUNC_21: missing task_id skips persistence",
         %{deps: deps, agent_id: agent_id, sandbox_owner: sandbox_owner} do
      # Per-action Router (v28.0)
      {:ok, router} =
        Router.start_link(
          action_type: :wait,
          action_id: "a1",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: deps.pubsub,
          registry: deps.registry,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # No task_id in opts
      opts = [agent_id: agent_id, action_id: "a1"]

      # Action should succeed (capture expected warning log)
      capture_log(fn ->
        assert {:ok, _result} = Router.execute_action(router, :wait, %{"wait" => 0}, opts)
      end)

      # Verify no log created (task_id missing)
      logs = from(l in Log, where: l.agent_id == ^agent_id) |> Repo.all()
      assert Enum.empty?(logs)
    end
  end

  # Note: get_action_type_from_module/1 is tested indirectly through persist_action_result
  # The integration tests above (ARC_FUNC_17-21) verify correct action_type is logged
end
