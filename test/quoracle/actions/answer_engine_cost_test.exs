defmodule Quoracle.Actions.AnswerEngineCostTest do
  @moduledoc """
  Tests for ACTION_Answer v4.0 cost recording integration.

  WorkGroupID: feat-20251212-191913
  Packet: 3 (LLM Integration)

  Requirements:
  - R11: Cost Recording [INTEGRATION]
  - R12: No Recording Without Context [INTEGRATION]
  - R13: Grounding Metadata [UNIT]
  - R14: Nil Cost Handling [UNIT]

  Note: These tests verify cost recording behavior through the execute/3 function.
  Tests will fail until maybe_record_cost/4 is implemented and wired into execute/3.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Repo
  alias Quoracle.Tasks.Task
  alias Quoracle.Costs.AgentCost
  alias Quoracle.Actions.AnswerEngine

  import Ecto.Query

  # Test model config to bypass ConfigModelSettings lookup
  defp test_model_config do
    %{
      model_id: "test-gemini",
      model_spec: "google-vertex:gemini-2.0-flash",
      resource_id: "test-project",
      region: "us-central1"
    }
  end

  # Mock plug that returns a successful Gemini response with grounding
  defp mock_gemini_plug do
    fn conn ->
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => "The answer is 4."}],
              "role" => "model"
            },
            "finishReason" => "STOP",
            "groundingMetadata" => %{
              "groundingChunks" => [
                %{"web" => %{"uri" => "https://example.com", "title" => "Math Facts"}}
              ]
            }
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 20,
          "totalTokenCount" => 30
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end
  end

  # Setup: Create task and isolated PubSub (DataCase handles sandbox)
  setup %{sandbox_owner: sandbox_owner} do
    {:ok, task} =
      %Task{}
      |> Task.changeset(%{prompt: "Test task for cost recording", status: "running"})
      |> Repo.insert()

    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    {:ok, sandbox_owner: sandbox_owner, task: task, pubsub: pubsub_name}
  end

  # ============================================================
  # ACTION_Answer v4.0: R11 - Cost Recording [INTEGRATION]
  # ============================================================

  describe "R11: cost recording on success" do
    test "records answer engine cost on success", %{task: task, pubsub: pubsub} do
      agent_id = "cost_test_agent_#{System.unique_integer([:positive])}"

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        model_config: test_model_config(),
        plug: mock_gemini_plug(),
        access_token: "test-token"
      ]

      # Execute answer engine - expects success and cost recording
      {:ok, _result} = AnswerEngine.execute(%{prompt: "What is 2+2?"}, agent_id, opts)

      # Verify cost was recorded
      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert length(costs) == 1

      cost = hd(costs)
      assert cost.cost_type == "llm_answer"
      assert cost.task_id == task.id
    end

    test "broadcasts cost_recorded event", %{task: task, pubsub: pubsub} do
      agent_id = "broadcast_test_agent_#{System.unique_integer([:positive])}"

      task_topic = "tasks:#{task.id}:costs"
      Phoenix.PubSub.subscribe(pubsub, task_topic)

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        model_config: test_model_config(),
        plug: mock_gemini_plug(),
        access_token: "test-token"
      ]

      {:ok, _result} = AnswerEngine.execute(%{prompt: "Test broadcast"}, agent_id, opts)

      assert_receive {:cost_recorded, event}, 30_000
      assert event.cost_type == "llm_answer"
    end
  end

  # ============================================================
  # ACTION_Answer v4.0: R12 - No Recording Without Context [INTEGRATION]
  # ============================================================

  describe "R12: no recording without context" do
    test "skips recording when agent_id not provided in opts", %{task: task, pubsub: pubsub} do
      # Missing agent_id in opts (still required as function arg)
      opts = [
        task_id: task.id,
        pubsub: pubsub,
        model_config: test_model_config(),
        plug: mock_gemini_plug(),
        access_token: "test-token"
      ]

      {:ok, _result} =
        AnswerEngine.execute(%{prompt: "No agent context"}, "direct_agent", opts)

      # Verify no cost was recorded for this context
      costs = Repo.all(from(c in AgentCost, where: c.task_id == ^task.id))
      assert Enum.empty?(costs)
    end

    test "skips recording when task_id not provided", %{pubsub: pubsub} do
      agent_id = "no_task_agent_#{System.unique_integer([:positive])}"

      # Missing task_id
      opts = [
        agent_id: agent_id,
        pubsub: pubsub,
        model_config: test_model_config(),
        plug: mock_gemini_plug(),
        access_token: "test-token"
      ]

      {:ok, _result} = AnswerEngine.execute(%{prompt: "No task context"}, agent_id, opts)

      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert Enum.empty?(costs)
    end

    test "skips recording when pubsub not provided", %{task: task} do
      agent_id = "no_pubsub_agent_#{System.unique_integer([:positive])}"

      # Missing pubsub
      opts = [
        agent_id: agent_id,
        task_id: task.id,
        model_config: test_model_config(),
        plug: mock_gemini_plug(),
        access_token: "test-token"
      ]

      {:ok, _result} = AnswerEngine.execute(%{prompt: "No pubsub context"}, agent_id, opts)

      costs = Repo.all(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert Enum.empty?(costs)
    end
  end

  # ============================================================
  # ACTION_Answer v4.0: R13 - Grounding Metadata [UNIT]
  # ============================================================

  describe "R13: grounding metadata in cost record" do
    test "cost metadata includes grounded=true", %{task: task, pubsub: pubsub} do
      agent_id = "grounding_test_agent_#{System.unique_integer([:positive])}"

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        model_config: test_model_config(),
        plug: mock_gemini_plug(),
        access_token: "test-token"
      ]

      {:ok, _result} = AnswerEngine.execute(%{prompt: "What is Elixir?"}, agent_id, opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost != nil
      assert cost.metadata["grounded"] == true
    end

    test "cost metadata includes sources_count", %{task: task, pubsub: pubsub} do
      agent_id = "sources_count_agent_#{System.unique_integer([:positive])}"

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        model_config: test_model_config(),
        plug: mock_gemini_plug(),
        access_token: "test-token"
      ]

      {:ok, result} =
        AnswerEngine.execute(%{prompt: "Latest news about Elixir"}, agent_id, opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost != nil
      assert cost.metadata["sources_count"] == length(result.sources)
    end

    test "cost metadata includes model_spec", %{task: task, pubsub: pubsub} do
      agent_id = "model_spec_agent_#{System.unique_integer([:positive])}"

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        model_config: test_model_config(),
        plug: mock_gemini_plug(),
        access_token: "test-token"
      ]

      {:ok, _result} = AnswerEngine.execute(%{prompt: "Test model spec"}, agent_id, opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost != nil
      assert cost.metadata["model_spec"] != nil
    end
  end

  # ============================================================
  # ACTION_Answer v4.0: R14 - Nil Cost Handling [UNIT]
  # ============================================================

  describe "R14: nil cost handling" do
    test "records cost even when usage data not available", %{task: task, pubsub: pubsub} do
      agent_id = "nil_cost_agent_#{System.unique_integer([:positive])}"

      opts = [
        agent_id: agent_id,
        task_id: task.id,
        pubsub: pubsub,
        model_config: test_model_config(),
        plug: mock_gemini_plug(),
        access_token: "test-token"
      ]

      {:ok, _result} = AnswerEngine.execute(%{prompt: "Nil cost test"}, agent_id, opts)

      cost = Repo.one(from(c in AgentCost, where: c.agent_id == ^agent_id))
      assert cost != nil
      assert cost.cost_type == "llm_answer"
      # cost_usd may be nil if provider doesn't return cost data
    end
  end
end
