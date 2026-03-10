defmodule Quoracle.Actions.SchemaRecordCostTest do
  @moduledoc """
  Tests for ACTION_Schema v24.0 - record_cost action schema.

  WorkGroupID: wip-20251231-budget
  Packet: Packet 7 (Record Cost Action)
  """
  use ExUnit.Case, async: true

  alias Quoracle.Actions.Schema

  describe "record_cost action schema (v24.0)" do
    # R1: Action Registered [UNIT]
    test "R1: record_cost in action list" do
      actions = Schema.list_actions()
      assert :record_cost in actions
    end

    # R3: Required Params [UNIT]
    test "R3: record_cost requires amount only" do
      {:ok, schema} = Schema.get_schema(:record_cost)
      assert :amount in schema.required_params
      assert length(schema.required_params) == 1
    end

    # R4: Amount Type String [UNIT]
    test "R4: record_cost amount is string type" do
      {:ok, schema} = Schema.get_schema(:record_cost)
      assert schema.param_types[:amount] == :string
    end

    # R5: Optional Params [UNIT]
    test "R5: record_cost has optional description, category, and metadata" do
      {:ok, schema} = Schema.get_schema(:record_cost)
      assert :description in schema.optional_params
      assert :category in schema.optional_params
      assert :metadata in schema.optional_params
    end

    # R6: Action Description Present [UNIT]
    test "R6: record_cost has action description" do
      description = Schema.get_action_description(:record_cost)
      assert is_binary(description)
      assert description =~ "WHEN"
      assert description =~ "cost"
    end

    # R7: Action Priority Defined [UNIT]
    test "R7: record_cost has a priority" do
      priority = Schema.get_action_priority(:record_cost)
      assert is_integer(priority) and priority > 0
    end
  end

  describe "record_cost param_descriptions" do
    test "has description for amount parameter" do
      {:ok, schema} = Schema.get_schema(:record_cost)
      assert Map.has_key?(schema.param_descriptions, :amount)
      assert schema.param_descriptions[:amount] =~ "USD"
    end
  end

  describe "record_cost consensus_rules" do
    test "amount uses exact_match" do
      {:ok, schema} = Schema.get_schema(:record_cost)
      assert schema.consensus_rules[:amount] == :exact_match
    end

    test "description uses first_non_nil" do
      {:ok, schema} = Schema.get_schema(:record_cost)
      assert schema.consensus_rules[:description] == :first_non_nil
    end

    test "category uses first_non_nil" do
      {:ok, schema} = Schema.get_schema(:record_cost)
      assert schema.consensus_rules[:category] == :first_non_nil
    end

    test "metadata uses merge_maps" do
      {:ok, schema} = Schema.get_schema(:record_cost)
      assert schema.consensus_rules[:metadata] == :merge_maps
    end
  end
end
