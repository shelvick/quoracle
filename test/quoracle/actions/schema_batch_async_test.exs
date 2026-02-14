defmodule Quoracle.Actions.SchemaBatchAsyncTest do
  @moduledoc """
  Tests for ACTION_Schema v30.0 - batch_async action schema and async_batchable functions.
  WorkGroupID: feat-20260126-batch-async
  Packet: 1 (Schema Foundation)
  """

  use ExUnit.Case, async: true
  alias Quoracle.Actions.Schema
  alias Quoracle.Actions.Schema.ActionList

  # ARC Verification Criteria from ACTION_Schema v30.0

  describe "batch_async action definition (v30.0)" do
    # R12: Action Registered
    test "batch_async in action list" do
      # [UNIT] - WHEN list_actions/0 called THEN includes :batch_async
      actions = Schema.list_actions()
      assert :batch_async in actions
    end

    # R13: Schema Defined
    test "batch_async schema exists" do
      # [UNIT] - WHEN get_schema(:batch_async) called THEN returns valid schema
      assert {:ok, schema} = Schema.get_schema(:batch_async)
      assert is_map(schema)
      assert Map.has_key?(schema, :required_params)
      assert Map.has_key?(schema, :optional_params)
      assert Map.has_key?(schema, :param_types)
      assert Map.has_key?(schema, :consensus_rules)
    end

    # R14: Required Params
    test "batch_async requires actions param" do
      # [UNIT] - WHEN get_schema(:batch_async) called THEN required_params includes :actions
      {:ok, schema} = Schema.get_schema(:batch_async)
      assert :actions in schema.required_params
    end

    # R17: Param Type List
    test "batch_async actions is list type" do
      # [UNIT] - WHEN get_schema(:batch_async) called THEN actions has type {:list, :async_action_spec}
      {:ok, schema} = Schema.get_schema(:batch_async)
      assert schema.param_types[:actions] == {:list, :async_action_spec}
    end

    # R18: Consensus Rules
    test "batch_async has correct consensus rules" do
      # [UNIT] - WHEN get_schema(:batch_async) called THEN actions uses :batch_sequence_merge
      {:ok, schema} = Schema.get_schema(:batch_async)
      assert schema.consensus_rules[:actions] == :batch_sequence_merge
    end

    # R19: Action Description Present
    test "batch_async has action description" do
      # [UNIT] - WHEN get_action_description(:batch_async) called THEN returns parallel execution guidance
      description = Schema.get_action_description(:batch_async)
      assert is_binary(description)
      assert String.contains?(description, "parallel")
    end

    # R20: Action Priority Defined
    test "batch_async has priority 5" do
      # [UNIT] - WHEN get_action_priority(:batch_async) called THEN returns 5
      assert Schema.get_action_priority(:batch_async) == 5
    end

    # R21: Async Excluded Actions Function
    test "async_excluded_actions returns expected list" do
      # [UNIT] - WHEN async_excluded_actions/0 called THEN returns [:wait, :batch_sync, :batch_async]
      excluded = ActionList.async_excluded_actions()
      assert is_list(excluded)
      assert :wait in excluded
      assert :batch_sync in excluded
      assert :batch_async in excluded
      assert length(excluded) == 3
    end

    # R22: Async Batchable Check
    test "async_batchable? returns true for eligible actions" do
      # [UNIT] - WHEN async_batchable?(:file_read) called THEN returns true
      assert ActionList.async_batchable?(:file_read)
      assert ActionList.async_batchable?(:file_write)
      assert ActionList.async_batchable?(:todo)
      assert ActionList.async_batchable?(:orient)
      assert ActionList.async_batchable?(:spawn_child)
      assert ActionList.async_batchable?(:execute_shell)
      assert ActionList.async_batchable?(:fetch_web)
      assert ActionList.async_batchable?(:call_api)
    end

    # R23: Async Batchable Excludes Wait
    test "async_batchable? returns false for :wait" do
      # [UNIT] - WHEN async_batchable?(:wait) called THEN returns false
      refute ActionList.async_batchable?(:wait)
    end

    # R24: Total Actions Updated
    test "action list has 22 actions" do
      # [UNIT] - WHEN list_actions/0 called THEN returns 22 actions (21 + batch_async)
      actions = Schema.list_actions()
      assert length(actions) == 22
    end
  end

  describe "batch_async param descriptions" do
    test "batch_async has param description for actions" do
      # [UNIT] - WHEN get_schema(:batch_async) called THEN param_descriptions includes :actions
      {:ok, schema} = Schema.get_schema(:batch_async)
      assert Map.has_key?(schema.param_descriptions, :actions)
      assert is_binary(schema.param_descriptions[:actions])
    end

    test "batch_async actions description mentions minimum 2 actions" do
      # Verify LLM guidance mentions minimum requirement
      {:ok, schema} = Schema.get_schema(:batch_async)
      description = schema.param_descriptions[:actions]
      assert description =~ "Minimum 2"
    end
  end

  describe "async_batchable? exclusion list" do
    test "async_batchable? returns false for :batch_sync" do
      # batch_sync cannot be nested in batch_async
      refute ActionList.async_batchable?(:batch_sync)
    end

    test "async_batchable? returns false for :batch_async" do
      # batch_async cannot be nested in batch_async
      refute ActionList.async_batchable?(:batch_async)
    end

    test "async_batchable? accepts slow actions unlike batch_sync" do
      # batch_async allows slow actions (unlike batch_sync's inclusion list)
      assert ActionList.async_batchable?(:execute_shell)
      assert ActionList.async_batchable?(:fetch_web)
      assert ActionList.async_batchable?(:call_api)
      assert ActionList.async_batchable?(:call_mcp)
      assert ActionList.async_batchable?(:answer_engine)
      assert ActionList.async_batchable?(:generate_images)
    end

    test "async_excluded_actions contains exactly 3 actions" do
      # Only :wait, :batch_sync, :batch_async excluded
      excluded = ActionList.async_excluded_actions()
      assert length(excluded) == 3
    end
  end

  describe "batch_async vs batch_sync differences" do
    test "batch_async has higher priority than batch_sync" do
      assert Schema.get_action_priority(:batch_async) > Schema.get_action_priority(:batch_sync)
    end

    test "both batch actions use batch_sequence_merge for actions" do
      {:ok, async_schema} = Schema.get_schema(:batch_async)
      {:ok, sync_schema} = Schema.get_schema(:batch_sync)

      assert async_schema.consensus_rules[:actions] == :batch_sequence_merge
      assert sync_schema.consensus_rules[:actions] == :batch_sequence_merge
    end
  end
end
