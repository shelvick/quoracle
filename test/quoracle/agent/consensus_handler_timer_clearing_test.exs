defmodule Quoracle.Agent.ConsensusHandlerTimerClearingTest do
  @moduledoc """
  Tests for ConsensusHandler v21.0 - DRY Timer Cancellation via StateUtils

  WorkGroupID: fix-20260117-consensus-staleness
  Packet: 1 (Foundation)
  Requirements: R47-R51

  These tests verify that handle_wait_parameter and action_executor
  properly use StateUtils.cancel_wait_timer/1 to clear timers.
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.ConsensusHandler

  # ==========================================================================
  # R47-R48: handle_wait_parameter Timer Clearing
  # ==========================================================================

  describe "[UNIT] R47: handle_wait_parameter Uses StateUtils" do
    test "handle_wait_parameter clears 2-tuple timer via StateUtils pattern" do
      timer_ref = Process.send_after(self(), :r47_2tuple, 60_000)
      state = %{wait_timer: {timer_ref, :timed_wait}}

      # After calling handle_wait_parameter, timer should be cleared
      result = ConsensusHandler.handle_wait_parameter(state, :orient, true)

      # BUG: Currently does NOT clear wait_timer to nil
      # This test should FAIL until the fix is implemented
      assert result.wait_timer == nil
    end

    test "handle_wait_parameter clears 3-tuple timer via StateUtils pattern" do
      timer_ref = Process.send_after(self(), :r47_3tuple, 60_000)
      state = %{wait_timer: {timer_ref, "timer-id", 1}}

      result = ConsensusHandler.handle_wait_parameter(state, :orient, true)

      # BUG: Currently does NOT handle 3-tuple format at all
      # This test should FAIL until the fix is implemented
      assert result.wait_timer == nil
    end
  end

  describe "[UNIT] R48: handle_wait_parameter Clears to nil" do
    test "handle_wait_parameter clears wait_timer to nil after cancel" do
      timer_ref = Process.send_after(self(), :r48_clear, 60_000)
      state = %{wait_timer: {timer_ref, :timed_wait}}

      # wait: true should just clear old timer and NOT set new one
      result = ConsensusHandler.handle_wait_parameter(state, :orient, true)

      # BUG: Currently returns state with original wait_timer
      assert result.wait_timer == nil
    end

    test "handle_wait_parameter with wait:false clears timer before triggering" do
      timer_ref = Process.send_after(self(), :r48_waitfalse, 60_000)
      state = %{wait_timer: {timer_ref, :timed_wait}}

      result = ConsensusHandler.handle_wait_parameter(state, :orient, false)

      # BUG: Currently returns state with original wait_timer (not cleared)
      # Note: wait:false also sends :trigger_consensus message
      assert result.wait_timer == nil
      assert_receive :trigger_consensus
    end

    test "handle_wait_parameter with timed wait clears old timer before setting new" do
      old_timer = Process.send_after(self(), :old_timer, 60_000)
      state = %{wait_timer: {old_timer, :timed_wait}}

      # wait: 5 (seconds) should clear old timer and set new one
      result = ConsensusHandler.handle_wait_parameter(state, :orient, 5)

      # New timer should be set (different from old)
      assert result.wait_timer != nil
      {new_ref, :timed_wait} = result.wait_timer
      assert is_reference(new_ref)
      assert new_ref != old_timer

      # Old timer should have been cancelled (no message)
      refute_receive :old_timer, 10

      # Cleanup: cancel new timer
      Process.cancel_timer(new_ref)
    end
  end

  # ==========================================================================
  # R49-R51: action_executor Timer Clearing (SOURCE VERIFICATION)
  #
  # These tests verify the ACTUAL action_executor.ex source code contains
  # the correct pattern. The current buggy code at lines 334-342 has:
  #   - Only 2-tuple pattern match (not 3-tuple)
  #   - Returns `state` unchanged after cancel (doesn't clear to nil)
  #
  # The fix is to replace the inline case statement with:
  #   state = StateUtils.cancel_wait_timer(state)
  # ==========================================================================

  describe "[UNIT] R49: action_executor Uses StateUtils.cancel_wait_timer" do
    test "action_executor source contains StateUtils.cancel_wait_timer call" do
      # R49: WHEN action_executor cancels timer THEN calls StateUtils.cancel_wait_timer/1
      # This test verifies the actual source code, not a simulation

      action_executor_path = "lib/quoracle/agent/consensus_handler/action_executor.ex"
      {:ok, source} = File.read(action_executor_path)

      # The fix should add this call in the :wait action timer handling section
      # (around lines 332-347 where the buggy inline case statement currently is)
      has_stateutils_cancel =
        String.contains?(source, "StateUtils.cancel_wait_timer(state)") or
          String.contains?(source, "StateUtils.cancel_wait_timer(")

      assert has_stateutils_cancel,
             """
             action_executor.ex should call StateUtils.cancel_wait_timer/1 for timer cancellation.

             Current buggy code at lines 334-342:
               case state.wait_timer do
                 {timer_ref, _type} when is_reference(timer_ref) ->
                   Process.cancel_timer(timer_ref)
                   state  # BUG: doesn't clear to nil!
                 _ -> state
               end

             Expected fix:
               state = StateUtils.cancel_wait_timer(state)
             """
    end

    test "action_executor does NOT have inline case for timer cancellation" do
      # R49: Verify the buggy inline pattern is removed

      action_executor_path = "lib/quoracle/agent/consensus_handler/action_executor.ex"
      {:ok, source} = File.read(action_executor_path)

      # The buggy pattern: case state.wait_timer do {timer_ref, _type}...
      # This inline pattern should be replaced with StateUtils.cancel_wait_timer
      has_buggy_pattern =
        String.contains?(source, "case state.wait_timer do") and
          String.contains?(source, "{timer_ref, _type} when is_reference(timer_ref)")

      refute has_buggy_pattern,
             """
             action_executor.ex should NOT have inline case statement for timer cancellation.
             Use StateUtils.cancel_wait_timer/1 instead for DRY and correct 3-tuple handling.
             """
    end
  end

  describe "[UNIT] R50: action_executor Handles 3-Tuple Timer" do
    test "action_executor timer handling works for 3-tuple format" do
      # R50: WHEN wait_timer is 3-tuple THEN action_executor cancels it correctly
      #
      # The buggy inline code only matches 2-tuple {timer_ref, _type}.
      # StateUtils.cancel_wait_timer handles both 2-tuple and 3-tuple.
      # By using StateUtils, action_executor automatically gains 3-tuple support.

      action_executor_path = "lib/quoracle/agent/consensus_handler/action_executor.ex"
      {:ok, source} = File.read(action_executor_path)

      # If action_executor uses StateUtils.cancel_wait_timer, it handles 3-tuple
      # If it has the buggy inline pattern, it only handles 2-tuple
      uses_stateutils = String.contains?(source, "StateUtils.cancel_wait_timer")

      # The buggy 2-tuple-only pattern
      has_2tuple_only_pattern =
        String.contains?(source, "{timer_ref, _type} when is_reference(timer_ref)") and
          not String.contains?(source, "{timer_ref, _id, _gen}")

      assert uses_stateutils or not has_2tuple_only_pattern,
             """
             action_executor.ex must handle 3-tuple timer format {ref, id, gen}.

             Current buggy code only matches 2-tuple:
               {timer_ref, _type} when is_reference(timer_ref) -> ...

             Fix: Use StateUtils.cancel_wait_timer/1 which handles:
               - nil
               - {timer_ref, type} (2-tuple)
               - {timer_ref, id, gen} (3-tuple)
             """
    end
  end

  describe "[UNIT] R51: action_executor Clears wait_timer to nil" do
    test "action_executor clears wait_timer to nil after cancelling" do
      # R51: WHEN action_executor cancels timer THEN wait_timer is nil before setting new
      #
      # The buggy code returns `state` unchanged after Process.cancel_timer.
      # This leaves wait_timer with the old value instead of nil.

      action_executor_path = "lib/quoracle/agent/consensus_handler/action_executor.ex"
      {:ok, source} = File.read(action_executor_path)

      # The buggy pattern returns `state` unchanged:
      #   Process.cancel_timer(timer_ref)
      #   state  <- BUG: should be %{state | wait_timer: nil}
      #
      # StateUtils.cancel_wait_timer properly clears to nil.

      # Check for the buggy pattern: Process.cancel_timer followed by bare `state`
      # This regex-like check looks for the pattern in the wait action handling section
      has_buggy_return =
        String.contains?(source, "Process.cancel_timer(timer_ref)") and
          String.contains?(source, "state\n") and
          not String.contains?(source, "StateUtils.cancel_wait_timer")

      refute has_buggy_return,
             """
             action_executor.ex must clear wait_timer to nil after cancelling.

             Current buggy code:
               Process.cancel_timer(timer_ref)
               state  # Returns state with OLD wait_timer value!

             Fix: Use StateUtils.cancel_wait_timer/1 which:
               1. Calls Process.cancel_timer
               2. Returns %{state | wait_timer: nil}
             """
    end
  end
end
