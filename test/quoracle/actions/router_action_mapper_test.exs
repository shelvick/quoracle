defmodule Quoracle.Actions.Router.ActionMapperTest do
  @moduledoc """
  Tests for Router's ActionMapper module.
  Verifies that answer_engine is properly mapped.
  """

  use ExUnit.Case, async: true
  alias Quoracle.Actions.Router.ActionMapper

  describe "answer_engine mapping" do
    test "get_action_module/1 maps answer_engine to AnswerEngine module" do
      # Verify that ActionMapper includes answer_engine mapping
      result = ActionMapper.get_action_module(:answer_engine)
      assert {:ok, Quoracle.Actions.AnswerEngine} = result
    end

    test "returns ok tuple for valid answer_engine action" do
      # Verify answer_engine is recognized as a valid action
      result = ActionMapper.get_action_module(:answer_engine)
      assert {:ok, _module} = result
    end

    test "returns error for unmapped actions" do
      # Verify unmapped actions return error
      result = ActionMapper.get_action_module(:nonexistent_action)
      assert {:error, :not_implemented} = result
    end
  end

  # ACTION_Router v18.0 - Search Secrets Action Routing
  # ARC Verification Criteria for search_secrets action mapping
  describe "search_secrets mapping (v18.0)" do
    # R1: ActionMapper Includes search_secrets
    test "ActionMapper routes search_secrets to SearchSecrets module" do
      # [UNIT] - WHEN get_action_module(:search_secrets) called THEN returns {:ok, Quoracle.Actions.SearchSecrets}
      result = ActionMapper.get_action_module(:search_secrets)
      assert {:ok, Quoracle.Actions.SearchSecrets} = result
    end
  end

  # ACTION_Router v19.0 - Dismiss Child Action Routing
  # ARC Verification Criteria for dismiss_child action mapping
  # WorkGroupID: feat-20251224-dismiss-child
  # Packet: 1 (Infrastructure)
  describe "dismiss_child mapping (v19.0)" do
    # R1: ActionMapper Includes dismiss_child
    test "ActionMapper routes dismiss_child to DismissChild module" do
      # [UNIT] - WHEN get_action_module(:dismiss_child) called THEN returns {:ok, Quoracle.Actions.DismissChild}
      result = ActionMapper.get_action_module(:dismiss_child)
      assert {:ok, Quoracle.Actions.DismissChild} = result
    end
  end

  # ACTION_Router v20.0 - generate_images Action Routing
  # ARC Verification Criteria for generate_images action mapping
  # WorkGroupID: feat-20251229-052855
  # Packet: 3 (Action Integration)
  describe "generate_images mapping (v20.0)" do
    # R1: ActionMapper Includes generate_images
    test "ActionMapper routes generate_images to GenerateImages module" do
      # [UNIT] - WHEN get_action_module(:generate_images) called THEN returns {:ok, Quoracle.Actions.GenerateImages}
      result = ActionMapper.get_action_module(:generate_images)
      assert {:ok, Quoracle.Actions.GenerateImages} = result
    end
  end

  # ACTION_Router v22.0 - adjust_budget Action Routing
  # ARC Verification Criteria for adjust_budget action mapping
  # WorkGroupID: feat-20251231-191717
  # Packet: 1 (Action Definition)
  describe "adjust_budget mapping (v22.0)" do
    # R10: ActionMapper Entry [UNIT]
    test "R10: get_action_module returns AdjustBudget for adjust_budget" do
      # [UNIT] - WHEN get_action_module(:adjust_budget) THEN returns AdjustBudget module
      result = ActionMapper.get_action_module(:adjust_budget)
      assert {:ok, Quoracle.Actions.AdjustBudget} = result
    end
  end

  # ACTION_Router v24.0 - batch_sync Action Routing
  # Integration gap fix from feat-20260123-batch-sync audit
  # WorkGroupID: feat-20260123-batch-sync
  # Packet: 4 (Integration Fix)
  describe "batch_sync mapping (v24.0)" do
    # R1: ActionMapper Includes batch_sync
    @tag :batch_sync
    test "R1: get_action_module returns BatchSync for batch_sync" do
      # [UNIT] - WHEN get_action_module(:batch_sync) THEN returns BatchSync module
      result = ActionMapper.get_action_module(:batch_sync)
      assert {:ok, Quoracle.Actions.BatchSync} = result
    end
  end
end
