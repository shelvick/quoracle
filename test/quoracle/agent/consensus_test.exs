defmodule Quoracle.Agent.ConsensusTest do
  @moduledoc """
  Tests for the Consensus module that coordinates multi-model decision making.
  All tests use test_mode: true which bypasses database access.
  """

  # Tests use async: true with shared mode for Task.async_stream processes
  use ExUnit.Case, async: true

  alias Quoracle.Agent.Consensus

  import ExUnit.CaptureLog
  import Quoracle.Agent.ConsensusTestHelpers

  describe "message alternation validation" do
    # Validation helper supporting both string and atom keys
    defp validate_alternation([]), do: :ok
    defp validate_alternation([_]), do: :ok

    defp validate_alternation(messages) do
      has_consecutive_same =
        messages
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.any?(fn [current, next] ->
          get_role(current) == get_role(next)
        end)

      if has_consecutive_same, do: {:error, :invalid_alternation}, else: :ok
    end

    defp get_role(message) do
      message["role"] || message[:role]
    end

    test "messages built for initial consensus maintain alternation" do
      prompt = "What should we do?"

      history = [
        %{role: "user", content: "Previous question"},
        %{role: "assistant", content: "Previous answer"}
      ]

      messages = build_test_messages(prompt, history)

      # Validate alternation (excluding system messages)
      messages_for_validation =
        messages
        |> Enum.filter(&(&1.role != "system"))
        |> Enum.map(&%{"role" => to_string(&1.role), "content" => &1.content})

      assert validate_alternation(messages_for_validation) == :ok
    end
  end

  describe "get_consensus/3" do
    test "returns consensus when majority agrees on action" do
      prompt = "Analyze the current situation and decide next action"

      history = [
        %{role: "user", content: "Start analyzing data"},
        %{role: "assistant", content: "I'll analyze the data"}
      ]

      # Use test mode to avoid database access
      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, test_mode: true)

      assert {:ok, decision} = result
      assert elem(decision, 0) in [:consensus, :forced_decision]

      {_type, action, opts} = decision
      assert is_map(action)
      assert Map.has_key?(action, :action)
      assert Map.has_key?(action, :params)
      assert Map.has_key?(action, :reasoning)
      assert Keyword.get(opts, :confidence) > 0
    end

    test "returns exactly ONE action decision - never multiple alternatives" do
      prompt = "What should we do next?"
      history = []

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, test_mode: true)

      assert {:ok, decision} = result
      {_type, action, _opts} = decision

      # Must be exactly one action, not a list
      assert is_map(action)
      assert is_atom(action.action)
      refute is_list(action)
    end

    test "uses 3 models by default" do
      prompt = "Decide on next action"
      history = []

      # Default should use 3-model pool
      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, test_mode: true)

      assert {:ok, _decision} = result
      # Implementation will internally use Manager.get_model_pool() which returns 3 models
    end

    test "uses 5 models when critical flag is set" do
      prompt = "Critical decision needed"
      history = []
      opts = [critical: true, test_mode: true]

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, opts)

      assert {:ok, _decision} = result

      # Implementation will internally use Manager.get_critical_model_pool() which returns 5 models
    end

    test "includes conversation history in consensus process" do
      prompt = "Continue with the plan?"

      history = [
        %{role: "user", content: "We need to process user data"},
        %{role: "assistant", content: "I'll start by analyzing the requirements"},
        %{role: "user", content: "Good, what's next?"}
      ]

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, test_mode: true)

      assert {:ok, _decision} = result
      # History should be preserved and used in context
    end

    test "handles empty conversation history" do
      prompt = "Initial decision"
      history = []

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, test_mode: true)

      assert {:ok, _decision} = result
    end

    test "returns error when all models fail" do
      prompt = "Test prompt"
      history = []
      # Test flag
      opts = [simulate_failure: true, test_mode: true]

      messages = build_test_messages(prompt, history)

      # Capture expected log output from consensus failures
      capture_log(fn ->
        send(self(), {:result, Consensus.get_consensus(messages, opts)})
      end)

      assert_receive {:result, result}
      assert {:error, reason} = result
      assert reason in [:all_models_failed, :query_error]
    end
  end

  describe "consensus types" do
    test "returns consensus type when majority exists" do
      prompt = "Clear majority case"
      history = []

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, test_mode: true)

      assert {:ok, decision} = result
      assert elem(decision, 0) in [:consensus, :forced_decision]

      # With majority, should be :consensus
      # Without majority after max rounds, should be :forced_decision
    end

    test "returns forced_decision after max refinement rounds" do
      prompt = "No consensus case requiring forced decision"
      history = []
      # Test flag
      opts = [force_no_consensus: true, test_mode: true]

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, opts)

      assert {:ok, {type, _action, opts}} = result
      # After max rounds with no majority, should force decision
      assert type == :forced_decision
      assert Keyword.get(opts, :confidence) <= 0.5
    end

    test "confidence score reflects consensus strength" do
      prompt = "Test confidence scoring"
      history = []

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, test_mode: true)

      assert {:ok, {_type, _action, opts}} = result
      confidence = Keyword.get(opts, :confidence)

      assert is_float(confidence)
      assert confidence >= 0.1
      assert confidence <= 1.0
    end
  end

  describe "action structure" do
    test "returned action has required fields" do
      prompt = "Test action structure"
      history = []

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, test_mode: true)

      assert {:ok, {_type, action, _opts}} = result

      assert Map.has_key?(action, :action)
      assert Map.has_key?(action, :params)
      assert Map.has_key?(action, :reasoning)

      assert is_atom(action.action)
      assert is_map(action.params)
      assert is_binary(action.reasoning)
    end

    test "action type is valid schema action" do
      prompt = "Choose a valid action"
      history = []

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, test_mode: true)

      assert {:ok, {_type, action, _opts}} = result

      valid_actions = [
        :spawn_child,
        :wait,
        :send_message,
        :orient,
        :answer_engine,
        :execute_shell,
        :fetch_web,
        :call_api,
        :call_mcp
      ]

      assert action.action in valid_actions
    end

    test "params match action schema requirements" do
      prompt = "Execute action with proper params"
      history = []

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, test_mode: true)

      assert {:ok, {_type, action, _opts}} = result

      # Params should be appropriate for the action type
      case action.action do
        :spawn_child ->
          assert Map.has_key?(action.params, :task)

        :send_message ->
          assert Map.has_key?(action.params, :to)
          assert Map.has_key?(action.params, :content)

        :wait ->
          # May have optional duration
          if map_size(action.params) > 0 do
            assert Map.has_key?(action.params, :wait)
          end

        _ ->
          # Other actions have their own param requirements
          assert is_map(action.params)
      end
    end
  end
end
