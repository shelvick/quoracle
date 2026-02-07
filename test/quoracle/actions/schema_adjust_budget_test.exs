defmodule Quoracle.Actions.SchemaAdjustBudgetTest do
  @moduledoc """
  Tests for ACTION_Schema v25.0 - adjust_budget action schema.

  WorkGroupID: feat-20251231-191717
  Packet: Packet 1 (Action Definition)
  """
  use ExUnit.Case, async: true

  alias Quoracle.Actions.Schema

  describe "adjust_budget action schema (v25.0)" do
    # R1: Action in List [UNIT]
    test "R1: list_actions includes adjust_budget" do
      actions = Schema.list_actions()
      assert :adjust_budget in actions
    end

    # R2: Schema Definition [UNIT]
    test "R2: get_schema returns adjust_budget schema" do
      result = Schema.get_schema(:adjust_budget)
      assert {:ok, schema} = result
      assert Map.has_key?(schema, :required_params)
      assert Map.has_key?(schema, :param_types)
    end

    # R3: Required Parameters [UNIT]
    test "R3: adjust_budget requires child_id and new_budget" do
      {:ok, schema} = Schema.get_schema(:adjust_budget)
      assert :child_id in schema.required_params
      assert :new_budget in schema.required_params
      assert length(schema.required_params) == 2
    end

    # R4: String Type for new_budget [UNIT]
    # Note: Uses :string not :decimal - validator doesn't support :decimal type
    # Action module converts string to Decimal internally (same as record_cost)
    test "R4: new_budget has string type" do
      {:ok, schema} = Schema.get_schema(:adjust_budget)
      assert schema.param_types[:new_budget] == :string
    end

    # R5: Action Description [UNIT]
    test "R5: adjust_budget has description" do
      description = Schema.get_action_description(:adjust_budget)
      assert is_binary(description)
      assert description =~ "WHEN"
      assert description =~ "budget"
    end

    # R6: Action Priority [UNIT]
    test "R6: adjust_budget has priority" do
      priority = Schema.get_action_priority(:adjust_budget)
      assert is_integer(priority)
      assert priority > 0
    end
  end

  describe "adjust_budget param_types" do
    test "child_id is string type" do
      {:ok, schema} = Schema.get_schema(:adjust_budget)
      assert schema.param_types[:child_id] == :string
    end
  end

  describe "adjust_budget param_descriptions" do
    test "has description for child_id parameter" do
      {:ok, schema} = Schema.get_schema(:adjust_budget)
      assert Map.has_key?(schema.param_descriptions, :child_id)
      assert schema.param_descriptions[:child_id] =~ "child"
    end

    test "has description for new_budget parameter" do
      {:ok, schema} = Schema.get_schema(:adjust_budget)
      assert Map.has_key?(schema.param_descriptions, :new_budget)
      assert schema.param_descriptions[:new_budget] =~ "budget"
    end
  end
end
