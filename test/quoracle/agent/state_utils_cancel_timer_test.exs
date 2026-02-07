defmodule Quoracle.Agent.StateUtilsCancelTimerTest do
  @moduledoc """
  Tests for StateUtils.cancel_wait_timer/1 (v5.0 - DRY Timer Cancellation)

  WorkGroupID: fix-20260117-consensus-staleness
  Packet: 1 (Foundation)
  Requirements: R13-R18
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.StateUtils

  describe "[UNIT] R13: StateUtils.cancel_wait_timer Exists" do
    test "StateUtils.cancel_wait_timer/1 can be called" do
      # R13: Verify the function exists by calling it
      # Will fail with UndefinedFunctionError until implemented
      state = %{wait_timer: nil}
      result = StateUtils.cancel_wait_timer(state)
      assert result == state
    end
  end

  describe "[UNIT] R14: StateUtils Handles nil Timer" do
    test "cancel_wait_timer handles nil timer" do
      state = %{wait_timer: nil}
      result = StateUtils.cancel_wait_timer(state)
      assert result == state
    end

    test "cancel_wait_timer returns state unchanged when wait_timer is nil" do
      state = %{wait_timer: nil, agent_id: "test-agent", other_field: "preserved"}
      result = StateUtils.cancel_wait_timer(state)
      assert result == state
      assert result.other_field == "preserved"
    end
  end

  describe "[UNIT] R15: StateUtils Handles 2-Tuple Timer" do
    test "cancel_wait_timer handles 2-tuple timer {ref, type}" do
      # Create a real timer reference for realistic test
      timer_ref = Process.send_after(self(), :test_msg, 60_000)
      state = %{wait_timer: {timer_ref, :timed_wait}}

      result = StateUtils.cancel_wait_timer(state)

      assert result.wait_timer == nil
      # Timer should have been cancelled (no message received)
      refute_receive :test_msg, 10
    end

    test "cancel_wait_timer cancels and clears 2-tuple with :wait_action type" do
      timer_ref = Process.send_after(self(), :wait_action_msg, 60_000)
      state = %{wait_timer: {timer_ref, :wait_action}}

      result = StateUtils.cancel_wait_timer(state)

      assert result.wait_timer == nil
      refute_receive :wait_action_msg, 10
    end
  end

  describe "[UNIT] R16: StateUtils Handles 3-Tuple Timer" do
    test "cancel_wait_timer handles 3-tuple timer {ref, id, gen}" do
      timer_ref = Process.send_after(self(), :three_tuple_msg, 60_000)
      state = %{wait_timer: {timer_ref, "timer-id-123", 1}}

      result = StateUtils.cancel_wait_timer(state)

      assert result.wait_timer == nil
      refute_receive :three_tuple_msg, 10
    end

    test "cancel_wait_timer handles 3-tuple with any timer_id string" do
      timer_ref = Process.send_after(self(), :three_tuple_msg2, 60_000)
      state = %{wait_timer: {timer_ref, "custom-timer-uuid", 42}}

      result = StateUtils.cancel_wait_timer(state)

      assert result.wait_timer == nil
      refute_receive :three_tuple_msg2, 10
    end
  end

  describe "[UNIT] R13-R16: Edge Cases" do
    test "cancel_wait_timer handles unknown tuple format gracefully" do
      # Fallback clause should clear to nil
      state = %{wait_timer: {:not_a_ref, :unknown}}

      result = StateUtils.cancel_wait_timer(state)

      assert result.wait_timer == nil
    end

    test "cancel_wait_timer preserves other state fields" do
      timer_ref = Process.send_after(self(), :preserve_test, 60_000)

      state = %{
        wait_timer: {timer_ref, :timed_wait},
        agent_id: "test-agent",
        model_histories: %{"model1" => []},
        pending_actions: %{},
        consensus_scheduled: true
      }

      result = StateUtils.cancel_wait_timer(state)

      assert result.wait_timer == nil
      assert result.agent_id == "test-agent"
      assert result.model_histories == %{"model1" => []}
      assert result.pending_actions == %{}
      assert result.consensus_scheduled == true
    end
  end
end
