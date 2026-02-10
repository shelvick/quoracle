defmodule Quoracle.Agent.StateUtilsScheduleContinuationTest do
  @moduledoc """
  Tests for StateUtils.schedule_consensus_continuation/1 (v6.0 - DRY Consensus Continuation)

  WorkGroupID: fix-20260117-consensus-continuation
  Packet: 1 (Foundation)
  Requirements: R19-R25 (AGENT_StateUtils v6.0) / R1-R7 (TEST_ConsensusContinuation)

  Bug: Self-contained actions (`:todo`, `:orient`) with wait:false don't auto-continue
  because ActionExecutor sends `:trigger_consensus` but never sets `consensus_scheduled = true`,
  causing the staleness check to ignore the trigger.

  Solution: Centralize "set flag + send trigger" in a single helper function.
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.StateUtils

  describe "[UNIT] R19: Function Exists" do
    test "StateUtils.schedule_consensus_continuation/1 can be called" do
      # R19: Verify the function exists by calling it
      # Will fail with UndefinedFunctionError until implemented
      state = %{consensus_scheduled: false}
      result = StateUtils.schedule_consensus_continuation(state)
      assert is_map(result)
    end
  end

  describe "[UNIT] R20: Sets Consensus Scheduled Flag" do
    test "schedule_consensus_continuation sets consensus_scheduled to true" do
      state = %{consensus_scheduled: false, other: :value}
      result = StateUtils.schedule_consensus_continuation(state)
      assert result.consensus_scheduled == true
    end

    test "schedule_consensus_continuation sets flag even when already true" do
      state = %{consensus_scheduled: true}
      result = StateUtils.schedule_consensus_continuation(state)
      assert result.consensus_scheduled == true
    end
  end

  describe "[UNIT] R21: Sends Trigger Message" do
    test "schedule_consensus_continuation sends :trigger_consensus message" do
      state = %{consensus_scheduled: false}
      _result = StateUtils.schedule_consensus_continuation(state)
      assert_receive :trigger_consensus
    end

    test "schedule_consensus_continuation sends message to self()" do
      # Verify the message is sent to the calling process
      state = %{consensus_scheduled: false}
      _result = StateUtils.schedule_consensus_continuation(state)

      # Should receive the message in this test process
      assert_receive :trigger_consensus
    end
  end

  describe "[UNIT] R22: Returns Updated State" do
    test "schedule_consensus_continuation returns state with flag set" do
      state = %{consensus_scheduled: false, agent_id: "test-agent"}
      result = StateUtils.schedule_consensus_continuation(state)

      assert result.consensus_scheduled == true
      assert result.agent_id == "test-agent"
    end

    test "schedule_consensus_continuation returns map type" do
      state = %{consensus_scheduled: false}
      result = StateUtils.schedule_consensus_continuation(state)
      assert is_map(result)
    end
  end

  describe "[UNIT] R23: Idempotent Behavior" do
    test "schedule_consensus_continuation is idempotent - multiple calls succeed" do
      state = %{consensus_scheduled: false}

      # Call multiple times
      result1 = StateUtils.schedule_consensus_continuation(state)
      result2 = StateUtils.schedule_consensus_continuation(result1)

      # Flag should still be true
      assert result1.consensus_scheduled == true
      assert result2.consensus_scheduled == true

      # Should receive two messages (both calls send)
      assert_receive :trigger_consensus
      assert_receive :trigger_consensus
    end

    test "schedule_consensus_continuation handles rapid consecutive calls" do
      state = %{consensus_scheduled: false}

      # Call 5 times rapidly
      final_state =
        1..5
        |> Enum.reduce(state, fn _, acc ->
          StateUtils.schedule_consensus_continuation(acc)
        end)

      assert final_state.consensus_scheduled == true

      # Should have 5 messages in mailbox
      for _ <- 1..5 do
        assert_receive :trigger_consensus
      end
    end
  end

  describe "[UNIT] R24: Preserves Other State Fields" do
    test "schedule_consensus_continuation preserves other state fields" do
      timer_ref = make_ref()

      state = %{
        consensus_scheduled: false,
        agent_id: "test-agent",
        model_histories: %{"m1" => []},
        wait_timer: {timer_ref, :timed_wait},
        pending_actions: %{ref1: :action1},
        queued_messages: [:msg1, :msg2]
      }

      result = StateUtils.schedule_consensus_continuation(state)

      assert result.consensus_scheduled == true
      assert result.agent_id == "test-agent"
      assert result.model_histories == %{"m1" => []}
      assert result.wait_timer == {timer_ref, :timed_wait}
      assert result.pending_actions == %{ref1: :action1}
      assert result.queued_messages == [:msg1, :msg2]
    end

    test "schedule_consensus_continuation does not add extra keys" do
      state = %{consensus_scheduled: false, only_key: :value}
      result = StateUtils.schedule_consensus_continuation(state)

      assert Map.keys(result) |> Enum.sort() == [:consensus_scheduled, :only_key]
    end
  end

  describe "[UNIT] R25: Works with Minimal State" do
    test "schedule_consensus_continuation works with minimal state (empty map)" do
      state = %{}
      result = StateUtils.schedule_consensus_continuation(state)

      assert result.consensus_scheduled == true
      assert_receive :trigger_consensus
    end

    test "schedule_consensus_continuation works when consensus_scheduled key missing" do
      state = %{agent_id: "test", other: :field}
      result = StateUtils.schedule_consensus_continuation(state)

      assert result.consensus_scheduled == true
      assert result.agent_id == "test"
      assert result.other == :field
      assert_receive :trigger_consensus
    end
  end
end
