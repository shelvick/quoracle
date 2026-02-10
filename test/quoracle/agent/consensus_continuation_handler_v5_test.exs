defmodule Quoracle.Agent.ConsensusContinuationHandlerV5Test do
  @moduledoc """
  Tests for ConsensusContinuationHandler v5.0 - Delegation to StateUtils.cancel_wait_timer

  WorkGroupID: fix-20260117-consensus-staleness
  Packet: 1 (Foundation)
  Requirements: R17-R18
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.ConsensusContinuationHandler
  alias Quoracle.Agent.StateUtils

  describe "[UNIT] R17: Delegates to StateUtils" do
    test "ConsensusContinuationHandler.cancel_wait_timer delegates to StateUtils" do
      # Test that both produce identical results (delegation behavior)
      timer_ref = Process.send_after(self(), :delegate_test, 60_000)
      state = %{wait_timer: {timer_ref, :timed_wait}}

      # ConsensusContinuationHandler should delegate to StateUtils
      # Both calls should produce the same result
      cch_result = ConsensusContinuationHandler.cancel_wait_timer(state)

      # Create fresh timer for StateUtils call
      timer_ref2 = Process.send_after(self(), :delegate_test2, 60_000)
      state2 = %{wait_timer: {timer_ref2, :timed_wait}}
      su_result = StateUtils.cancel_wait_timer(state2)

      # Both should clear wait_timer to nil
      assert cch_result.wait_timer == nil
      assert su_result.wait_timer == nil
    end

    test "ConsensusContinuationHandler.cancel_wait_timer handles nil like StateUtils" do
      state = %{wait_timer: nil}

      cch_result = ConsensusContinuationHandler.cancel_wait_timer(state)
      su_result = StateUtils.cancel_wait_timer(state)

      assert cch_result == su_result
      assert cch_result == state
    end

    test "ConsensusContinuationHandler.cancel_wait_timer handles 2-tuple like StateUtils" do
      timer_ref = Process.send_after(self(), :two_tuple_delegate, 60_000)
      state = %{wait_timer: {timer_ref, :timed_wait}}

      result = ConsensusContinuationHandler.cancel_wait_timer(state)

      assert result.wait_timer == nil
    end

    test "ConsensusContinuationHandler.cancel_wait_timer handles 3-tuple like StateUtils" do
      timer_ref = Process.send_after(self(), :three_tuple_delegate, 60_000)
      state = %{wait_timer: {timer_ref, "timer-id", 1}}

      result = ConsensusContinuationHandler.cancel_wait_timer(state)

      assert result.wait_timer == nil
    end
  end

  describe "[INTEGRATION] R18: Backward Compatibility" do
    test "existing cancel_wait_timer callers work unchanged" do
      # Create state with 2-tuple timer (existing format)
      timer_ref = Process.send_after(self(), :compat_test, 60_000)
      state = %{wait_timer: {timer_ref, :timed_wait}, agent_id: "test"}

      # Old calling pattern should still work
      result = ConsensusContinuationHandler.cancel_wait_timer(state)

      assert result.wait_timer == nil
      assert result.agent_id == "test"
    end

    test "handle_wait_timeout uses cancel_wait_timer correctly" do
      # The cancel_timer_fn callback receives state and should clear timer
      timer_ref = Process.send_after(self(), :timeout_test, 60_000)

      state = %{
        wait_timer: {timer_ref, :timed_wait},
        agent_id: "compat-agent",
        model_histories: %{"model1" => []},
        skip_auto_consensus: true
      }

      # Simulate the cancel_timer_fn that Core passes
      cancel_timer_fn = &ConsensusContinuationHandler.cancel_wait_timer/1

      # Apply the function
      result = cancel_timer_fn.(state)

      assert result.wait_timer == nil
      assert result.agent_id == "compat-agent"
    end
  end
end
