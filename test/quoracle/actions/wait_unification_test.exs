defmodule Quoracle.Actions.WaitUnificationTest do
  @moduledoc """
  Tests for wait parameter unification (WorkGroupID: wait-20251114-203234).

  These tests verify:
  - ACTION_Schema v18.0: wait action uses 'wait' parameter (not 'duration')
  - ACTION_Validator v7.0: union type validation for boolean and number
  """
  use ExUnit.Case, async: true

  alias Quoracle.Actions.Schema
  alias Quoracle.Actions.Validator

  describe "ACTION_Schema v18.0 - Wait Parameter Unification" do
    # R14 from CONSENSUS_PromptBuilder spec
    test "[UNIT] wait action schema accepts boolean and number types" do
      {:ok, schema} = Schema.get_schema(:wait)

      # Verify wait parameter has union type
      assert schema.param_types[:wait] == {:union, [:boolean, :number]},
             "Expected {:union, [:boolean, :number]}, got: #{inspect(schema.param_types[:wait])}"
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
end
