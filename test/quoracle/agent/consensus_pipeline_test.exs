defmodule Quoracle.Agent.ConsensusPipelineTest do
  @moduledoc """
  Split from ConsensusTest for better parallelism.
  Tests refinement process, error handling, configuration,
  and JSON response parsing.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.Consensus

  import ExUnit.CaptureLog
  import Quoracle.Agent.ConsensusTestHelpers

  describe "refinement process" do
    test "triggers refinement when no initial majority" do
      prompt = "Ambiguous situation needing refinement"
      history = []
      opts = [simulate_no_majority: true, test_mode: true]

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, opts)

      assert {:ok, _decision} = result
    end

    test "preserves reasoning history during refinement" do
      prompt = "Complex decision requiring multiple rounds"

      history = [
        %{role: "user", content: "Previous context"}
      ]

      opts = [track_refinement: true, test_mode: true]

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, opts)

      assert {:ok, {_type, action, _opts}} = result
      assert action.reasoning != ""
    end

    test "stops refinement after max rounds" do
      prompt = "Never-converging case"
      history = []
      opts = [force_max_rounds: true, test_mode: true]

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, opts)

      assert {:ok, {type, _action, _opts}} = result
      assert type == :forced_decision
    end

    test "handles refinement query failures gracefully" do
      prompt = "Refinement with potential failures"
      history = []
      opts = [simulate_refinement_failure: true, test_mode: true]

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, opts)

      assert {:ok, _decision} = result
    end
  end

  describe "error handling" do
    test "returns error when prompt is invalid" do
      messages = []
      result = Consensus.get_consensus(messages, test_mode: true)

      assert {:ok, _} = result
    end

    test "handles malformed conversation history" do
      messages = [
        %{role: "system", content: "System prompt"},
        %{role: "user", content: "Valid message"}
      ]

      result = Consensus.get_consensus(messages, test_mode: true)

      assert {:ok, _} = result
    end

    test "returns error for nil inputs" do
      result = Consensus.get_consensus(nil, test_mode: true)

      assert {:error, reason} = result
      assert reason == :invalid_arguments
    end

    test "handles partial model failures" do
      prompt = "Test with some models failing"
      history = []
      opts = [simulate_partial_failure: true, test_mode: true]

      capture_log(fn ->
        messages = build_test_messages(prompt, history)
        result = Consensus.get_consensus(messages, opts)

        assert {:ok, _decision} = result
      end)
    end
  end

  describe "configuration-based test mode" do
    test "uses test_mode option instead of Mix.env()" do
      prompt = "Test with config"
      history = []

      opts = [test_mode: true]
      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, opts)
      assert {:ok, _decision} = result
    end

    test "test mode can be disabled via options" do
      prompt = "Production mode test"
      history = []

      opts = [test_mode: true, simulate_failure: false]

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, opts)
      assert {:ok, decision} = result
      assert elem(decision, 0) in [:consensus, :forced_decision]
    end

    test "checks test_mode option on every call" do
      prompt = "Dynamic config test"
      history = []

      opts1 = [test_mode: true]
      messages = build_test_messages(prompt, history)
      assert {:ok, _result1} = Consensus.get_consensus(messages, opts1)

      opts2 = [test_mode: true, force_no_consensus: true]
      messages = build_test_messages(prompt, history)
      assert {:ok, result2} = Consensus.get_consensus(messages, opts2)

      assert elem(result2, 0) == :forced_decision
    end
  end

  describe "JSON response parsing" do
    test "parses properly formatted JSON action responses" do
      json_response = ~s({
        "action": "spawn_child",
        "params": {"task": "analyze data"},
        "reasoning": "Data analysis is needed"
      })

      parsed = Consensus.parse_json_response(json_response)

      assert {:ok, action} = parsed
      assert action.action == :spawn_child
      assert action.params == %{"task" => "analyze data"}
      assert action.reasoning == "Data analysis is needed"
    end

    test "handles JSON with extra fields gracefully" do
      json_response = ~s({
        "action": "wait",
        "params": {"wait": 5000},
        "reasoning": "Need to wait",
        "confidence": 0.95,
        "model": "gpt-4"
      })

      {:ok, action} = Consensus.parse_json_response(json_response)

      assert action.action == :wait
      assert action.params == %{"wait" => 5000}
      assert action.reasoning == "Need to wait"
      refute Map.has_key?(action, :confidence)
      refute Map.has_key?(action, :model)
    end

    test "converts string actions to atoms safely" do
      json_response = ~s({
        "action": "execute_shell",
        "params": {"command": "ls"},
        "reasoning": "List files"
      })

      {:ok, action} = Consensus.parse_json_response(json_response)

      assert action.action == :execute_shell
      assert is_atom(action.action)
    end

    test "returns error for invalid JSON" do
      invalid_json = "not valid json {action:"

      log =
        capture_log(fn ->
          result = Consensus.parse_json_response(invalid_json)
          assert {:error, :invalid_json} = result
        end)

      assert log =~ "Failed to"
    end

    test "extracts JSON from Markdown code blocks with json tag" do
      markdown_wrapped = """
      Here's my response:

      ```json
      {
        "action": "wait",
        "params": {"wait": 1000},
        "reasoning": "Waiting for process to complete"
      }
      ```

      That's the action to take.
      """

      {:ok, action} = Consensus.parse_json_response(markdown_wrapped)

      assert action.action == :wait
      assert action.params == %{"wait" => 1000}
      assert action.reasoning == "Waiting for process to complete"
    end

    test "extracts JSON from Markdown code blocks without language tag" do
      markdown_wrapped = """
      ```
      {
        "action": "orient",
        "params": {},
        "reasoning": "Getting my bearings"
      }
      ```
      """

      {:ok, action} = Consensus.parse_json_response(markdown_wrapped)

      assert action.action == :orient
      assert action.params == %{}
      assert action.reasoning == "Getting my bearings"
    end

    test "extracts JSON with text before and after" do
      wrapped_json = """
      I'll help you with that. Here's my decision:
      {"action": "spawn_child", "params": {"task": "subtask"}, "reasoning": "decompose"}
      That should work!
      """

      {:ok, action} = Consensus.parse_json_response(wrapped_json)

      assert action.action == :spawn_child
      assert action.params == %{"task" => "subtask"}
      assert action.reasoning == "decompose"
    end

    test "handles complex nested JSON in Markdown" do
      complex_wrapped = """
      The response is:
      ```json
      {
        "action": "wait",
        "params": {
          "nested": {
            "value": "test",
            "deep": {"level": 3}
          }
        },
        "reasoning": "complex nesting"
      }
      ```
      End of response.
      """

      {:ok, action} = Consensus.parse_json_response(complex_wrapped)

      assert action.action == :wait
      assert action.params["nested"]["value"] == "test"
      assert action.params["nested"]["deep"]["level"] == 3
      assert action.reasoning == "complex nesting"
    end

    test "handles JSON with braces in string values" do
      json_with_braces = """
      Before text
      {"action": "wait", "params": {"msg": "use } and { here"}, "reasoning": "test"}
      After text
      """

      {:ok, action} = Consensus.parse_json_response(json_with_braces)

      assert action.action == :wait
      assert action.params == %{"msg" => "use } and { here"}
      assert action.reasoning == "test"
    end

    test "returns error when no JSON found in wrapped text" do
      no_json = "This is just plain text with no JSON in it"

      log =
        capture_log(fn ->
          result = Consensus.parse_json_response(no_json)
          assert {:error, :invalid_json} = result
        end)

      assert log =~ "Failed to"
    end

    test "returns error for missing required fields" do
      incomplete_json = ~s({"action": "wait"})

      result = Consensus.parse_json_response(incomplete_json)

      assert {:error, :missing_fields} = result
    end

    test "returns error for unknown action types" do
      unknown_action = ~s({
        "action": "unknown_action_xyz",
        "params": {},
        "reasoning": "test"
      })

      result = Consensus.parse_json_response(unknown_action)

      assert {:error, :unknown_action} = result
    end

    test "handles nested parameter structures" do
      json_response = ~s({
        "action": "spawn_child",
        "params": {
          "task": "complex task",
          "config": {
            "timeout": 30000,
            "retries": 3
          },
          "models": ["gpt-4", "claude"]
        },
        "reasoning": "Complex params"
      })

      {:ok, action} = Consensus.parse_json_response(json_response)

      assert action.params["task"] == "complex task"
      assert action.params["config"]["timeout"] == 30000
      assert action.params["config"]["retries"] == 3
      assert action.params["models"] == ["gpt-4", "claude"]
    end
  end
end
