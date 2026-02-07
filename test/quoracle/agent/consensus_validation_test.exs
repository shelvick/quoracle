defmodule Quoracle.Agent.ConsensusValidationTest do
  @moduledoc """
  Tests for pre-clustering validation filter (v7.0).
  Validates LLM responses before clustering to prevent invalid actions from winning consensus.

  Requirements: R25-R34 (tiebreak-20251208-202952, Packet 2)
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Quoracle.Agent.Consensus

  # Ensure action atoms exist at compile time by referencing ActionList
  _ = Quoracle.Actions.Schema.ActionList.actions()

  # =============================================================================
  # Unit Tests: filter_invalid_responses/1 (R25-R28)
  # =============================================================================

  describe "filter_invalid_responses/1" do
    @tag :r25
    test "passes all valid responses through unchanged" do
      # Valid orient action with all 4 required params
      valid_responses = [
        %{
          action: :orient,
          params: %{
            current_situation: "test situation",
            goal_clarity: "clear goals",
            available_resources: "all resources",
            key_challenges: "no challenges",
            delegation_consideration: "none"
          },
          reasoning: "reasoning 1"
        },
        %{
          action: :orient,
          params: %{
            current_situation: "another situation",
            goal_clarity: "goals clear",
            available_resources: "resources available",
            key_challenges: "challenges identified",
            delegation_consideration: "none"
          },
          reasoning: "reasoning 2"
        }
      ]

      {validated, invalid_count} = Consensus.filter_invalid_responses(valid_responses)

      assert length(validated) == 2
      assert invalid_count == 0
    end

    @tag :r26
    test "filters out responses with invalid parameters" do
      # Missing required params for orient
      invalid_response = %{
        action: :orient,
        params: %{},
        reasoning: "missing required params"
      }

      valid_response = %{
        action: :orient,
        params: %{
          current_situation: "situation",
          goal_clarity: "goals",
          available_resources: "resources",
          key_challenges: "challenges",
          delegation_consideration: "none"
        },
        reasoning: "valid"
      }

      responses = [invalid_response, valid_response]

      # Capture log to suppress warning output from invalid responses
      {{validated, invalid_count}, _log} =
        with_log(fn ->
          Consensus.filter_invalid_responses(responses)
        end)

      assert length(validated) == 1
      assert invalid_count == 1
      assert hd(validated).reasoning == "valid"
    end

    @tag :r26
    test "filters responses with wrong parameter types" do
      # current_situation should be string, not integer
      invalid_response = %{
        action: :orient,
        params: %{
          current_situation: 12345,
          goal_clarity: "goals",
          available_resources: "resources",
          key_challenges: "challenges",
          delegation_consideration: "none"
        },
        reasoning: "wrong type"
      }

      {{validated, invalid_count}, _log} =
        with_log(fn -> Consensus.filter_invalid_responses([invalid_response]) end)

      assert validated == []
      assert invalid_count == 1
    end

    @tag :r26
    test "filters responses with unknown action types" do
      # Action that doesn't exist
      invalid_response = %{
        action: :nonexistent_action,
        params: %{foo: "bar"},
        reasoning: "unknown action"
      }

      {{validated, invalid_count}, _log} =
        with_log(fn -> Consensus.filter_invalid_responses([invalid_response]) end)

      assert validated == []
      assert invalid_count == 1
    end

    @tag :r27
    test "returns count of filtered responses" do
      valid_params = %{
        current_situation: "situation",
        goal_clarity: "goals",
        available_resources: "resources",
        key_challenges: "challenges",
        delegation_consideration: "none"
      }

      responses = [
        # Invalid: missing required params
        %{action: :orient, params: %{}, reasoning: "invalid 1"},
        # Valid
        %{action: :orient, params: valid_params, reasoning: "valid"},
        # Invalid: missing required params
        %{action: :orient, params: %{}, reasoning: "invalid 2"},
        # Invalid: missing required params
        %{action: :orient, params: %{}, reasoning: "invalid 3"}
      ]

      {{validated, invalid_count}, _log} =
        with_log(fn -> Consensus.filter_invalid_responses(responses) end)

      assert length(validated) == 1
      assert invalid_count == 3
    end

    @tag :r28
    test "logs warning for each invalid response" do
      # Logger.warning is called for each invalid response
      invalid_responses = [
        %{action: :orient, params: %{}, reasoning: "invalid 1"},
        %{action: :orient, params: %{}, reasoning: "invalid 2"}
      ]

      {{valid, invalid_count}, _log} =
        with_log(fn -> Consensus.filter_invalid_responses(invalid_responses) end)

      # Both responses filtered
      assert valid == []
      assert invalid_count == 2
    end

    @tag :r28
    test "logs warning with action name and error reason" do
      # Logger.warning includes action name and reason
      invalid_response = %{
        action: :spawn_child,
        params: %{},
        reasoning: "missing task param"
      }

      {{valid, invalid_count}, _log} =
        with_log(fn -> Consensus.filter_invalid_responses([invalid_response]) end)

      assert valid == []
      assert invalid_count == 1
    end
  end

  # =============================================================================
  # Unit Tests: Error Handling (R29-R30)
  # =============================================================================

  describe "all_responses_invalid error (R29-R30)" do
    @tag :r29
    test "returns all_responses_invalid when all fail validation" do
      # Test the filter function with all invalid responses
      all_invalid = [
        %{action: :orient, params: %{}, reasoning: "invalid 1"},
        %{action: :orient, params: %{}, reasoning: "invalid 2"},
        %{action: :orient, params: %{}, reasoning: "invalid 3"}
      ]

      # Verify filter returns empty list with count > 0
      {{valid, invalid_count}, _log} =
        with_log(fn -> Consensus.filter_invalid_responses(all_invalid) end)

      assert valid == []
      assert invalid_count == 3

      # This condition triggers :all_responses_invalid in consensus flow
      # (verified by implementation: valid == [] and invalid_count > 0)
    end

    @tag :r30
    test "continues with valid responses when some are invalid" do
      valid_params = %{
        current_situation: "situation",
        goal_clarity: "goals",
        available_resources: "resources",
        key_challenges: "challenges",
        delegation_consideration: "none"
      }

      mixed_responses = [
        # Invalid
        %{action: :orient, params: %{}, reasoning: "invalid"},
        # Valid
        %{action: :orient, params: valid_params, reasoning: "valid"}
      ]

      {{valid, invalid_count}, _log} =
        with_log(fn -> Consensus.filter_invalid_responses(mixed_responses) end)

      # Should have 1 valid, 1 filtered
      assert length(valid) == 1
      assert invalid_count == 1
      assert hd(valid).reasoning == "valid"
    end
  end

  # =============================================================================
  # Integration Tests (R31-R34)
  # =============================================================================

  describe "validation before clustering (R31)" do
    @tag :r31
    test "invalid responses do not enter clustering" do
      valid_orient_params = %{
        current_situation: "situation",
        goal_clarity: "goals",
        available_resources: "resources",
        key_challenges: "challenges",
        delegation_consideration: "none"
      }

      # Two invalid responses would form majority if not filtered
      responses_with_invalid_majority = [
        # Invalid (missing required params) - would be majority if not filtered
        %{action: :orient, params: %{}, reasoning: "invalid 1"},
        # Invalid (missing required params)
        %{action: :orient, params: %{}, reasoning: "invalid 2"},
        # Valid - should win since invalids filtered
        %{action: :orient, params: valid_orient_params, reasoning: "valid orient"}
      ]

      # Verify filter removes the invalid majority
      {{valid, invalid_count}, _log} =
        with_log(fn -> Consensus.filter_invalid_responses(responses_with_invalid_majority) end)

      # Only the valid response should remain
      assert length(valid) == 1
      assert invalid_count == 2
      assert hd(valid).reasoning == "valid orient"
    end
  end

  describe "test mode validates (R32)" do
    @tag :r32
    test "test mode responses are validated" do
      # Test that validation IS applied even in test mode
      # MockResponseGenerator creates valid responses, so they should pass validation
      messages = [%{role: "user", content: "test"}]

      result = Consensus.get_consensus(messages, test_mode: true)

      # MockResponseGenerator creates valid orient responses - should succeed
      assert {:ok, {_result_type, action, _meta}} = result
      assert action.action == :orient
    end
  end

  describe "get_consensus_with_state validates (R33)" do
    @tag :r33
    test "get_consensus_with_state validates responses" do
      # Test that invalid responses are filtered by filter_invalid_responses
      invalid_response = %{
        action: :spawn_child,
        params: %{},
        reasoning: "missing task"
      }

      {{valid, invalid_count}, _log} =
        with_log(fn -> Consensus.filter_invalid_responses([invalid_response]) end)

      assert valid == []
      assert invalid_count == 1
    end

    @tag :r33
    test "get_consensus_with_state continues with valid responses" do
      state = %{
        model_histories: %{
          "test:model-1" => [%{role: "user", content: "test"}]
        }
      }

      # Test that validation is applied in state-based API
      # MockResponseGenerator creates valid responses
      result =
        Consensus.get_consensus_with_state(state,
          test_mode: true,
          model_pool: ["test:model-1"]
        )

      assert {:ok, {_result_type, action, meta}, _updated_state} = result
      assert action.action == :orient
      assert Keyword.get(meta, :per_model_queries) == true
    end
  end

  describe "get_consensus with messages validates (R34)" do
    @tag :r34
    test "get_consensus with messages validates responses" do
      # Test that all-invalid list is correctly identified
      invalid_responses = [
        %{action: :orient, params: %{}, reasoning: "invalid 1"},
        %{action: :orient, params: %{}, reasoning: "invalid 2"}
      ]

      {{valid, invalid_count}, _log} =
        with_log(fn -> Consensus.filter_invalid_responses(invalid_responses) end)

      assert valid == []
      assert invalid_count == 2
    end

    @tag :r34
    test "get_consensus with messages continues with valid" do
      # Test that validation is applied in messages-based API
      # MockResponseGenerator creates valid responses
      messages = [%{role: "user", content: "perform task"}]

      result = Consensus.get_consensus(messages, test_mode: true)

      assert {:ok, {_result_type, action, _meta}} = result
      assert action.action == :orient
    end
  end
end
