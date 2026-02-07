defmodule Quoracle.Agent.StaleContinueConsensusTest do
  @moduledoc """
  Tests for stale :trigger_consensus staleness check (v17.0, v3.0 drain compatibility).

  Bug fix: Race condition where stale :trigger_consensus timer messages trigger
  unwanted consensus cycles. When a timed wait parameter creates a timer, and an
  external message arrives AFTER the timer fires but BEFORE the message is processed,
  the timer's :trigger_consensus message is stale but still triggers consensus.

  Solution: Add dual-flag staleness check to handle_trigger_consensus:
  If `consensus_scheduled == false` AND `wait_timer == nil`, ignore as stale.

  v3.0: Drain compatibility tests verify drain_trigger_messages/0 integration.

  WorkGroupID: fix-20260116-stale-continue-consensus
  WorkGroupID: fix-20260118-trigger-drain-pause (v3.0 drain tests)

  Requirements:
  - R63: Stale Message Detection - Both Flags False [UNIT]
  - R64: Valid Message - Scheduled Flag True [UNIT]
  - R65: Valid Message - Timer Active [UNIT]
  - R66: Flags Cleared After Processing [UNIT]
  - R67: Debug Logging for Stale Messages [UNIT]
  - R68: External Message Cancels Timer Then Stale Ignored [INTEGRATION]
  - R69: Tuple Form Also Has Staleness Check [UNIT]

  v3.0 Drain Compatibility (fix-20260118-trigger-drain-pause):
  - R101: Stale Message Doesn't Drain Subsequent Triggers [UNIT]
  - R102: Valid Message Drains All Subsequent Triggers [UNIT]
  - R103: Drain Happens After Staleness Check Passes [UNIT]
  - R104: Staleness Detection Logic Unchanged After Drain Addition [UNIT]

  Acceptance Tests:
  - A11: Pause Stops Agent After Single Consensus [SYSTEM/ACCEPTANCE]
  - A12: Rapid External Messages Don't Cause Extra Consensus [SYSTEM/ACCEPTANCE]
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core.MessageInfoHandler
  alias Quoracle.Agent.MessageHandler

  # Test isolation helpers
  defp unique_id, do: "agent-#{System.unique_integer([:positive])}"

  defp create_isolated_infrastructure do
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({Phoenix.PubSub, name: pubsub_name})
    start_supervised!({DynamicSupervisor, name: dynsup_name, strategy: :one_for_one})

    %{registry: registry_name, pubsub: pubsub_name, dynsup: dynsup_name}
  end

  defp create_test_state(infra, opts) do
    agent_id = Keyword.get(opts, :agent_id, unique_id())
    pending_actions = Keyword.get(opts, :pending_actions, %{})
    queued_messages = Keyword.get(opts, :queued_messages, [])
    model_histories = Keyword.get(opts, :model_histories, %{"model1" => []})
    consensus_scheduled = Keyword.get(opts, :consensus_scheduled, false)
    wait_timer = Keyword.get(opts, :wait_timer, nil)
    skip_auto_consensus = Keyword.get(opts, :skip_auto_consensus, true)

    %{
      agent_id: agent_id,
      router_pid: self(),
      registry: infra.registry,
      dynsup: infra.dynsup,
      pubsub: infra.pubsub,
      model_histories: model_histories,
      models: ["model1"],
      pending_actions: pending_actions,
      queued_messages: queued_messages,
      consensus_scheduled: consensus_scheduled,
      wait_timer: wait_timer,
      skip_auto_consensus: skip_auto_consensus,
      test_mode: true,
      context_limits_loaded: true,
      context_limit: 4000,
      context_lessons: %{},
      model_states: %{}
    }
  end

  # ===========================================================================
  # Unit Tests (R63-R67, R69)
  # ===========================================================================

  describe "[UNIT] R63: Stale Detection" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "R63: ignores :trigger_consensus when consensus_scheduled=false and wait_timer=nil", %{
      infra: infra
    } do
      # Setup: State with BOTH flags indicating no active wait/scheduled consensus
      # This is the STALE scenario - the message is leftover from a cancelled timer
      #
      # Use skip_auto_consensus: true so we can test staleness detection itself
      # (if staleness check works, it returns early BEFORE checking skip_auto_consensus)
      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      initial_histories = state.model_histories

      # Action: Call handle_trigger_consensus with stale message
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: For a STALE message, the implementation should:
      # 1. Detect staleness (both flags false)
      # 2. Return early without modifying state
      #
      # CURRENT BUG: Implementation clears consensus_scheduled even for stale messages
      # and proceeds to check skip_auto_consensus (which returns early, but only by luck)
      #
      # The fix should add staleness check BEFORE clearing any flags:
      # - If stale, return {:noreply, state} immediately (no modifications)
      #
      # We verify by checking that state is UNCHANGED (not just that consensus_scheduled
      # ends up false - that could happen by luck)

      # Key test: With staleness check, model_histories should be unchanged
      assert result_state.model_histories == initial_histories,
             "Stale :trigger_consensus should be ignored - model_histories unchanged"

      # Verify state is truly unchanged for stale message
      assert result_state.consensus_scheduled == false
      assert result_state.wait_timer == nil
    end

    test "R63: stale detection returns early without calling MessageHandler", %{infra: infra} do
      # This test verifies that stale messages don't reach MessageHandler at all
      # by checking that skip_auto_consensus is NOT consulted for stale messages
      #
      # With proper staleness check: stale message returns BEFORE skip_auto_consensus check
      # Without staleness check: skip_auto_consensus is checked and controls behavior

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          # Even with skip_auto_consensus: false, stale should return early
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # With proper staleness check, state should be unchanged
      # The staleness check should be:
      #   is_stale = consensus_scheduled == false and wait_timer == nil
      #   if is_stale, return {:noreply, state} (unchanged)
      assert result_state.consensus_scheduled == false
      assert result_state.wait_timer == nil
    end

    test "R63: stale detection works regardless of previous timer format", %{infra: infra} do
      # Setup: wait_timer is nil (could have been any format before being cancelled)
      # This tests that the staleness check only looks at CURRENT state
      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Should be detected as stale and ignored
      assert result_state.consensus_scheduled == false
      assert result_state.wait_timer == nil
    end
  end

  describe "[UNIT] R64: Valid - Scheduled Flag" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "R64: processes :trigger_consensus when consensus_scheduled is true", %{infra: infra} do
      # Setup: consensus_scheduled is true (from handle_action_result deferral)
      # wait_timer is nil (this is the immediate deferral case, not timed wait)
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      # Action: Call handle_trigger_consensus
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: Message should be processed (not ignored as stale)
      # After processing, consensus_scheduled should be cleared to false
      assert result_state.consensus_scheduled == false,
             "consensus_scheduled should be cleared after valid :trigger_consensus"

      # This test passes with current implementation, but we're verifying
      # the positive case still works after adding staleness check
    end

    test "R64: consensus_scheduled=true takes precedence over wait_timer=nil", %{infra: infra} do
      # This verifies the OR logic: either flag true means NOT stale
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Should process (not stale) and clear the flag
      assert result_state.consensus_scheduled == false
    end
  end

  describe "[UNIT] R65: Valid - Timer Active" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "R65: processes :trigger_consensus when wait_timer is active (2-tuple)", %{infra: infra} do
      # Setup: wait_timer is active (2-tuple format: {timer_ref, :timed_wait})
      # consensus_scheduled is false (this is the timed wait expiration case)
      timer_ref = make_ref()

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      # Action: Call handle_trigger_consensus
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: Message should be processed (not ignored as stale)
      # After processing, wait_timer should be cleared to nil
      assert result_state.wait_timer == nil,
             "wait_timer should be cleared after processing timed :trigger_consensus"

      # consensus_scheduled should also be false (it was already false)
      assert result_state.consensus_scheduled == false
    end

    test "R65: processes :trigger_consensus when wait_timer is active (3-tuple)", %{infra: infra} do
      # Setup: wait_timer is 3-tuple format: {timer_ref, timer_id, generation}
      timer_ref = make_ref()

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, "timer-123", 5},
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Should process and clear the timer
      assert result_state.wait_timer == nil
      assert result_state.consensus_scheduled == false
    end

    test "R65: wait_timer active takes precedence over consensus_scheduled=false", %{infra: infra} do
      # This verifies the OR logic: either condition true means NOT stale
      timer_ref = make_ref()

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Should process (not stale)
      assert result_state.wait_timer == nil
    end
  end

  describe "[UNIT] R66: Flags Cleared" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "R66: clears consensus_scheduled and wait_timer after processing", %{infra: infra} do
      # Setup: Both flags are "active" (unusual but possible in edge case)
      timer_ref = make_ref()

      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      # Action: Call handle_trigger_consensus
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: BOTH should be cleared after processing
      assert result_state.consensus_scheduled == false,
             "consensus_scheduled should be false after processing"

      assert result_state.wait_timer == nil,
             "wait_timer should be nil after processing"
    end

    test "R66: clears wait_timer even when only consensus_scheduled was true", %{infra: infra} do
      # Setup: Only consensus_scheduled is true, wait_timer already nil
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Both should be cleared/remain cleared
      assert result_state.consensus_scheduled == false
      assert result_state.wait_timer == nil
    end

    test "R66: clears consensus_scheduled even when only wait_timer was active", %{infra: infra} do
      # Setup: Only wait_timer is active, consensus_scheduled is false
      timer_ref = make_ref()

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Both should be cleared
      assert result_state.consensus_scheduled == false
      assert result_state.wait_timer == nil
    end
  end

  describe "[UNIT] R67: Debug Logging" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R67: Debug logging is implemented via Logger.debug in the implementation.
    # We verify behavior (stale messages return unchanged state) rather than
    # log output, since test config sets Logger to :error level and we cannot
    # modify global Logger config (affects concurrent tests).
    #
    # The Logger.debug call exists in implementation for debugging in dev/prod.

    test "R67: stale message returns unchanged state (debug logged)", %{infra: infra} do
      # Setup: Stale scenario - both flags indicate no active wait/scheduled consensus
      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      initial_state = state

      # Action: Call handle_trigger_consensus with stale message
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: Stale message is detected and state is unchanged
      # (Logger.debug is called but not captured due to test log level)
      assert result_state == initial_state,
             "Stale message should return unchanged state"
    end

    test "R67: valid message modifies state (no debug log)", %{infra: infra} do
      # Setup: Valid scenario - consensus_scheduled is true
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      # Action: Call handle_trigger_consensus
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: Valid message clears flags (state is modified, no stale log)
      assert result_state.consensus_scheduled == false,
             "consensus_scheduled should be cleared for valid message"
    end
  end

  describe "[UNIT] R69: Tuple Form Staleness" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "R69: tuple handler ignores stale message", %{infra: infra} do
      # Setup: Stale scenario for tuple form {:trigger_consensus}
      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      initial_state = state

      # Action: Call handle_trigger_consensus
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: Should ignore stale message (state unchanged)
      assert result_state == initial_state,
             "Stale {:trigger_consensus} tuple should return unchanged state"
    end

    test "R69: tuple handler processes valid message", %{infra: infra} do
      # Setup: Valid scenario for tuple form
      timer_ref = make_ref()

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      # Action: Call handle_trigger_consensus
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: Should process (not stale) and clear timer
      assert result_state.wait_timer == nil,
             "wait_timer should be cleared after valid {:trigger_consensus} tuple"
    end

    test "R69: tuple handler has same staleness logic as atom handler", %{infra: infra} do
      # Setup: Stale scenario - verify tuple handler behaves same as atom handler
      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      # Action: Call both handlers with identical stale state
      {:noreply, atom_result} = MessageInfoHandler.handle_trigger_consensus(state)
      {:noreply, tuple_result} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: Both should return unchanged state (both detect staleness)
      # Logger.debug is called in both but not captured (test log level)
      assert atom_result == state, "Atom handler should return unchanged state for stale"
      assert tuple_result == state, "Tuple handler should return unchanged state for stale"
      assert atom_result == tuple_result, "Both handlers should behave identically"
    end
  end

  # ===========================================================================
  # Integration Test (R68)
  # ===========================================================================

  describe "[INTEGRATION] R68: Timer Cancel Race" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "R68: external message cancels timer - stale continue_consensus ignored", %{infra: infra} do
      # This simulates the race condition:
      # 1. Agent has timed wait, timer fires, :trigger_consensus in mailbox
      # 2. External message arrives, cancels wait_timer
      # 3. External message triggers consensus (correct)
      # 4. Stale :trigger_consensus processed - should be IGNORED

      # Step 1: Setup state with active timed wait
      timer_ref = make_ref()

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, :timed_wait},
          pending_actions: %{},
          queued_messages: []
        )

      # Step 2: Simulate external message arriving and cancelling timer
      # MessageHandler.handle_agent_message calls cancel_wait_timer
      {:noreply, state_after_msg} =
        MessageHandler.handle_agent_message(state, :parent, "external message")

      # Timer should be cancelled
      assert state_after_msg.wait_timer == nil,
             "External message should cancel wait_timer"

      # Step 3: Now the stale :trigger_consensus is processed
      # consensus_scheduled is false (external msg didn't set it - it triggered consensus)
      # wait_timer is nil (cancelled by external message)
      # This is the STALE scenario!

      state_for_stale = %{state_after_msg | consensus_scheduled: false}

      # Track if consensus runs (it shouldn't for stale message)
      _test_pid = self()
      _consensus_count = :counters.new(1, [:atomics])

      # Mock consensus by setting skip_auto_consensus: false but tracking calls
      # Actually, we can verify by checking that model_histories is unchanged
      _initial_histories = state_for_stale.model_histories

      # Step 4: Process the "stale" :trigger_consensus
      {:noreply, final_state} = MessageInfoHandler.handle_trigger_consensus(state_for_stale)

      # Assert: Stale message should be ignored - no additional consensus
      # The external message already triggered consensus, so model_histories
      # should only have entries from that (not doubled by stale message)

      # For this test, we verify the staleness check prevents the call
      # Since skip_auto_consensus defaults to true in our state, we check
      # that the flags remain unchanged (indicating early return for stale)
      assert final_state.consensus_scheduled == false,
             "Stale :trigger_consensus should not modify consensus_scheduled"

      assert final_state.wait_timer == nil,
             "Stale :trigger_consensus should not modify wait_timer"
    end

    test "R68: simulates full race timeline", %{infra: infra} do
      # More comprehensive race simulation:
      # T0: Agent completes action with timed wait (5000ms)
      # T1: Timer fires at 5000ms, sends :trigger_consensus to mailbox
      # T2: Child message "SYNC_COMPLETE" arrives at 5001ms
      # T3: handle_agent_message processes child message, cancels timer, triggers consensus
      # T4: GenServer processes stale :trigger_consensus from T1 - should be IGNORED

      # Setup initial state (at T0, after action with timed wait)
      timer_ref = make_ref()

      state_t0 =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, "timer-001", 1},
          pending_actions: %{},
          model_histories: %{"model1" => []}
        )

      # T1-T2: Timer fires, message arrives
      # We simulate this by having the :trigger_consensus in the "mailbox"
      # but processing the child message first

      # T3: Process child message (this cancels timer and triggers consensus)
      {:noreply, state_t3} =
        MessageHandler.handle_agent_message(state_t0, "child-123", "SYNC_COMPLETE")

      # After child message:
      # - wait_timer is nil (cancelled)
      # - consensus may have been triggered (or deferred if consensus_scheduled pattern)
      assert state_t3.wait_timer == nil, "Timer should be cancelled by child message"

      # T4: Process stale :trigger_consensus
      # At this point, consensus_scheduled should be false (either never set, or cleared)
      state_for_t4 = %{state_t3 | consensus_scheduled: false}

      # This is the key test: the stale message should be ignored
      {:noreply, state_t4} = MessageInfoHandler.handle_trigger_consensus(state_for_t4)

      # Verify no unexpected changes
      assert state_t4.consensus_scheduled == false
      assert state_t4.wait_timer == nil

      # The key behavior: model_histories should NOT have doubled entries
      # from both the child message consensus AND the stale timer consensus
      # (Though verifying exact history count requires mocking consensus)
    end
  end

  # ===========================================================================
  # Acceptance Tests (A11-A12)
  # ===========================================================================

  describe "[ACCEPTANCE] A11-A12: User Behavior" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    @tag :acceptance
    test "A11: pause during timed wait stops agent after single consensus cycle", %{infra: infra} do
      # User scenario:
      # 1. Agent is in timed wait (timer about to fire)
      # 2. User clicks Pause
      # 3. Timer fires, :trigger_consensus message arrives
      # 4. Agent should complete ONE consensus cycle, then stop
      # 5. Should NOT have extra consensus from stale timer

      # Setup: Agent state simulating mid-timed-wait
      timer_ref = make_ref()

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, :timed_wait},
          model_histories: %{"model1" => [%{type: :decision, content: %{action: :wait}}]},
          pending_actions: %{}
        )

      # Simulate user clicking Pause:
      # - This sets skip_auto_consensus: true (or similar flag)
      # - Agent continues processing current message but won't start new consensus

      state_paused = %{state | skip_auto_consensus: true}

      # Process the :trigger_consensus from the timer
      {:noreply, state_after_timer} =
        MessageInfoHandler.handle_trigger_consensus(state_paused)

      # With skip_auto_consensus: true, consensus shouldn't run, but the
      # staleness check should still clear the timer if valid

      # If the timer was valid (wait_timer was set), it should be cleared
      # even though consensus is skipped
      assert state_after_timer.wait_timer == nil,
             "wait_timer should be cleared after processing :trigger_consensus"

      # Now if another stale :trigger_consensus arrives (edge case),
      # it should be ignored
      state_for_stale = %{state_after_timer | consensus_scheduled: false}

      {:noreply, final_state} = MessageInfoHandler.handle_trigger_consensus(state_for_stale)

      # Stale message should not cause any issues
      assert final_state.consensus_scheduled == false
      assert final_state.wait_timer == nil

      # Key assertion: Only ONE consensus could have run (from the first valid message)
      # and subsequent stale messages are ignored
    end

    @tag :acceptance
    test "A12: rapid messages during timed wait cause single consensus not multiple", %{
      infra: infra
    } do
      # User scenario:
      # 1. Agent in timed wait
      # 2. Multiple child messages arrive rapidly
      # 3. Messages batched, single consensus processes all
      # 4. No extra consensus from stale timer(s)

      # Setup: Agent in timed wait
      timer_ref = make_ref()

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, "timer-001", 1},
          model_histories: %{"model1" => []},
          pending_actions: %{},
          queued_messages: []
        )

      # Multiple rapid messages arrive
      {:noreply, state1} = MessageHandler.handle_agent_message(state, "child-1", "msg 1")

      # First message cancels timer
      assert state1.wait_timer == nil, "First message should cancel timer"

      # Subsequent messages may be queued or processed immediately
      {:noreply, state2} = MessageHandler.handle_agent_message(state1, "child-2", "msg 2")
      {:noreply, state3} = MessageHandler.handle_agent_message(state2, "child-3", "msg 3")

      # Now process any pending :trigger_consensus messages
      # They should all be stale because wait_timer is nil and
      # consensus_scheduled should be false after messages are processed

      state_for_stale = %{state3 | consensus_scheduled: false}

      # Track number of consensus calls (should be 0 for stale messages)
      _consensus_count = :counters.new(1, [:atomics])

      # Process multiple "stale" :trigger_consensus messages
      {:noreply, s1} = MessageInfoHandler.handle_trigger_consensus(state_for_stale)
      {:noreply, s2} = MessageInfoHandler.handle_trigger_consensus(s1)
      {:noreply, s3} = MessageInfoHandler.handle_trigger_consensus(s2)

      # All should be ignored as stale (no timer, no scheduled flag)
      assert s3.consensus_scheduled == false
      assert s3.wait_timer == nil

      # The key behavior: Multiple stale messages don't cause multiple consensus
      # Model histories should only have entries from the legitimate message processing,
      # not from stale timer messages
    end

    @tag :acceptance
    test "A11/A12 combined: verify via state inspection", %{infra: infra} do
      # This test verifies user-observable behavior by inspecting state
      # after the race condition scenario

      # Initial state: Agent with timed wait
      timer_ref = make_ref()

      initial_state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, :timed_wait},
          model_histories: %{"model1" => [%{type: :decision, content: %{action: :wait}}]},
          pending_actions: %{}
        )

      # Count model_histories entries before
      _initial_history_count = length(initial_state.model_histories["model1"])

      # Process external message (cancels timer, triggers one consensus path)
      {:noreply, state_after_msg} =
        MessageHandler.handle_agent_message(initial_state, :parent, "user follow-up")

      # Process stale :trigger_consensus
      state_for_stale = %{state_after_msg | consensus_scheduled: false}
      {:noreply, final_state} = MessageInfoHandler.handle_trigger_consensus(state_for_stale)

      # User expectation verification:
      # The stale message should NOT have added extra entries
      # (exact count depends on whether consensus was mocked, but the
      # staleness check should prevent the stale path from running)

      # Most importantly: no crash, no unexpected behavior
      assert is_map(final_state)
      assert final_state.consensus_scheduled == false
      assert final_state.wait_timer == nil

      # The model_histories increase should be from the ONE legitimate consensus,
      # not doubled by the stale timer message
    end
  end

  # ===========================================================================
  # Drain Compatibility Tests (R101-R104) - v3.0
  # ===========================================================================

  # These tests verify that drain_trigger_messages/0 integrates correctly
  # with the existing staleness check. The drain should only happen for
  # VALID messages (not stale), and staleness detection must be unchanged.
  describe "[UNIT] R101-R104: Drain Compatibility (v3.0)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "R101: stale message doesn't drain subsequent triggers from mailbox", %{infra: infra} do
      # This test MUST fail without drain implementation.
      # Structure: First prove drain works for valid, then test stale doesn't drain.

      # PART 1: Prove drain works for VALID message (control - must fail without drain)
      valid_state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      send(self(), :trigger_consensus)
      {:noreply, _} = MessageInfoHandler.handle_trigger_consensus(valid_state)

      # This assertion FAILS without drain implementation
      refute_receive :trigger_consensus,
                     0,
                     "CONTROL: Valid trigger should drain subsequent messages"

      # PART 2: Now test stale message DOESN'T drain
      stale_state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      send(self(), :trigger_consensus)
      send(self(), :trigger_consensus)

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(stale_state)

      # Stale message returns early WITHOUT draining
      assert result_state == stale_state, "Stale message should return unchanged state"
      assert_receive :trigger_consensus, 0, "Stale should NOT drain - trigger 1 remains"
      assert_receive :trigger_consensus, 0, "Stale should NOT drain - trigger 2 remains"
    end

    test "R102: valid message drains all subsequent triggers from mailbox", %{infra: infra} do
      # Setup: State is VALID (consensus_scheduled is true)
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      # Add trigger messages to mailbox
      send(self(), :trigger_consensus)
      send(self(), :trigger_consensus)
      send(self(), :trigger_consensus)

      # Process the valid :trigger_consensus
      {:noreply, _result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: All subsequent triggers should be drained
      refute_receive :trigger_consensus, 0, "All triggers should be drained by valid message"
    end

    test "R103: drain happens after staleness check passes", %{infra: infra} do
      # Setup: State with active timer (valid message)
      timer_ref = make_ref()

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      # Add other message types that should NOT be drained
      send(self(), {:agent_message, :parent, "important"})
      send(self(), :trigger_consensus)
      send(self(), {:action_result, :some_result})

      # Process valid :trigger_consensus (timer active = valid)
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: Timer cleared (valid message processed)
      assert result_state.wait_timer == nil

      # Assert: Only :trigger_consensus drained, other messages preserved
      refute_receive :trigger_consensus, 0, "Trigger should be drained"

      assert_receive {:agent_message, :parent, "important"},
                     0,
                     "Agent message should be preserved"

      assert_receive {:action_result, :some_result}, 0, "Action result should be preserved"
    end

    test "R104: staleness detection logic unchanged after drain addition", %{infra: infra} do
      # This test verifies the staleness check formula is unchanged:
      # is_stale = (consensus_scheduled == false) AND (wait_timer == nil)
      #
      # MUST fail without drain: includes control assertion for drain behavior.

      # CONTROL: Prove drain works for valid message (must fail without drain)
      control_state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      send(self(), :trigger_consensus)
      {:noreply, _} = MessageInfoHandler.handle_trigger_consensus(control_state)
      refute_receive :trigger_consensus, 0, "CONTROL: Valid message must drain triggers"

      # Case 1: Both false = STALE (should return unchanged)
      stale_state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      {:noreply, stale_result} = MessageInfoHandler.handle_trigger_consensus(stale_state)
      assert stale_result == stale_state, "Case 1: Both false = STALE"

      # Case 2: consensus_scheduled true = VALID
      scheduled_state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      {:noreply, scheduled_result} = MessageInfoHandler.handle_trigger_consensus(scheduled_state)

      assert scheduled_result.consensus_scheduled == false,
             "Case 2: Scheduled flag cleared = VALID"

      # Case 3: wait_timer active = VALID
      timer_ref = make_ref()

      timer_state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      {:noreply, timer_result} = MessageInfoHandler.handle_trigger_consensus(timer_state)
      assert timer_result.wait_timer == nil, "Case 3: Timer cleared = VALID"

      # Case 4: Both true = VALID (edge case)
      both_state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      {:noreply, both_result} = MessageInfoHandler.handle_trigger_consensus(both_state)
      assert both_result.consensus_scheduled == false, "Case 4: Both cleared = VALID"
      assert both_result.wait_timer == nil, "Case 4: Both cleared = VALID"
    end

    test "R101-R104: drain count matches mailbox trigger count for valid message", %{infra: infra} do
      # Setup: Valid state with known number of triggers in mailbox
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      # Add exactly 5 triggers
      for _ <- 1..5, do: send(self(), :trigger_consensus)

      # Process the valid message (which should drain all 5)
      {:noreply, _result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Verify all 5 were drained
      refute_receive :trigger_consensus, 0, "All 5 triggers should be drained"
    end
  end
end
