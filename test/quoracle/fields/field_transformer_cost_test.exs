defmodule Quoracle.Fields.FieldTransformerCostTest do
  @moduledoc """
  Tests for MOD_FieldTransformer v3.0 cost recording integration.

  WorkGroupID: feat-20251212-191913
  Packet: 3 (LLM Integration)

  Requirements:
  - R9: Cost Recording When Context Provided [INTEGRATION]
  - R10: No Recording Without Context [INTEGRATION]
  - R11: Cost Type Is Summarization [UNIT]
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Repo
  alias Quoracle.Tasks.Task
  alias Quoracle.Costs.AgentCost
  alias Quoracle.Models.TableConsensusConfig
  alias Quoracle.Models.TableCredentials

  alias Quoracle.Fields.FieldTransformer

  import Ecto.Query

  @test_model_id "openai:gpt-4o-mini"

  # Mock plug that returns a successful summarization response
  defp mock_summarization_plug do
    fn conn ->
      response = %{
        "id" => "test-id",
        "object" => "chat.completion",
        "model" => "gemini-2.0-flash",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => "This is a summarized narrative for testing purposes."
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 20,
          "total_tokens" => 120
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end
  end

  # Helper to call summarize_narrative with proper field structure
  # Creates long enough text (>500 chars) to trigger LLM summarization
  defp call_summarize_narrative(long_text, opts) do
    parent_fields = %{transformed: %{accumulated_narrative: ""}}
    provided_fields = %{immediate_context: long_text}
    # Always include mock plug for test isolation
    opts_with_plug = Keyword.put_new(opts, :plug, mock_summarization_plug())
    FieldTransformer.summarize_narrative(parent_fields, provided_fields, opts_with_plug)
  end

  # Setup: Create task, configure summarization model, credentials, isolated PubSub
  setup %{sandbox_owner: sandbox_owner} do
    # Configure summarization model (required for FieldTransformer)
    {:ok, _} =
      TableConsensusConfig.upsert("summarization_model", %{
        "model_id" => @test_model_id
      })

    # Create credentials for the model (required for ModelQuery)
    {:ok, _} =
      TableCredentials.insert(%{
        model_id: @test_model_id,
        model_spec: @test_model_id,
        api_key: "test-key-summarization"
      })

    {:ok, task} =
      %Task{}
      |> Task.changeset(%{prompt: "Test task for summarization costs", status: "running"})
      |> Repo.insert()

    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    {:ok, sandbox_owner: sandbox_owner, task: task, pubsub: pubsub_name}
  end

  # ============================================================
  # MOD_FieldTransformer v3.0: R9 - Cost Recording When Context Provided [INTEGRATION]
  # ============================================================

  describe "R9: cost recording when context provided" do
    test "passes cost recording context to ModelQuery", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "transformer_cost_agent_#{System.unique_integer([:positive])}"
      long_text = String.duplicate("This is a long narrative text. ", 100)

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner
      ]

      # summarize_narrative returns a string directly (triggers LLM when >500 chars)
      _summary = call_summarize_narrative(long_text, opts)

      # Verify cost was recorded via ModelQuery
      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert costs != []

      cost = hd(costs)
      assert cost.cost_type == "llm_summarization"
      assert cost.task_id == task.id
    end

    test "broadcasts cost_recorded event for summarization", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "transformer_broadcast_agent_#{System.unique_integer([:positive])}"
      long_text = String.duplicate("Broadcast test narrative. ", 100)

      task_topic = "tasks:#{task.id}:costs"
      Phoenix.PubSub.subscribe(pubsub, task_topic)

      opts = [agent_id: agent_id, task_id: task.id, pubsub: pubsub, sandbox_owner: sandbox_owner]
      _summary = call_summarize_narrative(long_text, opts)

      assert_receive {:cost_recorded, event}, 30_000
      assert event.cost_type == "llm_summarization"
    end

    test "cost metadata includes model_spec", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "transformer_model_agent_#{System.unique_integer([:positive])}"
      long_text = String.duplicate("Model spec test narrative. ", 100)

      opts = [agent_id: agent_id, task_id: task.id, pubsub: pubsub, sandbox_owner: sandbox_owner]
      _summary = call_summarize_narrative(long_text, opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost.metadata["model_spec"] != nil
    end
  end

  # ============================================================
  # MOD_FieldTransformer v3.0: R10 - No Recording Without Context [INTEGRATION]
  # ============================================================

  describe "R10: no recording without context" do
    test "handles missing recording context gracefully", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      long_text = String.duplicate("No context test narrative. ", 100)

      # Missing agent_id
      opts = [task_id: task.id, pubsub: pubsub, sandbox_owner: sandbox_owner]
      summary = call_summarize_narrative(long_text, opts)

      # Should still return summary successfully
      assert summary != nil
      assert is_binary(summary)

      # No costs should be recorded
      costs = Repo.all(AgentCost)
      assert Enum.empty?(costs)
    end

    test "skips recording when task_id not provided", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "transformer_no_task_agent_#{System.unique_integer([:positive])}"
      long_text = String.duplicate("No task_id test. ", 100)

      # Missing task_id
      opts = [agent_id: agent_id, pubsub: pubsub, sandbox_owner: sandbox_owner]
      _summary = call_summarize_narrative(long_text, opts)

      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert Enum.empty?(costs)
    end

    test "skips recording when pubsub not provided", %{task: task, sandbox_owner: sandbox_owner} do
      agent_id = "transformer_no_pubsub_agent_#{System.unique_integer([:positive])}"
      long_text = String.duplicate("No pubsub test. ", 100)

      # Missing pubsub
      opts = [agent_id: agent_id, task_id: task.id, sandbox_owner: sandbox_owner]
      _summary = call_summarize_narrative(long_text, opts)

      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert Enum.empty?(costs)
    end

    test "works without any recording context (backward compatible)", %{
      sandbox_owner: sandbox_owner
    } do
      long_text = String.duplicate("Backward compatible test. ", 100)

      # No recording context at all
      summary = call_summarize_narrative(long_text, sandbox_owner: sandbox_owner)

      # Should still return summary successfully
      assert summary != nil
      assert is_binary(summary)
    end
  end

  # ============================================================
  # MOD_FieldTransformer v3.0: R11 - Cost Type Is Summarization [UNIT]
  # ============================================================

  describe "R11: cost type is summarization" do
    test "cost type is llm_summarization not llm_consensus", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "transformer_type_agent_#{System.unique_integer([:positive])}"
      long_text = String.duplicate("Cost type test narrative. ", 100)

      opts = [agent_id: agent_id, task_id: task.id, pubsub: pubsub, sandbox_owner: sandbox_owner]
      _summary = call_summarize_narrative(long_text, opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost.cost_type == "llm_summarization"
      refute cost.cost_type == "llm_consensus"
    end

    test "cost type distinguishes summarization from other LLM costs", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "transformer_distinct_agent_#{System.unique_integer([:positive])}"
      long_text = String.duplicate("Distinct type test. ", 100)

      opts = [agent_id: agent_id, task_id: task.id, pubsub: pubsub, sandbox_owner: sandbox_owner]
      _summary = call_summarize_narrative(long_text, opts)

      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      # All costs from summarize_narrative should be llm_summarization
      assert Enum.all?(costs, &(&1.cost_type == "llm_summarization"))
    end

    test "cost metadata includes token counts", %{
      task: task,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "transformer_tokens_agent_#{System.unique_integer([:positive])}"
      long_text = String.duplicate("Token count test. ", 100)

      opts = [agent_id: agent_id, task_id: task.id, pubsub: pubsub, sandbox_owner: sandbox_owner]
      _summary = call_summarize_narrative(long_text, opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      # Should have token information in metadata
      assert Map.has_key?(cost.metadata, "input_tokens")
      assert Map.has_key?(cost.metadata, "output_tokens")
    end
  end
end
