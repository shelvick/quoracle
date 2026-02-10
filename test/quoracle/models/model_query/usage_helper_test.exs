defmodule Quoracle.Models.ModelQuery.UsageHelperTest do
  @moduledoc """
  Tests for MODEL_Query UsageHelper.

  v12.0 (feat-cost-breakdown-20251230):
  - R31-R38: Detailed token capture

  v17.0 (feat-20260203-194408):
  - R20: Flush Empty Accumulator [UNIT]
  - R21: Flush Single Entry [INTEGRATION]
  - R22: Flush Multiple Entries (Batch) [INTEGRATION]
  - R23: Broadcast After Flush [INTEGRATION]
  - R24: Flush Failure Logged and Discarded [INTEGRATION]
  - R25: Timestamps Set on Flush [INTEGRATION]
  """

  use Quoracle.DataCase, async: true

  import Ecto.Query

  alias Quoracle.Repo
  alias Quoracle.Tasks.Task
  alias Quoracle.Costs.AgentCost
  alias Quoracle.Models.ModelQuery.UsageHelper

  # Setup: Create task and isolated PubSub (DataCase handles sandbox)
  setup %{sandbox_owner: _sandbox_owner} do
    {:ok, task} =
      %Task{}
      |> Task.changeset(%{prompt: "Test task for usage helper", status: "running"})
      |> Repo.insert()

    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    {:ok, task: task, pubsub: pubsub_name}
  end

  # Helper to build a response with full token details
  defp build_response(opts) do
    usage = Keyword.get(opts, :usage, %{})
    provider_meta = Keyword.get(opts, :provider_meta, nil)

    base = %{
      id: "test-id",
      model: "test-model",
      message: %{role: "assistant", content: "Test response"},
      usage: usage,
      finish_reason: :stop
    }

    if provider_meta do
      Map.put(base, :provider_meta, provider_meta)
    else
      base
    end
  end

  # Helper to call maybe_record_costs and return the recorded cost
  defp record_and_fetch_cost(response, model_name, options) do
    successful_with_models = [{model_name, response}]
    UsageHelper.maybe_record_costs(successful_with_models, options)

    agent_id = Map.get(options, :agent_id)
    Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
  end

  # ============================================================
  # MODEL_Query v12.0: R31 - All Token Types Captured [UNIT]
  # ============================================================

  describe "R31: all token types captured" do
    test "metadata includes all 5 token types", %{task: task, pubsub: pubsub} do
      agent_id = "r31_agent_#{System.unique_integer([:positive])}"

      # Note: cache_creation_input_tokens is in usage map (where ReqLLM puts it)
      response =
        build_response(
          usage: %{
            input_tokens: 100,
            output_tokens: 50,
            reasoning_tokens: 25,
            cached_tokens: 10,
            cache_creation_input_tokens: 5
          }
        )

      options = %{
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub
      }

      cost = record_and_fetch_cost(response, "test-model", options)

      # Verify all 5 token types are in metadata
      assert Map.has_key?(cost.metadata, "input_tokens")
      assert Map.has_key?(cost.metadata, "output_tokens")
      assert Map.has_key?(cost.metadata, "reasoning_tokens")
      assert Map.has_key?(cost.metadata, "cached_tokens")
      assert Map.has_key?(cost.metadata, "cache_creation_tokens")

      # Verify values
      assert cost.metadata["input_tokens"] == 100
      assert cost.metadata["output_tokens"] == 50
      assert cost.metadata["reasoning_tokens"] == 25
      assert cost.metadata["cached_tokens"] == 10
      assert cost.metadata["cache_creation_tokens"] == 5
    end
  end

  # ============================================================
  # MODEL_Query v12.0: R32 - Cache Creation from Usage Map [UNIT]
  # ============================================================

  describe "R32: cache creation from usage map" do
    test "extracts cache_creation_tokens from usage map", %{task: task, pubsub: pubsub} do
      agent_id = "r32_agent_#{System.unique_integer([:positive])}"

      # ReqLLM's Anthropic provider puts cache_creation_input_tokens in usage map
      response =
        build_response(
          usage: %{input_tokens: 100, output_tokens: 50, cache_creation_input_tokens: 42}
        )

      options = %{
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub
      }

      cost = record_and_fetch_cost(response, "test-model", options)

      assert cost.metadata["cache_creation_tokens"] == 42
    end
  end

  # ============================================================
  # MODEL_Query v12.0: R33 - Missing Token Types Stored as Nil [UNIT]
  # ============================================================

  describe "R33: missing token types stored as nil" do
    test "stores nil for missing token types", %{task: task, pubsub: pubsub} do
      agent_id = "r33_agent_#{System.unique_integer([:positive])}"

      # Response with only basic tokens, no reasoning/cached/cache_creation
      response =
        build_response(usage: %{input_tokens: 100, output_tokens: 50})

      options = %{
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub
      }

      cost = record_and_fetch_cost(response, "test-model", options)

      # Keys must EXIST with nil values (not just return nil for missing keys)
      assert Map.has_key?(cost.metadata, "reasoning_tokens")
      assert Map.has_key?(cost.metadata, "cached_tokens")
      assert Map.has_key?(cost.metadata, "cache_creation_tokens")

      # Values should be nil, not 0
      assert cost.metadata["reasoning_tokens"] == nil
      assert cost.metadata["cached_tokens"] == nil
      assert cost.metadata["cache_creation_tokens"] == nil
    end
  end

  # ============================================================
  # MODEL_Query v12.0: R34 - Aggregate Costs Captured [UNIT]
  # ============================================================

  describe "R34: aggregate costs captured" do
    test "metadata includes aggregate cost fields", %{task: task, pubsub: pubsub} do
      agent_id = "r34_agent_#{System.unique_integer([:positive])}"

      response =
        build_response(
          usage: %{
            input_tokens: 100,
            output_tokens: 50,
            input_cost: 0.001,
            output_cost: 0.002,
            total_cost: 0.003
          }
        )

      options = %{
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub
      }

      cost = record_and_fetch_cost(response, "test-model", options)

      # Verify cost fields are in metadata
      assert Map.has_key?(cost.metadata, "input_cost")
      assert Map.has_key?(cost.metadata, "output_cost")
      assert Map.has_key?(cost.metadata, "total_cost")
    end
  end

  # ============================================================
  # MODEL_Query v12.0: R35 - Cost Format Consistency [UNIT]
  # ============================================================

  describe "R35: cost format consistency" do
    test "formats costs as strings for JSON storage", %{task: task, pubsub: pubsub} do
      agent_id = "r35_agent_#{System.unique_integer([:positive])}"

      response =
        build_response(
          usage: %{
            input_tokens: 100,
            output_tokens: 50,
            input_cost: 0.001,
            output_cost: Decimal.new("0.002"),
            total_cost: 0.003
          }
        )

      options = %{
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub
      }

      cost = record_and_fetch_cost(response, "test-model", options)

      # Costs should be stored as strings for JSON compatibility
      assert is_binary(cost.metadata["input_cost"])
      assert is_binary(cost.metadata["output_cost"])
      assert is_binary(cost.metadata["total_cost"])
    end
  end

  # ============================================================
  # MODEL_Query v12.0: R36 - Nil Cost Preserved [UNIT]
  # ============================================================

  describe "R36: nil cost preserved" do
    test "preserves nil costs without conversion", %{task: task, pubsub: pubsub} do
      agent_id = "r36_agent_#{System.unique_integer([:positive])}"

      # Response with nil costs
      response =
        build_response(
          usage: %{
            input_tokens: 100,
            output_tokens: 50,
            input_cost: nil,
            output_cost: nil,
            total_cost: nil
          }
        )

      options = %{
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub
      }

      cost = record_and_fetch_cost(response, "test-model", options)

      # Keys must EXIST with nil values (not just return nil for missing keys)
      assert Map.has_key?(cost.metadata, "input_cost")
      assert Map.has_key?(cost.metadata, "output_cost")
      assert Map.has_key?(cost.metadata, "total_cost")

      # Nil costs should remain nil (not "0" or "nil")
      assert cost.metadata["input_cost"] == nil
      assert cost.metadata["output_cost"] == nil
      assert cost.metadata["total_cost"] == nil
    end
  end

  # ============================================================
  # MODEL_Query v12.0: R37 - Backward Compatibility [INTEGRATION]
  # ============================================================

  describe "R37: backward compatibility" do
    test "maintains backward compatibility with existing queries", %{task: task, pubsub: pubsub} do
      agent_id = "r37_agent_#{System.unique_integer([:positive])}"

      # Response with standard fields that existing code expects
      response =
        build_response(
          usage: %{
            input_tokens: 100,
            output_tokens: 50
          }
        )

      options = %{
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub
      }

      cost = record_and_fetch_cost(response, "test-model", options)

      # Existing queries rely on these fields - they must still work
      assert cost.metadata["input_tokens"] == 100
      assert cost.metadata["output_tokens"] == 50
      assert cost.metadata["model_spec"] == "test-model"

      # Cost record should have required fields
      assert cost.agent_id == agent_id
      assert cost.task_id == task.id
      assert cost.cost_type == "llm_consensus"

      # NEW: After v12.0, metadata should also have new token/cost keys
      # This ensures backward compatibility check fails until implementation
      assert Map.has_key?(cost.metadata, "reasoning_tokens")
      assert Map.has_key?(cost.metadata, "cached_tokens")
      assert Map.has_key?(cost.metadata, "cache_creation_tokens")
      assert Map.has_key?(cost.metadata, "input_cost")
      assert Map.has_key?(cost.metadata, "output_cost")
      assert Map.has_key?(cost.metadata, "total_cost")
    end
  end

  # ============================================================
  # MODEL_Query v12.0: R38 - Provider Meta Absent [UNIT]
  # ============================================================

  describe "R38: provider meta absent" do
    test "handles missing provider_meta gracefully", %{task: task, pubsub: pubsub} do
      agent_id = "r38_agent_#{System.unique_integer([:positive])}"

      # Response without provider_meta at all
      response =
        build_response(usage: %{input_tokens: 100, output_tokens: 50})

      options = %{
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub
      }

      cost = record_and_fetch_cost(response, "test-model", options)

      # Should not crash
      assert cost != nil

      # Key must EXIST with nil value (not just return nil for missing key)
      assert Map.has_key?(cost.metadata, "cache_creation_tokens")
      assert cost.metadata["cache_creation_tokens"] == nil
    end

    test "handles empty provider_meta map gracefully", %{task: task, pubsub: pubsub} do
      agent_id = "r38_empty_agent_#{System.unique_integer([:positive])}"

      # Response with empty provider_meta
      response =
        build_response(
          usage: %{input_tokens: 100, output_tokens: 50},
          provider_meta: %{}
        )

      options = %{
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub
      }

      cost = record_and_fetch_cost(response, "test-model", options)

      # Should not crash
      assert cost != nil

      # Key must EXIST with nil value (not just return nil for missing key)
      assert Map.has_key?(cost.metadata, "cache_creation_tokens")
      assert cost.metadata["cache_creation_tokens"] == nil
    end
  end

  # === v5.0 Embedding Cost Computation Tests (fix-costs-20260129) ===

  describe "[UNIT] embedding cost computation (R10-R12)" do
    # R10: Cost Computed from LLMDB Pricing
    test "embedding cost record has non-nil cost_usd when LLMDB pricing available",
         %{task: task, pubsub: pubsub} do
      # record_single_request should produce a cost_usd when usage includes total_cost
      # In the new implementation, embeddings.ex record_cost will compute total_cost
      # from LLMDB pricing before passing to UsageHelper.
      # Here we test that UsageHelper correctly extracts total_cost from usage.
      response = %{
        usage: %{input_tokens: 1000, output_tokens: 0, total_cost: Decimal.new("0.00013")}
      }

      agent_id = "agent-embed-cost-#{System.unique_integer([:positive])}"

      UsageHelper.record_single_request(response, "llm_embedding", %{
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        model_spec: "azure-openai:text-embedding-3-large"
      })

      cost = Repo.one!(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost.cost_usd != nil
      assert Decimal.equal?(cost.cost_usd, Decimal.new("0.00013"))
    end

    # R11: total_cost in Usage Map passed through
    test "record_single_request preserves total_cost in metadata",
         %{task: task, pubsub: pubsub} do
      response = %{
        usage: %{input_tokens: 500, output_tokens: 0, total_cost: Decimal.new("0.000065")}
      }

      agent_id = "agent-embed-meta-#{System.unique_integer([:positive])}"

      UsageHelper.record_single_request(response, "llm_embedding", %{
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        model_spec: "azure-openai:text-embedding-3-large"
      })

      cost = Repo.one!(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost.metadata["total_cost"] != nil
    end

    # R12: model_spec in Cost Options
    test "embedding cost record includes model_spec in metadata",
         %{task: task, pubsub: pubsub} do
      response = %{usage: %{input_tokens: 100, output_tokens: 0}}
      agent_id = "agent-embed-spec-#{System.unique_integer([:positive])}"

      UsageHelper.record_single_request(response, "llm_embedding", %{
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        model_spec: "azure-openai:text-embedding-3-large"
      })

      cost = Repo.one!(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost.metadata["model_spec"] == "azure-openai:text-embedding-3-large"
    end
  end

  # ============================================================
  # MODEL_Query v17.0: flush_accumulated_costs/2 Tests
  # WorkGroupID: feat-20260203-194408
  # ============================================================

  # Need to alias the Accumulator module for v17.0 tests
  alias Quoracle.Costs.Accumulator

  # ============================================================
  # R20: Flush Empty Accumulator [UNIT]
  # ============================================================

  describe "R20: flush empty accumulator" do
    test "returns :ok for empty accumulator", %{pubsub: pubsub} do
      acc = Accumulator.new()

      assert :ok = UsageHelper.flush_accumulated_costs(acc, pubsub)
    end

    test "does not insert any records for empty accumulator", %{pubsub: pubsub} do
      initial_count = Repo.aggregate(AgentCost, :count)
      acc = Accumulator.new()

      :ok = UsageHelper.flush_accumulated_costs(acc, pubsub)

      assert Repo.aggregate(AgentCost, :count) == initial_count
    end
  end

  # ============================================================
  # R21: Flush Single Entry [INTEGRATION]
  # ============================================================

  describe "R21: flush single entry" do
    test "inserts single entry to database", %{task: task, pubsub: pubsub} do
      agent_id = "r21_agent_#{System.unique_integer([:positive])}"

      acc =
        Accumulator.new()
        |> Accumulator.add(build_accumulator_entry(agent_id, task.id))

      :ok = UsageHelper.flush_accumulated_costs(acc, pubsub)

      cost = Repo.one!(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost.cost_type == "llm_embedding"
      assert cost.task_id == task.id
    end
  end

  # ============================================================
  # R22: Flush Multiple Entries (Batch) [INTEGRATION]
  # ============================================================

  describe "R22: flush batch insert" do
    test "batch inserts multiple entries", %{task: task, pubsub: pubsub} do
      agent_id = "r22_agent_#{System.unique_integer([:positive])}"

      acc =
        Accumulator.new()
        |> Accumulator.add(build_accumulator_entry(agent_id, task.id, cost_type: "llm_embedding"))
        |> Accumulator.add(build_accumulator_entry(agent_id, task.id, cost_type: "llm_embedding"))
        |> Accumulator.add(build_accumulator_entry(agent_id, task.id, cost_type: "llm_embedding"))

      :ok = UsageHelper.flush_accumulated_costs(acc, pubsub)

      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert length(costs) == 3
    end

    test "all entries have correct data after batch insert", %{task: task, pubsub: pubsub} do
      agent_id = "r22_verify_#{System.unique_integer([:positive])}"

      entries = [
        build_accumulator_entry(agent_id, task.id, cost_usd: Decimal.new("0.001")),
        build_accumulator_entry(agent_id, task.id, cost_usd: Decimal.new("0.002")),
        build_accumulator_entry(agent_id, task.id, cost_usd: Decimal.new("0.003"))
      ]

      acc = Enum.reduce(entries, Accumulator.new(), &Accumulator.add(&2, &1))

      :ok = UsageHelper.flush_accumulated_costs(acc, pubsub)

      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id, order_by: c.cost_usd))
      assert length(costs) == 3

      assert Decimal.equal?(Enum.at(costs, 0).cost_usd, Decimal.new("0.001"))
      assert Decimal.equal?(Enum.at(costs, 1).cost_usd, Decimal.new("0.002"))
      assert Decimal.equal?(Enum.at(costs, 2).cost_usd, Decimal.new("0.003"))
    end
  end

  # ============================================================
  # R23: Broadcast After Flush [INTEGRATION]
  # ============================================================

  describe "R23: flush broadcast" do
    test "broadcasts each cost to PubSub", %{task: task, pubsub: pubsub} do
      agent_id = "r23_agent_#{System.unique_integer([:positive])}"
      agent_topic = "agents:#{agent_id}:costs"
      Phoenix.PubSub.subscribe(pubsub, agent_topic)

      acc =
        Accumulator.new()
        |> Accumulator.add(build_accumulator_entry(agent_id, task.id))
        |> Accumulator.add(build_accumulator_entry(agent_id, task.id))

      :ok = UsageHelper.flush_accumulated_costs(acc, pubsub)

      # Should receive 2 broadcasts
      assert_receive {:cost_recorded, %{agent_id: ^agent_id}}, 5000
      assert_receive {:cost_recorded, %{agent_id: ^agent_id}}, 5000
    end

    test "broadcasts to both agent and task topics", %{task: task, pubsub: pubsub} do
      agent_id = "r23_dual_#{System.unique_integer([:positive])}"
      agent_topic = "agents:#{agent_id}:costs"
      task_topic = "tasks:#{task.id}:costs"

      Phoenix.PubSub.subscribe(pubsub, agent_topic)
      Phoenix.PubSub.subscribe(pubsub, task_topic)

      acc =
        Accumulator.new()
        |> Accumulator.add(build_accumulator_entry(agent_id, task.id))

      :ok = UsageHelper.flush_accumulated_costs(acc, pubsub)

      # Should receive on both topics
      assert_receive {:cost_recorded, %{agent_id: ^agent_id}}, 5000
      assert_receive {:cost_recorded, %{task_id: task_id}}, 5000
      assert task_id == task.id
    end
  end

  # ============================================================
  # R24: Flush Failure Logged and Discarded [INTEGRATION]
  # ============================================================

  describe "R24: flush failure handling" do
    test "logs and discards on DB failure", %{pubsub: pubsub} do
      # Use invalid task_id to trigger foreign key constraint failure
      invalid_task_id = Ecto.UUID.generate()
      agent_id = "r24_agent_#{System.unique_integer([:positive])}"

      acc =
        Accumulator.new()
        |> Accumulator.add(build_accumulator_entry(agent_id, invalid_task_id))

      # Should not raise, should return :ok even on failure
      assert :ok = UsageHelper.flush_accumulated_costs(acc, pubsub)

      # No records should be inserted
      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert costs == []
    end
  end

  # ============================================================
  # R25: Timestamps Set on Flush [INTEGRATION]
  # ============================================================

  describe "R25: flush timestamps" do
    test "sets inserted_at timestamp", %{task: task, pubsub: pubsub} do
      agent_id = "r25_agent_#{System.unique_integer([:positive])}"
      before_flush = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      acc =
        Accumulator.new()
        |> Accumulator.add(build_accumulator_entry(agent_id, task.id))

      :ok = UsageHelper.flush_accumulated_costs(acc, pubsub)

      after_flush =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(1, :second)
        |> NaiveDateTime.truncate(:second)

      cost = Repo.one!(from(c in AgentCost, where: c.agent_id == ^agent_id))

      assert NaiveDateTime.compare(cost.inserted_at, before_flush) in [:eq, :gt]
      assert NaiveDateTime.compare(cost.inserted_at, after_flush) in [:eq, :lt]
    end

    test "all entries in batch have same timestamp", %{task: task, pubsub: pubsub} do
      agent_id = "r25_batch_#{System.unique_integer([:positive])}"

      acc =
        Accumulator.new()
        |> Accumulator.add(build_accumulator_entry(agent_id, task.id))
        |> Accumulator.add(build_accumulator_entry(agent_id, task.id))
        |> Accumulator.add(build_accumulator_entry(agent_id, task.id))

      :ok = UsageHelper.flush_accumulated_costs(acc, pubsub)

      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      timestamps = Enum.map(costs, & &1.inserted_at) |> Enum.uniq()

      # All entries should have the same timestamp (batch insert)
      assert length(timestamps) == 1
    end
  end

  # Helper for v17.0 accumulator entries
  defp build_accumulator_entry(agent_id, task_id, overrides \\ []) do
    defaults = %{
      agent_id: agent_id,
      task_id: task_id,
      cost_type: Keyword.get(overrides, :cost_type, "llm_embedding"),
      cost_usd: Keyword.get(overrides, :cost_usd, Decimal.new("0.0001")),
      metadata: %{"model_spec" => "azure:text-embedding-3-large"}
    }

    Map.merge(
      defaults,
      Map.new(Keyword.delete(overrides, :cost_type) |> Keyword.delete(:cost_usd))
    )
  end
end
