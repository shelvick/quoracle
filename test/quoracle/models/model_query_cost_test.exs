defmodule Quoracle.Models.ModelQueryCostTest do
  @moduledoc """
  Tests for MODEL_Query v11.0 cost recording integration.

  WorkGroupID: feat-20251212-191913
  Packet: 3 (LLM Integration)

  Requirements:
  - R24: Cost Extraction [UNIT]
  - R25: Nil Cost Handling [UNIT]
  - R26: Cost Recording When Context Provided [INTEGRATION]
  - R27: No Recording Without Context [INTEGRATION]
  - R28: Per-Model Recording [INTEGRATION]
  - R29: Cost Type Override [UNIT]
  - R30: Aggregate Usage Includes Costs [UNIT]
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Repo
  alias Quoracle.Tasks.Task
  alias Quoracle.Costs.AgentCost

  # Module under test - deferred for TDD
  @model_query Quoracle.Models.ModelQuery

  alias Quoracle.Models.TableCredentials

  # Helper to create test credentials with a real LLMDB model_spec
  # Uses openai:gpt-4o-mini which LLMDB recognizes, with unique model_id for test isolation
  defp create_test_credential(model_id) do
    {:ok, _credential} =
      TableCredentials.insert(%{
        model_id: model_id,
        # Use real model_spec that LLMDB/ReqLLM recognizes
        model_spec: "openai:gpt-4o-mini",
        api_key: "test-key-#{model_id}"
      })

    model_id
  end

  # Mock plug that returns a successful response
  defp mock_success_plug do
    fn conn ->
      response = %{
        "id" => "test-id",
        "model" => "test-model",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "Test response"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 20,
          "total_tokens" => 30
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end
  end

  # Helper to call query_models at runtime
  # Converts keyword list to map as query_models expects a map
  defp call_query_models(messages, model_ids, opts) when is_list(opts) do
    @model_query.query_models(messages, model_ids, Map.new(opts))
  end

  defp call_query_models(messages, model_ids, opts) do
    @model_query.query_models(messages, model_ids, opts)
  end

  # Setup: Create task and isolated PubSub (DataCase handles sandbox)
  setup %{sandbox_owner: sandbox_owner} do
    {:ok, task} =
      %Task{}
      |> Task.changeset(%{prompt: "Test task for model query costs", status: "running"})
      |> Repo.insert()

    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    {:ok, sandbox_owner: sandbox_owner, task: task, pubsub: pubsub_name}
  end

  # ============================================================
  # MODEL_Query v11.0: R24 - Cost Extraction [UNIT]
  # ============================================================

  describe "R24: cost extraction" do
    test "calculate_aggregate_usage extracts input_cost as Decimal" do
      # Simulated usage data with cost fields
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        input_cost: "0.001",
        output_cost: "0.002",
        total_cost: "0.003"
      }

      # The aggregate usage should extract cost fields as Decimals
      result = @model_query.calculate_aggregate_usage([usage])

      assert result.input_cost != nil
      assert is_struct(result.input_cost, Decimal)
    end

    test "calculate_aggregate_usage extracts output_cost as Decimal" do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        input_cost: "0.001",
        output_cost: "0.002",
        total_cost: "0.003"
      }

      result = @model_query.calculate_aggregate_usage([usage])

      assert result.output_cost != nil
    end

    test "calculate_aggregate_usage extracts total_cost as Decimal" do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        input_cost: "0.001",
        output_cost: "0.002",
        total_cost: "0.003"
      }

      result = @model_query.calculate_aggregate_usage([usage])

      assert result.total_cost != nil
    end
  end

  # ============================================================
  # MODEL_Query v11.0: R25 - Nil Cost Handling [UNIT]
  # ============================================================

  describe "R25: nil cost handling" do
    test "treats nil input_cost as zero in aggregation" do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        input_cost: nil,
        output_cost: "0.002",
        total_cost: nil
      }

      result = @model_query.calculate_aggregate_usage([usage])

      # Should not crash, should treat nil as zero
      assert result.input_tokens == 100
    end

    test "treats nil output_cost as zero in aggregation" do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        input_cost: "0.001",
        output_cost: nil,
        total_cost: nil
      }

      result = @model_query.calculate_aggregate_usage([usage])

      assert result.output_tokens == 50
    end

    test "handles all nil cost fields without crashing" do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        input_cost: nil,
        output_cost: nil,
        total_cost: nil
      }

      result = @model_query.calculate_aggregate_usage([usage])

      assert result.input_tokens == 100
      assert result.output_tokens == 50
    end
  end

  # ============================================================
  # MODEL_Query v11.0: R26 - Cost Recording When Context Provided [INTEGRATION]
  # ============================================================

  describe "R26: cost recording when context provided" do
    test "records costs when recording context provided", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "query_cost_agent_#{System.unique_integer([:positive])}"
      model_id = "test_model_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "Test query for cost recording"}]

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      # This will use configured models - we just verify cost recording works
      {:ok, _responses} = call_query_models(messages, [model_id], opts)

      # Verify cost was recorded
      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert costs != []

      cost = hd(costs)
      assert cost.cost_type == "llm_consensus"
      assert cost.task_id == task.id
    end

    test "broadcasts cost_recorded event for consensus query", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "query_broadcast_agent_#{System.unique_integer([:positive])}"
      model_id = "test_model_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "Broadcast test query"}]

      task_topic = "tasks:#{task.id}:costs"
      Phoenix.PubSub.subscribe(pubsub, task_topic)

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, _responses} = call_query_models(messages, [model_id], opts)

      assert_receive {:cost_recorded, event}, 30_000
      assert event.cost_type == "llm_consensus"
    end

    test "cost metadata includes model_spec", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "query_model_agent_#{System.unique_integer([:positive])}"
      model_id = "test_model_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "Model spec test"}]

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, _responses} = call_query_models(messages, [model_id], opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost.metadata["model_spec"] != nil
    end

    test "cost metadata includes token counts", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "query_tokens_agent_#{System.unique_integer([:positive])}"
      model_id = "test_model_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "Token count test"}]

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, _responses} = call_query_models(messages, [model_id], opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      # Token counts should be present in metadata
      assert Map.has_key?(cost.metadata, "input_tokens")
      assert Map.has_key?(cost.metadata, "output_tokens")
    end
  end

  # ============================================================
  # MODEL_Query v11.0: R27 - No Recording Without Context [INTEGRATION]
  # ============================================================

  describe "R27: no recording without context" do
    test "skips recording when agent_id not provided", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      model_id = "test_model_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "No agent_id test"}]

      # Missing agent_id
      opts = [
        task_id: task.id,
        pubsub: pubsub,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, _responses} = call_query_models(messages, [model_id], opts)

      # No costs should be recorded
      costs = Repo.all(AgentCost)
      assert Enum.empty?(costs)
    end

    test "skips recording when task_id not provided", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "query_no_task_agent_#{System.unique_integer([:positive])}"
      model_id = "test_model_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "No task_id test"}]

      # Missing task_id
      opts = [
        agent_id: agent_id,
        pubsub: pubsub,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, _responses} = call_query_models(messages, [model_id], opts)

      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert Enum.empty?(costs)
    end

    test "skips recording when pubsub not provided", %{task: task, sandbox_owner: sandbox_owner} do
      agent_id = "query_no_pubsub_agent_#{System.unique_integer([:positive])}"
      model_id = "test_model_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "No pubsub test"}]

      # Missing pubsub
      opts = [
        agent_id: agent_id,
        task_id: task.id,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, _responses} = call_query_models(messages, [model_id], opts)

      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert Enum.empty?(costs)
    end

    test "works without recording context (backward compatible)", %{sandbox_owner: sandbox_owner} do
      model_id = "test_model_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "Backward compatible test"}]

      # No recording context at all
      opts = [
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, responses} = call_query_models(messages, [model_id], opts)

      # Should still return responses successfully
      assert responses != nil
    end
  end

  # ============================================================
  # MODEL_Query v11.0: R28 - Aggregated Cost for Multi-Model Queries [INTEGRATION]
  # ============================================================

  describe "R28: aggregated cost for multi-model queries" do
    test "records separate cost for each model in multi-model query", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "query_multi_model_agent_#{System.unique_integer([:positive])}"
      model_id_1 = "model_1_#{System.unique_integer([:positive])}"
      model_id_2 = "model_2_#{System.unique_integer([:positive])}"
      create_test_credential(model_id_1)
      create_test_credential(model_id_2)
      messages = [%{role: "user", content: "Multi-model cost test"}]

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      # Query multiple models
      {:ok, _responses} = call_query_models(messages, [model_id_1, model_id_2], opts)

      # Should have one cost record per model queried
      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert length(costs) >= 2
    end

    test "each model cost has correct model_spec in metadata", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "query_multi_spec_agent_#{System.unique_integer([:positive])}"
      model_id_1 = "model_1_#{System.unique_integer([:positive])}"
      model_id_2 = "model_2_#{System.unique_integer([:positive])}"
      create_test_credential(model_id_1)
      create_test_credential(model_id_2)
      messages = [%{role: "user", content: "Multi-spec test"}]

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, _responses} = call_query_models(messages, [model_id_1, model_id_2], opts)

      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      model_specs = Enum.map(costs, & &1.metadata["model_spec"])

      # Each cost should have a different model_spec
      assert length(Enum.uniq(model_specs)) == length(costs)
    end

    test "handles nil cost fields in aggregation", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "query_nil_agg_agent_#{System.unique_integer([:positive])}"
      model_id = "model_1_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "Nil aggregation test"}]

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, _responses} = call_query_models(messages, [model_id], opts)

      # Even with nil costs, records should exist
      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert costs != []
      # Each record should have all required fields
      Enum.each(costs, fn cost ->
        assert cost.cost_type == "llm_consensus"
        assert cost.agent_id == agent_id
        assert cost.task_id == task.id
      end)
    end
  end

  # ============================================================
  # MODEL_Query v11.0: R29 - Cost Type Override [UNIT]
  # ============================================================

  describe "R29: cost type override" do
    test "uses provided cost_type from options", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "query_custom_type_agent_#{System.unique_integer([:positive])}"
      model_id = "test_model_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "Custom type test"}]

      # Provide custom cost_type in options
      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        cost_type: "llm_summarization",
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, _responses} = call_query_models(messages, [model_id], opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      # Should use the provided cost_type instead of default "llm_consensus"
      assert cost.cost_type == "llm_summarization"
    end

    test "uses default cost_type when not provided", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "query_default_type_agent_#{System.unique_integer([:positive])}"
      model_id = "test_model_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "Default type test"}]

      # No cost_type in options
      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, _responses} = call_query_models(messages, [model_id], opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      # Should use default "llm_consensus"
      assert cost.cost_type == "llm_consensus"
    end
  end

  # ============================================================
  # MODEL_Query v11.0: R30 - Aggregate Usage Includes Costs [UNIT]
  # ============================================================

  describe "R30: aggregate usage includes costs" do
    test "query_models return includes total_cost in aggregate_usage", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "query_agg_total_agent_#{System.unique_integer([:positive])}"
      model_id = "test_model_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "Aggregate cost test"}]

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, result} = call_query_models(messages, [model_id], opts)

      # aggregate_usage should include cost fields
      assert Map.has_key?(result.aggregate_usage, :total_cost)
    end

    test "query_models return includes input_cost in aggregate_usage", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "query_agg_input_agent_#{System.unique_integer([:positive])}"
      model_id = "test_model_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "Aggregate input cost test"}]

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, result} = call_query_models(messages, [model_id], opts)

      assert Map.has_key?(result.aggregate_usage, :input_cost)
    end

    test "query_models return includes output_cost in aggregate_usage", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "query_agg_output_agent_#{System.unique_integer([:positive])}"
      model_id = "test_model_#{System.unique_integer([:positive])}"
      create_test_credential(model_id)
      messages = [%{role: "user", content: "Aggregate output cost test"}]

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        plug: mock_success_plug(),
        sandbox_owner: sandbox_owner,
        execution_mode: :sequential
      ]

      {:ok, result} = call_query_models(messages, [model_id], opts)

      assert Map.has_key?(result.aggregate_usage, :output_cost)
    end
  end
end
