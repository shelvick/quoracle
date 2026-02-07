defmodule Quoracle.Tasks.TaskBudgetLimitTest do
  @moduledoc """
  Tests for TABLE_Tasks budget_limit field modification.

  WorkGroupID: wip-20251231-budget
  Packet: 2 (Tracker Integration)

  ARC Verification Criteria:
  - R11: Budget Limit Nullable [UNIT]
  - R12: Budget Limit Positive [UNIT]
  - R13: Budget Limit Precision [UNIT]
  - R14: Budget Limit Update [UNIT]
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Tasks.Task
  alias Quoracle.Repo

  describe "R11: budget limit nullable" do
    # R11: WHEN task created without budget_limit THEN NULL stored
    test "accepts nil budget_limit as N/A" do
      attrs = %{prompt: "Test prompt", status: "running", budget_limit: nil}
      changeset = Task.changeset(%Task{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :budget_limit) == nil
    end

    test "task created without budget_limit stores NULL" do
      attrs = %{prompt: "Test prompt", status: "running"}
      changeset = Task.changeset(%Task{}, attrs)

      assert {:ok, task} = Repo.insert(changeset)
      assert task.budget_limit == nil

      # Verify persistence
      reloaded = Repo.get!(Task, task.id)
      assert reloaded.budget_limit == nil
    end
  end

  describe "R12: budget limit positive" do
    # R12: WHEN budget_limit provided THEN must be positive Decimal
    test "validates budget_limit is positive - zero rejected" do
      attrs = %{prompt: "Test prompt", status: "running", budget_limit: Decimal.new("0")}
      changeset = Task.changeset(%Task{}, attrs)

      refute changeset.valid?
      assert "must be positive" in errors_on(changeset).budget_limit
    end

    test "validates negative budget_limit rejected" do
      attrs = %{prompt: "Test prompt", status: "running", budget_limit: Decimal.new("-10.00")}
      changeset = Task.changeset(%Task{}, attrs)

      refute changeset.valid?
      assert "must be positive" in errors_on(changeset).budget_limit
    end

    test "accepts positive budget_limit" do
      attrs = %{prompt: "Test prompt", status: "running", budget_limit: Decimal.new("100.00")}
      changeset = Task.changeset(%Task{}, attrs)

      assert changeset.valid?
      assert Decimal.equal?(get_change(changeset, :budget_limit), Decimal.new("100.00"))
    end

    test "accepts small positive budget_limit" do
      attrs = %{prompt: "Test prompt", status: "running", budget_limit: Decimal.new("0.01")}
      changeset = Task.changeset(%Task{}, attrs)

      assert changeset.valid?
    end
  end

  describe "R13: budget limit precision" do
    # R13: WHEN large budget set THEN full precision preserved
    @tag :integration
    test "preserves Decimal precision for budget_limit" do
      large_budget = Decimal.new("123456789.12")
      attrs = %{prompt: "Test prompt", status: "running", budget_limit: large_budget}
      changeset = Task.changeset(%Task{}, attrs)

      assert {:ok, task} = Repo.insert(changeset)
      assert Decimal.equal?(task.budget_limit, large_budget)

      # Verify full precision preserved in DB
      reloaded = Repo.get!(Task, task.id)
      assert Decimal.equal?(reloaded.budget_limit, large_budget)
    end

    @tag :integration
    test "preserves 2 decimal places for currency" do
      attrs = %{prompt: "Test prompt", status: "running", budget_limit: Decimal.new("99.99")}
      changeset = Task.changeset(%Task{}, attrs)

      assert {:ok, task} = Repo.insert(changeset)
      assert Decimal.equal?(task.budget_limit, Decimal.new("99.99"))
    end
  end

  describe "R14: budget limit update" do
    # R14: WHEN budget_limit_changeset called THEN validates and updates
    test "budget_limit_changeset updates budget" do
      # Create task via changeset (budget_limit field may not exist on struct yet)
      task = %Task{prompt: "Test", status: "running"}
      new_limit = Decimal.new("100.00")

      changeset = Task.budget_limit_changeset(task, new_limit)

      assert changeset.valid?
      assert Decimal.equal?(get_change(changeset, :budget_limit), new_limit)
    end

    test "budget_limit_changeset validates positive" do
      task = %Task{prompt: "Test", status: "running"}

      changeset = Task.budget_limit_changeset(task, Decimal.new("0"))

      refute changeset.valid?
      assert "must be positive" in errors_on(changeset).budget_limit
    end

    test "budget_limit_changeset allows nil (remove limit)" do
      task = %Task{prompt: "Test", status: "running"}

      changeset = Task.budget_limit_changeset(task, nil)

      assert changeset.valid?
      assert get_change(changeset, :budget_limit) == nil
    end

    @tag :integration
    test "budget_limit_changeset persists update" do
      {:ok, task} =
        Repo.insert(
          Task.changeset(%Task{}, %{
            prompt: "Test",
            status: "running",
            budget_limit: Decimal.new("50.00")
          })
        )

      changeset = Task.budget_limit_changeset(task, Decimal.new("200.00"))
      assert {:ok, updated} = Repo.update(changeset)

      assert Decimal.equal?(updated.budget_limit, Decimal.new("200.00"))

      # Verify persistence
      reloaded = Repo.get!(Task, updated.id)
      assert Decimal.equal?(reloaded.budget_limit, Decimal.new("200.00"))
    end
  end
end
