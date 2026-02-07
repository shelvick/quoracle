defmodule Quoracle.Agent.ContinuationContextTest do
  @moduledoc """
  Tests for multi-turn conversation context and state utilities.
  Verifies agents maintain proper conversation history across turns.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.{StateUtils, Consensus}

  # ============================================================================
  # Unit Tests - StateUtils (5 tests)
  # ============================================================================

  describe "StateUtils.find_last_decision/2" do
    @tag :arc_func_01
    test "returns most recent decision when history contains decisions" do
      state = %{
        model_histories: %{
          "test-model" => [
            %{type: :decision, content: %{action: :wait}, timestamp: ~U[2025-01-03 12:00:00Z]},
            %{type: :event, content: "some event", timestamp: ~U[2025-01-03 11:59:00Z]},
            %{
              type: :decision,
              content: %{action: :send_message},
              timestamp: ~U[2025-01-03 11:58:00Z]
            }
          ]
        }
      }

      result = StateUtils.find_last_decision(state, "test-model")

      assert result != nil
      assert result.type == :decision
      assert result.content.action == :wait
    end

    @tag :arc_func_02
    test "returns nil when history is empty" do
      state = %{model_histories: %{"test-model" => []}}

      result = StateUtils.find_last_decision(state, "test-model")

      assert result == nil
    end

    @tag :arc_func_02
    test "returns nil when history has no decisions" do
      state = %{
        model_histories: %{
          "test-model" => [
            %{type: :event, content: "event1", timestamp: ~U[2025-01-03 12:00:00Z]},
            %{
              type: :result,
              content: "wrapped content",
              action_id: "action_1",
              result: {:ok, :done},
              timestamp: ~U[2025-01-03 11:59:00Z]
            }
          ]
        }
      }

      result = StateUtils.find_last_decision(state, "test-model")

      assert result == nil
    end
  end

  describe "StateUtils.find_result_for_action/3" do
    @tag :arc_func_03
    test "returns matching result when it exists" do
      state = %{
        model_histories: %{
          "test-model" => [
            %{
              type: :result,
              content: "wrapped content",
              action_id: "action_2",
              result: {:ok, :sent},
              timestamp: ~U[2025-01-03 12:00:00Z]
            },
            %{
              type: :result,
              content: "wrapped content",
              action_id: "action_1",
              result: {:ok, :done},
              timestamp: ~U[2025-01-03 11:59:00Z]
            }
          ]
        }
      }

      result = StateUtils.find_result_for_action(state, "test-model", "action_2")

      assert result != nil
      assert result.type == :result
      assert result.action_id == "action_2"
      assert result.result == {:ok, :sent}
    end

    @tag :arc_func_04
    test "returns nil when no matching result exists" do
      state = %{
        model_histories: %{
          "test-model" => [
            %{
              type: :result,
              content: "wrapped content",
              action_id: "action_1",
              result: {:ok, :done},
              timestamp: ~U[2025-01-03 12:00:00Z]
            }
          ]
        }
      }

      result = StateUtils.find_result_for_action(state, "test-model", "action_99")

      assert result == nil
    end

    @tag :arc_func_05
    test "returns most recent when multiple results match" do
      state = %{
        model_histories: %{
          "test-model" => [
            %{
              type: :result,
              content: "wrapped content",
              action_id: "action_1",
              result: {:ok, :second},
              timestamp: ~U[2025-01-03 12:00:00Z]
            },
            %{
              type: :result,
              content: "wrapped content",
              action_id: "action_1",
              result: {:ok, :first},
              timestamp: ~U[2025-01-03 11:59:00Z]
            }
          ]
        }
      }

      result = StateUtils.find_result_for_action(state, "test-model", "action_1")

      assert result.action_id == "action_1"
      assert result.result == {:ok, :second}
    end
  end

  # ============================================================================
  # Unit Tests - Consensus API Change (3 tests)
  # ============================================================================

  describe "Consensus.get_consensus/2 - new signature" do
    @tag :arc_fix_01
    test "accepts messages array as first parameter" do
      messages = [
        %{role: "system", content: "system prompt"},
        %{role: "user", content: "test message"}
      ]

      opts = [test_mode: true, mock_action: :send_message]

      result = Consensus.get_consensus(messages, opts)

      assert {:ok, consensus_result} = result
      assert elem(consensus_result, 0) in [:consensus, :forced_decision]
      action = elem(consensus_result, 1)
      assert is_atom(action.action)
    end

    @tag :arc_fix_02
    test "does not duplicate messages in consensus flow" do
      messages = [
        %{role: "system", content: "system prompt"},
        %{role: "user", content: "original prompt"},
        %{role: "assistant", content: "{\"action\": \"send_message\"}"},
        %{role: "user", content: "[Action 'send_message' in progress]"}
      ]

      opts = [test_mode: true]

      {:ok, _result} = Consensus.get_consensus(messages, opts)

      user_messages = Enum.filter(messages, &(&1.role == "user"))
      original_count = Enum.count(user_messages, &(&1.content == "original prompt"))

      assert original_count == 1,
             "Original prompt should appear exactly once in input messages"
    end

    @tag :arc_fix_03
    test "extracts last user message as prompt for refinement context" do
      messages = [
        %{role: "system", content: "system prompt"},
        %{role: "user", content: "Tell me a joke"},
        %{role: "assistant", content: "{\"action\": \"send_message\"}"},
        %{role: "user", content: "[Action 'send_message' in progress]"}
      ]

      opts = [test_mode: true]

      {:ok, _result} = Consensus.get_consensus(messages, opts)

      # Should extract the LAST user message (what triggered this consensus round)
      prompt = Consensus.extract_prompt_for_context(messages)
      assert prompt == "[Action 'send_message' in progress]"
    end
  end
end
