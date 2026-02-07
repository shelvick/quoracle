defmodule Quoracle.Models.EmbeddingsCostTest do
  @moduledoc """
  Tests for MODEL_Embeddings cost recording integration.

  v4.0 (feat-20251212-191913):
  - R6-R9: Cost recording context handling

  v6.0 (feat-20260203-194408):
  - R13: Direct Recording Without Accumulator [INTEGRATION]
  - R14: Accumulate With Accumulator [INTEGRATION]
  - R15: Accumulator Returned in Result [UNIT]
  - R16: Cost Entry Format Preserved [UNIT]
  - R17: Cached Results Skip Accumulation [UNIT]
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Repo
  alias Quoracle.Tasks.Task
  alias Quoracle.Costs.AgentCost

  alias Quoracle.Models.Embeddings

  import Ecto.Query

  # Helper to call get_embedding with mock embedding function
  defp call_get_embedding(text, opts) do
    # Add mock embedding function for test isolation
    opts_with_mock =
      Keyword.put(opts, :embedding_fn, fn _text ->
        # Return a mock embedding (1536 dimensions like text-embedding-3-small)
        {:ok, Enum.map(1..1536, fn _ -> :rand.uniform() end)}
      end)

    Embeddings.get_embedding(text, opts_with_mock)
  end

  # Setup: Create task and isolated PubSub (DataCase handles sandbox)
  setup %{sandbox_owner: sandbox_owner} do
    {:ok, task} =
      %Task{}
      |> Task.changeset(%{prompt: "Test task for embedding costs", status: "running"})
      |> Repo.insert()

    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    {:ok, sandbox_owner: sandbox_owner, task: task, pubsub: pubsub_name}
  end

  # ============================================================
  # MODEL_Embeddings v4.0: R6 - Cost Recording When Context Provided [INTEGRATION]
  # ============================================================

  describe "R6: cost recording when context provided" do
    test "records embedding cost when context provided and not cached", %{
      task: task,
      pubsub: pubsub
    } do
      agent_id = "embedding_cost_agent_#{System.unique_integer([:positive])}"
      text = "Test text for embedding generation #{System.unique_integer([:positive])}"

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub
      ]

      {:ok, _result} = call_get_embedding(text, opts)

      # Verify cost was recorded
      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert length(costs) == 1

      cost = hd(costs)
      assert cost.cost_type == "llm_embedding"
      assert cost.task_id == task.id
    end

    test "broadcasts cost_recorded event for embedding", %{task: task, pubsub: pubsub} do
      agent_id = "embedding_broadcast_agent_#{System.unique_integer([:positive])}"
      text = "Broadcast test text #{System.unique_integer([:positive])}"

      task_topic = "tasks:#{task.id}:costs"
      Phoenix.PubSub.subscribe(pubsub, task_topic)

      opts = [agent_id: agent_id, task_id: task.id, pubsub: pubsub]
      {:ok, _result} = call_get_embedding(text, opts)

      assert_receive {:cost_recorded, event}, 30_000
      assert event.cost_type == "llm_embedding"
    end

    test "cost metadata includes model_spec", %{task: task, pubsub: pubsub} do
      agent_id = "embedding_model_agent_#{System.unique_integer([:positive])}"
      text = "Model spec test #{System.unique_integer([:positive])}"

      opts = [agent_id: agent_id, task_id: task.id, pubsub: pubsub]
      {:ok, _result} = call_get_embedding(text, opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost.metadata["model_spec"] != nil
    end

    test "cost metadata includes chunk count", %{task: task, pubsub: pubsub} do
      agent_id = "embedding_chunks_agent_#{System.unique_integer([:positive])}"
      text = "Chunk count test #{System.unique_integer([:positive])}"

      opts = [agent_id: agent_id, task_id: task.id, pubsub: pubsub]
      {:ok, _result} = call_get_embedding(text, opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost.metadata["chunks"] != nil
    end
  end

  # ============================================================
  # MODEL_Embeddings v4.0: R7 - No Recording When Cached [INTEGRATION]
  # ============================================================

  describe "R7: no recording when cached" do
    test "skips recording when result is cached", %{task: task, pubsub: pubsub} do
      agent_id = "embedding_cache_agent_#{System.unique_integer([:positive])}"
      # Use same text to trigger cache hit on second call
      text = "Cache test text for deduplication"

      opts = [agent_id: agent_id, task_id: task.id, pubsub: pubsub]

      # First call - should record cost
      {:ok, result1} = call_get_embedding(text, opts)
      refute result1.cached

      # Second call - should be cached, no new cost
      {:ok, result2} = call_get_embedding(text, opts)
      assert result2.cached

      # Should only have one cost record (from first call)
      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert length(costs) == 1
    end

    test "cost metadata shows cached=false for recorded costs", %{task: task, pubsub: pubsub} do
      agent_id = "embedding_cached_false_agent_#{System.unique_integer([:positive])}"
      text = "Cached false test #{System.unique_integer([:positive])}"

      opts = [agent_id: agent_id, task_id: task.id, pubsub: pubsub]
      {:ok, _result} = call_get_embedding(text, opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      # Only non-cached results should be recorded, and metadata should reflect this
      assert cost.metadata["cached"] == false
    end
  end

  # ============================================================
  # MODEL_Embeddings v4.0: R8 - No Recording Without Context [INTEGRATION]
  # ============================================================

  describe "R8: no recording without context" do
    test "skips recording when agent_id not provided", %{task: task, pubsub: pubsub} do
      text = "No agent_id test #{System.unique_integer([:positive])}"

      # Missing agent_id
      opts = [task_id: task.id, pubsub: pubsub]
      {:ok, _result} = call_get_embedding(text, opts)

      # No costs should be recorded
      costs = Repo.all(AgentCost)
      assert Enum.empty?(costs)
    end

    test "skips recording when task_id not provided", %{pubsub: pubsub} do
      agent_id = "embedding_no_task_agent_#{System.unique_integer([:positive])}"
      text = "No task_id test #{System.unique_integer([:positive])}"

      # Missing task_id
      opts = [agent_id: agent_id, pubsub: pubsub]
      {:ok, _result} = call_get_embedding(text, opts)

      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert Enum.empty?(costs)
    end

    test "skips recording when pubsub not provided", %{task: task} do
      agent_id = "embedding_no_pubsub_agent_#{System.unique_integer([:positive])}"
      text = "No pubsub test #{System.unique_integer([:positive])}"

      # Missing pubsub
      opts = [agent_id: agent_id, task_id: task.id]
      {:ok, _result} = call_get_embedding(text, opts)

      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert Enum.empty?(costs)
    end

    test "works without recording context (backward compatible)", %{} do
      text = "Backward compatible test #{System.unique_integer([:positive])}"

      # No recording context at all
      {:ok, result} = call_get_embedding(text, [])

      # Should still return embedding successfully
      assert result.embedding != nil
      assert is_list(result.embedding)
    end
  end

  # ============================================================
  # MODEL_Embeddings v4.0: R9 - Nil Cost Handling [UNIT]
  # ============================================================

  describe "R9: nil cost handling" do
    test "records nil cost when response has no cost data", %{task: task, pubsub: pubsub} do
      agent_id = "embedding_nil_cost_agent_#{System.unique_integer([:positive])}"
      text = "Nil cost test #{System.unique_integer([:positive])}"

      opts = [agent_id: agent_id, task_id: task.id, pubsub: pubsub]
      {:ok, _result} = call_get_embedding(text, opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      # If the embedding provider doesn't return cost, it should be nil
      # but the record should still exist
      assert cost != nil
      assert cost.cost_type == "llm_embedding"
      # cost_usd may be nil or a value depending on provider
    end

    test "cost type is llm_embedding", %{task: task, pubsub: pubsub} do
      agent_id = "embedding_type_agent_#{System.unique_integer([:positive])}"
      text = "Type test #{System.unique_integer([:positive])}"

      opts = [agent_id: agent_id, task_id: task.id, pubsub: pubsub]
      {:ok, _result} = call_get_embedding(text, opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost.cost_type == "llm_embedding"
    end
  end

  # ============================================================
  # MODEL_Embeddings v5.0: R10 - Cost Computed from LLMDB Pricing [UNIT]
  # WorkGroupID: fix-costs-20260129
  # ============================================================

  describe "R10: cost from LLMDB pricing" do
    test "compute_embedding_cost returns Decimal for known model", %{} do
      # openai:text-embedding-3-large has cost.input = 1.3e-4 per million tokens
      # For 1000 input tokens: 1000 * 1.3e-4 / 1_000_000
      model_spec = "openai:text-embedding-3-large"
      usage = %{input_tokens: 1000}

      result = Embeddings.compute_embedding_cost(model_spec, usage)
      assert result != nil, "Expected non-nil cost from LLMDB pricing"
      assert %Decimal{} = result
      assert Decimal.gt?(result, Decimal.new(0))
    end
  end

  # ============================================================
  # MODEL_Embeddings v5.0: R11 - Nil Cost When Model Has No Pricing [UNIT]
  # ============================================================

  describe "R11: nil cost when no LLMDB pricing" do
    test "compute_embedding_cost returns nil for unknown model", %{} do
      result = Embeddings.compute_embedding_cost("unknown:nonexistent", %{input_tokens: 1000})
      assert result == nil
    end
  end

  # ============================================================
  # MODEL_Embeddings v5.0: R12 - Cost Includes All Chunk Tokens [UNIT]
  # ============================================================

  describe "R12: cost includes all chunk tokens" do
    test "compute_embedding_cost scales with token count", %{} do
      model_spec = "openai:text-embedding-3-large"
      cost_1k = Embeddings.compute_embedding_cost(model_spec, %{input_tokens: 1000})
      cost_2k = Embeddings.compute_embedding_cost(model_spec, %{input_tokens: 2000})

      assert cost_1k != nil
      assert cost_2k != nil
      # 2x tokens should produce 2x cost
      assert Decimal.equal?(Decimal.mult(cost_1k, 2), cost_2k)
    end
  end

  # ============================================================
  # MODEL_Embeddings v6.0: Cost Accumulator Support
  # WorkGroupID: feat-20260203-194408
  # Packet: 2 (Threading)
  # ============================================================

  alias Quoracle.Costs.Accumulator

  # ============================================================
  # R13: Direct Recording Without Accumulator [INTEGRATION]
  # ============================================================

  describe "R13: direct recording without accumulator" do
    test "records cost directly when no accumulator provided", %{task: task, pubsub: pubsub} do
      agent_id = "r13_agent_#{System.unique_integer([:positive])}"
      text = "Direct recording test #{System.unique_integer([:positive])}"

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub
        # Note: no :cost_accumulator
      ]

      {:ok, _result} = call_get_embedding(text, opts)

      # Cost should be recorded directly to DB
      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert length(costs) == 1
    end
  end

  # ============================================================
  # R14: Accumulate With Accumulator [INTEGRATION]
  # ============================================================

  describe "R14: accumulate with accumulator" do
    test "accumulates cost when accumulator provided", %{task: task, pubsub: pubsub} do
      agent_id = "r14_agent_#{System.unique_integer([:positive])}"
      text = "Accumulate test #{System.unique_integer([:positive])}"

      acc = Accumulator.new()

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        cost_accumulator: acc
      ]

      {:ok, _result, updated_acc} = call_get_embedding(text, opts)

      # Accumulator should have entry, DB should NOT
      assert Accumulator.count(updated_acc) == 1
      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert Enum.empty?(costs)
    end
  end

  # ============================================================
  # R15: Accumulator Returned in Result [UNIT]
  # ============================================================

  describe "R15: accumulator returned in result" do
    test "returns updated accumulator in result tuple", %{task: task, pubsub: pubsub} do
      agent_id = "r15_agent_#{System.unique_integer([:positive])}"
      text = "Result tuple test #{System.unique_integer([:positive])}"

      acc = Accumulator.new()

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        cost_accumulator: acc
      ]

      result = call_get_embedding(text, opts)

      # Should return 3-tuple with accumulator
      assert {:ok, embedding_result, %Accumulator{}} = result
      assert is_map(embedding_result)
      assert Map.has_key?(embedding_result, :embedding)
    end
  end

  # ============================================================
  # R16: Cost Entry Format Preserved [UNIT]
  # ============================================================

  describe "R16: cost entry format preserved" do
    test "accumulated cost entry has correct structure", %{task: task, pubsub: pubsub} do
      agent_id = "r16_agent_#{System.unique_integer([:positive])}"
      text = "Format test #{System.unique_integer([:positive])}"

      acc = Accumulator.new()

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        cost_accumulator: acc
      ]

      {:ok, _result, updated_acc} = call_get_embedding(text, opts)

      [entry] = Accumulator.to_list(updated_acc)

      # Verify entry has all required fields
      assert entry.agent_id == agent_id
      assert entry.task_id == task.id
      assert entry.cost_type == "llm_embedding"
      assert Map.has_key?(entry, :cost_usd)
      assert is_map(entry.metadata)
      assert Map.has_key?(entry.metadata, "model_spec")
    end
  end

  # ============================================================
  # R17: Cached Results Skip Accumulation [UNIT]
  # ============================================================

  describe "R17: cached results skip accumulation" do
    test "cached results do not accumulate cost", %{task: task, pubsub: pubsub} do
      agent_id = "r17_agent_#{System.unique_integer([:positive])}"
      # Use same text for cache hit
      text = "Cache skip accumulation test"

      # First call - no accumulator, records to DB (warms cache)
      opts1 = [agent_id: agent_id, task_id: task.id, pubsub: pubsub]
      {:ok, result1} = call_get_embedding(text, opts1)
      refute result1.cached

      # Second call - with accumulator, should be cached
      acc = Accumulator.new()
      opts2 = [agent_id: agent_id, task_id: task.id, pubsub: pubsub, cost_accumulator: acc]
      result2 = call_get_embedding(text, opts2)

      # Cached result returns 2-tuple (no accumulator update needed)
      assert {:ok, cached_result} = result2
      assert cached_result.cached

      # OR if implementation returns 3-tuple with unchanged accumulator:
      # assert {:ok, cached_result, ^acc} = result2
      # assert cached_result.cached
      # assert Accumulator.empty?(acc)
    end
  end
end
