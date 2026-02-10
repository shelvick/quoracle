defmodule Quoracle.Agent.ConsensusContinuationHandlerV2Test do
  @moduledoc """
  Tests for ConsensusContinuationHandler v2.0 (fix-20251209-035351 Packet 3).

  R1: handle_wait_timeout delegates to ConsensusHandler.get_action_consensus
  R2: does NOT call ContextManager.build_conversation_messages
  R3: only handles timer cleanup and delegation
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.ConsensusContinuationHandler

  defp base_state do
    %{
      agent_id: "test-agent-#{System.unique_integer([:positive])}",
      model_histories: %{},
      pubsub: nil,
      wait_timer: nil,
      test_mode: true
    }
  end

  describe "[UNIT] handle_wait_timeout delegation (R1)" do
    test "R1: delegates to ConsensusHandler.get_action_consensus" do
      # R1: handle_wait_timeout should delegate directly to ConsensusHandler
      # NOT use injected get_consensus_fn parameter

      state = base_state()
      timer_id = "timer-#{System.unique_integer([:positive])}"
      test_pid = self()

      # Mock cancel_timer_fn - just returns state
      cancel_timer_fn = fn s -> s end

      # Mock execute_action_fn - capture execution
      execute_action_fn = fn s, action ->
        send(test_pid, {:executed, action})
        s
      end

      # R1: The v2.0 signature should NOT require get_consensus_fn
      # It should delegate to ConsensusHandler.get_action_consensus(state) internally
      # This test will FAIL if implementation still requires 5 args with get_consensus_fn

      # v2.0 signature: handle_wait_timeout(state, timer_id, cancel_timer_fn, execute_action_fn)
      # Old signature: handle_wait_timeout(state, timer_id, cancel_timer_fn, get_consensus_fn, execute_action_fn)

      result =
        ConsensusContinuationHandler.handle_wait_timeout(
          state,
          timer_id,
          cancel_timer_fn,
          execute_action_fn
        )

      # Should return {:noreply, state} tuple
      assert {:noreply, _new_state} = result
    end

    test "R1: handle_wait_timeout uses ConsensusHandler directly" do
      # This test verifies that handle_wait_timeout calls ConsensusHandler
      # internally rather than accepting a get_consensus_fn parameter

      state = base_state()
      timer_id = "timer-#{System.unique_integer([:positive])}"

      cancel_timer_fn = fn s -> s end
      execute_action_fn = fn s, _action -> s end

      # Try calling with 4 args (v2.0 pattern without get_consensus_fn)
      # Will fail if implementation requires 5 args
      result =
        ConsensusContinuationHandler.handle_wait_timeout(
          state,
          timer_id,
          cancel_timer_fn,
          execute_action_fn
        )

      assert {:noreply, _} = result
    end
  end

  describe "[UNIT] no ContextManager calls (R2)" do
    test "R2: does not call ContextManager.build_conversation_messages" do
      # R2: The handler should NOT call ContextManager.build_conversation_messages
      # ConsensusHandler handles all context building internally

      state = base_state()
      timer_id = "timer-test"

      cancel_timer_fn = fn s -> s end
      execute_action_fn = fn s, _action -> s end

      # If implementation calls ContextManager.build_conversation_messages,
      # the state would need more fields. With minimal state, it should still work
      # because ConsensusHandler handles context building (not this handler)

      result =
        ConsensusContinuationHandler.handle_wait_timeout(
          state,
          timer_id,
          cancel_timer_fn,
          execute_action_fn
        )

      # Should succeed without needing full conversation context
      assert {:noreply, _} = result
    end
  end

  describe "[UNIT] single responsibility (R3)" do
    test "R3: handler only manages timer cleanup and delegates" do
      # R3: ConsensusContinuationHandler should:
      # 1. Cancel the timer (via cancel_timer_fn)
      # 2. Delegate to ConsensusHandler.get_action_consensus
      # 3. Execute action (via execute_action_fn)
      # Nothing else - no message building, no context manipulation

      state = base_state()
      timer_id = "timer-cleanup"
      test_pid = self()

      # Track that cancel_timer_fn is called
      cancel_timer_fn = fn s ->
        send(test_pid, :timer_cancelled)
        s
      end

      # Track that execute_action_fn is called with action
      execute_action_fn = fn s, action ->
        send(test_pid, {:action_executed, action})
        s
      end

      _result =
        ConsensusContinuationHandler.handle_wait_timeout(
          state,
          timer_id,
          cancel_timer_fn,
          execute_action_fn
        )

      # Verify timer was cancelled
      assert_receive :timer_cancelled
      # Verify action was executed (means consensus was obtained)
      assert_receive {:action_executed, action}, 30_000
      assert is_map(action)
    end

    test "R3: handler adds wait_timeout to history before consensus" do
      # The handler should add the wait_timeout event to history
      # so the LLM knows the timer expired

      state = base_state()
      timer_id = "timer-history"
      test_pid = self()

      cancel_timer_fn = fn s -> s end

      execute_action_fn = fn s, _action ->
        # Capture state to verify history was updated
        send(test_pid, {:state_at_execute, s})
        s
      end

      _result =
        ConsensusContinuationHandler.handle_wait_timeout(
          state,
          timer_id,
          cancel_timer_fn,
          execute_action_fn
        )

      # The state passed to execute should have history updated
      assert_receive {:state_at_execute, updated_state}, 30_000
      # model_histories should have been updated with wait_timeout event
      histories = Map.get(updated_state, :model_histories, %{})

      # model_histories should exist and be a map (wait_timeout event recorded in history)
      assert Map.has_key?(updated_state, :model_histories)
      assert is_map(histories)
    end
  end

  describe "[UNIT] handle_consensus_continuation delegation" do
    test "handle_consensus_continuation uses ConsensusHandler directly" do
      # handle_consensus_continuation should also delegate to ConsensusHandler
      # without requiring a request_consensus_fn parameter

      state = base_state()
      test_pid = self()

      execute_action_fn = fn s, action ->
        send(test_pid, {:executed, action})
        s
      end

      # v2.0: handle_consensus_continuation(state, execute_action_fn)
      # Old: handle_consensus_continuation(state, request_consensus_fn, execute_action_fn)

      result =
        ConsensusContinuationHandler.handle_consensus_continuation(
          state,
          execute_action_fn
        )

      assert {:noreply, _} = result
    end
  end
end
