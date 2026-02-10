defmodule Quoracle.Costs.AggregatorTest do
  @moduledoc """
  Tests for COST_Aggregator module.

  WorkGroupID: feat-20251212-191913
  Packet: 4 (Aggregation)

  Requirements (v1.0):
  - R1: By Agent Total [INTEGRATION]
  - R2: By Agent Empty [INTEGRATION]
  - R3: By Agent and Type [INTEGRATION]
  - R4: By Agent Children [INTEGRATION]
  - R5: Recursive Descendants [INTEGRATION]
  - R6: No Children [INTEGRATION]
  - R7: By Task Total [INTEGRATION]
  - R8: By Task and Type [INTEGRATION]
  - R9: By Task and Model [INTEGRATION]
  - R10: By Agent and Model [INTEGRATION]
  - R11: Model Token Aggregation [INTEGRATION]
  - R12: List By Agent [INTEGRATION]
  - R13: List With Limit [INTEGRATION]
  - R14: Nil Cost Aggregation [INTEGRATION]
  - R15: Aggregation Consistency [UNIT/PROPERTY]
  - R16: Children Exclusion [UNIT/PROPERTY]

  Requirements (v2.0 - feat-cost-breakdown-20251230):
  - R17: Task Detailed Query Returns All Token Types [INTEGRATION]
  - R18: Agent Detailed Query Returns All Token Types [INTEGRATION]
  - R19: Missing Token Types Default to Zero [INTEGRATION]
  - R20: Aggregate Costs Summed Correctly [INTEGRATION]
  - R21: Zero Cost Returns Nil [UNIT]
  - R22: Historical Data Graceful Handling [INTEGRATION]
  - R23: Detailed Backward Compatible [INTEGRATION]
  - R24: Empty Result [INTEGRATION]
  - R25: Model Ordering [INTEGRATION]
  - R26: Request Count Accurate [INTEGRATION]
  - R27: Nil Cost Records Handled [INTEGRATION]
  - R28: UUID Binary Conversion [UNIT]
  """

  use Quoracle.DataCase, async: true
  use ExUnitProperties

  alias Quoracle.Repo
  alias Quoracle.Tasks.Task
  alias Quoracle.Agents.Agent
  alias Quoracle.Costs.AgentCost
  alias Quoracle.Costs.Aggregator

  # ============================================================
  # Test Data Setup Helpers
  # ============================================================

  # Create a task for testing
  defp create_task do
    {:ok, task} =
      %Task{}
      |> Task.changeset(%{prompt: "Test task", status: "running"})
      |> Repo.insert()

    task
  end

  # Create an agent with optional parent
  defp create_agent(task, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "agent_#{System.unique_integer([:positive])}")
    parent_id = Keyword.get(opts, :parent_id, nil)

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        task_id: task.id,
        agent_id: agent_id,
        parent_id: parent_id,
        config: %{},
        status: "running"
      })
      |> Repo.insert()

    agent
  end

  # Create a cost record
  defp create_cost(task, agent_id, opts \\ []) do
    cost_type = Keyword.get(opts, :cost_type, "llm_consensus")
    cost_usd = Keyword.get(opts, :cost_usd, Decimal.new("0.05"))
    model_spec = Keyword.get(opts, :model_spec, "anthropic/claude-sonnet-4-20250514")
    input_tokens = Keyword.get(opts, :input_tokens, 1000)
    output_tokens = Keyword.get(opts, :output_tokens, 500)

    {:ok, cost} =
      %AgentCost{}
      |> AgentCost.changeset(%{
        agent_id: agent_id,
        task_id: task.id,
        cost_type: cost_type,
        cost_usd: cost_usd,
        metadata: %{
          "model_spec" => model_spec,
          "input_tokens" => input_tokens,
          "output_tokens" => output_tokens
        }
      })
      |> Repo.insert()

    cost
  end

  # Create a detailed cost record with all v2.0 token types and costs
  defp create_detailed_cost(task, agent_id, opts) do
    cost_type = Keyword.get(opts, :cost_type, "llm_consensus")
    cost_usd = Keyword.get(opts, :cost_usd, Decimal.new("0.05"))
    model_spec = Keyword.get(opts, :model_spec, "anthropic/claude-sonnet-4-20250514")

    # Token counts (5 types)
    input_tokens = Keyword.get(opts, :input_tokens, 1000)
    output_tokens = Keyword.get(opts, :output_tokens, 500)
    reasoning_tokens = Keyword.get(opts, :reasoning_tokens, 200)
    cached_tokens = Keyword.get(opts, :cached_tokens, 100)
    cache_creation_tokens = Keyword.get(opts, :cache_creation_tokens, 50)

    # Aggregate costs
    input_cost = Keyword.get(opts, :input_cost, "0.01")
    output_cost = Keyword.get(opts, :output_cost, "0.02")
    total_cost = Keyword.get(opts, :total_cost, "0.03")

    metadata =
      %{
        "model_spec" => model_spec,
        "input_tokens" => input_tokens,
        "output_tokens" => output_tokens,
        "reasoning_tokens" => reasoning_tokens,
        "cached_tokens" => cached_tokens,
        "cache_creation_tokens" => cache_creation_tokens,
        "input_cost" => input_cost,
        "output_cost" => output_cost,
        "total_cost" => total_cost
      }
      |> Enum.reject(fn {_k, v} -> v == :skip end)
      |> Map.new()

    {:ok, cost} =
      %AgentCost{}
      |> AgentCost.changeset(%{
        agent_id: agent_id,
        task_id: task.id,
        cost_type: cost_type,
        cost_usd: cost_usd,
        metadata: metadata
      })
      |> Repo.insert()

    cost
  end

  # Create an agent tree: root -> child1, child2 -> grandchild
  defp create_agent_tree(task) do
    root = create_agent(task, agent_id: "root_#{System.unique_integer([:positive])}")

    child1 =
      create_agent(task,
        agent_id: "child1_#{System.unique_integer([:positive])}",
        parent_id: root.agent_id
      )

    child2 =
      create_agent(task,
        agent_id: "child2_#{System.unique_integer([:positive])}",
        parent_id: root.agent_id
      )

    grandchild =
      create_agent(task,
        agent_id: "grandchild_#{System.unique_integer([:positive])}",
        parent_id: child1.agent_id
      )

    %{root: root, child1: child1, child2: child2, grandchild: grandchild}
  end

  # ============================================================
  # COST_Aggregator: R1 - By Agent Total [INTEGRATION]
  # ============================================================

  describe "by_agent/1 - agent total" do
    test "returns sum of agent's own costs" do
      task = create_task()
      agent = create_agent(task)

      # Add multiple costs
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.10"))
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.15"))
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.25"))

      result = Aggregator.by_agent(agent.agent_id)

      assert Decimal.equal?(result.total_cost, Decimal.new("0.50"))
      assert result.total_requests == 3
    end

    test "excludes other agents' costs" do
      task = create_task()
      agent1 = create_agent(task)
      agent2 = create_agent(task)

      create_cost(task, agent1.agent_id, cost_usd: Decimal.new("0.10"))
      create_cost(task, agent2.agent_id, cost_usd: Decimal.new("0.20"))

      result = Aggregator.by_agent(agent1.agent_id)

      assert Decimal.equal?(result.total_cost, Decimal.new("0.10"))
      assert result.total_requests == 1
    end
  end

  # ============================================================
  # COST_Aggregator: R2 - By Agent Empty [INTEGRATION]
  # ============================================================

  describe "by_agent/1 - empty agent" do
    test "returns zero summary for agent with no costs" do
      task = create_task()
      agent = create_agent(task)

      result = Aggregator.by_agent(agent.agent_id)

      assert result.total_cost == nil
      assert result.total_requests == 0
      assert result.by_type == %{}
    end

    test "returns zero summary for nonexistent agent" do
      result = Aggregator.by_agent("nonexistent_agent_id")

      assert result.total_cost == nil
      assert result.total_requests == 0
      assert result.by_type == %{}
    end
  end

  # ============================================================
  # COST_Aggregator: R3 - By Agent and Type [INTEGRATION]
  # ============================================================

  describe "by_agent_and_type/1 - type breakdown" do
    test "groups costs by cost_type" do
      task = create_task()
      agent = create_agent(task)

      # Add different cost types
      create_cost(task, agent.agent_id, cost_type: "llm_consensus", cost_usd: Decimal.new("0.10"))
      create_cost(task, agent.agent_id, cost_type: "llm_consensus", cost_usd: Decimal.new("0.05"))
      create_cost(task, agent.agent_id, cost_type: "llm_embedding", cost_usd: Decimal.new("0.02"))

      create_cost(task, agent.agent_id,
        cost_type: "llm_summarization",
        cost_usd: Decimal.new("0.03")
      )

      result = Aggregator.by_agent_and_type(agent.agent_id)

      assert Decimal.equal?(result["llm_consensus"], Decimal.new("0.15"))
      assert Decimal.equal?(result["llm_embedding"], Decimal.new("0.02"))
      assert Decimal.equal?(result["llm_summarization"], Decimal.new("0.03"))
    end

    test "by_agent includes by_type breakdown" do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id, cost_type: "llm_consensus", cost_usd: Decimal.new("0.10"))
      create_cost(task, agent.agent_id, cost_type: "llm_embedding", cost_usd: Decimal.new("0.05"))

      result = Aggregator.by_agent(agent.agent_id)

      assert Map.has_key?(result, :by_type)
      assert Decimal.equal?(result.by_type["llm_consensus"], Decimal.new("0.10"))
      assert Decimal.equal?(result.by_type["llm_embedding"], Decimal.new("0.05"))
    end

    test "returns empty map for agent with no costs" do
      task = create_task()
      agent = create_agent(task)

      result = Aggregator.by_agent_and_type(agent.agent_id)

      assert result == %{}
    end
  end

  # ============================================================
  # COST_Aggregator: R4 - By Agent Children [INTEGRATION]
  # ============================================================

  describe "by_agent_children/1 - descendants costs" do
    test "returns descendants' costs excluding self" do
      task = create_task()
      tree = create_agent_tree(task)

      # Add costs to root and children
      create_cost(task, tree.root.agent_id, cost_usd: Decimal.new("1.00"))
      create_cost(task, tree.child1.agent_id, cost_usd: Decimal.new("0.20"))
      create_cost(task, tree.child2.agent_id, cost_usd: Decimal.new("0.30"))
      create_cost(task, tree.grandchild.agent_id, cost_usd: Decimal.new("0.10"))

      result = Aggregator.by_agent_children(tree.root.agent_id)

      # Should include child1 + child2 + grandchild = 0.60, NOT root's 1.00
      assert Decimal.equal?(result.total_cost, Decimal.new("0.60"))
      assert result.total_requests == 3
    end

    test "never includes agent's own costs" do
      task = create_task()
      tree = create_agent_tree(task)

      # Only add cost to root
      create_cost(task, tree.root.agent_id, cost_usd: Decimal.new("1.00"))

      result = Aggregator.by_agent_children(tree.root.agent_id)

      # Root's cost should NOT appear in children total
      assert result.total_cost == nil
      assert result.total_requests == 0
    end
  end

  # ============================================================
  # COST_Aggregator: R5 - Recursive Descendants [INTEGRATION]
  # ============================================================

  describe "get_descendant_agent_ids/1 - recursive lookup" do
    test "finds multi-level descendants" do
      task = create_task()
      tree = create_agent_tree(task)

      descendants = Aggregator.get_descendant_agent_ids(tree.root.agent_id)

      # Should find child1, child2, grandchild (3 total)
      assert length(descendants) == 3
      assert tree.child1.agent_id in descendants
      assert tree.child2.agent_id in descendants
      assert tree.grandchild.agent_id in descendants
    end

    test "does not include self in descendants" do
      task = create_task()
      tree = create_agent_tree(task)

      descendants = Aggregator.get_descendant_agent_ids(tree.root.agent_id)

      refute tree.root.agent_id in descendants
    end

    test "finds deep hierarchy" do
      task = create_task()

      # Create 4-level deep hierarchy
      level1 = create_agent(task, agent_id: "level1_#{System.unique_integer([:positive])}")

      level2 =
        create_agent(task,
          agent_id: "level2_#{System.unique_integer([:positive])}",
          parent_id: level1.agent_id
        )

      level3 =
        create_agent(task,
          agent_id: "level3_#{System.unique_integer([:positive])}",
          parent_id: level2.agent_id
        )

      level4 =
        create_agent(task,
          agent_id: "level4_#{System.unique_integer([:positive])}",
          parent_id: level3.agent_id
        )

      descendants = Aggregator.get_descendant_agent_ids(level1.agent_id)

      assert length(descendants) == 3
      assert level2.agent_id in descendants
      assert level3.agent_id in descendants
      assert level4.agent_id in descendants
    end
  end

  # ============================================================
  # COST_Aggregator: R6 - No Children [INTEGRATION]
  # ============================================================

  describe "by_agent_children/1 - leaf agent" do
    test "returns zero summary for leaf agent" do
      task = create_task()
      tree = create_agent_tree(task)

      # Grandchild is a leaf node
      create_cost(task, tree.grandchild.agent_id, cost_usd: Decimal.new("0.50"))

      result = Aggregator.by_agent_children(tree.grandchild.agent_id)

      # Leaf agent has no children
      assert result.total_cost == nil
      assert result.total_requests == 0
      assert result.by_type == %{}
    end

    test "returns zero summary for agent with no children" do
      task = create_task()
      agent = create_agent(task)

      result = Aggregator.by_agent_children(agent.agent_id)

      assert result.total_cost == nil
      assert result.total_requests == 0
    end
  end

  # ============================================================
  # COST_Aggregator: R7 - By Task Total [INTEGRATION]
  # ============================================================

  describe "by_task/1 - task total" do
    test "returns total for entire task tree" do
      task = create_task()
      tree = create_agent_tree(task)

      # Add costs to all agents
      create_cost(task, tree.root.agent_id, cost_usd: Decimal.new("0.10"))
      create_cost(task, tree.child1.agent_id, cost_usd: Decimal.new("0.20"))
      create_cost(task, tree.child2.agent_id, cost_usd: Decimal.new("0.30"))
      create_cost(task, tree.grandchild.agent_id, cost_usd: Decimal.new("0.40"))

      result = Aggregator.by_task(task.id)

      assert Decimal.equal?(result.total_cost, Decimal.new("1.00"))
      assert result.total_requests == 4
    end

    test "excludes other tasks' costs" do
      task1 = create_task()
      task2 = create_task()

      agent1 = create_agent(task1)
      agent2 = create_agent(task2)

      create_cost(task1, agent1.agent_id, cost_usd: Decimal.new("0.50"))
      create_cost(task2, agent2.agent_id, cost_usd: Decimal.new("1.00"))

      result = Aggregator.by_task(task1.id)

      assert Decimal.equal?(result.total_cost, Decimal.new("0.50"))
      assert result.total_requests == 1
    end

    test "returns zero summary for task with no costs" do
      task = create_task()
      _agent = create_agent(task)

      result = Aggregator.by_task(task.id)

      assert result.total_cost == nil
      assert result.total_requests == 0
    end
  end

  # ============================================================
  # COST_Aggregator: R8 - By Task and Type [INTEGRATION]
  # ============================================================

  describe "by_task_and_type/1 - type breakdown" do
    test "groups costs by type for task" do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id, cost_type: "llm_consensus", cost_usd: Decimal.new("0.10"))
      create_cost(task, agent.agent_id, cost_type: "llm_consensus", cost_usd: Decimal.new("0.20"))
      create_cost(task, agent.agent_id, cost_type: "llm_embedding", cost_usd: Decimal.new("0.05"))

      result = Aggregator.by_task_and_type(task.id)

      assert Decimal.equal?(result["llm_consensus"], Decimal.new("0.30"))
      assert Decimal.equal?(result["llm_embedding"], Decimal.new("0.05"))
    end

    test "by_task includes by_type breakdown" do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id, cost_type: "llm_consensus", cost_usd: Decimal.new("0.10"))
      create_cost(task, agent.agent_id, cost_type: "llm_answer", cost_usd: Decimal.new("0.05"))

      result = Aggregator.by_task(task.id)

      assert Map.has_key?(result, :by_type)
      assert Decimal.equal?(result.by_type["llm_consensus"], Decimal.new("0.10"))
      assert Decimal.equal?(result.by_type["llm_answer"], Decimal.new("0.05"))
    end
  end

  # ============================================================
  # COST_Aggregator: R9 - By Task and Model [INTEGRATION]
  # ============================================================

  describe "by_task_and_model/1 - model breakdown" do
    test "groups costs by model for task" do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id,
        model_spec: "anthropic/claude-sonnet-4-20250514",
        cost_usd: Decimal.new("0.10")
      )

      create_cost(task, agent.agent_id,
        model_spec: "anthropic/claude-sonnet-4-20250514",
        cost_usd: Decimal.new("0.05")
      )

      create_cost(task, agent.agent_id,
        model_spec: "google-vertex/gemini-2.5-pro",
        cost_usd: Decimal.new("0.08")
      )

      result = Aggregator.by_task_and_model(task.id)

      # Find the anthropic model entry
      anthropic = Enum.find(result, &(&1.model_spec == "anthropic/claude-sonnet-4-20250514"))
      google = Enum.find(result, &(&1.model_spec == "google-vertex/gemini-2.5-pro"))

      assert anthropic != nil
      assert Decimal.equal?(anthropic.total_cost, Decimal.new("0.15"))
      assert anthropic.request_count == 2

      assert google != nil
      assert Decimal.equal?(google.total_cost, Decimal.new("0.08"))
      assert google.request_count == 1
    end

    test "orders by total_cost descending" do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id, model_spec: "cheap/model", cost_usd: Decimal.new("0.01"))

      create_cost(task, agent.agent_id,
        model_spec: "expensive/model",
        cost_usd: Decimal.new("1.00")
      )

      result = Aggregator.by_task_and_model(task.id)

      # First should be the expensive model
      assert hd(result).model_spec == "expensive/model"
    end

    test "returns empty list for task with no costs" do
      task = create_task()

      result = Aggregator.by_task_and_model(task.id)

      assert result == []
    end
  end

  # ============================================================
  # COST_Aggregator: R10 - By Agent and Model [INTEGRATION]
  # ============================================================

  describe "by_agent_and_model/1 - model breakdown" do
    test "groups agent costs by model" do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id,
        model_spec: "bedrock/claude-sonnet-4",
        cost_usd: Decimal.new("0.20")
      )

      create_cost(task, agent.agent_id,
        model_spec: "openai/gpt-4o-mini",
        cost_usd: Decimal.new("0.05")
      )

      result = Aggregator.by_agent_and_model(agent.agent_id)

      bedrock = Enum.find(result, &(&1.model_spec == "bedrock/claude-sonnet-4"))
      openai = Enum.find(result, &(&1.model_spec == "openai/gpt-4o-mini"))

      assert bedrock != nil
      assert Decimal.equal?(bedrock.total_cost, Decimal.new("0.20"))

      assert openai != nil
      assert Decimal.equal?(openai.total_cost, Decimal.new("0.05"))
    end

    test "excludes other agents' costs" do
      task = create_task()
      agent1 = create_agent(task)
      agent2 = create_agent(task)

      create_cost(task, agent1.agent_id, model_spec: "model/a", cost_usd: Decimal.new("0.10"))
      create_cost(task, agent2.agent_id, model_spec: "model/a", cost_usd: Decimal.new("0.50"))

      result = Aggregator.by_agent_and_model(agent1.agent_id)

      assert length(result) == 1
      assert hd(result).request_count == 1
      assert Decimal.equal?(hd(result).total_cost, Decimal.new("0.10"))
    end
  end

  # ============================================================
  # COST_Aggregator: R11 - Model Token Aggregation [INTEGRATION]
  # ============================================================

  describe "model queries - token aggregation" do
    test "aggregate tokens from metadata" do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id,
        model_spec: "test/model",
        input_tokens: 1000,
        output_tokens: 500
      )

      create_cost(task, agent.agent_id,
        model_spec: "test/model",
        input_tokens: 2000,
        output_tokens: 800
      )

      result = Aggregator.by_task_and_model(task.id)

      model = hd(result)
      # Total tokens = (1000+500) + (2000+800) = 4300
      assert model.total_tokens == 4300
    end

    test "handles nil tokens in metadata" do
      task = create_task()
      agent = create_agent(task)

      # Create cost without token info
      {:ok, _cost} =
        %AgentCost{}
        |> AgentCost.changeset(%{
          agent_id: agent.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.10"),
          metadata: %{"model_spec" => "test/model"}
        })
        |> Repo.insert()

      result = Aggregator.by_task_and_model(task.id)

      model = hd(result)
      assert model.total_tokens == 0
    end

    test "by_agent_and_model includes token totals" do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id,
        model_spec: "test/model",
        input_tokens: 500,
        output_tokens: 200
      )

      result = Aggregator.by_agent_and_model(agent.agent_id)

      model = hd(result)
      assert model.total_tokens == 700
    end
  end

  # ============================================================
  # COST_Aggregator: R12 - List By Agent [INTEGRATION]
  # ============================================================

  describe "list_by_agent/1 - individual records" do
    test "returns costs in reverse chronological order" do
      task = create_task()
      agent = create_agent(task)

      # Create costs - they will have sequential inserted_at timestamps
      _cost1 = create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.01"))
      _cost2 = create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.02"))
      _cost3 = create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.03"))

      result = Aggregator.list_by_agent(agent.agent_id)

      # Should return 3 costs ordered by inserted_at DESC
      assert length(result) == 3

      # Verify ordering: each record's inserted_at >= next record's inserted_at
      [first, second, third] = result
      assert NaiveDateTime.compare(first.inserted_at, second.inserted_at) in [:gt, :eq]
      assert NaiveDateTime.compare(second.inserted_at, third.inserted_at) in [:gt, :eq]
    end

    test "returns only specified agent's costs" do
      task = create_task()
      agent1 = create_agent(task)
      agent2 = create_agent(task)

      create_cost(task, agent1.agent_id)
      create_cost(task, agent2.agent_id)

      result = Aggregator.list_by_agent(agent1.agent_id)

      assert length(result) == 1
      assert hd(result).agent_id == agent1.agent_id
    end

    test "returns full AgentCost structs" do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id,
        cost_type: "llm_embedding",
        cost_usd: Decimal.new("0.05"),
        model_spec: "test/model"
      )

      result = Aggregator.list_by_agent(agent.agent_id)

      cost = hd(result)
      assert %AgentCost{} = cost
      assert cost.cost_type == "llm_embedding"
      assert Decimal.equal?(cost.cost_usd, Decimal.new("0.05"))
      assert cost.metadata["model_spec"] == "test/model"
    end
  end

  # ============================================================
  # COST_Aggregator: R13 - List With Limit [INTEGRATION]
  # ============================================================

  describe "list_by_agent/2 - limit option" do
    test "respects limit option" do
      task = create_task()
      agent = create_agent(task)

      # Create 10 costs
      for _ <- 1..10, do: create_cost(task, agent.agent_id)

      result = Aggregator.list_by_agent(agent.agent_id, limit: 5)

      assert length(result) == 5
    end

    test "default limit is 100" do
      task = create_task()
      agent = create_agent(task)

      # Create 5 costs (less than default limit)
      for _ <- 1..5, do: create_cost(task, agent.agent_id)

      result = Aggregator.list_by_agent(agent.agent_id)

      # Should return all 5, not limited
      assert length(result) == 5
    end

    test "list_by_task also respects limit" do
      task = create_task()
      agent = create_agent(task)

      for _ <- 1..10, do: create_cost(task, agent.agent_id)

      result = Aggregator.list_by_task(task.id, limit: 3)

      assert length(result) == 3
    end
  end

  # ============================================================
  # COST_Aggregator: R14 - Nil Cost Aggregation [INTEGRATION]
  # ============================================================

  describe "nil cost handling" do
    test "aggregation handles nil costs correctly" do
      task = create_task()
      agent = create_agent(task)

      # Mix of nil and non-nil costs
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.10"))
      create_cost(task, agent.agent_id, cost_usd: nil)
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.20"))

      result = Aggregator.by_agent(agent.agent_id)

      # Nil costs excluded from sum but counted in requests
      assert Decimal.equal?(result.total_cost, Decimal.new("0.30"))
      assert result.total_requests == 3
    end

    test "nil costs counted in total_requests" do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id, cost_usd: nil)
      create_cost(task, agent.agent_id, cost_usd: nil)

      result = Aggregator.by_agent(agent.agent_id)

      assert result.total_cost == nil
      assert result.total_requests == 2
    end

    test "by_type handles nil costs" do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id, cost_type: "llm_consensus", cost_usd: nil)

      create_cost(task, agent.agent_id,
        cost_type: "llm_consensus",
        cost_usd: Decimal.new("0.10")
      )

      result = Aggregator.by_agent_and_type(agent.agent_id)

      # Sum of nil + 0.10 = 0.10 (nil treated as 0 in sum)
      assert Decimal.equal?(result["llm_consensus"], Decimal.new("0.10"))
    end
  end

  # ============================================================
  # COST_Aggregator: R15 - Aggregation Consistency [PROPERTY]
  # ============================================================

  describe "aggregation consistency" do
    property "task total equals sum of agent totals" do
      check all(
              cost_values <- list_of(integer(1..1000), min_length: 1, max_length: 10),
              num_agents <- integer(1..3)
            ) do
        task = create_task()

        # Create agents and distribute costs
        agents =
          for i <- 1..num_agents do
            create_agent(task, agent_id: "prop_agent_#{i}_#{System.unique_integer([:positive])}")
          end

        # Add costs to agents (round-robin)
        for {cost_cents, i} <- Enum.with_index(cost_values) do
          agent = Enum.at(agents, rem(i, num_agents))
          cost_decimal = Decimal.div(Decimal.new(cost_cents), 100)
          create_cost(task, agent.agent_id, cost_usd: cost_decimal)
        end

        # Sum of individual agent totals
        agent_sum =
          Enum.reduce(agents, Decimal.new(0), fn agent, acc ->
            agent_result = Aggregator.by_agent(agent.agent_id)

            if agent_result.total_cost do
              Decimal.add(acc, agent_result.total_cost)
            else
              acc
            end
          end)

        # Task total
        task_result = Aggregator.by_task(task.id)

        # They should match
        if task_result.total_cost do
          assert Decimal.equal?(agent_sum, task_result.total_cost)
        else
          assert Decimal.equal?(agent_sum, Decimal.new(0))
        end
      end
    end
  end

  # ============================================================
  # COST_Aggregator: R16 - Children Exclusion [PROPERTY]
  # ============================================================

  describe "children exclusion" do
    property "children costs never include self" do
      check all(
              own_cost_cents <- integer(1..1000),
              child_cost_cents <- integer(1..1000)
            ) do
        task = create_task()

        # Create parent and child
        parent =
          create_agent(task, agent_id: "prop_parent_#{System.unique_integer([:positive])}")

        child =
          create_agent(task,
            agent_id: "prop_child_#{System.unique_integer([:positive])}",
            parent_id: parent.agent_id
          )

        own_cost = Decimal.div(Decimal.new(own_cost_cents), 100)
        child_cost = Decimal.div(Decimal.new(child_cost_cents), 100)

        create_cost(task, parent.agent_id, cost_usd: own_cost)
        create_cost(task, child.agent_id, cost_usd: child_cost)

        children_result = Aggregator.by_agent_children(parent.agent_id)

        # Children total should equal child's cost, NOT include parent's
        assert children_result.total_cost != nil
        assert Decimal.equal?(children_result.total_cost, child_cost)
        refute Decimal.equal?(children_result.total_cost, Decimal.add(own_cost, child_cost))
      end
    end
  end

  # ============================================================
  # COST_Aggregator v2.0: R17 - Task Detailed Query Returns All Token Types [INTEGRATION]
  # ============================================================

  describe "by_task_and_model_detailed/1 - all token types" do
    test "returns all 5 token types per model" do
      task = create_task()
      agent = create_agent(task)

      create_detailed_cost(task, agent.agent_id,
        model_spec: "anthropic/claude-sonnet-4",
        input_tokens: 1000,
        output_tokens: 500,
        reasoning_tokens: 200,
        cached_tokens: 100,
        cache_creation_tokens: 50
      )

      result = Aggregator.by_task_and_model_detailed(task.id)

      assert length(result) == 1
      model = hd(result)

      # Verify all 5 token types are present
      assert Map.has_key?(model, :input_tokens)
      assert Map.has_key?(model, :output_tokens)
      assert Map.has_key?(model, :reasoning_tokens)
      assert Map.has_key?(model, :cached_tokens)
      assert Map.has_key?(model, :cache_creation_tokens)

      # Verify values
      assert model.input_tokens == 1000
      assert model.output_tokens == 500
      assert model.reasoning_tokens == 200
      assert model.cached_tokens == 100
      assert model.cache_creation_tokens == 50
    end
  end

  # ============================================================
  # COST_Aggregator v2.0: R18 - Agent Detailed Query Returns All Token Types [INTEGRATION]
  # ============================================================

  describe "by_agent_and_model_detailed/1 - all token types" do
    test "returns all 5 token types per model" do
      task = create_task()
      agent = create_agent(task)

      create_detailed_cost(task, agent.agent_id,
        model_spec: "google-vertex/gemini-2.5-pro",
        input_tokens: 800,
        output_tokens: 400,
        reasoning_tokens: 150,
        cached_tokens: 80,
        cache_creation_tokens: 40
      )

      result = Aggregator.by_agent_and_model_detailed(agent.agent_id)

      assert length(result) == 1
      model = hd(result)

      # Verify all 5 token types are present
      assert Map.has_key?(model, :input_tokens)
      assert Map.has_key?(model, :output_tokens)
      assert Map.has_key?(model, :reasoning_tokens)
      assert Map.has_key?(model, :cached_tokens)
      assert Map.has_key?(model, :cache_creation_tokens)

      # Verify values
      assert model.input_tokens == 800
      assert model.output_tokens == 400
      assert model.reasoning_tokens == 150
      assert model.cached_tokens == 80
      assert model.cache_creation_tokens == 40
    end
  end

  # ============================================================
  # COST_Aggregator v2.0: R19 - Missing Token Types Default to Zero [INTEGRATION]
  # ============================================================

  describe "detailed queries - missing token types" do
    test "missing token types aggregate as zero" do
      task = create_task()
      agent = create_agent(task)

      # Create cost with only input/output tokens (historical record)
      create_cost(task, agent.agent_id,
        model_spec: "legacy/model",
        input_tokens: 500,
        output_tokens: 200
      )

      result = Aggregator.by_task_and_model_detailed(task.id)

      assert length(result) == 1
      model = hd(result)

      # Missing tokens should default to 0
      assert model.reasoning_tokens == 0
      assert model.cached_tokens == 0
      assert model.cache_creation_tokens == 0

      # Present tokens should have values
      assert model.input_tokens == 500
      assert model.output_tokens == 200
    end
  end

  # ============================================================
  # COST_Aggregator v2.0: R20 - Aggregate Costs Summed Correctly [INTEGRATION]
  # ============================================================

  describe "detailed queries - cost aggregation" do
    test "aggregate costs summed correctly per model" do
      task = create_task()
      agent = create_agent(task)

      # Two records for same model
      create_detailed_cost(task, agent.agent_id,
        model_spec: "test/model",
        input_cost: "0.01",
        output_cost: "0.02",
        total_cost: "0.03"
      )

      create_detailed_cost(task, agent.agent_id,
        model_spec: "test/model",
        input_cost: "0.02",
        output_cost: "0.04",
        total_cost: "0.06"
      )

      result = Aggregator.by_task_and_model_detailed(task.id)

      assert length(result) == 1
      model = hd(result)

      # Costs should be summed
      assert Decimal.equal?(model.input_cost, Decimal.new("0.03"))
      assert Decimal.equal?(model.output_cost, Decimal.new("0.06"))
    end
  end

  # ============================================================
  # COST_Aggregator v2.0: R21 - Zero Cost Returns Nil [UNIT]
  # ============================================================

  describe "detailed queries - zero cost handling" do
    test "zero cost returns nil" do
      task = create_task()
      agent = create_agent(task)

      # Create record with zero costs
      create_detailed_cost(task, agent.agent_id,
        model_spec: "test/model",
        input_cost: "0",
        output_cost: "0",
        total_cost: "0",
        cost_usd: Decimal.new("0")
      )

      result = Aggregator.by_task_and_model_detailed(task.id)

      assert length(result) == 1
      model = hd(result)

      # Zero should return nil, not Decimal.new(0)
      assert model.input_cost == nil
      assert model.output_cost == nil
      assert model.total_cost == nil
    end
  end

  # ============================================================
  # COST_Aggregator v2.0: R22 - Historical Data Graceful Handling [INTEGRATION]
  # ============================================================

  describe "detailed queries - historical data" do
    test "handles historical records without new token fields" do
      task = create_task()
      agent = create_agent(task)

      # Create historical record (pre-v2.0, no reasoning/cached/cache_creation tokens)
      {:ok, _cost} =
        %AgentCost{}
        |> AgentCost.changeset(%{
          agent_id: agent.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.10"),
          metadata: %{
            "model_spec" => "historical/model",
            "input_tokens" => 1000,
            "output_tokens" => 500
          }
        })
        |> Repo.insert()

      result = Aggregator.by_task_and_model_detailed(task.id)

      assert length(result) == 1
      model = hd(result)

      # Should still work, with missing fields as 0
      assert model.model_spec == "historical/model"
      assert model.input_tokens == 1000
      assert model.output_tokens == 500
      assert model.reasoning_tokens == 0
      assert model.cached_tokens == 0
      assert model.cache_creation_tokens == 0
    end
  end

  # ============================================================
  # COST_Aggregator v2.0: R23 - Detailed Backward Compatible [INTEGRATION]
  # ============================================================

  describe "detailed queries - backward compatibility" do
    test "original by_task_and_model unchanged" do
      task = create_task()
      agent = create_agent(task)

      create_detailed_cost(task, agent.agent_id,
        model_spec: "test/model",
        cost_usd: Decimal.new("0.15"),
        input_tokens: 1000,
        output_tokens: 500
      )

      # Original function should still work
      original_result = Aggregator.by_task_and_model(task.id)

      assert length(original_result) == 1
      model = hd(original_result)

      # Original function returns model_cost type (not model_cost_detailed)
      assert model.model_spec == "test/model"
      assert Decimal.equal?(model.total_cost, Decimal.new("0.15"))
      assert model.request_count == 1
      assert model.total_tokens == 1500
    end
  end

  # ============================================================
  # COST_Aggregator v2.0: R24 - Empty Result [INTEGRATION]
  # ============================================================

  describe "detailed queries - empty result" do
    test "returns empty list for task with no costs" do
      task = create_task()

      result = Aggregator.by_task_and_model_detailed(task.id)

      assert result == []
    end

    test "returns empty list for agent with no costs" do
      task = create_task()
      agent = create_agent(task)

      result = Aggregator.by_agent_and_model_detailed(agent.agent_id)

      assert result == []
    end
  end

  # ============================================================
  # COST_Aggregator v2.0: R25 - Model Ordering [INTEGRATION]
  # ============================================================

  describe "detailed queries - model ordering" do
    test "orders models by total_cost descending" do
      task = create_task()
      agent = create_agent(task)

      # Create costs for different models with different totals
      create_detailed_cost(task, agent.agent_id,
        model_spec: "cheap/model",
        cost_usd: Decimal.new("0.01")
      )

      create_detailed_cost(task, agent.agent_id,
        model_spec: "expensive/model",
        cost_usd: Decimal.new("1.00")
      )

      create_detailed_cost(task, agent.agent_id,
        model_spec: "medium/model",
        cost_usd: Decimal.new("0.50")
      )

      result = Aggregator.by_task_and_model_detailed(task.id)

      assert length(result) == 3

      # Should be ordered by total_cost DESC
      [first, second, third] = result
      assert first.model_spec == "expensive/model"
      assert second.model_spec == "medium/model"
      assert third.model_spec == "cheap/model"
    end
  end

  # ============================================================
  # COST_Aggregator v2.0: R26 - Request Count Accurate [INTEGRATION]
  # ============================================================

  describe "detailed queries - request count" do
    test "request_count matches record count per model" do
      task = create_task()
      agent = create_agent(task)

      # Create 3 records for model A, 2 for model B
      for _ <- 1..3 do
        create_detailed_cost(task, agent.agent_id, model_spec: "model/a")
      end

      for _ <- 1..2 do
        create_detailed_cost(task, agent.agent_id, model_spec: "model/b")
      end

      result = Aggregator.by_task_and_model_detailed(task.id)

      model_a = Enum.find(result, &(&1.model_spec == "model/a"))
      model_b = Enum.find(result, &(&1.model_spec == "model/b"))

      assert model_a.request_count == 3
      assert model_b.request_count == 2
    end
  end

  # ============================================================
  # COST_Aggregator v2.0: R27 - Nil Cost Records Handled [INTEGRATION]
  # ============================================================

  describe "detailed queries - nil cost handling" do
    test "nil cost_usd excluded from sum" do
      task = create_task()
      agent = create_agent(task)

      # Create record with valid cost
      create_detailed_cost(task, agent.agent_id,
        model_spec: "test/model",
        cost_usd: Decimal.new("0.10")
      )

      # Create record with nil cost
      {:ok, _cost} =
        %AgentCost{}
        |> AgentCost.changeset(%{
          agent_id: agent.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: nil,
          metadata: %{
            "model_spec" => "test/model",
            "input_tokens" => 500,
            "output_tokens" => 200
          }
        })
        |> Repo.insert()

      result = Aggregator.by_task_and_model_detailed(task.id)

      assert length(result) == 1
      model = hd(result)

      # Should only sum the non-nil cost
      assert Decimal.equal?(model.total_cost, Decimal.new("0.10"))
      # But request_count should include both
      assert model.request_count == 2
    end
  end

  # ============================================================
  # COST_Aggregator v2.0: R28 - UUID Binary Conversion [UNIT]
  # ============================================================

  describe "detailed queries - UUID handling" do
    test "converts string UUID to binary for query" do
      task = create_task()
      agent = create_agent(task)

      create_detailed_cost(task, agent.agent_id, model_spec: "test/model")

      # Pass task.id as string UUID (which it already is from Ecto)
      result = Aggregator.by_task_and_model_detailed(task.id)

      # Should work without error
      assert length(result) == 1
      assert hd(result).model_spec == "test/model"
    end

    test "handles task_id in expected UUID format" do
      task = create_task()
      agent = create_agent(task)

      create_detailed_cost(task, agent.agent_id, model_spec: "uuid/test")

      # Verify task.id is a valid UUID string
      assert {:ok, _binary} = Ecto.UUID.dump(task.id)

      result = Aggregator.by_task_and_model_detailed(task.id)

      assert length(result) == 1
    end
  end
end
