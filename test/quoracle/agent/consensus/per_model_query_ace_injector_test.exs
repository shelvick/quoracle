defmodule Quoracle.Agent.Consensus.PerModelQueryAceInjectorTest do
  @moduledoc """
  Tests for PerModelQuery v13.0 - ACE injector integration.

  Verifies that AceInjector is called during per-model consensus queries
  to inject ACE context into the first user message.

  WorkGroupID: wip-20260104-ace-injector
  Packet: 1 (ACE Injector)

  ARC Verification Criteria: R61-R64
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.Consensus.PerModelQuery

  # ========== TEST HELPERS ==========

  defp make_lesson(content, type \\ :factual, confidence \\ 0.8) do
    %{content: content, type: type, confidence: confidence}
  end

  defp make_model_state(summary) do
    %{summary: summary}
  end

  defp make_history_entry(type, content) do
    %{type: type, content: content, timestamp: DateTime.utc_now()}
  end

  defp make_state_with_ace(model_id, lessons, model_state \\ nil) do
    %{
      agent_id: "test-agent-#{System.unique_integer([:positive])}",
      task_id: "test-task",
      model_histories: %{
        model_id => [
          make_history_entry(:user, "Initial user message"),
          make_history_entry(:assistant, "Initial response")
        ]
      },
      context_lessons: if(lessons, do: %{model_id => lessons}, else: %{}),
      model_states: if(model_state, do: %{model_id => model_state}, else: %{}),
      todos: [],
      children: [],
      budget_data: nil
    }
  end

  # ========== R61: ACE INJECTOR CALLED ==========

  describe "R61: AceInjector called during query" do
    test "query_single_model_with_retry injects ACE into messages sent to LLM" do
      # This test verifies the ACTUAL code path in PerModelQuery
      # by capturing the messages sent to the LLM via injectable model_query_fn
      model_id = "test-model"
      lessons = [make_lesson("ACE lesson from condensation")]
      state = make_state_with_ace(model_id, lessons)

      # Capture messages sent to LLM
      test_pid = self()

      mock_query_fn = fn messages, _models, _opts ->
        # Send captured messages back to test process
        send(test_pid, {:captured_messages, messages})

        # Return mock successful response
        {:ok,
         %{
           successful_responses: [
             %{model: model_id, content: ~s({"action": "orient", "params": {}, "wait": false})}
           ],
           failed_models: []
         }}
      end

      opts = [
        model_query_fn: mock_query_fn,
        round: 1
      ]

      # Call actual PerModelQuery function
      {:ok, _response, _state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # Verify ACE content appears in captured messages
      assert_receive {:captured_messages, messages}, 30_000

      all_content = Enum.map_join(messages, " ", & &1.content)

      # R61: ACE should be injected into messages
      assert all_content =~ "<lessons>",
             "ACE lessons should be injected into messages sent to LLM"

      assert all_content =~ "ACE lesson from condensation"
    end

    test "query_single_model_with_retry injects model state into messages" do
      model_id = "test-model"
      model_state = make_model_state("Task is 75% complete")
      state = make_state_with_ace(model_id, [], model_state)

      test_pid = self()

      mock_query_fn = fn messages, _models, _opts ->
        send(test_pid, {:captured_messages, messages})

        {:ok,
         %{
           successful_responses: [
             %{model: model_id, content: ~s({"action": "orient", "params": {}, "wait": false})}
           ],
           failed_models: []
         }}
      end

      opts = [model_query_fn: mock_query_fn, round: 1]

      {:ok, _response, _state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      assert_receive {:captured_messages, messages}, 30_000
      all_content = Enum.map_join(messages, " ", & &1.content)

      # R61: Model state should be injected
      assert all_content =~ "<state>", "Model state should be injected into messages"
      assert all_content =~ "Task is 75% complete"
    end
  end
end
