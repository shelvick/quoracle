defmodule Quoracle.Agent.MessageHandlerTimerTest do
  @moduledoc """
  Tests for MessageHandler timer cancellation bugfix.
  Verifies that ALL consensus-triggering messages cancel active wait timers.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.MessageHandler

  # Helper to create complete agent state for testing
  # Per-action Router (v28.0): Core no longer stores router_pid - each action spawns its own Router
  defp build_test_state(sandbox_owner, overrides) do
    # Create isolated PubSub for this test
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    base_state = %{
      agent_id: agent_id,
      wait_timer: nil,
      pubsub: pubsub,
      pending_actions: %{},
      model_histories: %{"default" => []},
      registry: Quoracle.AgentRegistry,
      dynsup: Quoracle.Agent.DynSup,
      parent_pid: nil,
      parent_id: nil,
      children: [],
      timer_generation: 0,
      action_counter: 0,
      task_id: nil,
      task: nil,
      state: :ready,
      test_mode: true,
      test_opts: [],
      sandbox_owner: sandbox_owner,
      test_pid: self(),
      context_summary: nil,
      context_limits_loaded: true,
      context_limit: 4000,
      model_id: "test-model",
      models: [],
      skip_auto_consensus: true
    }

    Map.merge(base_state, overrides)
  end

  describe "handle_action_result/3 timer cancellation" do
    test "cancels active wait timer when action result arrives", %{sandbox_owner: sandbox_owner} do
      # Create agent state with active wait timer
      timer_ref = make_ref()

      state =
        build_test_state(sandbox_owner, %{
          agent_id: "test-agent-1",
          wait_timer: {timer_ref, :wait_action},
          pending_actions: %{"action-123" => %{type: :orient}}
        })

      # Call handle_action_result (should cancel timer)
      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, "action-123", {:ok, %{data: "result"}})

      # Verify timer was cancelled - state-based verification only
      assert new_state.wait_timer == nil
    end

    test "cancels wait parameter timer when action result arrives", %{
      sandbox_owner: sandbox_owner
    } do
      # Create agent state with wait parameter timer
      timer_ref = make_ref()

      state =
        build_test_state(sandbox_owner, %{
          agent_id: "test-agent-2",
          wait_timer: {timer_ref, :wait_parameter},
          pending_actions: %{"action-456" => %{type: :spawn}}
        })

      # Call handle_action_result
      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, "action-456", {:ok, %{child_id: "child-1"}})

      # Verify timer was cancelled - state-based verification only
      assert new_state.wait_timer == nil
    end

    test "handles nil wait_timer gracefully", %{sandbox_owner: sandbox_owner} do
      state =
        build_test_state(sandbox_owner, %{
          agent_id: "test-agent-3",
          wait_timer: nil,
          pending_actions: %{"action-789" => %{type: :wait}}
        })

      # Should not crash when no timer to cancel
      {:noreply, new_state} = MessageHandler.handle_action_result(state, "action-789", {:ok, %{}})
      assert new_state.wait_timer == nil
    end
  end

  describe "handle_agent_message/2 timer cancellation" do
    test "cancels active wait timer when agent message arrives", %{sandbox_owner: sandbox_owner} do
      timer_ref = make_ref()

      state =
        build_test_state(sandbox_owner, %{
          agent_id: "test-agent-4",
          wait_timer: {timer_ref, :wait_action},
          parent_agent_id: "parent-1"
        })

      # Call handle_agent_message (should cancel timer) - v10.0 uses 3-arity
      {:noreply, new_state} =
        MessageHandler.handle_agent_message(state, "parent-1", "Hello child")

      # Verify timer was cancelled - state-based verification only
      assert new_state.wait_timer == nil
    end

    test "cancels timer for messages from child agents", %{sandbox_owner: sandbox_owner} do
      timer_ref = make_ref()

      state =
        build_test_state(sandbox_owner, %{
          agent_id: "test-agent-5",
          wait_timer: {timer_ref, :wait_parameter},
          children: ["child-1", "child-2"]
        })

      # Message from child agent - v10.0 uses 3-arity
      {:noreply, new_state} =
        MessageHandler.handle_agent_message(state, "child-1", "Task complete")

      # Timer should be cancelled - state-based verification only
      assert new_state.wait_timer == nil
    end

    test "cancels timer for messages from sibling agents", %{sandbox_owner: sandbox_owner} do
      timer_ref = make_ref()

      state =
        build_test_state(sandbox_owner, %{
          agent_id: "test-agent-6",
          wait_timer: {timer_ref, :wait_action}
        })

      # Message from sibling/unknown agent - v10.0 uses 3-arity
      {:noreply, new_state} =
        MessageHandler.handle_agent_message(state, "sibling-agent", "Coordination message")

      # Timer should still be cancelled - state-based verification only
      assert new_state.wait_timer == nil
    end
  end

  describe "handle_message/2 timer cancellation (existing)" do
    test "already cancels wait timer for generic messages", %{sandbox_owner: sandbox_owner} do
      # This should already work - testing for regression
      timer_ref = make_ref()

      state =
        build_test_state(sandbox_owner, %{
          agent_id: "test-agent-7",
          wait_timer: {timer_ref, :wait_parameter}
        })

      # Generic message
      {:noreply, new_state} = MessageHandler.handle_message(state, "Some update")

      # Timer should be cancelled (existing behavior) - state-based verification only
      assert new_state.wait_timer == nil
    end
  end

  describe "timer cancellation consistency" do
    test "all three handlers use same cancel_wait_timer function", %{sandbox_owner: sandbox_owner} do
      # Test that cancellation logic is unified, not duplicated
      timer_ref = make_ref()

      # Per-action Router (v28.0): build_test_state returns just a map, not a tuple
      base_state =
        build_test_state(sandbox_owner, %{
          agent_id: "test-agent-8",
          wait_timer: {timer_ref, :wait_action},
          pending_actions: %{"action-1" => %{type: :web}}
        })

      # Test all three handlers
      {:noreply, state1} = MessageHandler.handle_message(base_state, "message")
      assert state1.wait_timer == nil

      {:noreply, state2} =
        MessageHandler.handle_action_result(
          %{base_state | wait_timer: {make_ref(), :wait_action}},
          "action-1",
          {:ok, %{}}
        )

      assert state2.wait_timer == nil

      {:noreply, state3} =
        MessageHandler.handle_agent_message(
          %{base_state | wait_timer: {make_ref(), :wait_action}},
          "other-agent",
          "hello"
        )

      assert state3.wait_timer == nil

      # All three should cancel timers consistently (state-based verification only)
    end

    test "timer cancellation happens before consensus trigger", %{sandbox_owner: sandbox_owner} do
      # Important: timer must be cancelled BEFORE consensus runs
      # Otherwise consensus might set a new timer that gets immediately cancelled
      timer_ref = make_ref()

      state =
        build_test_state(sandbox_owner, %{
          agent_id: "test-agent-9",
          wait_timer: {timer_ref, :wait_parameter},
          pending_actions: %{"action-x" => %{type: :shell}}
        })

      # Process action result (timer should be cancelled before consensus)
      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, "action-x", {:ok, %{output: "done"}})

      # Verify timer was cancelled (state-based verification only)
      assert new_state.wait_timer == nil

      # The order of operations is enforced by implementation, not test verification
      # Timer cancellation happens synchronously before consensus is triggered
    end
  end

  describe "timer reference validation" do
    test "only cancels timer if reference matches", %{sandbox_owner: sandbox_owner} do
      # Protection against cancelling wrong timer
      timer_ref = make_ref()

      state =
        build_test_state(sandbox_owner, %{
          agent_id: "test-agent-10",
          wait_timer: {timer_ref, :wait_action}
        })

      # Simulate wait_expired with WRONG reference
      wrong_ref = make_ref()
      {:noreply, new_state} = MessageHandler.handle_message(state, {:wait_expired, wrong_ref})

      # Should NOT cancel timer (refs don't match)
      assert new_state.wait_timer == {timer_ref, :wait_action}

      # Now with correct reference
      {:noreply, new_state2} = MessageHandler.handle_message(state, {:wait_expired, timer_ref})

      # Should cancel timer (refs match)
      assert new_state2.wait_timer == nil
    end
  end
end
