defmodule Quoracle.Costs.CostRecordingIntegrationTest do
  @moduledoc """
  Integration tests for cost recording context passthrough.

  Bug: fix-ui-costs-20251214
  Root cause: build_query_options was stripping cost context (agent_id, task_id, pubsub),
  causing UsageHelper.maybe_record_costs to skip recording (all context was nil).

  These tests verify the internal fix:
  - Cost context flows through ConsensusHandler → Consensus → PerModelQuery → ModelQuery
  - Costs are inserted into agent_costs table with correct metadata

  Uses mock_query_fn injection to test the pipeline without real HTTP calls.
  UI display is covered by CostDisplay tests.
  """

  use Quoracle.DataCase, async: true

  import Ecto.Query

  alias Quoracle.Costs.AgentCost
  alias Quoracle.Repo

  # Mock usage data for tests that use model_query_fn
  @mock_usage %{
    input_tokens: 100,
    output_tokens: 50,
    total_tokens: 150
  }

  # Helper to build ReqLLM.Response for tests
  defp build_response(text_content, model) do
    %ReqLLM.Response{
      id: "test-#{System.unique_integer([:positive])}",
      model: model,
      context: ReqLLM.Context.new([]),
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text(text_content)]
      },
      usage: @mock_usage,
      finish_reason: :stop,
      provider_meta: %{}
    }
  end

  describe "integration: full pipeline cost context" do
    test "ConsensusHandler → Consensus → PerModelQuery passes cost context" do
      # This test verifies the complete pipeline from ConsensusHandler to model_query_fn.
      # It uses the same mock_query_fn pattern as other tests but starts from ConsensusHandler.

      test_pid = self()

      mock_query_fn = fn _messages, models, opts ->
        # Capture received opts for verification
        send(test_pid, {:handler_query_opts, opts})

        json_content =
          Jason.encode!(%{
            "action" => "orient",
            "params" => %{"summary" => "handler test"},
            "reasoning" => "test",
            "wait" => true
          })

        response = build_response(json_content, hd(models))

        {:ok,
         %{
           successful_responses: [response],
           failed_models: [],
           total_latency_ms: 100,
           aggregate_usage: @mock_usage
         }}
      end

      # Create state with all cost context fields
      # NOTE: test_mode must be false to use model_query_fn
      # (test_mode: true returns mock results without calling model_query_fn)
      state = %{
        agent_id: "handler-agent-123",
        task_id: "handler-task-456",
        pubsub: :handler_pubsub,
        sandbox_owner: self(),
        model_pool: ["mock:model"],
        model_histories: %{
          "mock:model" => [
            %{type: :user, content: "Test message", timestamp: DateTime.utc_now()}
          ]
        },
        user_prompt: "Handler test prompt",
        system_prompt: nil,
        test_mode: false,
        test_opts: [model_query_fn: mock_query_fn]
      }

      # Call ConsensusHandler (the actual entry point from agent)
      # This exercises: ConsensusHandler → Consensus → PerModelQuery → model_query_fn
      _result = Quoracle.Agent.ConsensusHandler.get_action_consensus(state)

      # Verify cost context flowed through entire pipeline
      assert_receive {:handler_query_opts, received_opts}, 30_000

      assert received_opts[:agent_id] == "handler-agent-123",
             "agent_id not passed from ConsensusHandler through pipeline"

      assert received_opts[:task_id] == "handler-task-456",
             "task_id not passed from ConsensusHandler through pipeline"

      assert received_opts[:pubsub] == :handler_pubsub,
             "pubsub not passed from ConsensusHandler through pipeline"
    end
  end

  describe "acceptance: TaskManager → costs recorded" do
    @tag :acceptance
    @tag capture_log: true
    test "task creation through TaskManager records costs to database", %{
      sandbox_owner: sandbox_owner
    } do
      import Test.AgentTestHelpers

      # Setup isolated dependencies
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: registry_name})

      dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"
      start_supervised!({DynamicSupervisor, name: dynsup_name, strategy: :one_for_one})

      test_pid = self()

      # Mock query function that returns valid action JSON and records costs
      # This simulates what ModelQuery.query_models does: HTTP call + cost recording
      mock_query_fn = fn _messages, models, opts ->
        # Capture that we received the cost context
        send(test_pid, {:acceptance_query_opts, opts})

        model = hd(models)

        json_content =
          Jason.encode!(%{
            "action" => "orient",
            "params" => %{
              "current_situation" => "acceptance test",
              "goal_clarity" => "clear",
              "available_resources" => "test resources",
              "key_challenges" => "none",
              "delegation_consideration" => "not needed"
            },
            "reasoning" => "test reasoning",
            "wait" => true
          })

        response = build_response(json_content, model)

        # Record costs just like ModelQuery.query_models does
        # This is the key part - we simulate the cost recording that happens in the real pipeline
        successful_with_models = [{model, response}]
        Quoracle.Models.ModelQuery.UsageHelper.maybe_record_costs(successful_with_models, opts)

        {:ok,
         %{
           successful_responses: [response],
           failed_models: [],
           total_latency_ms: 100,
           aggregate_usage: @mock_usage
         }}
      end

      # Get test profile for task creation - use unique name to avoid ON CONFLICT contention
      profile = Test.AgentTestHelpers.create_test_profile()

      # USER ENTRY POINT: TaskManager.create_task
      # This is how a user creates a task - the complete entry point
      task_fields = %{profile: profile.name}
      agent_fields = %{task_description: "Acceptance test: verify costs are recorded"}

      # Use a mock model to avoid DB queries for model pool
      test_model = "mock:acceptance-test"

      {:ok, {task, agent_pid}} =
        Quoracle.Tasks.TaskManager.create_task(task_fields, agent_fields,
          sandbox_owner: sandbox_owner,
          dynsup: dynsup_name,
          registry: registry_name,
          pubsub: pubsub_name,
          # Explicit model_pool avoids DB query during agent init
          model_pool: [test_model],
          # Key: test_mode: false so real pipeline runs with model_query_fn
          test_mode: false,
          test_opts: [model_query_fn: mock_query_fn]
        )

      # Register cleanup for the agent
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: registry_name)

      # Trigger consensus by sending a message to the agent
      # This simulates a user sending a message which triggers the consensus pipeline
      # Note: handle_message is async (GenServer.cast), so we must wait for completion
      Quoracle.Agent.Core.handle_message(agent_pid, {self(), "trigger consensus"})

      # Wait for mock_query_fn to be called (proves consensus pipeline was reached)
      assert_receive {:acceptance_query_opts, received_opts}, 30_000

      # Wait for consensus to fully complete and costs to be committed
      # Use GenServer.call to synchronize - ensures all prior casts have been processed
      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)

      # Verify cost context was passed through the entire pipeline
      assert received_opts[:task_id] == task.id,
             "task_id not passed through TaskManager → Agent → Consensus pipeline"

      assert is_binary(received_opts[:agent_id]),
             "agent_id not passed through pipeline"

      assert received_opts[:pubsub] == pubsub_name,
             "pubsub not passed through pipeline"

      # USER-OBSERVABLE OUTCOME: Costs exist in the database
      # This is what the user would see - costs recorded, not "N/A" in UI
      costs =
        from(c in AgentCost, where: c.task_id == ^task.id)
        |> Repo.all()

      assert costs != [],
             """
             ACCEPTANCE TEST FAILURE: No costs recorded to database!

             User created task via TaskManager.create_task but costs were not recorded.
             This means the UI would show "N/A" instead of actual costs.

             The bug: cost context (agent_id, task_id, pubsub) is being stripped
             somewhere in the pipeline:
             TaskManager → Agent.Core → ConsensusHandler → Consensus → PerModelQuery → ModelQuery

             Check that all build_query_options functions pass cost context through.
             """

      # Verify cost has correct task association
      [cost | _] = costs
      assert cost.task_id == task.id
      assert cost.cost_type == "llm_consensus"
    end
  end
end
