defmodule Quoracle.Agent.ConsensusIntegrationTest do
  @moduledoc """
  Integration tests for Consensus module with PromptBuilder and JSON parsing.
  Tests the integration of system prompts and real JSON parsing.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Agent.Consensus
  alias Quoracle.Agent.Consensus.MockResponseGenerator

  import Quoracle.Agent.ConsensusTestHelpers

  describe "system prompt integration" do
    test "includes system prompt from PromptBuilder in messages" do
      # Verify system prompt is included via test helper
      prompt = "What should we do next?"
      history = []

      # Use test helper which mirrors production pattern
      messages = build_test_messages(prompt, history)

      assert [%{role: "system", content: system_content} | _rest] = messages
      assert system_content =~ "You are one agent"
      assert system_content =~ "Available Actions"
    end
  end

  describe "JSON parsing integration" do
    test "uses parse_json_response for actual parsing" do
      # This will fail until simulation is replaced
      json_response = """
      {
        "action": "wait",
        "params": {"wait": 1000},
        "reasoning": "Waiting for data to be ready"
      }
      """

      # parse_json_response should be used internally
      {:ok, parsed} = Consensus.parse_json_response(json_response)

      assert parsed.action == :wait
      assert parsed.params == %{"wait" => 1000}
      assert parsed.reasoning == "Waiting for data to be ready"
    end

    test "handles invalid JSON with error logging" do
      # Test that invalid JSON is handled and logged
      invalid_json = "This is not JSON"

      log =
        capture_log(fn ->
          result = Consensus.parse_json_response(invalid_json)
          assert {:error, :invalid_json} = result
        end)

      # Should log the error (uses JsonExtractor now)
      assert log =~ "Failed to parse JSON"
    end

    test "consensus continues with valid responses when some fail" do
      # Mixed valid/invalid responses should still work
      prompt = "Decide action"
      history = []

      # This will need MockResponseGenerator to produce mixed responses
      opts = [test_mode: true, simulate_partial_failure: true]

      # Capture logs since partial failures will log parsing errors
      capture_log(fn ->
        messages = build_test_messages(prompt, history)
        result = Consensus.get_consensus(messages, opts)
        assert {:ok, _decision} = result
      end)
    end
  end

  describe "MockResponseGenerator JSON output" do
    test "generates valid JSON responses" do
      model_pool = [:gpt4, :claude, :gemini]
      opts = []

      {:ok, responses} = MockResponseGenerator.generate(model_pool, opts)

      Enum.each(responses, fn response ->
        assert is_binary(response.content)

        # Should be valid JSON
        assert {:ok, parsed} = Jason.decode(response.content)
        assert Map.has_key?(parsed, "action")
        assert Map.has_key?(parsed, "params")
        assert Map.has_key?(parsed, "reasoning")
      end)
    end

    test "generates malformed JSON when requested" do
      model_pool = [:gpt4]
      opts = [malformed: true, malformed_type: :invalid_json]

      {:ok, responses} = MockResponseGenerator.generate(model_pool, opts)
      [response] = responses

      # Should not be valid JSON
      assert {:error, _} = Jason.decode(response.content)
    end

    test "generates mixed valid/invalid responses" do
      model_pool = [:gpt4, :claude, :gemini]
      opts = [mixed_responses: true]

      {:ok, responses} = MockResponseGenerator.generate(model_pool, opts)

      valid_count =
        responses
        |> Enum.count(fn r ->
          case Jason.decode(r.content) do
            {:ok, _} -> true
            _ -> false
          end
        end)

      # Should have at least one valid and one invalid
      assert valid_count > 0
      assert valid_count < length(responses)
    end

    test "generates specific action when seeded" do
      model_pool = [:gpt4]
      opts = [seed_action: :spawn_child, seed_params: %{"task" => "analyze data"}]

      {:ok, responses} = MockResponseGenerator.generate(model_pool, opts)
      [response] = responses

      {:ok, parsed} = Jason.decode(response.content)
      assert parsed["action"] == "spawn_child"
      assert parsed["params"]["task"] == "analyze data"
    end
  end

  describe "end-to-end consensus with JSON" do
    test "consensus returns properly parsed action from JSON" do
      prompt = "What should we do?"
      history = []

      # Use test mode with JSON responses
      opts = [test_mode: true, use_json: true]

      messages = build_test_messages(prompt, history)
      {:ok, decision} = Consensus.get_consensus(messages, opts)
      {_type, action, _opts} = decision

      # Action should be properly parsed from JSON
      assert is_atom(action.action)
      assert is_map(action.params)
      assert is_binary(action.reasoning)
    end

    test "refinement works with JSON responses" do
      prompt = "Complex decision"
      history = []

      # Force refinement with no initial majority
      opts = [test_mode: true, force_refinement: true, use_json: true]

      messages = build_test_messages(prompt, history)
      {:ok, decision} = Consensus.get_consensus(messages, opts)
      {type, _action, opts_result} = decision

      # Should go through refinement
      assert type in [:consensus, :forced_decision]
      assert Keyword.get(opts_result, :rounds) > 1
    end
  end
end
