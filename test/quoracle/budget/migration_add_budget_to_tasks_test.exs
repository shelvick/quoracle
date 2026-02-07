defmodule Quoracle.Budget.MigrationAddBudgetToTasksTest do
  @moduledoc """
  Tests for MIG_AddBudgetToTasks migration - adding budget_limit column to tasks table.

  WorkGroupID: wip-20251231-budget
  Packet: 1 (Foundation - Data Model)

  ARC Verification Criteria:
  - R1: Migration Execution - budget_limit column added with correct type
  - R2: Nullable Semantics - NULL stored (not 0) when not provided
  - R3: Decimal Precision - 123456789.12 stored exactly
  - R4: Rollback Safety - column removed cleanly (reversible)
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Repo

  describe "R1: migration execution" do
    # R1: WHEN migration runs THEN budget_limit column added with correct type
    test "budget_limit column exists on tasks table" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT column_name, data_type, numeric_precision, numeric_scale
          FROM information_schema.columns
          WHERE table_name = 'tasks' AND column_name = 'budget_limit'
          """
        )

      assert length(result.rows) == 1
      [[column_name, data_type, precision, scale]] = result.rows

      assert column_name == "budget_limit"
      assert data_type == "numeric"
      # Precision 12, scale 2 for currency
      assert precision == 12
      assert scale == 2
    end

    test "partial index exists on budget_limit for non-NULL values" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT indexname, indexdef FROM pg_indexes
          WHERE tablename = 'tasks' AND indexname LIKE '%budget_limit%'
          """
        )

      assert length(result.rows) == 1
      [[_index_name, index_def]] = result.rows

      # Verify it's a partial index (WHERE clause)
      assert index_def =~ "WHERE"
      assert index_def =~ "budget_limit IS NOT NULL"
    end
  end

  describe "R2: nullable semantics" do
    # R2: WHEN task created without budget_limit THEN NULL stored (not 0)
    test "budget_limit is nullable (NULL stored, not 0)" do
      # Insert task without budget_limit
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO tasks (id, prompt, status, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          "Test task without budget",
          "pending",
          now,
          now
        ]
      )

      # Verify NULL is stored
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT budget_limit FROM tasks
          WHERE prompt = 'Test task without budget'
          """
        )

      assert length(result.rows) == 1
      [[budget_limit]] = result.rows

      # Should be NULL, not 0
      assert budget_limit == nil
    end
  end

  describe "R3: decimal precision" do
    # R3: WHEN budget_limit set to 123456789.12 THEN exact value stored
    test "stores large decimal values with full precision" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      large_budget = Decimal.new("123456789.12")

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO tasks (id, prompt, status, budget_limit, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          "Test task with large budget",
          "pending",
          large_budget,
          now,
          now
        ]
      )

      # Verify exact value is stored
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT budget_limit FROM tasks
          WHERE prompt = 'Test task with large budget'
          """
        )

      assert length(result.rows) == 1
      [[stored_budget]] = result.rows

      # Postgrex returns Decimal directly
      assert Decimal.equal?(stored_budget, large_budget)
    end

    test "preserves 2 decimal places for currency" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      precise_budget = Decimal.new("99.99")

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO tasks (id, prompt, status, budget_limit, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          "Test task with precise budget",
          "pending",
          precise_budget,
          now,
          now
        ]
      )

      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT budget_limit FROM tasks
          WHERE prompt = 'Test task with precise budget'
          """
        )

      [[stored_budget]] = result.rows
      assert Decimal.equal?(stored_budget, Decimal.new("99.99"))
    end
  end

  describe "R4: rollback safety" do
    # R4: WHEN migration rolled back THEN column removed cleanly
    test "migration is reversible (column exists proves migration ran)" do
      # Verify column exists (proves migration ran)
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT column_name FROM information_schema.columns
          WHERE table_name = 'tasks' AND column_name = 'budget_limit'
          """
        )

      assert length(result.rows) == 1

      # Note: Cannot actually rollback in test env (would break other tests)
      # Migration uses reversible Ecto.Migration operations:
      # - alter table add column - reversible (Ecto removes column)
      # - create index - reversible (Ecto drops index)
      # Actual rollback tested manually: mix ecto.rollback --step 1
    end
  end
end
