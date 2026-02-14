defmodule Quoracle.Actions.SchemaBatchSyncTest do
  @moduledoc """
  Tests for ACTION_Schema v29.0 - batch_sync action schema and batchable_actions constant.
  WorkGroupID: feat-20260123-batch-sync
  Packet: 1 (Schema Foundation)
  """

  use ExUnit.Case, async: true
  alias Quoracle.Actions.Schema
  alias Quoracle.Actions.Schema.ActionList

  # ARC Verification Criteria from ACTION_Schema v29.0

  describe "batch_sync action definition (v29.0)" do
    # R1: Action Registered
    test "batch_sync in action list" do
      # [UNIT] - WHEN list_actions/0 called THEN includes :batch_sync
      actions = Schema.list_actions()
      assert :batch_sync in actions
    end

    # R2: Schema Defined
    test "batch_sync schema exists" do
      # [UNIT] - WHEN get_schema(:batch_sync) called THEN returns valid schema
      assert {:ok, schema} = Schema.get_schema(:batch_sync)
      assert is_map(schema)
      assert Map.has_key?(schema, :required_params)
      assert Map.has_key?(schema, :optional_params)
      assert Map.has_key?(schema, :param_types)
      assert Map.has_key?(schema, :consensus_rules)
    end

    # R3: Required Params
    test "batch_sync requires actions param" do
      # [UNIT] - WHEN get_schema(:batch_sync) called THEN required_params includes :actions
      {:ok, schema} = Schema.get_schema(:batch_sync)
      assert :actions in schema.required_params
    end

    # R4: Param Type List
    test "batch_sync actions is list type" do
      # [UNIT] - WHEN get_schema(:batch_sync) called THEN actions has type {:list, :batchable_action_spec}
      {:ok, schema} = Schema.get_schema(:batch_sync)
      assert schema.param_types[:actions] == {:list, :batchable_action_spec}
    end

    # R5: Consensus Rule
    test "batch_sync uses batch_sequence_merge consensus rule" do
      # [UNIT] - WHEN get_schema(:batch_sync) called THEN actions uses :batch_sequence_merge rule
      {:ok, schema} = Schema.get_schema(:batch_sync)
      assert schema.consensus_rules[:actions] == :batch_sequence_merge
    end

    # R6: Action Description Present
    test "batch_sync has action description" do
      # [UNIT] - WHEN get_action_description(:batch_sync) called THEN returns WHEN/HOW guidance
      description = Schema.get_action_description(:batch_sync)
      assert is_binary(description)
      assert String.contains?(description, "WHEN")
      assert String.contains?(description, "HOW")
    end

    # R7: Action Priority Defined
    test "batch_sync has priority 4" do
      # [UNIT] - WHEN get_action_priority(:batch_sync) called THEN returns 4
      assert Schema.get_action_priority(:batch_sync) == 4
    end

    # R8: Batchable Actions Function
    test "batchable_actions returns expected list" do
      # [UNIT] - WHEN batchable_actions/0 called THEN returns list of batchable action atoms
      actions = ActionList.batchable_actions()
      assert is_list(actions)
      refute Enum.empty?(actions)

      # Verify expected batchable actions
      assert :spawn_child in actions
      assert :send_message in actions
      assert :orient in actions
      assert :todo in actions
      assert :generate_secret in actions
      assert :adjust_budget in actions
      assert :learn_skills in actions
      assert :create_skill in actions
      assert :search_secrets in actions
      assert :file_read in actions
      assert :file_write in actions
    end

    # R9: Wait Not Batchable
    test "wait excluded from batchable_actions" do
      # [UNIT] - WHEN batchable_actions/0 called THEN :wait is NOT in list
      actions = ActionList.batchable_actions()
      refute :wait in actions
    end

    # R10: Batch Sync Not Batchable
    test "batch_sync excluded from batchable_actions (no nesting)" do
      # [UNIT] - WHEN batchable_actions/0 called THEN :batch_sync is NOT in list
      actions = ActionList.batchable_actions()
      refute :batch_sync in actions
    end

    # R11: Total Actions Updated
    test "action list has 21 actions" do
      # [UNIT] - WHEN list_actions/0 called THEN returns 21 actions (20 + batch_sync)
      actions = Schema.list_actions()
      assert length(actions) == 22
    end
  end

  describe "batch_sync param description" do
    test "batch_sync has param description for actions" do
      # [UNIT] - WHEN get_schema(:batch_sync) called THEN param_descriptions includes :actions
      {:ok, schema} = Schema.get_schema(:batch_sync)
      assert Map.has_key?(schema.param_descriptions, :actions)
      assert is_binary(schema.param_descriptions[:actions])
    end

    test "batch_sync actions description mentions minimum 2 actions" do
      # Verify LLM guidance mentions minimum requirement
      {:ok, schema} = Schema.get_schema(:batch_sync)
      description = schema.param_descriptions[:actions]
      assert description =~ "Minimum 2"
    end
  end

  describe "batchable_actions exclusions" do
    test "slow actions excluded from batchable_actions" do
      # Verify slow/async actions are excluded
      actions = ActionList.batchable_actions()

      # Slow/async actions should NOT be batchable
      refute :execute_shell in actions
      refute :fetch_web in actions
      refute :call_api in actions
      refute :call_mcp in actions
      refute :answer_engine in actions
      refute :generate_images in actions
    end

    test "batchable_actions contains exactly 13 actions" do
      # Verify the exact count of batchable actions
      actions = ActionList.batchable_actions()
      assert length(actions) == 13
    end
  end
end
