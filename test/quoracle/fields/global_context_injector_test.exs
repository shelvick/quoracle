defmodule Quoracle.Fields.GlobalContextInjectorTest do
  @moduledoc """
  Tests for the GlobalContextInjector module that injects system-level fields from root task.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Fields.GlobalContextInjector
  alias Quoracle.Tasks.Task
  alias Quoracle.Repo

  describe "inject/1" do
    # R1: Global Context Injection - INTEGRATION
    test "injects global_context from task", %{} do
      # Create a task with global context
      {:ok, task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Test task",
          status: "running",
          global_context: "System-wide context for all agents",
          initial_constraints: ["Be secure", "Be efficient"]
        })
        |> Repo.insert()

      result = GlobalContextInjector.inject(task.id)

      assert result.global_context == "System-wide context for all agents"
      assert result.constraints == ["Be secure", "Be efficient"]
    end

    # R2: Missing Task Handling - INTEGRATION
    test "handles missing task gracefully", %{} do
      non_existent_id = Ecto.UUID.generate()

      result = GlobalContextInjector.inject(non_existent_id)

      assert result.global_context == ""
      assert result.constraints == []
    end

    # R5: Empty Field Defaults - UNIT
    test "provides empty defaults for missing fields", %{} do
      # Task with no global fields
      {:ok, task} =
        %Task{}
        |> Task.changeset(%{
          prompt: "Task without global fields",
          status: "running"
        })
        |> Repo.insert()

      result = GlobalContextInjector.inject(task.id)

      assert result.global_context == ""
      assert result.constraints == []
    end

    test "handles task with nil global_context", %{} do
      {:ok, task} =
        %Task{}
        |> Task.changeset(%{
          prompt: "Task with nil context",
          status: "running",
          global_context: nil,
          initial_constraints: nil
        })
        |> Repo.insert()

      result = GlobalContextInjector.inject(task.id)

      assert result.global_context == ""
      assert result.constraints == []
    end

    test "returns both fields in correct structure", %{} do
      {:ok, task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Full task",
          status: "running",
          global_context: "Context",
          initial_constraints: ["C1", "C2"]
        })
        |> Repo.insert()

      result = GlobalContextInjector.inject(task.id)

      assert is_map(result)
      assert Map.keys(result) |> Enum.sort() == [:constraints, :global_context]
      assert is_binary(result.global_context)
      assert is_list(result.constraints)
    end
  end

  describe "database error handling" do
    # R4: Database Error Handling - INTEGRATION
    test "handles database connection errors gracefully" do
      # Test without sandbox ownership
      # This simulates what happens when DB is unavailable
      # The implementation should catch DBConnection.OwnershipError

      # Call inject from a spawned process (without sandbox access)
      # This will trigger DBConnection.OwnershipError which should be caught
      task =
        Elixir.Task.async(fn ->
          GlobalContextInjector.inject("any-id")
        end)

      result = Elixir.Task.await(task)

      # Should return safe defaults when DB is inaccessible
      assert result.global_context == ""
      assert result.constraints == []
    end
  end

  describe "integration scenarios" do
    test "basic injection flow with constraints", %{} do
      # Create task with initial constraints
      {:ok, task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Root task",
          status: "running",
          global_context: "This is the global context shared by all agents in the hierarchy.",
          initial_constraints: [
            "Follow security best practices",
            "Optimize for performance",
            "Maintain audit trail"
          ]
        })
        |> Repo.insert()

      result = GlobalContextInjector.inject(task.id)

      assert result.global_context ==
               "This is the global context shared by all agents in the hierarchy."

      assert result.constraints == [
               "Follow security best practices",
               "Optimize for performance",
               "Maintain audit trail"
             ]
    end

    test "handles malformed task data gracefully", %{} do
      # Create task with unexpected data types
      {:ok, task} =
        %Task{}
        |> Task.changeset(%{
          prompt: "Malformed task",
          status: "running"
        })
        |> Repo.insert()

      # Manually update with invalid data (bypassing changeset validation)
      # This simulates corrupted data in DB
      # Convert string UUID to binary format for Postgrex
      Repo.query!(
        "UPDATE tasks SET initial_constraints = $1::jsonb WHERE id = $2",
        [~s("not an array"), Ecto.UUID.dump!(task.id)]
      )

      # Should handle gracefully
      result = GlobalContextInjector.inject(task.id)

      # Falls back to safe defaults or handles corrupted data
      assert result.global_context == ""
      assert is_list(result.constraints)
    end
  end

  describe "performance considerations" do
    test "handles large constraint lists efficiently", %{} do
      # Create task with many constraints
      large_constraints = for i <- 1..100, do: "Constraint #{i}"

      {:ok, task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Task with many constraints",
          status: "running",
          global_context: "Context",
          initial_constraints: large_constraints
        })
        |> Repo.insert()

      result = GlobalContextInjector.inject(task.id)

      # Should handle large lists
      assert length(result.constraints) == 100
      assert result.constraints == Enum.uniq(result.constraints)
    end

    test "caching behavior for repeated calls", %{} do
      {:ok, task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Cached task",
          status: "running",
          global_context: "Context for caching",
          initial_constraints: ["C1"]
        })
        |> Repo.insert()

      # Multiple calls should return consistent results
      result1 = GlobalContextInjector.inject(task.id)
      result2 = GlobalContextInjector.inject(task.id)
      result3 = GlobalContextInjector.inject(task.id)

      assert result1 == result2
      assert result2 == result3
      assert result1.global_context == "Context for caching"
    end
  end
end
