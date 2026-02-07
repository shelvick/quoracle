defmodule Quoracle.Profiles.ActionGateTest do
  @moduledoc """
  Tests for PROFILE_ActionGate - Runtime permission checker.

  All tests are [UNIT] level - pure module with no external dependencies.

  ## Capability Groups API (R1-R9)
  - R1: check/2 returns :ok for allowed action with capability group
  - R2: check/2 returns error for blocked action (empty groups)
  - R3: check/2 returns :ok for base actions with empty groups
  - R4: check!/2 raises for blocked action
  - R5: check!/2 returns :ok for allowed action
  - R6: filter_actions/2 removes blocked actions
  - R7: filter_actions/2 preserves allowed actions
  - R8: ActionNotAllowedError message includes action and capability groups
  - R9: check/2 handles non-list input gracefully
  """

  use ExUnit.Case, async: true

  alias Quoracle.Profiles.ActionGate
  alias Quoracle.Profiles.ActionNotAllowedError

  # ==========================================================================
  # v2.0 Capability Groups API Tests (R1-R9)
  # ==========================================================================

  describe "check/2 with capability_groups" do
    # R1: Check Returns OK for Allowed
    @tag :r1
    test "check returns :ok for allowed action with matching capability group" do
      # :execute_shell requires :local_execution capability group
      assert :ok = ActionGate.check(:execute_shell, [:local_execution])
    end

    @tag :r1
    test "check returns :ok for hierarchy actions with hierarchy group" do
      assert :ok = ActionGate.check(:spawn_child, [:hierarchy])
      assert :ok = ActionGate.check(:dismiss_child, [:hierarchy])
      assert :ok = ActionGate.check(:adjust_budget, [:hierarchy])
    end

    @tag :r1
    test "check returns :ok for file actions with file_read group" do
      assert :ok = ActionGate.check(:file_read, [:file_read])
    end

    @tag :r1
    test "check returns :ok for file actions with file_write group" do
      assert :ok = ActionGate.check(:file_write, [:file_write])
    end

    @tag :r1
    test "check returns :ok for external API with external_api group" do
      assert :ok = ActionGate.check(:call_api, [:external_api])
    end

    # R2: Check Returns Error for Blocked
    @tag :r2
    test "check returns error for blocked action with empty groups" do
      # :execute_shell requires :local_execution, not present in empty list
      assert {:error, :action_not_allowed} = ActionGate.check(:execute_shell, [])
    end

    @tag :r2
    test "check returns error for action without matching capability group" do
      # :execute_shell requires :local_execution, but only :hierarchy provided
      assert {:error, :action_not_allowed} = ActionGate.check(:execute_shell, [:hierarchy])
    end

    @tag :r2
    test "check returns error for spawn_child without hierarchy group" do
      assert {:error, :action_not_allowed} = ActionGate.check(:spawn_child, [:local_execution])
    end

    @tag :r2
    test "check returns error for file_write without file_write group" do
      # file_read does NOT grant file_write
      assert {:error, :action_not_allowed} = ActionGate.check(:file_write, [:file_read])
    end

    # R3: Check Returns OK for Base Actions
    @tag :r3
    test "check returns :ok for base actions with empty groups" do
      # Base actions (7 total per PROFILE_CapabilityGroups spec) are always allowed
      # Note: search_secrets, generate_secret, record_cost are NOT base actions - they require groups
      assert :ok = ActionGate.check(:wait, [])
      assert :ok = ActionGate.check(:orient, [])
      assert :ok = ActionGate.check(:todo, [])
      assert :ok = ActionGate.check(:send_message, [])
      assert :ok = ActionGate.check(:fetch_web, [])
      assert :ok = ActionGate.check(:answer_engine, [])
      assert :ok = ActionGate.check(:generate_images, [])
    end

    # R9: Handles Invalid Input
    @tag :r9
    test "check handles non-list capability_groups gracefully" do
      # Passing an atom instead of a list should return error
      assert {:error, :action_not_allowed} = ActionGate.check(:execute_shell, :not_a_list)
    end

    @tag :r9
    test "check handles nil capability_groups gracefully" do
      # nil means no capability_groups specified - allows all actions
      assert :ok = ActionGate.check(:execute_shell, nil)
    end
  end

  describe "check!/2 with capability_groups" do
    # R4: Check Bang Raises for Blocked
    @tag :r4
    test "check! raises for blocked action without matching group" do
      # :spawn_child requires :hierarchy, but only :file_read provided
      assert_raise ActionNotAllowedError, fn ->
        ActionGate.check!(:spawn_child, [:file_read])
      end
    end

    @tag :r4
    test "check! raises for action with empty groups" do
      assert_raise ActionNotAllowedError, fn ->
        ActionGate.check!(:execute_shell, [])
      end
    end

    # R5: Check Bang Returns OK for Allowed
    @tag :r5
    test "check! returns :ok for base actions with empty groups" do
      # Base actions always allowed
      assert :ok = ActionGate.check!(:wait, [])
      assert :ok = ActionGate.check!(:orient, [])
    end

    @tag :r5
    test "check! returns :ok for action with matching capability group" do
      assert :ok = ActionGate.check!(:execute_shell, [:local_execution])
      assert :ok = ActionGate.check!(:spawn_child, [:hierarchy])
      assert :ok = ActionGate.check!(:call_api, [:external_api])
    end

    @tag :r5
    test "check! returns :ok with multiple capability groups" do
      # All capabilities
      all_groups = [:hierarchy, :local_execution, :file_read, :file_write, :external_api]
      assert :ok = ActionGate.check!(:execute_shell, all_groups)
      assert :ok = ActionGate.check!(:spawn_child, all_groups)
      assert :ok = ActionGate.check!(:file_read, all_groups)
      assert :ok = ActionGate.check!(:file_write, all_groups)
      assert :ok = ActionGate.check!(:call_api, all_groups)
    end
  end

  describe "filter_actions/2 with capability_groups" do
    # R6: Filter Actions Removes Blocked
    @tag :r6
    test "filter_actions removes blocked actions with empty groups" do
      actions = [:wait, :execute_shell, :send_message]
      # Empty groups only allows base actions
      result = ActionGate.filter_actions(actions, [])

      assert :wait in result
      assert :send_message in result
      refute :execute_shell in result
    end

    @tag :r6
    test "filter_actions removes actions not matching any group" do
      actions = [:spawn_child, :execute_shell, :call_api, :wait]
      # Only :hierarchy group - should remove :execute_shell and :call_api
      result = ActionGate.filter_actions(actions, [:hierarchy])

      assert :spawn_child in result
      assert :wait in result
      refute :execute_shell in result
      refute :call_api in result
    end

    # R7: Filter Actions Preserves Allowed
    @tag :r7
    test "filter_actions preserves allowed actions with matching groups" do
      actions = [:wait, :spawn_child]
      result = ActionGate.filter_actions(actions, [:hierarchy])

      assert :wait in result
      assert :spawn_child in result
      assert length(result) == 2
    end

    @tag :r7
    test "filter_actions preserves all actions with all groups" do
      actions = [:wait, :spawn_child, :execute_shell, :file_read, :file_write, :call_api]
      all_groups = [:hierarchy, :local_execution, :file_read, :file_write, :external_api]
      result = ActionGate.filter_actions(actions, all_groups)

      assert length(result) == 6

      Enum.each(actions, fn action ->
        assert action in result
      end)
    end

    @tag :r7
    test "filter_actions preserves order of allowed actions" do
      actions = [:wait, :orient, :todo, :send_message]
      result = ActionGate.filter_actions(actions, [])

      # All are base actions, so order should be preserved
      assert result == [:wait, :orient, :todo, :send_message]
    end

    @tag :r6
    test "filter_actions handles mixed groups correctly" do
      actions = [:spawn_child, :execute_shell, :call_api, :file_read, :wait]
      # hierarchy + local_execution - should allow spawn_child, execute_shell, wait
      result = ActionGate.filter_actions(actions, [:hierarchy, :local_execution])

      assert :spawn_child in result
      assert :execute_shell in result
      assert :wait in result
      refute :call_api in result
      refute :file_read in result
    end

    @tag :r6
    test "filter_actions returns empty list when all blocked" do
      actions = [:execute_shell, :spawn_child, :call_api]
      # Empty groups blocks all non-base actions
      result = ActionGate.filter_actions(actions, [])

      assert result == []
    end

    @tag :r9
    test "filter_actions handles invalid input gracefully" do
      actions = [:wait, :execute_shell]
      # Passing non-list should return actions unchanged (defensive)
      result = ActionGate.filter_actions(actions, :not_a_list)

      assert result == actions
    end
  end

  describe "ActionNotAllowedError with capability_groups" do
    # R8: Error Message Informative
    @tag :r8
    test "error message includes action and capability groups" do
      error =
        assert_raise ActionNotAllowedError, fn ->
          ActionGate.check!(:execute_shell, [:file_read])
        end

      message = Exception.message(error)

      assert message =~ "execute_shell"
      assert message =~ "file_read"
    end

    @tag :r8
    test "error message lists multiple capability groups" do
      error =
        assert_raise ActionNotAllowedError, fn ->
          ActionGate.check!(:call_api, [:hierarchy, :local_execution])
        end

      message = Exception.message(error)

      assert message =~ "call_api"
      assert message =~ "hierarchy"
      assert message =~ "local_execution"
    end

    @tag :r8
    test "error contains action and capability_groups fields" do
      error =
        assert_raise ActionNotAllowedError, fn ->
          ActionGate.check!(:spawn_child, [:file_read, :local_execution])
        end

      assert error.action == :spawn_child
      assert error.capability_groups == [:file_read, :local_execution]
    end

    @tag :r8
    test "error message handles empty capability groups" do
      error =
        assert_raise ActionNotAllowedError, fn ->
          ActionGate.check!(:execute_shell, [])
        end

      message = Exception.message(error)

      assert message =~ "execute_shell"
      # Empty list should still produce valid message
      assert is_binary(message)
    end
  end
end
