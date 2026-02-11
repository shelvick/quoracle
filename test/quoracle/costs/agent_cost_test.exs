defmodule Quoracle.Costs.AgentCostTest do
  @moduledoc """
  Tests for TABLE_AgentCosts (R1-R8) and MIG_CreateAgentCosts (R1-R8).

  These tests verify:
  - Schema structure and field types
  - Changeset validations (required fields, cost_type inclusion)
  - Database operations (insert, retrieve, associations)
  - Migration correctness (indexes, constraints, precision)

  WorkGroupID: feat-20251212-191913
  Packet: 1 (Foundation)
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Tasks.Task
  alias Quoracle.Repo

  # Defer module loading to runtime for TDD
  @agent_cost_module Quoracle.Costs.AgentCost

  # Helper to create struct at runtime (defers module existence check)
  defp agent_cost_struct(attrs \\ %{}) do
    struct(@agent_cost_module, attrs)
  end

  # Helper to call changeset at runtime
  defp agent_cost_changeset(cost, attrs) do
    @agent_cost_module.changeset(cost, attrs)
  end

  # ============================================================
  # TABLE_AgentCosts: R1 - Schema Structure [UNIT]
  # ============================================================

  describe "schema structure" do
    test "schema has required fields" do
      cost = agent_cost_struct()

      assert Map.has_key?(cost, :id)
      assert Map.has_key?(cost, :agent_id)
      assert Map.has_key?(cost, :task_id)
      assert Map.has_key?(cost, :cost_type)
      assert Map.has_key?(cost, :cost_usd)
      assert Map.has_key?(cost, :metadata)
      assert Map.has_key?(cost, :inserted_at)
    end

    test "schema has task association" do
      cost = agent_cost_struct()
      assert Map.has_key?(cost, :task)
    end

    test "cost_types/0 returns allowed cost types" do
      types = @agent_cost_module.cost_types()

      assert is_list(types)
      assert "llm_consensus" in types
      assert "llm_embedding" in types
      assert "llm_answer" in types
      assert "llm_summarization" in types
    end
  end

  # ============================================================
  # TABLE_AgentCosts: R2 - Required Field Validation [UNIT]
  # ============================================================

  describe "changeset validation - required fields" do
    test "changeset requires agent_id, task_id, cost_type" do
      changeset = agent_cost_changeset(agent_cost_struct(), %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).agent_id
      assert "can't be blank" in errors_on(changeset).task_id
      assert "can't be blank" in errors_on(changeset).cost_type
    end

    test "changeset requires agent_id" do
      attrs = %{task_id: Ecto.UUID.generate(), cost_type: "llm_consensus"}
      changeset = agent_cost_changeset(agent_cost_struct(), attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).agent_id
    end

    test "changeset requires task_id" do
      attrs = %{agent_id: Ecto.UUID.generate(), cost_type: "llm_consensus"}
      changeset = agent_cost_changeset(agent_cost_struct(), attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).task_id
    end

    test "changeset requires cost_type" do
      attrs = %{agent_id: Ecto.UUID.generate(), task_id: Ecto.UUID.generate()}
      changeset = agent_cost_changeset(agent_cost_struct(), attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).cost_type
    end
  end

  # ============================================================
  # TABLE_AgentCosts: R3 - Cost Type Validation [UNIT]
  # ============================================================

  describe "changeset validation - cost_type inclusion" do
    test "changeset validates cost_type inclusion" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        cost_type: "invalid_type"
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).cost_type
    end

    test "changeset accepts valid cost_type: llm_consensus" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        cost_type: "llm_consensus"
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)
      assert changeset.valid?
    end

    test "changeset accepts valid cost_type: llm_embedding" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        cost_type: "llm_embedding"
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)
      assert changeset.valid?
    end

    test "changeset accepts valid cost_type: llm_answer" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        cost_type: "llm_answer"
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)
      assert changeset.valid?
    end

    test "changeset accepts valid cost_type: llm_summarization" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        cost_type: "llm_summarization"
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)
      assert changeset.valid?
    end
  end

  # ============================================================
  # TABLE_AgentCosts: R4 - Nil Cost Allowed [UNIT]
  # ============================================================

  describe "changeset validation - optional fields" do
    test "changeset allows nil cost_usd" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        cost_type: "llm_consensus",
        cost_usd: nil
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)
      assert changeset.valid?
    end

    test "changeset allows nil metadata" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        cost_type: "llm_consensus",
        metadata: nil
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)
      assert changeset.valid?
    end

    test "changeset allows cost_usd to be omitted" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        cost_type: "llm_consensus"
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)
      assert changeset.valid?
    end
  end

  # ============================================================
  # TABLE_AgentCosts: R5 - Decimal Cost Storage [INTEGRATION]
  # MIG_CreateAgentCosts: R6 - Decimal Precision [INTEGRATION]
  # ============================================================

  describe "database integration - decimal precision" do
    setup do
      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Test task", status: "running"}))

      {:ok, task: task}
    end

    test "stores and retrieves Decimal precision correctly", %{task: task} do
      # Test with high precision value (10 decimal places)
      cost_value = Decimal.new("0.0000012345")

      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: task.id,
        cost_type: "llm_consensus",
        cost_usd: cost_value
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)
      assert {:ok, cost} = Repo.insert(changeset)

      # Reload from database
      reloaded = Repo.get!(@agent_cost_module, cost.id)
      assert Decimal.equal?(reloaded.cost_usd, cost_value)
    end

    test "preserves decimal precision to 10 places", %{task: task} do
      # Test with exactly 10 decimal places
      cost_value = Decimal.new("0.1234567890")

      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: task.id,
        cost_type: "llm_embedding",
        cost_usd: cost_value
      }

      assert {:ok, cost} = Repo.insert(agent_cost_changeset(agent_cost_struct(), attrs))
      reloaded = Repo.get!(@agent_cost_module, cost.id)

      # Verify all 10 decimal places preserved
      assert Decimal.equal?(reloaded.cost_usd, cost_value)
    end

    test "stores nil cost_usd in database", %{task: task} do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: task.id,
        cost_type: "llm_answer",
        cost_usd: nil
      }

      assert {:ok, cost} = Repo.insert(agent_cost_changeset(agent_cost_struct(), attrs))
      reloaded = Repo.get!(@agent_cost_module, cost.id)

      assert is_nil(reloaded.cost_usd)
    end
  end

  # ============================================================
  # TABLE_AgentCosts: R6 - Metadata Map Storage [INTEGRATION]
  # MIG_CreateAgentCosts: R7 - JSONB Metadata [INTEGRATION]
  # ============================================================

  describe "database integration - metadata storage" do
    setup do
      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Test task", status: "running"}))

      {:ok, task: task}
    end

    test "stores and retrieves metadata map correctly", %{task: task} do
      metadata = %{
        "model_spec" => "anthropic/claude-sonnet-4-20250514",
        "input_tokens" => 1234,
        "output_tokens" => 567,
        "latency_ms" => 2345
      }

      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: task.id,
        cost_type: "llm_consensus",
        cost_usd: Decimal.new("0.05"),
        metadata: metadata
      }

      assert {:ok, cost} = Repo.insert(agent_cost_changeset(agent_cost_struct(), attrs))
      reloaded = Repo.get!(@agent_cost_module, cost.id)

      assert reloaded.metadata["model_spec"] == "anthropic/claude-sonnet-4-20250514"
      assert reloaded.metadata["input_tokens"] == 1234
      assert reloaded.metadata["output_tokens"] == 567
      assert reloaded.metadata["latency_ms"] == 2345
    end

    test "stores nested metadata structure", %{task: task} do
      metadata = %{
        "model_spec" => "azure/text-embedding-3-large",
        "details" => %{
          "cached" => true,
          "chunks" => 3
        }
      }

      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: task.id,
        cost_type: "llm_embedding",
        metadata: metadata
      }

      assert {:ok, cost} = Repo.insert(agent_cost_changeset(agent_cost_struct(), attrs))
      reloaded = Repo.get!(@agent_cost_module, cost.id)

      assert reloaded.metadata["details"]["cached"] == true
      assert reloaded.metadata["details"]["chunks"] == 3
    end

    test "supports JSONB queries on metadata", %{task: task} do
      agent_id = Ecto.UUID.generate()

      # Insert cost with specific model_spec
      attrs = %{
        agent_id: agent_id,
        task_id: task.id,
        cost_type: "llm_consensus",
        metadata: %{"model_spec" => "anthropic/claude-sonnet-4-20250514"}
      }

      assert {:ok, _} = Repo.insert(agent_cost_changeset(agent_cost_struct(), attrs))

      # Query using JSONB operator
      query =
        from(c in @agent_cost_module,
          where:
            c.task_id == ^task.id and
              fragment("metadata->>'model_spec' = ?", "anthropic/claude-sonnet-4-20250514")
        )

      results = Repo.all(query)
      assert length(results) == 1
      assert hd(results).agent_id == agent_id
    end
  end

  # ============================================================
  # TABLE_AgentCosts: R7 - Task Association [INTEGRATION]
  # ============================================================

  describe "database integration - task association" do
    setup do
      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Test task", status: "running"}))

      {:ok, task: task}
    end

    test "preloads task association", %{task: task} do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: task.id,
        cost_type: "llm_consensus"
      }

      assert {:ok, cost} = Repo.insert(agent_cost_changeset(agent_cost_struct(), attrs))

      # Preload task
      cost_with_task = Repo.preload(cost, :task)

      assert cost_with_task.task.id == task.id
      assert cost_with_task.task.prompt == "Test task"
    end
  end

  # ============================================================
  # TABLE_AgentCosts: R8 - Foreign Key Constraint [INTEGRATION]
  # MIG_CreateAgentCosts: R3 - Foreign Key Constraint [INTEGRATION]
  # ============================================================

  describe "database integration - foreign key constraint" do
    test "enforces task_id foreign key constraint" do
      invalid_task_id = Ecto.UUID.generate()

      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: invalid_task_id,
        cost_type: "llm_consensus"
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)

      assert {:error, changeset} = Repo.insert(changeset)
      assert "does not exist" in errors_on(changeset).task_id
    end
  end

  # ============================================================
  # MIG_CreateAgentCosts: R1 - Migration Runs Successfully [INTEGRATION]
  # MIG_CreateAgentCosts: R2 - Primary Key Structure [INTEGRATION]
  # ============================================================

  describe "migration - table structure" do
    setup do
      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Test task", status: "running"}))

      {:ok, task: task}
    end

    test "migration creates agent_costs table", %{task: task} do
      # If we can insert, the table exists
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: task.id,
        cost_type: "llm_consensus"
      }

      assert {:ok, _} = Repo.insert(agent_cost_changeset(agent_cost_struct(), attrs))
    end

    test "table has binary_id primary key", %{task: task} do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: task.id,
        cost_type: "llm_consensus"
      }

      assert {:ok, cost} = Repo.insert(agent_cost_changeset(agent_cost_struct(), attrs))

      # Verify UUID format (36 chars with dashes)
      assert is_binary(cost.id)
      assert String.length(cost.id) == 36
      assert String.match?(cost.id, ~r/^[0-9a-f-]{36}$/)
    end

    test "inserted_at is set automatically", %{task: task} do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: task.id,
        cost_type: "llm_consensus"
      }

      assert {:ok, cost} = Repo.insert(agent_cost_changeset(agent_cost_struct(), attrs))
      assert cost.inserted_at != nil
    end
  end

  # ============================================================
  # MIG_CreateAgentCosts: R4 - Cascade Delete [INTEGRATION]
  # ============================================================

  describe "migration - cascade delete" do
    test "deletes costs when task deleted" do
      # Create task
      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Test task", status: "running"}))

      # Create multiple costs for the task
      for i <- 1..3 do
        attrs = %{
          agent_id: Ecto.UUID.generate(),
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.0#{i}")
        }

        {:ok, _} = Repo.insert(agent_cost_changeset(agent_cost_struct(), attrs))
      end

      # Verify costs exist
      costs_before = Repo.all(from(c in @agent_cost_module, where: c.task_id == ^task.id))
      assert length(costs_before) == 3

      # Delete task
      {:ok, _} = Repo.delete(task)

      # Verify costs are deleted (CASCADE)
      costs_after = Repo.all(from(c in @agent_cost_module, where: c.task_id == ^task.id))
      assert costs_after == []
    end
  end

  # ============================================================
  # MIG_CreateAgentCosts: R5 - Indexes Exist [INTEGRATION]
  # ============================================================

  describe "migration - indexes" do
    test "creates required indexes" do
      # Query pg_indexes to verify indexes exist
      query = """
      SELECT indexname FROM pg_indexes
      WHERE tablename = 'agent_costs'
      ORDER BY indexname
      """

      {:ok, result} = Repo.query(query)
      index_names = Enum.map(result.rows, fn [name] -> name end)

      # Verify primary key index exists
      assert Enum.any?(index_names, &String.contains?(&1, "pkey"))

      # Verify composite indexes exist
      # task_id + inserted_at
      assert Enum.any?(index_names, fn name ->
               String.contains?(name, "task_id") and String.contains?(name, "inserted_at")
             end)

      # agent_id + inserted_at
      assert Enum.any?(index_names, fn name ->
               String.contains?(name, "agent_id") and String.contains?(name, "inserted_at")
             end)

      # task_id + cost_type
      assert Enum.any?(index_names, fn name ->
               String.contains?(name, "task_id") and String.contains?(name, "cost_type")
             end)

      # agent_id + cost_type
      assert Enum.any?(index_names, fn name ->
               String.contains?(name, "agent_id") and String.contains?(name, "cost_type")
             end)

      # GIN index on metadata
      assert Enum.any?(index_names, &String.contains?(&1, "metadata"))
    end
  end

  # ============================================================
  # MIG_CreateAgentCosts: R8 - Rollback Works [INTEGRATION]
  # ============================================================

  describe "migration - rollback" do
    test "rollback drops table and indexes" do
      # Verify migration uses reversible change/0 pattern
      # Find the migration file
      migration_files =
        "priv/repo/migrations"
        |> File.ls!()
        |> Enum.filter(&String.contains?(&1, "create_agent_costs"))

      assert length(migration_files) == 1, "Expected exactly one create_agent_costs migration"

      migration_file = hd(migration_files)
      migration_path = Path.join("priv/repo/migrations", migration_file)

      # Read and verify migration content
      {:ok, content} = File.read(migration_path)

      # Verify it uses change/0 (reversible) instead of up/0 + down/0
      assert content =~ "def change",
             "Migration must use change/0 for automatic rollback support"

      # Verify it doesn't have explicit up/down (which would bypass auto-rollback)
      refute content =~ "def up",
             "Migration should not have explicit up/0 - use change/0 for reversibility"

      refute content =~ "def down",
             "Migration should not have explicit down/0 - use change/0 for reversibility"

      # Verify all operations are reversible
      assert content =~ "create table(:agent_costs",
             "Migration must create agent_costs table"

      assert content =~ "create index(:agent_costs",
             "Migration must create indexes on agent_costs"

      # Verify no irreversible operations (execute without rollback)
      refute content =~ ~r/execute\s*\(/,
             "Migration should not use raw execute (not auto-reversible)"
    end
  end

  # ============================================================
  # TABLE_AgentCosts v2.0: R9 - child_budget_absorbed Cost Type [UNIT]
  # WorkGroupID: fix-20260211-budget-enforcement
  # Packet: 2 (Dismissal Reconciliation)
  # ============================================================

  describe "child_budget_absorbed cost type (v2.0)" do
    @tag :r9
    @tag :unit
    test "R9: child_budget_absorbed is a valid cost type" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        cost_type: "child_budget_absorbed"
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)
      assert changeset.valid?
    end

    @tag :r9
    test "R9b: child_budget_absorbed included in cost_types/0" do
      types = @agent_cost_module.cost_types()
      assert "child_budget_absorbed" in types
    end
  end

  # ============================================================
  # TABLE_AgentCosts v2.0: R10 - Absorption Record DB Round-Trip [INTEGRATION]
  # ============================================================

  describe "absorption record storage (v2.0)" do
    setup do
      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Test task", status: "running"}))

      {:ok, task: task}
    end

    @tag :r10
    @tag :integration
    test "R10: absorption record stores tree spent as cost_usd", %{task: task} do
      tree_spent = Decimal.new("30.00")

      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: task.id,
        cost_type: "child_budget_absorbed",
        cost_usd: tree_spent,
        metadata: %{
          "child_agent_id" => "child-123",
          "child_allocated" => "50.00",
          "child_tree_spent" => "30.00",
          "unspent_returned" => "20.00",
          "dismissed_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)
      assert {:ok, cost} = Repo.insert(changeset)

      # Reload from database and verify cost_usd
      reloaded = Repo.get!(@agent_cost_module, cost.id)
      assert Decimal.equal?(reloaded.cost_usd, tree_spent)
      assert reloaded.cost_type == "child_budget_absorbed"
    end

    @tag :r10
    @tag :integration
    test "R10b: absorption record with zero spent stores zero cost_usd", %{task: task} do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: task.id,
        cost_type: "child_budget_absorbed",
        cost_usd: Decimal.new("0"),
        metadata: %{
          "child_agent_id" => "child-zero",
          "child_allocated" => "50.00",
          "child_tree_spent" => "0",
          "unspent_returned" => "50.00",
          "dismissed_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)
      assert {:ok, cost} = Repo.insert(changeset)

      reloaded = Repo.get!(@agent_cost_module, cost.id)
      assert Decimal.equal?(reloaded.cost_usd, Decimal.new("0"))
    end
  end

  # ============================================================
  # TABLE_AgentCosts v2.0: R11 - Absorption Metadata Structure [INTEGRATION]
  # ============================================================

  describe "absorption metadata structure (v2.0)" do
    setup do
      {:ok, task} =
        Repo.insert(Task.changeset(%Task{}, %{prompt: "Test task", status: "running"}))

      {:ok, task: task}
    end

    @tag :r11
    @tag :integration
    test "R11: absorption metadata contains required fields", %{task: task} do
      dismissed_at = DateTime.to_iso8601(DateTime.utc_now())

      metadata = %{
        "child_agent_id" => "child-abc123",
        "child_allocated" => "50.00",
        "child_tree_spent" => "30.00",
        "unspent_returned" => "20.00",
        "dismissed_at" => dismissed_at
      }

      attrs = %{
        agent_id: Ecto.UUID.generate(),
        task_id: task.id,
        cost_type: "child_budget_absorbed",
        cost_usd: Decimal.new("30.00"),
        metadata: metadata
      }

      changeset = agent_cost_changeset(agent_cost_struct(), attrs)
      assert {:ok, cost} = Repo.insert(changeset)

      reloaded = Repo.get!(@agent_cost_module, cost.id)

      # Verify all required metadata fields
      assert reloaded.metadata["child_agent_id"] == "child-abc123"
      assert reloaded.metadata["child_allocated"] == "50.00"
      assert reloaded.metadata["child_tree_spent"] == "30.00"
      assert reloaded.metadata["unspent_returned"] == "20.00"
      assert reloaded.metadata["dismissed_at"] == dismissed_at
    end
  end
end
