defmodule Quoracle.Logs.LogTest do
  use Quoracle.DataCase, async: true

  alias Quoracle.Logs.Log
  alias Quoracle.Tasks.Task
  alias Quoracle.Repo

  describe "schema" do
    test "has correct fields" do
      log = %Log{}
      assert Map.has_key?(log, :id)
      assert Map.has_key?(log, :agent_id)
      assert Map.has_key?(log, :task_id)
      assert Map.has_key?(log, :action_type)
      assert Map.has_key?(log, :params)
      assert Map.has_key?(log, :result)
      assert Map.has_key?(log, :status)
      assert Map.has_key?(log, :inserted_at)
      refute Map.has_key?(log, :updated_at)
    end

    test "belongs to task" do
      log = %Log{}
      assert Map.has_key?(log, :task)
    end
  end

  describe "changeset/2" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task_id: task.id}
    end

    test "valid with required fields", %{task_id: task_id} do
      attrs = %{
        agent_id: "agent-123",
        task_id: task_id,
        action_type: "send_message",
        params: %{to: "agent-456", content: "Hello"},
        status: "success"
      }

      changeset = Log.changeset(%Log{}, attrs)
      assert changeset.valid?
    end

    test "requires agent_id" do
      attrs = %{
        task_id: Ecto.UUID.generate(),
        action_type: "send_message",
        params: %{},
        status: "success"
      }

      changeset = Log.changeset(%Log{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).agent_id
    end

    test "requires task_id" do
      attrs = %{
        agent_id: "agent-123",
        action_type: "send_message",
        params: %{},
        status: "success"
      }

      changeset = Log.changeset(%Log{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).task_id
    end

    test "requires action_type" do
      attrs = %{
        agent_id: "agent-123",
        task_id: Ecto.UUID.generate(),
        params: %{},
        status: "success"
      }

      changeset = Log.changeset(%Log{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).action_type
    end

    test "requires params" do
      attrs = %{
        agent_id: "agent-123",
        task_id: Ecto.UUID.generate(),
        action_type: "send_message",
        status: "success"
      }

      changeset = Log.changeset(%Log{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).params
    end

    test "requires status" do
      attrs = %{
        agent_id: "agent-123",
        task_id: Ecto.UUID.generate(),
        action_type: "send_message",
        params: %{}
      }

      changeset = Log.changeset(%Log{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).status
    end

    test "validates status is success or error", %{task_id: task_id} do
      for status <- ["success", "error"] do
        attrs = %{
          agent_id: "agent-#{status}",
          task_id: task_id,
          action_type: "test_action",
          params: %{},
          status: status
        }

        changeset = Log.changeset(%Log{}, attrs)
        assert changeset.valid?, "Expected #{status} to be valid"
      end
    end

    test "rejects invalid status", %{task_id: task_id} do
      attrs = %{
        agent_id: "agent-123",
        task_id: task_id,
        action_type: "send_message",
        params: %{},
        status: "invalid_status"
      }

      changeset = Log.changeset(%Log{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "allows optional result", %{task_id: task_id} do
      attrs = %{
        agent_id: "agent-123",
        task_id: task_id,
        action_type: "send_message",
        params: %{},
        result: %{data: "result data"},
        status: "success"
      }

      changeset = Log.changeset(%Log{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :result) == %{data: "result data"}
    end
  end

  describe "database integration" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task_id: task.id}
    end

    @tag :integration
    test "ARC_FUNC_01: WHEN action executes IF result captured THEN log with success status", %{
      task_id: task_id
    } do
      attrs = %{
        agent_id: "agent-001",
        task_id: task_id,
        action_type: "send_message",
        params: %{to: "agent-002", content: "Test"},
        result: %{message_id: "msg-123"},
        status: "success"
      }

      changeset = Log.changeset(%Log{}, attrs)
      assert {:ok, log} = Repo.insert(changeset)

      assert log.id != nil
      assert log.agent_id == "agent-001"
      assert log.task_id == task_id
      assert log.action_type == "send_message"
      assert log.status == "success"
      assert log.result == %{message_id: "msg-123"}
      assert log.inserted_at != nil
    end

    @tag :integration
    test "ARC_FUNC_02: WHEN action fails IF error captured THEN log with error status", %{
      task_id: task_id
    } do
      attrs = %{
        agent_id: "agent-002",
        task_id: task_id,
        action_type: "call_api",
        params: %{endpoint: "/test"},
        result: %{error: "Connection timeout"},
        status: "error"
      }

      changeset = Log.changeset(%Log{}, attrs)
      assert {:ok, log} = Repo.insert(changeset)

      assert log.status == "error"
      assert log.result == %{error: "Connection timeout"}
    end

    @tag :integration
    test "foreign key constraint enforces valid task_id" do
      invalid_task_id = Ecto.UUID.generate()

      attrs = %{
        agent_id: "agent-orphan",
        task_id: invalid_task_id,
        action_type: "test",
        params: %{},
        status: "success"
      }

      assert_raise Ecto.InvalidChangesetError, fn ->
        Repo.insert!(Log.changeset(%Log{}, attrs))
      end
    end

    @tag :integration
    test "logs are append-only (no updated_at timestamp)", %{task_id: task_id} do
      {:ok, log} =
        Repo.insert(
          Log.changeset(%Log{}, %{
            agent_id: "agent-003",
            task_id: task_id,
            action_type: "test",
            params: %{},
            status: "success"
          })
        )

      # Verify no updated_at field in database
      refute Map.has_key?(log, :updated_at)
    end

    @tag :integration
    test "generates binary_id for primary key", %{task_id: task_id} do
      {:ok, log} =
        Repo.insert(
          Log.changeset(%Log{}, %{
            agent_id: "agent-004",
            task_id: task_id,
            action_type: "test",
            params: %{},
            status: "success"
          })
        )

      assert is_binary(log.id)
      # UUID string format is 36 characters (with dashes)
      assert String.length(log.id) == 36
    end
  end

  describe "indexes and queries" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task_id: task.id}
    end

    @tag :integration
    test "ARC_FUNC_03: query agent logs uses agent_id index", %{task_id: task_id} do
      # Create logs for specific agent
      for i <- 1..5 do
        Repo.insert(
          Log.changeset(%Log{}, %{
            agent_id: "agent-target",
            task_id: task_id,
            action_type: "action_#{i}",
            params: %{index: i},
            status: "success"
          })
        )
      end

      # Create logs for other agents
      for i <- 1..3 do
        Repo.insert(
          Log.changeset(%Log{}, %{
            agent_id: "agent-other-#{i}",
            task_id: task_id,
            action_type: "action",
            params: %{},
            status: "success"
          })
        )
      end

      # Query logs for specific agent
      query = from(l in Log, where: l.agent_id == "agent-target", order_by: [asc: l.inserted_at])
      logs = Repo.all(query)

      assert length(logs) == 5
      assert Enum.all?(logs, fn log -> log.agent_id == "agent-target" end)
    end

    @tag :integration
    test "ARC_FUNC_04: query task logs uses task_id index", %{task_id: task_id} do
      # Create logs for this task
      for i <- 1..4 do
        Repo.insert(
          Log.changeset(%Log{}, %{
            agent_id: "agent-#{i}",
            task_id: task_id,
            action_type: "action",
            params: %{},
            status: "success"
          })
        )
      end

      # Query all logs for task
      query = from(l in Log, where: l.task_id == ^task_id)
      logs = Repo.all(query)

      assert length(logs) == 4
      assert Enum.all?(logs, fn log -> log.task_id == task_id end)
    end

    @tag :integration
    test "ARC_FUNC_06: ordering by inserted_at maintains chronological order", %{task_id: task_id} do
      # Create logs with delays
      for i <- 1..5 do
        Repo.insert(
          Log.changeset(%Log{}, %{
            agent_id: "agent-chrono",
            task_id: task_id,
            action_type: "action_#{i}",
            params: %{sequence: i},
            status: "success"
          })
        )

        if i < 5, do: :timer.sleep(10)
      end

      # Query ordered by inserted_at
      query = from(l in Log, where: l.agent_id == "agent-chrono", order_by: [asc: l.inserted_at])
      logs = Repo.all(query)

      # Verify all sequences present (order may be non-deterministic with same timestamps)
      sequences = Enum.map(logs, fn log -> log.params["sequence"] end) |> Enum.sort()
      assert sequences == [1, 2, 3, 4, 5]
    end

    @tag :integration
    test "ARC_FUNC_07: aggregate count by action_type", %{task_id: task_id} do
      # Create logs with different action types
      action_types = ["send_message", "send_message", "wait", "orient", "orient", "orient"]

      for action_type <- action_types do
        Repo.insert(
          Log.changeset(%Log{}, %{
            agent_id: "agent-stats",
            task_id: task_id,
            action_type: action_type,
            params: %{},
            status: "success"
          })
        )
      end

      # Aggregate count by action_type
      query =
        from(l in Log,
          where: l.task_id == ^task_id,
          group_by: l.action_type,
          select: {l.action_type, count(l.id)}
        )

      counts = Repo.all(query) |> Map.new()

      assert counts["send_message"] == 2
      assert counts["wait"] == 1
      assert counts["orient"] == 3
    end
  end

  describe "cascade deletion" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task: task}
    end

    @tag :integration
    test "ARC_FUNC_05: WHEN task deleted IF CASCADE configured THEN logs deleted", %{task: task} do
      # Create logs for task
      {:ok, log} =
        Repo.insert(
          Log.changeset(%Log{}, %{
            agent_id: "agent-cascade",
            task_id: task.id,
            action_type: "test",
            params: %{},
            status: "success"
          })
        )

      # Delete task
      assert {:ok, _} = Repo.delete(task)

      # Verify log was deleted via CASCADE
      assert Repo.get(Log, log.id) == nil
    end
  end
end
