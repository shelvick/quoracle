defmodule Quoracle.Actions.WaitUnificationTest do
  @moduledoc """
  Tests for wait parameter unification (WorkGroupID: wait-20251114-203234).

  These tests verify:
  - ACTION_Schema v18.0: wait action uses 'wait' parameter (not 'duration')
  - ACTION_Validator v7.0: union type validation for boolean and number
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Schema
  alias Quoracle.Actions.Validator

  describe "ACTION_Schema v18.0 - Wait Parameter Unification" do
    # R13 from CONSENSUS_PromptBuilder spec
    test "[UNIT] wait action schema uses wait parameter (not duration)" do
      {:ok, schema} = Schema.get_schema(:wait)

      # Verify 'wait' is in optional params
      assert :wait in schema.optional_params,
             "Expected :wait in optional_params, got: #{inspect(schema.optional_params)}"

      # Verify 'duration' is NOT in optional params (breaking change)
      refute :duration in schema.optional_params,
             "Expected :duration to be removed, but found in: #{inspect(schema.optional_params)}"
    end

    # R14 from CONSENSUS_PromptBuilder spec
    test "[UNIT] wait action schema accepts boolean and number types" do
      {:ok, schema} = Schema.get_schema(:wait)

      # Verify wait parameter has union type
      assert schema.param_types[:wait] == {:union, [:boolean, :number]},
             "Expected {:union, [:boolean, :number]}, got: #{inspect(schema.param_types[:wait])}"
    end

    test "[UNIT] wait action has correct consensus rule for wait parameter" do
      {:ok, schema} = Schema.get_schema(:wait)

      # Verify consensus rule exists for wait (not duration)
      assert Map.has_key?(schema.consensus_rules, :wait),
             "Expected consensus_rules to have :wait key"

      # Verify consensus rule is percentile 50 (median)
      assert schema.consensus_rules.wait == {:percentile, 50},
             "Expected {:percentile, 50}, got: #{inspect(schema.consensus_rules.wait)}"

      # Verify no consensus rule for duration (removed)
      refute Map.has_key?(schema.consensus_rules, :duration),
             "Expected consensus_rules to NOT have :duration key"
    end

    # R15 from CONSENSUS_PromptBuilder spec
    test "[UNIT] wait action description emphasizes equivalence with wait parameter" do
      description = Schema.get_action_description(:wait)

      assert description != nil, "Expected wait action to have a description"

      # Check that description mentions unification or equivalence
      assert String.contains?(description, "unified") ||
               String.contains?(description, "same") ||
               String.contains?(description, "parameter"),
             "Expected description to mention unification with wait parameter, got: #{description}"
    end

    # R16 from CONSENSUS_PromptBuilder spec
    test "[UNIT] wait action schema does not include duration parameter" do
      {:ok, schema} = Schema.get_schema(:wait)

      # Check param_types doesn't have duration
      refute Map.has_key?(schema.param_types, :duration),
             "Expected param_types to NOT have :duration key"

      # Check param_descriptions doesn't have duration
      refute Map.has_key?(schema.param_descriptions || %{}, :duration),
             "Expected param_descriptions to NOT have :duration key"
    end
  end

  describe "ACTION_Validator v7.0 - Boolean Type Support" do
    # R11: Wait Boolean True Validation
    test "[UNIT] wait action accepts boolean true" do
      action = %{
        "action" => "wait",
        "params" => %{"wait" => true},
        "reasoning" => "Wait indefinitely for next message"
      }

      assert {:ok, validated} = Validator.validate_action(action)
      assert validated.params.wait == true
    end

    # R12: Wait Boolean False Validation
    test "[UNIT] wait action accepts boolean false" do
      action = %{
        "action" => "wait",
        "params" => %{"wait" => false},
        "reasoning" => "Continue immediately"
      }

      assert {:ok, validated} = Validator.validate_action(action)
      assert validated.params.wait == false
    end

    # R13: Wait Number Validation
    test "[UNIT] wait action accepts positive number" do
      action = %{
        "action" => "wait",
        "params" => %{"wait" => 5},
        "reasoning" => "Wait 5 seconds"
      }

      assert {:ok, validated} = Validator.validate_action(action)
      assert validated.params.wait == 5
    end

    test "[UNIT] wait action accepts fractional seconds" do
      action = %{
        "action" => "wait",
        "params" => %{"wait" => 0.5},
        "reasoning" => "Wait half a second"
      }

      assert {:ok, validated} = Validator.validate_action(action)
      assert validated.params.wait == 0.5
    end

    # R14: Wait Zero Validation
    test "[UNIT] wait action accepts zero" do
      action = %{
        "action" => "wait",
        "params" => %{"wait" => 0},
        "reasoning" => "Continue immediately with zero wait"
      }

      assert {:ok, validated} = Validator.validate_action(action)
      assert validated.params.wait == 0
    end

    # R15: Wait Invalid Type Rejection
    test "[UNIT] wait action rejects string type" do
      action = %{
        "action" => "wait",
        "params" => %{"wait" => "5"},
        "reasoning" => "Invalid string wait value"
      }

      assert {:error, reason} = Validator.validate_action(action)

      assert reason == :invalid_param_type,
             "Expected :invalid_param_type, got: #{inspect(reason)}"
    end

    test "[UNIT] wait action rejects atom type" do
      action = %{
        "action" => "wait",
        "params" => %{"wait" => :five},
        "reasoning" => "Invalid atom wait value"
      }

      assert {:error, reason} = Validator.validate_action(action)

      assert reason == :invalid_param_type,
             "Expected :invalid_param_type, got: #{inspect(reason)}"
    end

    test "[UNIT] wait action rejects nil" do
      action = %{
        "action" => "wait",
        "params" => %{"wait" => nil},
        "reasoning" => "Invalid nil wait value"
      }

      assert {:error, reason} = Validator.validate_action(action)

      assert reason == :invalid_param_type,
             "Expected :invalid_param_type, got: #{inspect(reason)}"
    end

    test "[UNIT] wait action rejects list type" do
      action = %{
        "action" => "wait",
        "params" => %{"wait" => [1, 2, 3]},
        "reasoning" => "Invalid list wait value"
      }

      assert {:error, reason} = Validator.validate_action(action)

      assert reason == :invalid_param_type,
             "Expected :invalid_param_type, got: #{inspect(reason)}"
    end

    test "[UNIT] wait action rejects map type" do
      action = %{
        "action" => "wait",
        "params" => %{"wait" => %{"seconds" => 5}},
        "reasoning" => "Invalid map wait value"
      }

      assert {:error, reason} = Validator.validate_action(action)

      assert reason == :invalid_param_type,
             "Expected :invalid_param_type, got: #{inspect(reason)}"
    end

    # Breaking change verification
    test "[UNIT] wait action rejects duration parameter (breaking change)" do
      action = %{
        "action" => "wait",
        "params" => %{"duration" => 5},
        "reasoning" => "Using old duration parameter"
      }

      # Should fail validation because duration is no longer a valid parameter
      assert {:error, _reason} = Validator.validate_action(action)
    end
  end

  describe "Union Type Validation" do
    test "[UNIT] validator handles union type {:union, [:boolean, :number]}" do
      # This tests the generic union type validation capability
      # that powers the wait parameter validation
      # Note: This will fail until union type support is implemented

      # Test that wait action with boolean is validated correctly
      action_bool = %{
        "action" => "wait",
        "params" => %{"wait" => true},
        "reasoning" => "Testing union type with boolean"
      }

      # Test that wait action with number is validated correctly
      action_num = %{
        "action" => "wait",
        "params" => %{"wait" => 42},
        "reasoning" => "Testing union type with number"
      }

      # Both should pass when union type support is implemented
      assert {:ok, _} = Validator.validate_action(action_bool),
             "Expected boolean to be valid for union type"

      assert {:ok, _} = Validator.validate_action(action_num),
             "Expected number to be valid for union type"

      # String should fail
      action_str = %{
        "action" => "wait",
        "params" => %{"wait" => "invalid"},
        "reasoning" => "Testing union type with invalid string"
      }

      assert {:error, _} = Validator.validate_action(action_str),
             "Expected string to be invalid for union type"
    end
  end

  describe "Integration Tests" do
    test "[INTEGRATION] wait action with various values through full validation" do
      test_cases = [
        {true, "Wait indefinitely", :ok},
        {false, "Continue immediately", :ok},
        {0, "Zero wait", :ok},
        {5, "Wait 5 seconds", :ok},
        {0.1, "Wait 100ms", :ok},
        {"5", "String value", :error},
        {nil, "Nil value", :error},
        {[], "List value", :error}
      ]

      for {wait_value, reasoning, expected} <- test_cases do
        action = %{
          "action" => "wait",
          "params" => %{"wait" => wait_value},
          "reasoning" => reasoning
        }

        case expected do
          :ok ->
            assert {:ok, validated} = Validator.validate_action(action),
                   "Expected validation to pass for wait=#{inspect(wait_value)}"

            assert validated.params.wait == wait_value

          :error ->
            assert {:error, _} = Validator.validate_action(action),
                   "Expected validation to fail for wait=#{inspect(wait_value)}"
        end
      end
    end

    test "[INTEGRATION] empty params for wait action still valid" do
      # Wait action should allow empty params (all params are optional)
      action = %{
        "action" => "wait",
        "params" => %{},
        "reasoning" => "Default wait behavior"
      }

      assert {:ok, validated} = Validator.validate_action(action)
      assert validated.params == %{}
    end
  end
end
