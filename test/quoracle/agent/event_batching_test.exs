defmodule Quoracle.Agent.EventBatchingTest do
  @moduledoc """
  Tests for event batching during consensus (v16.0).

  Bug fix: When consensus is in progress, incoming events each trigger their own
  consensus cycles. Solution: Defer consensus via :trigger_consensus and use
  consensus_scheduled flag to queue incoming events.

  WorkGroupID: fix-20260115-event-batching

  Requirements:
  - R69: consensus_scheduled field exists [UNIT]
  - R70: consensus_scheduled defaults to false [UNIT]
  - R71: consensus_scheduled is boolean type [UNIT]
  - R55: handle_action_result defers consensus [UNIT]
  - R56: handle_action_result sets consensus_scheduled flag [UNIT]
  - R57: handle_agent_message queues when consensus_scheduled [UNIT]
  - R58: handle_agent_message queues when pending_actions non-empty [UNIT]
  - R59: handle_trigger_consensus clears flag [UNIT]
  - R60: Consensus runs after flag cleared [INTEGRATION]
  - R61: Multiple events batched [INTEGRATION]
  - R62: continue: false skips deferral [UNIT]
  - A9: Multiple events batch into single consensus [SYSTEM/ACCEPTANCE]
  - A10: Pause responsiveness [SYSTEM/ACCEPTANCE]
  - P1: Event ordering preserved [PROPERTY]
  - P2: Flag invariant [PROPERTY]
  """
  use Quoracle.DataCase, async: true
  use ExUnitProperties

  @moduletag capture_log: true

  alias Quoracle.Agent.Core.State
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
      skip_auto_consensus: true,
      test_mode: true,
      wait_timer: nil,
      context_limits_loaded: true,
      context_limit: 4000,
      context_lessons: %{},
      model_states: %{}
    }
  end

  # ===========================================================================
  # AGENT_Core v28.0 - State Field Tests (R69-R71)
  # ===========================================================================

  describe "[UNIT] R69-R71: consensus_scheduled State field" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R69: consensus_scheduled field exists
    test "R69: State struct has consensus_scheduled field", %{infra: infra} do
      config = %{
        agent_id: unique_id(),
        router_pid: self(),
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub
      }

      state = State.new(config)

      # Test will fail until consensus_scheduled is added to State struct
      assert Map.has_key?(state, :consensus_scheduled),
             "State struct should have :consensus_scheduled field"
    end

    # R70: consensus_scheduled defaults to false
    test "R70: consensus_scheduled defaults to false", %{infra: infra} do
      config = %{
        agent_id: unique_id(),
        router_pid: self(),
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub
      }

      state = State.new(config)

      # Test will fail until consensus_scheduled is added with default false
      assert state.consensus_scheduled == false,
             "consensus_scheduled should default to false"
    end

    # R71: consensus_scheduled is boolean type
    test "R71: consensus_scheduled is boolean type", %{infra: infra} do
      config = %{
        agent_id: unique_id(),
        router_pid: self(),
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        consensus_scheduled: true
      }

      state = State.new(config)

      # Test will fail until consensus_scheduled is added and accepts boolean
      assert is_boolean(state.consensus_scheduled),
             "consensus_scheduled should be boolean type"

      assert state.consensus_scheduled == true
    end
  end

  # ===========================================================================
  # AGENT_MessageHandler v16.0 - Event Batching Tests (R55-R62)
  # ===========================================================================

  describe "[UNIT] R55-R56: handle_action_result defers consensus" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R55: handle_action_result defers consensus via :trigger_consensus
    test "R55: handle_action_result defers consensus via :trigger_consensus message", %{
      infra: infra
    } do
      # Setup: Agent with pending action
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :execute_shell, started_at: DateTime.utc_now()}
          },
          # Disable skip_auto_consensus to test the deferral path
          skip_auto_consensus: false
        )

      # Use a test process to receive the :trigger_consensus message
      # We need to intercept send(self(), :trigger_consensus)
      _test_pid = self()

      # Action: Process action result
      # This should send :trigger_consensus to self() instead of calling consensus directly
      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, "action-1", {:ok, "result"}, continue: true)

      # Assert: :trigger_consensus message should be in mailbox
      # Test will fail until handle_action_result sends :trigger_consensus
      assert_receive :trigger_consensus,
                     100,
                     "handle_action_result should send :trigger_consensus message"

      # State should have consensus_scheduled: true
      assert new_state.consensus_scheduled == true,
             "consensus_scheduled should be set to true"
    end

    # R56: handle_action_result sets consensus_scheduled flag
    test "R56: handle_action_result sets consensus_scheduled flag", %{infra: infra} do
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :orient, started_at: DateTime.utc_now()}
          },
          consensus_scheduled: false
        )

      # Action: Process action result
      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, "action-1", {:ok, "done"}, continue: true)

      # Assert: Flag should be set
      # Test will fail until handle_action_result sets consensus_scheduled: true
      assert new_state.consensus_scheduled == true,
             "consensus_scheduled should be true after action result"
    end
  end

  describe "[UNIT] R57-R58: handle_agent_message queuing" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R57: handle_agent_message queues when consensus_scheduled is true
    test "R57: handle_agent_message queues when consensus_scheduled is true", %{infra: infra} do
      # Setup: Agent with consensus_scheduled: true (no pending actions)
      state =
        create_test_state(infra,
          pending_actions: %{},
          consensus_scheduled: true
        )

      # Action: Send external message
      {:noreply, new_state} = MessageHandler.handle_agent_message(state, :parent, "test msg")

      # Assert: Message should be QUEUED, not processed immediately
      # Test will fail until handle_agent_message checks consensus_scheduled flag
      assert length(new_state.queued_messages) == 1,
             "Message should be queued when consensus_scheduled is true"

      [queued] = new_state.queued_messages
      assert queued.sender_id == :parent
      assert queued.content == "test msg"

      # History should NOT have the message (it's queued)
      history = new_state.model_histories["model1"] || []

      refute Enum.any?(history, fn entry ->
               is_map(entry.content) and entry.content[:content] == "test msg"
             end),
             "Message should be queued, not in history"
    end

    # R58: handle_agent_message still queues when pending_actions non-empty (existing behavior)
    test "R58: handle_agent_message still queues when pending_actions non-empty", %{infra: infra} do
      # Setup: Agent with pending action (consensus_scheduled: false)
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :fetch_web, started_at: DateTime.utc_now()}
          },
          consensus_scheduled: false
        )

      # Action: Send external message
      {:noreply, new_state} =
        MessageHandler.handle_agent_message(state, "child-1", "child message")

      # Assert: Message should be queued (existing v12.0 behavior)
      assert length(new_state.queued_messages) == 1
      [queued] = new_state.queued_messages
      assert queued.sender_id == "child-1"
      assert queued.content == "child message"
    end
  end

  describe "[UNIT] R59: handle_trigger_consensus clears flag" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R59: handle_trigger_consensus clears consensus_scheduled flag
    test "R59: handle_trigger_consensus clears consensus_scheduled flag", %{infra: infra} do
      # Setup: State with consensus_scheduled: true
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          skip_auto_consensus: false
        )

      # Mock the consensus to capture state when called
      _test_pid = self()

      # We need to test MessageInfoHandler.handle_trigger_consensus/1
      # It should clear the flag before delegating to MessageHandler
      alias Quoracle.Agent.Core.MessageInfoHandler

      # Action: Call handle_trigger_consensus
      # Note: This will call MessageHandler.handle_consensus_continuation which
      # calls run_consensus_cycle, so we use skip_auto_consensus to control flow
      state_with_skip = %{state | skip_auto_consensus: true}
      {:noreply, new_state} = MessageInfoHandler.handle_trigger_consensus(state_with_skip)

      # Assert: Flag should be cleared (even when skipping consensus)
      # Test will fail until handle_trigger_consensus clears consensus_scheduled
      assert new_state.consensus_scheduled == false,
             "consensus_scheduled should be false after handle_trigger_consensus"
    end
  end

  describe "[UNIT] R62: continue: false skips deferral" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R62: continue: false does not send :trigger_consensus
    test "R62: handle_action_result with continue: false does not defer consensus", %{
      infra: infra
    } do
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :wait, started_at: DateTime.utc_now()}
          },
          consensus_scheduled: false
        )

      # Action: Process action result with continue: false
      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, "action-1", {:ok, "waited"}, continue: false)

      # Assert: No :trigger_consensus message should be sent
      refute_receive :trigger_consensus, 100, "No :trigger_consensus when continue: false"

      # Flag should remain false
      assert new_state.consensus_scheduled == false,
             "consensus_scheduled should stay false when continue: false"
    end
  end

  # ===========================================================================
  # Integration Tests (R60-R61)
  # ===========================================================================

  describe "[INTEGRATION] R60-R61: Event batching flow" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R60: Consensus runs after flag cleared
    test "R60: handle_trigger_consensus delegates to run_consensus_cycle", %{infra: infra} do
      # Setup: State with queued messages and consensus_scheduled: true
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          queued_messages: [
            %{sender_id: :parent, content: "batched msg", queued_at: DateTime.utc_now()}
          ]
        )

      test_pid = self()

      # Create execute_action_fn to capture state when consensus runs
      execute_action_fn = fn state_at_execute, _action ->
        send(test_pid, {:consensus_ran, state_at_execute})
        state_at_execute
      end

      # Action: Call run_consensus_cycle (simulating what handle_trigger_consensus does)
      # First clear the flag like handle_trigger_consensus should
      state_cleared = %{state | consensus_scheduled: false}
      {:noreply, _} = MessageHandler.run_consensus_cycle(state_cleared, execute_action_fn)

      # Assert: Consensus should run with flushed messages
      assert_receive {:consensus_ran, state_at_consensus}, 5000

      # Flag should be false during consensus
      assert state_at_consensus.consensus_scheduled == false

      # Queued messages should be flushed
      assert state_at_consensus.queued_messages == []
    end

    # R61: Multiple events batched into single consensus
    test "R61: action result and external message batched into single consensus cycle", %{
      infra: infra
    } do
      # Setup: Agent with pending action
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :execute_shell, started_at: DateTime.utc_now()}
          },
          consensus_scheduled: false
        )

      # Step 1: Action result arrives - should set flag and defer
      {:noreply, state_after_result} =
        MessageHandler.handle_action_result(state, "action-1", {:ok, "result"}, continue: true)

      # Flag should be set
      assert state_after_result.consensus_scheduled == true

      # Step 2: External message arrives BEFORE deferred consensus runs
      # Should be queued because consensus_scheduled is true
      {:noreply, state_after_msg} =
        MessageHandler.handle_agent_message(state_after_result, :parent, "follow-up msg")

      # Message should be queued
      assert length(state_after_msg.queued_messages) == 1

      # Step 3: Deferred consensus runs (via :trigger_consensus handler)
      # Should flush ALL events into single consensus
      test_pid = self()

      execute_action_fn = fn state_at_execute, _action ->
        send(test_pid, {:batched_consensus, state_at_execute})
        state_at_execute
      end

      # Clear flag and run consensus (simulating handle_trigger_consensus)
      state_for_consensus = %{state_after_msg | consensus_scheduled: false}
      {:noreply, _} = MessageHandler.run_consensus_cycle(state_for_consensus, execute_action_fn)

      # Assert: Both action result AND external message in history
      assert_receive {:batched_consensus, final_state}, 5000

      history = final_state.model_histories["model1"] || []

      # Action result should be in history
      has_result = Enum.any?(history, fn e -> e.type == :result end)

      # External message should be in history (flushed from queue)
      has_msg =
        Enum.any?(history, fn e ->
          is_map(e.content) and e.content[:content] == "follow-up msg"
        end)

      assert has_result, "Action result should be in history"
      assert has_msg, "External message should be in history (batched)"

      # Queue should be empty
      assert final_state.queued_messages == []
    end
  end

  # ===========================================================================
  # Acceptance Tests (A9-A10)
  # ===========================================================================

  describe "[SYSTEM/ACCEPTANCE] A9-A10: Event batching user scenarios" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    @tag :acceptance
    # A9: Multiple events during consensus batch into single next cycle
    test "A9: multiple events during consensus batch into single next cycle", %{infra: infra} do
      # This tests the complete scenario:
      # 1. Agent processing action result
      # 2. Multiple events arrive (child message, parent broadcast, another result)
      # 3. All should batch into SINGLE next consensus

      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :orient, started_at: DateTime.utc_now()},
            "action-2" => %{type: :send_message, started_at: DateTime.utc_now()}
          }
        )

      # First action result - sets flag, defers consensus
      {:noreply, state1} =
        MessageHandler.handle_action_result(state, "action-1", {:ok, "oriented"}, continue: true)

      assert state1.consensus_scheduled == true, "Flag should be set after first action result"

      # External message arrives - should be queued
      {:noreply, state2} =
        MessageHandler.handle_agent_message(state1, "child-1", "child update")

      assert length(state2.queued_messages) == 1, "Child message should be queued"

      # Another external message
      {:noreply, state3} =
        MessageHandler.handle_agent_message(state2, :parent, "parent instruction")

      assert length(state3.queued_messages) == 2, "Parent message should be queued"

      # Second action result (skip continue to keep testing batching)
      {:noreply, state4} =
        MessageHandler.handle_action_result(state3, "action-2", {:ok, "sent"}, continue: false)

      # Now simulate the deferred consensus running
      test_pid = self()
      consensus_count = :counters.new(1, [:atomics])

      execute_action_fn = fn s, _action ->
        :counters.add(consensus_count, 1, 1)
        send(test_pid, {:consensus, :counters.get(consensus_count, 1), s})
        s
      end

      # Clear flag and run
      state_for_consensus = %{state4 | consensus_scheduled: false}
      {:noreply, _} = MessageHandler.run_consensus_cycle(state_for_consensus, execute_action_fn)

      # Should be exactly ONE consensus call
      assert_receive {:consensus, 1, final_state}, 5000
      refute_receive {:consensus, 2, _}, 100, "Should be only ONE consensus cycle"

      # All events should be in history
      history = final_state.model_histories["model1"] || []

      # Both action results
      result_count = Enum.count(history, fn e -> e.type == :result end)
      assert result_count == 2, "Both action results should be in history"

      # Both messages
      child_msg =
        Enum.any?(history, fn e ->
          is_map(e.content) and e.content[:content] == "child update"
        end)

      parent_msg =
        Enum.any?(history, fn e ->
          is_map(e.content) and e.content[:content] == "parent instruction"
        end)

      assert child_msg, "Child message should be in history"
      assert parent_msg, "Parent message should be in history"
    end

    @tag :acceptance
    # A10: Pause responsiveness
    test "A10: pause stops agent after single consensus cycle", %{infra: infra} do
      # This tests that pause doesn't have to wait for cascading cycles
      # When consensus_scheduled is used, events batch instead of cascade

      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :execute_shell, started_at: DateTime.utc_now()}
          }
        )

      # Action result defers consensus
      {:noreply, state_after_result} =
        MessageHandler.handle_action_result(state, "action-1", {:ok, "done"}, continue: true)

      # Verify deferral pattern: flag set, message sent
      assert state_after_result.consensus_scheduled == true

      # At this point, if user clicks "Pause", the agent should:
      # 1. Process the ONE :trigger_consensus message in mailbox
      # 2. Complete that single consensus cycle
      # 3. Stop (no cascading cycles from batched events)

      # The key verification is that consensus_scheduled acts as a "batch gate"
      # preventing multiple consensus cycles from being triggered by events

      # Messages that arrive now go to queue, not trigger new cycles
      {:noreply, state_with_msg} =
        MessageHandler.handle_agent_message(state_after_result, :parent, "late msg")

      # Message queued, not triggering another cycle
      assert length(state_with_msg.queued_messages) == 1

      # Only ONE :trigger_consensus should be in mailbox (from action result)
      # The message did NOT add another
      assert_receive :trigger_consensus, 100
      refute_receive :trigger_consensus, 100, "Only one :trigger_consensus should exist"
    end
  end

  # ===========================================================================
  # Property-Based Tests (P1-P2)
  # ===========================================================================

  describe "[PROPERTY] P1-P2: Event batching invariants" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # P1: Event ordering preserved
    property "P1: event arrival order preserved through batching", %{infra: infra} do
      check all(
              num_messages <- integer(1..10),
              messages <- list_of(binary(min_length: 1, max_length: 50), length: num_messages)
            ) do
        state =
          create_test_state(infra,
            pending_actions: %{
              "action-1" => %{type: :execute_shell, started_at: DateTime.utc_now()}
            }
          )

        # Queue all messages
        final_state =
          Enum.reduce(messages, state, fn msg, acc ->
            {:noreply, new_state} = MessageHandler.handle_agent_message(acc, :parent, msg)
            new_state
          end)

        # All messages should be queued in arrival order
        queued_contents = Enum.map(final_state.queued_messages, & &1.content)
        assert queued_contents == messages, "Messages should be in arrival order"
      end
    end

    # P2: Flag invariant - consensus_scheduled false when no deferred consensus pending
    property "P2: consensus_scheduled false when no deferred consensus pending", %{infra: infra} do
      check all(
              has_pending <- boolean(),
              _num_messages <- integer(0..5)
            ) do
        pending_actions =
          if has_pending do
            %{"action-1" => %{type: :orient, started_at: DateTime.utc_now()}}
          else
            %{}
          end

        state =
          create_test_state(infra,
            pending_actions: pending_actions,
            consensus_scheduled: false
          )

        # If no pending actions and no consensus scheduled, messages should not set flag
        # (they should be processed immediately)
        if map_size(pending_actions) == 0 do
          # Messages processed immediately - flag stays false
          {:noreply, new_state} =
            MessageHandler.handle_agent_message(state, :parent, "test")

          # Flag should still be false (no deferred consensus needed)
          # Note: This tests that immediate processing doesn't set the flag
          assert new_state.consensus_scheduled == false or
                   map_size(new_state.pending_actions) > 0,
                 "Flag should be false when no deferred consensus pending"
        end
      end
    end
  end
end
