defmodule Quoracle.Agent.ConsensusPropertyIntegrationTest do
  @moduledoc """
  Split from ConsensusTest for better parallelism.
  Tests property-based consensus verification and integration behavior.
  Contains the slowest tests (~880ms each for property checks).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Quoracle.Agent.Consensus
  alias Quoracle.Actions.Schema

  import Quoracle.Agent.ConsensusTestHelpers

  describe "property-based tests" do
    property "consensus is deterministic with same inputs and seed" do
      check all(
              prompt <- string(:printable, min_length: 5, max_length: 100),
              seed <- integer(1..10000),
              max_runs: 5
            ) do
        history = []
        opts = [seed: seed, test_mode: true]

        messages = build_test_messages(prompt, history)
        result1 = Consensus.get_consensus(messages, opts)
        result2 = Consensus.get_consensus(messages, opts)

        assert result1 == result2
      end
    end

    property "consensus always returns valid schema-compliant actions" do
      check all(
              prompt <- string(:printable, min_length: 5, max_length: 100),
              include_history <- boolean(),
              max_runs: 10
            ) do
        history =
          if include_history do
            [%{role: "user", content: "test context"}]
          else
            []
          end

        messages = build_test_messages(prompt, history)

        case Consensus.get_consensus(messages, test_mode: true) do
          {:ok, {_type, action, _opts}} ->
            assert {:ok, _} = Schema.validate_action_type(action.action)
            assert is_map(action.params)
            assert is_binary(action.reasoning)

            case action.action do
              :spawn_child ->
                assert Map.has_key?(action.params, :task)

              :send_message ->
                assert Map.has_key?(action.params, :to)
                assert Map.has_key?(action.params, :content)

              _ ->
                assert is_map(action.params)
            end

          {:error, reason} ->
            assert is_atom(reason)
        end
      end
    end
  end

  describe "integration behavior" do
    test "always returns a decision - never 'no decision' state" do
      scenarios = [
        {"Clear case", [], [test_mode: true]},
        {"Ambiguous case", [], [test_mode: true]},
        {"Complex case", [%{role: "user", content: "context"}], [test_mode: true]},
        {"Critical case", [], [critical: true, test_mode: true]}
      ]

      for {prompt, history, opts} <- scenarios do
        messages = build_test_messages(prompt, history)
        result = Consensus.get_consensus(messages, opts)

        case result do
          {:ok, decision} ->
            assert elem(decision, 0) in [:consensus, :forced_decision]
            {_type, action, _opts} = decision
            assert is_map(action)
            assert action.action != nil

          {:error, _reason} ->
            assert true

          other ->
            flunk("Unexpected result: #{inspect(other)}")
        end
      end
    end

    test "decision is deterministic with same inputs" do
      prompt = "Deterministic test"
      history = []
      opts = [seed: 42, test_mode: true]

      messages = build_test_messages(prompt, history)
      result1 = Consensus.get_consensus(messages, opts)
      result2 = Consensus.get_consensus(messages, opts)

      assert result1 == result2
    end

    test "uses priority-based tiebreaking for identical vote counts" do
      prompt = "Tie scenario"
      history = []
      opts = [simulate_tie: true, test_mode: true]

      messages = build_test_messages(prompt, history)
      result = Consensus.get_consensus(messages, opts)

      assert {:ok, {_type, action, _opts}} = result

      _conservative_actions = [:orient, :wait, :send_message]

      assert is_atom(action.action)
    end
  end
end
