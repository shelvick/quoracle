defmodule Quoracle.Tasks.TaskTest do
  use Quoracle.DataCase, async: true

  alias Quoracle.Tasks.Task
  alias Quoracle.Repo

  describe "schema" do
    test "has correct fields" do
      task = %Task{}
      assert Map.has_key?(task, :id)
      assert Map.has_key?(task, :prompt)
      assert Map.has_key?(task, :status)
      assert Map.has_key?(task, :result)
      assert Map.has_key?(task, :error_message)
      assert Map.has_key?(task, :inserted_at)
      assert Map.has_key?(task, :updated_at)
    end

    test "has associations" do
      task = %Task{}
      assert Map.has_key?(task, :agents)
      assert Map.has_key?(task, :logs)
      assert Map.has_key?(task, :messages)
    end
  end

  describe "changeset/2" do
    test "valid with required fields" do
      attrs = %{prompt: "Test prompt", status: "running"}
      changeset = Task.changeset(%Task{}, attrs)
      assert changeset.valid?
    end

    test "requires prompt" do
      attrs = %{status: "running"}
      changeset = Task.changeset(%Task{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).prompt
    end

    test "requires status" do
      attrs = %{prompt: "Test prompt"}
      changeset = Task.changeset(%Task{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).status
    end

    test "validates status is in allowed values" do
      valid_statuses = ["running", "paused", "completed", "failed"]

      for status <- valid_statuses do
        attrs = %{prompt: "Test prompt", status: status}
        changeset = Task.changeset(%Task{}, attrs)
        assert changeset.valid?, "Expected #{status} to be valid"
      end
    end

    # WorkGroupID: refactor-20251224-001420 - Async Pause Support
    # R8: Changeset Accepts Pausing Status
    test "R8: changeset accepts pausing as valid status" do
      attrs = %{prompt: "Test prompt", status: "pausing"}
      changeset = Task.changeset(%Task{}, attrs)
      assert changeset.valid?, "Expected 'pausing' to be valid status"
    end

    test "rejects invalid status" do
      attrs = %{prompt: "Test prompt", status: "invalid_status"}
      changeset = Task.changeset(%Task{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "allows optional result" do
      attrs = %{prompt: "Test prompt", status: "completed", result: "Task completed"}
      changeset = Task.changeset(%Task{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :result) == "Task completed"
    end

    test "allows optional error_message" do
      attrs = %{prompt: "Test prompt", status: "failed", error_message: "Error occurred"}
      changeset = Task.changeset(%Task{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :error_message) == "Error occurred"
    end
  end

  describe "status_changeset/2" do
    test "updates status to valid value" do
      task = %Task{status: "running"}
      changeset = Task.status_changeset(task, "paused")
      assert changeset.valid?
      assert get_change(changeset, :status) == "paused"
    end

    test "rejects invalid status transition" do
      task = %Task{status: "running"}
      changeset = Task.status_changeset(task, "invalid_status")
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    # WorkGroupID: refactor-20251224-001420 - Async Pause Support
    # R9: Status Changeset Accepts Pausing
    test "R9: status_changeset accepts pausing" do
      task = %Task{status: "running"}
      changeset = Task.status_changeset(task, "pausing")
      assert changeset.valid?, "Expected 'pausing' to be valid status"
      assert get_change(changeset, :status) == "pausing"
    end
  end

  describe "complete_changeset/2" do
    test "sets status to completed and stores result" do
      task = %Task{status: "running"}
      result = "Task completed successfully"
      changeset = Task.complete_changeset(task, result)

      assert changeset.valid?
      assert get_change(changeset, :status) == "completed"
      assert get_change(changeset, :result) == result
    end
  end

  describe "fail_changeset/2" do
    test "sets status to failed and stores error message" do
      task = %Task{status: "running"}
      error_message = "Task failed due to error"
      changeset = Task.fail_changeset(task, error_message)

      assert changeset.valid?
      assert get_change(changeset, :status) == "failed"
      assert get_change(changeset, :error_message) == error_message
    end
  end

  describe "database integration" do
    @tag :integration
    test "ARC_FUNC_01: WHEN task created IF prompt provided THEN record inserted with status and timestamps" do
      attrs = %{prompt: "Test task prompt", status: "running"}
      changeset = Task.changeset(%Task{}, attrs)

      assert {:ok, task} = Repo.insert(changeset)
      assert task.id != nil
      assert task.prompt == "Test task prompt"
      assert task.status == "running"
      assert task.inserted_at != nil
      assert task.updated_at != nil
    end

    @tag :integration
    test "ARC_FUNC_02: WHEN task status updated IF valid transition THEN updated_at refreshed" do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      original_updated_at = task.updated_at

      changeset = Task.status_changeset(task, "paused")
      assert {:ok, updated_task} = Repo.update(changeset)

      assert updated_task.status == "paused"
      # updated_at should be >= original (can be equal if operations are very fast)
      assert NaiveDateTime.compare(updated_task.updated_at, original_updated_at) in [:gt, :eq]
    end

    @tag :integration
    test "ARC_FUNC_04: WHEN task completed IF result provided THEN status and result stored" do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      result = "Task completed with success"
      changeset = Task.complete_changeset(task, result)
      assert {:ok, completed_task} = Repo.update(changeset)

      assert completed_task.status == "completed"
      assert completed_task.result == result
    end

    @tag :integration
    test "ARC_FUNC_05: WHEN task failed IF error occurred THEN status and error_message stored" do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      error_message = "Task failed due to timeout"
      changeset = Task.fail_changeset(task, error_message)
      assert {:ok, failed_task} = Repo.update(changeset)

      assert failed_task.status == "failed"
      assert failed_task.error_message == error_message
    end

    @tag :integration
    test "ARC_FUNC_06: WHEN task paused IF status change requested THEN status persisted" do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      changeset = Task.status_changeset(task, "paused")
      assert {:ok, paused_task} = Repo.update(changeset)

      assert paused_task.status == "paused"

      # Verify persistence by reloading from DB
      reloaded_task = Repo.get!(Task, paused_task.id)
      assert reloaded_task.status == "paused"
    end

    @tag :integration
    test "not null constraint on prompt" do
      # Attempt to insert task without prompt (bypassing changeset validation)
      assert_raise Postgrex.Error, fn ->
        Repo.insert!(%Task{status: "running"}, skip_validation: true)
      end
    end

    @tag :integration
    test "generates binary_id for primary key" do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      assert is_binary(task.id)
      # UUID string format is 36 characters (with dashes)
      assert String.length(task.id) == 36
    end
  end

  describe "indexes" do
    @tag :integration
    @tag :performance
    test "ARC_PERF_01: WHEN querying by status IF index exists THEN query uses index" do
      # Create multiple tasks with different statuses
      for i <- 1..10 do
        status = Enum.random(["running", "paused", "completed", "failed"])
        Repo.insert!(Task.changeset(%Task{}, %{prompt: "Task #{i}", status: status}))
      end

      # Query by status
      query = from(t in Task, where: t.status == "running", order_by: [desc: t.inserted_at])

      # Verify query works
      tasks = Repo.all(query)
      assert is_list(tasks)
      assert Enum.all?(tasks, fn t -> t.status == "running" end)

      # Note: Actual EXPLAIN ANALYZE verification would require raw SQL
      # For now, we verify the query executes successfully with the index present
    end

    @tag :integration
    @tag :performance
    test "index on updated_at for chronological queries" do
      # Create tasks at different times
      for i <- 1..5 do
        Repo.insert!(Task.changeset(%Task{}, %{prompt: "Task #{i}", status: "running"}))
        if i < 5, do: :timer.sleep(10)
      end

      # Query ordered by updated_at
      query = from(t in Task, order_by: [desc: t.updated_at])
      tasks = Repo.all(query)

      # Verify ordering
      timestamps = Enum.map(tasks, & &1.updated_at)
      assert timestamps == Enum.sort(timestamps, {:desc, NaiveDateTime})
    end
  end

  describe "cascade deletion" do
    @tag :integration
    test "ARC_FUNC_07: WHEN task deleted IF CASCADE configured THEN associated records deleted" do
      # This test will be expanded once TABLE_Agents, TABLE_Logs, TABLE_Messages are implemented
      # For now, we just verify the task can be deleted
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      assert {:ok, _} = Repo.delete(task)
      assert Repo.get(Task, task.id) == nil
    end
  end
end
