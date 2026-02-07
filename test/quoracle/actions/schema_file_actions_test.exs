defmodule Quoracle.Actions.SchemaFileActionsTest do
  @moduledoc """
  Tests for ACTION_Schema v27.0 - File Actions (file_read + file_write)
  WorkGroupID: feat-20260107-file-actions
  Packet: 1 (Schema Foundation)
  """
  use ExUnit.Case, async: true

  alias Quoracle.Actions.Schema

  @moduletag :file_actions

  # ===========================================================================
  # ACTION_Schema v27.0 - file_read Schema
  # ARC Verification Criteria R1-R5
  # ===========================================================================
  describe "file_read action definition (v27.0)" do
    # R1: Action Registered
    test "file_read in action list" do
      # [UNIT] - WHEN list_actions/0 called THEN includes :file_read
      actions = Schema.list_actions()
      assert :file_read in actions
    end

    # R2: Schema Defined
    test "file_read schema exists" do
      # [UNIT] - WHEN get_schema(:file_read) called THEN returns valid schema
      assert {:ok, schema} = Schema.get_schema(:file_read)
      assert is_map(schema)
      assert Map.has_key?(schema, :required_params)
      assert Map.has_key?(schema, :optional_params)
      assert Map.has_key?(schema, :param_types)
      assert Map.has_key?(schema, :consensus_rules)
    end

    # R3: Required Params
    test "file_read requires path" do
      # [UNIT] - WHEN get_schema(:file_read) called THEN required_params includes :path
      {:ok, schema} = Schema.get_schema(:file_read)
      assert :path in schema.required_params
    end

    # R4: Optional Params
    test "file_read has optional offset and limit" do
      # [UNIT] - WHEN get_schema(:file_read) called THEN optional_params includes :offset and :limit
      {:ok, schema} = Schema.get_schema(:file_read)
      assert :offset in schema.optional_params
      assert :limit in schema.optional_params
    end

    # R5: Param Types
    test "file_read param types correct" do
      # [UNIT] - WHEN get_schema(:file_read) called THEN path is :string, offset/limit are :integer
      {:ok, schema} = Schema.get_schema(:file_read)
      assert schema.param_types[:path] == :string
      assert schema.param_types[:offset] == :integer
      assert schema.param_types[:limit] == :integer
    end

    # Additional: Consensus Rules
    test "file_read consensus rules defined" do
      # [UNIT] - WHEN get_schema(:file_read) called THEN consensus_rules defined for all params
      {:ok, schema} = Schema.get_schema(:file_read)
      assert schema.consensus_rules[:path] == :exact_match
      assert schema.consensus_rules[:offset] == {:percentile, 50}
      assert schema.consensus_rules[:limit] == {:percentile, 50}
    end

    # Additional: Param Descriptions
    test "file_read has param descriptions" do
      # [UNIT] - WHEN get_schema(:file_read) called THEN param_descriptions exist
      {:ok, schema} = Schema.get_schema(:file_read)
      assert Map.has_key?(schema.param_descriptions, :path)
      assert Map.has_key?(schema.param_descriptions, :offset)
      assert Map.has_key?(schema.param_descriptions, :limit)
      assert is_binary(schema.param_descriptions[:path])
    end
  end

  # ===========================================================================
  # ACTION_Schema v27.0 - file_write Schema
  # ARC Verification Criteria R6-R11
  # ===========================================================================
  describe "file_write action definition (v27.0)" do
    # R6: Action Registered
    test "file_write in action list" do
      # [UNIT] - WHEN list_actions/0 called THEN includes :file_write
      actions = Schema.list_actions()
      assert :file_write in actions
    end

    # R7: Schema Defined
    test "file_write schema exists" do
      # [UNIT] - WHEN get_schema(:file_write) called THEN returns valid schema
      assert {:ok, schema} = Schema.get_schema(:file_write)
      assert is_map(schema)
      assert Map.has_key?(schema, :required_params)
      assert Map.has_key?(schema, :optional_params)
      assert Map.has_key?(schema, :param_types)
      assert Map.has_key?(schema, :consensus_rules)
    end

    # R8: Required Params
    test "file_write requires path and mode" do
      # [UNIT] - WHEN get_schema(:file_write) called THEN required_params includes :path and :mode
      {:ok, schema} = Schema.get_schema(:file_write)
      assert :path in schema.required_params
      assert :mode in schema.required_params
    end

    # R9: Mode Enum Type
    test "file_write mode is enum type" do
      # [UNIT] - WHEN get_schema(:file_write) called THEN mode has enum type [:write, :edit]
      {:ok, schema} = Schema.get_schema(:file_write)
      assert schema.param_types[:mode] == {:enum, [:write, :edit]}
    end

    # R10: XOR Params Defined
    test "file_write has xor_params for mode-specific params" do
      # [UNIT] - WHEN get_schema(:file_write) called THEN xor_params includes content vs old_string/new_string
      {:ok, schema} = Schema.get_schema(:file_write)
      assert Map.has_key?(schema, :xor_params)
      assert schema.xor_params == [[:content], [:old_string, :new_string]]
    end

    # R11: Consensus Rules
    test "file_write consensus rules correct" do
      # [UNIT] - WHEN get_schema(:file_write) called THEN content uses semantic_similarity, old_string/new_string use exact_match
      {:ok, schema} = Schema.get_schema(:file_write)
      assert schema.consensus_rules[:path] == :exact_match
      assert schema.consensus_rules[:mode] == :exact_match
      assert schema.consensus_rules[:content] == {:semantic_similarity, threshold: 0.95}
      assert schema.consensus_rules[:old_string] == :exact_match
      assert schema.consensus_rules[:new_string] == :exact_match
      assert schema.consensus_rules[:replace_all] == :mode_selection
    end

    # Additional: Optional Params
    test "file_write has correct optional params" do
      # [UNIT] - WHEN get_schema(:file_write) called THEN optional_params includes mode-specific params
      {:ok, schema} = Schema.get_schema(:file_write)
      assert :content in schema.optional_params
      assert :old_string in schema.optional_params
      assert :new_string in schema.optional_params
      assert :replace_all in schema.optional_params
    end

    # Additional: Param Types
    test "file_write param types correct" do
      # [UNIT] - WHEN get_schema(:file_write) called THEN all params have correct types
      {:ok, schema} = Schema.get_schema(:file_write)
      assert schema.param_types[:path] == :string
      assert schema.param_types[:content] == :string
      assert schema.param_types[:old_string] == :string
      assert schema.param_types[:new_string] == :string
      assert schema.param_types[:replace_all] == :boolean
    end

    # Additional: Param Descriptions
    test "file_write has param descriptions" do
      # [UNIT] - WHEN get_schema(:file_write) called THEN param_descriptions exist for all params
      {:ok, schema} = Schema.get_schema(:file_write)
      assert Map.has_key?(schema.param_descriptions, :path)
      assert Map.has_key?(schema.param_descriptions, :mode)
      assert Map.has_key?(schema.param_descriptions, :content)
      assert Map.has_key?(schema.param_descriptions, :old_string)
      assert Map.has_key?(schema.param_descriptions, :new_string)
      assert Map.has_key?(schema.param_descriptions, :replace_all)
    end
  end

  # ===========================================================================
  # ACTION_Schema v27.0 - Metadata
  # ARC Verification Criteria R12-R14
  # ===========================================================================
  describe "file actions metadata (v27.0)" do
    # R12: Descriptions Present
    test "file actions have descriptions" do
      # [UNIT] - WHEN get_action_description called for file_read/file_write THEN returns WHEN/HOW guidance
      file_read_desc = Schema.get_action_description(:file_read)
      assert is_binary(file_read_desc)
      assert String.contains?(file_read_desc, "WHEN")
      assert String.contains?(file_read_desc, "HOW")

      file_write_desc = Schema.get_action_description(:file_write)
      assert is_binary(file_write_desc)
      assert String.contains?(file_write_desc, "WHEN")
      assert String.contains?(file_write_desc, "HOW")
    end

    # R13: Priorities Defined
    test "file actions have priorities" do
      # [UNIT] - WHEN get_action_priority called for file_read/file_write THEN returns integers
      # file_read: 7 (read-only filesystem)
      # file_write: 19 (file modifications)
      assert Schema.get_action_priority(:file_read) == 7
      assert Schema.get_action_priority(:file_write) == 19
    end

    # R14: Total Actions Updated
    test "action list has 21 actions" do
      # [UNIT] - WHEN list_actions/0 called THEN returns 21 actions
      # Previous: 19 actions + file_read + file_write = 21
      actions = Schema.list_actions()
      assert length(actions) == 22
    end

    # Additional: wait_required? for file actions
    test "file actions require wait" do
      # [UNIT] - file actions require subsequent wait like other actions
      assert Schema.wait_required?(:file_read) == true
      assert Schema.wait_required?(:file_write) == true
    end
  end
end
