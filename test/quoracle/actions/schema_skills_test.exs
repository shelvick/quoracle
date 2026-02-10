defmodule Quoracle.Actions.SchemaSkillsTest do
  @moduledoc """
  Tests for ACTION_Schema v28.0 - Skills System action schemas.

  ARC Requirements (v28.0):
  - R5-R9: learn_skills schema
  - R10-R14: create_skill schema
  - R15-R17: metadata (descriptions, priorities, total actions)

  WorkGroupID: feat-20260112-skills-system
  """

  use ExUnit.Case, async: true

  alias Quoracle.Actions.Schema

  # ==========================================================================
  # R5-R9: learn_skills Schema
  # ==========================================================================

  describe "learn_skills schema (R5-R9)" do
    # R5: Action Registered
    test "learn_skills in action list" do
      actions = Schema.list_actions()
      assert :learn_skills in actions
    end

    # R6: Schema Defined
    test "learn_skills schema exists" do
      result = Schema.get_schema(:learn_skills)
      assert {:ok, schema} = result
      assert is_map(schema)
    end

    # R7: Required Params
    test "learn_skills requires skills" do
      {:ok, schema} = Schema.get_schema(:learn_skills)
      assert :skills in schema.required_params
    end

    # R8: Optional Params
    test "learn_skills permanent is optional" do
      {:ok, schema} = Schema.get_schema(:learn_skills)
      assert :permanent in schema.optional_params
    end

    # R9: Param Types
    test "learn_skills param types correct" do
      {:ok, schema} = Schema.get_schema(:learn_skills)
      assert schema.param_types[:skills] == {:list, :string}
      assert schema.param_types[:permanent] == :boolean
    end
  end

  # ==========================================================================
  # R10-R14: create_skill Schema
  # ==========================================================================

  describe "create_skill schema (R10-R14)" do
    # R10: Action Registered
    test "create_skill in action list" do
      actions = Schema.list_actions()
      assert :create_skill in actions
    end

    # R11: Schema Defined
    test "create_skill schema exists" do
      result = Schema.get_schema(:create_skill)
      assert {:ok, schema} = result
      assert is_map(schema)
    end

    # R12: Required Params
    test "create_skill requires name, description, content" do
      {:ok, schema} = Schema.get_schema(:create_skill)
      assert :name in schema.required_params
      assert :description in schema.required_params
      assert :content in schema.required_params
    end

    # R13: Optional Params
    test "create_skill metadata and attachments optional" do
      {:ok, schema} = Schema.get_schema(:create_skill)
      assert :metadata in schema.optional_params
      assert :attachments in schema.optional_params
    end

    # R14: Param Types
    test "create_skill param types correct" do
      {:ok, schema} = Schema.get_schema(:create_skill)
      assert schema.param_types[:name] == :string
      assert schema.param_types[:description] == :string
      assert schema.param_types[:content] == :string
      assert schema.param_types[:metadata] == :map
      assert schema.param_types[:attachments] == {:list, :map}
    end
  end

  # ==========================================================================
  # R15-R17: Metadata
  # ==========================================================================

  describe "skill actions metadata (R15-R17)" do
    # R15: Descriptions Present
    test "skill actions have descriptions" do
      for action <- [:learn_skills, :create_skill] do
        desc = Schema.get_action_description(action)
        assert is_binary(desc), "#{action} should have description"
        assert String.contains?(desc, "WHEN"), "#{action} description should have WHEN guidance"
      end
    end

    # R16: Priorities Defined
    test "skill actions have priorities" do
      for action <- [:learn_skills, :create_skill] do
        priority = Schema.get_action_priority(action)
        assert is_integer(priority), "#{action} should have integer priority"
        assert priority > 0, "#{action} priority should be positive"
      end
    end

    # R17: Total Actions Updated
    test "action list has 20 actions" do
      actions = Schema.list_actions()
      assert length(actions) == 22
    end
  end
end
