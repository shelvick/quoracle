defmodule Quoracle.Agent.MessageBatchingTest do
  @moduledoc """
  Tests for message batching in MessageHandler.

  v2.0: History alternation race condition fix (fix-20251231-history-alternation)
  v3.0: Deferred consensus for idle agents (fix-20260116-234557)
  v4.0: Trigger drain for message batching (fix-20260118-trigger-drain-pause)

  Verifies that:
  - External messages during action execution are queued and flushed atomically
  - Messages to idle agents are batched via deferred consensus
  - handle_send_user_message delegates to handle_agent_message
  - Multiple :trigger_consensus messages are drained before consensus (v4.0)
  """
  use Quoracle.DataCase, async: true
  use ExUnitProperties

  @moduletag capture_log: true

  alias Quoracle.Agent.Core.State
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
    skip_auto_consensus = Keyword.get(opts, :skip_auto_consensus, true)
    # v4.0: Allow overriding these fields from opts (was hardcoded, causing test failures)
    consensus_scheduled = Keyword.get(opts, :consensus_scheduled, false)
    wait_timer = Keyword.get(opts, :wait_timer, nil)
    model_histories = Keyword.get(opts, :model_histories, %{"model1" => []})
    models = Keyword.get(opts, :models, ["model1"])

    %{
      agent_id: agent_id,
      task_id: agent_id,
      router_pid: self(),
      parent_pid: Keyword.get(opts, :parent_pid, nil),
      registry: infra.registry,
      dynsup: infra.dynsup,
      pubsub: infra.pubsub,
      model_histories: model_histories,
      models: models,
      pending_actions: pending_actions,
      skip_auto_consensus: skip_auto_consensus,
      test_mode: true,
      wait_timer: wait_timer,
      # Required for ContextHelpers.ensure_context_ready/1
      context_limits_loaded: true,
      context_limit: 4000,
      # v2.0: Queue field for history alternation fix
      queued_messages: [],
      # v3.0: Deferred consensus flag
      consensus_scheduled: consensus_scheduled
    }
  end

  describe "Core.State queued_messages field (R13-R14)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R13: queued_messages Initialized
    test "Core.State initializes queued_messages as empty list", %{infra: infra} do
      config = %{
        agent_id: unique_id(),
        router_pid: self(),
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub
      }

      state = State.new(config)

      # R13: queued_messages defaults to empty list
      assert state.queued_messages == []
    end

    # R14: queued_messages Type
    test "queued message has required fields", %{infra: infra} do
      config = %{
        agent_id: unique_id(),
        router_pid: self(),
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        queued_messages: [
          %{
            sender_id: :parent,
            content: "test message",
            queued_at: DateTime.utc_now()
          }
        ]
      }

      state = State.new(config)

      # R14: Entry contains sender_id, content, queued_at
      [queued_msg] = state.queued_messages
      assert Map.has_key?(queued_msg, :sender_id)
      assert Map.has_key?(queued_msg, :content)
      assert Map.has_key?(queued_msg, :queued_at)
      assert queued_msg.sender_id == :parent
      assert queued_msg.content == "test message"
    end
  end

  describe "queue when pending (R1)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R1: Queue When Pending
    test "queues external message when action is pending", %{infra: infra} do
      # Setup: Agent with pending action
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :execute_shell, started_at: DateTime.utc_now()}
          }
        )

      # Action: Send external message via handle_agent_message
      {:noreply, new_state} = MessageHandler.handle_agent_message(state, :parent, "queued msg")

      # Assert: Message in queued_messages, NOT in history
      assert length(new_state.queued_messages) == 1
      [queued] = new_state.queued_messages
      assert queued.sender_id == :parent
      assert queued.content == "queued msg"
      assert %DateTime{} = queued.queued_at

      # History should NOT have the message yet (queued, not added)
      history = new_state.model_histories["model1"] || []
      refute Enum.any?(history, fn entry -> entry.content == "queued msg" end)
    end
  end

  describe "immediate when empty (R2)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R2: Immediate When Empty
    test "triggers consensus immediately when no actions pending", %{infra: infra} do
      # Setup: Agent with empty pending_actions
      state = create_test_state(infra, pending_actions: %{})

      # Action: Send external message
      {:noreply, new_state} = MessageHandler.handle_agent_message(state, :parent, "immediate msg")

      # Assert: queued_messages should be empty (not queued)
      assert new_state.queued_messages == []

      # Message should be in history (processed immediately)
      history = new_state.model_histories["model1"] || []

      assert Enum.any?(history, fn entry ->
               is_map(entry.content) and entry.content[:content] == "immediate msg"
             end)
    end
  end

  describe "flush on result (R3-R6)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R3: Flush on Result
    test "flushes queued messages when action result arrives", %{infra: infra} do
      # Setup: Agent with queued message and pending action
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :execute_shell, started_at: DateTime.utc_now()}
          }
        )

      # Queue a message first
      state = %{
        state
        | queued_messages: [
            %{sender_id: :parent, content: "queued during action", queued_at: DateTime.utc_now()}
          ]
      }

      # Action: Send action result
      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, "action-1", {:ok, "result"}, continue: false)

      # Assert: Queued message now in history
      history = new_state.model_histories["model1"] || []

      assert Enum.any?(history, fn entry ->
               is_map(entry.content) and entry.content[:content] == "queued during action"
             end)
    end

    # R4: Flush Order (Result First)
    test "action result precedes queued messages in history", %{infra: infra} do
      # Setup: Agent with queued message and pending action
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :execute_shell, started_at: DateTime.utc_now()}
          }
        )

      state = %{
        state
        | queued_messages: [
            %{sender_id: :parent, content: "queued msg", queued_at: DateTime.utc_now()}
          ]
      }

      # Action: Send action result
      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, "action-1", {:ok, "result"}, continue: false)

      # Assert: Result entry before message entry in history
      history = new_state.model_histories["model1"] || []

      result_idx =
        Enum.find_index(history, fn entry ->
          entry.type == :result
        end)

      msg_idx =
        Enum.find_index(history, fn entry ->
          is_map(entry.content) and entry.content[:content] == "queued msg"
        end)

      assert result_idx != nil, "Result entry not found in history"
      assert msg_idx != nil, "Queued message entry not found in history"
      # History is prepended, so result (added first) should have HIGHER index
      assert result_idx > msg_idx, "Result should precede queued message (prepended order)"
    end

    # R5: Queue Order Preserved
    test "queued messages maintain FIFO order during flush", %{infra: infra} do
      # Setup: Agent with multiple queued messages
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :execute_shell, started_at: DateTime.utc_now()}
          }
        )

      state = %{
        state
        | queued_messages: [
            %{sender_id: :parent, content: "first", queued_at: DateTime.utc_now()},
            %{sender_id: "child-1", content: "second", queued_at: DateTime.utc_now()},
            %{sender_id: :parent, content: "third", queued_at: DateTime.utc_now()}
          ]
      }

      # Action: Send action result
      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, "action-1", {:ok, "done"}, continue: false)

      # Assert: Messages in history in arrival order (FIFO)
      history = new_state.model_histories["model1"] || []

      # Find indices of the queued messages in history
      first_idx =
        Enum.find_index(history, fn e ->
          is_map(e.content) and e.content[:content] == "first"
        end)

      second_idx =
        Enum.find_index(history, fn e ->
          is_map(e.content) and e.content[:content] == "second"
        end)

      third_idx =
        Enum.find_index(history, fn e ->
          is_map(e.content) and e.content[:content] == "third"
        end)

      assert first_idx != nil and second_idx != nil and third_idx != nil

      # History is prepended, so FIFO order means first has highest idx, third has lowest
      assert first_idx > second_idx, "First should be before second (prepended)"
      assert second_idx > third_idx, "Second should be before third (prepended)"
    end

    # R6: Queue Cleared
    test "queue is empty after flush", %{infra: infra} do
      # Setup: Agent with queued messages
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :fetch_web, started_at: DateTime.utc_now()}
          }
        )

      state = %{
        state
        | queued_messages: [
            %{sender_id: :parent, content: "msg1", queued_at: DateTime.utc_now()},
            %{sender_id: :parent, content: "msg2", queued_at: DateTime.utc_now()}
          ]
      }

      # Action: Send action result
      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, "action-1", {:ok, "data"}, continue: false)

      # Assert: queued_messages is empty list
      assert new_state.queued_messages == []
    end
  end

  describe "timeout/error triggers flush (R7-R8)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R7: Timeout Triggers Flush
    test "action timeout flushes queued messages", %{infra: infra} do
      # Setup: Agent with queued message and pending action
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :execute_shell, started_at: DateTime.utc_now()}
          }
        )

      state = %{
        state
        | queued_messages: [
            %{sender_id: :parent, content: "queued before timeout", queued_at: DateTime.utc_now()}
          ]
      }

      # Action: Send timeout result (error tuple with :timeout)
      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, "action-1", {:error, :timeout},
          continue: false
        )

      # Assert: Queued message flushed to history
      history = new_state.model_histories["model1"] || []

      assert Enum.any?(history, fn entry ->
               is_map(entry.content) and entry.content[:content] == "queued before timeout"
             end)

      # Queue should be empty
      assert new_state.queued_messages == []
    end

    # R8: Error Result Triggers Flush
    test "action error result flushes queued messages", %{infra: infra} do
      # Setup: Agent with queued message and pending action
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :call_api, started_at: DateTime.utc_now()}
          }
        )

      state = %{
        state
        | queued_messages: [
            %{sender_id: "child-1", content: "queued before error", queued_at: DateTime.utc_now()}
          ]
      }

      # Action: Send error result
      {:noreply, new_state} =
        MessageHandler.handle_action_result(
          state,
          "action-1",
          {:error, "API failed"},
          continue: false
        )

      # Assert: Queued message flushed to history
      history = new_state.model_histories["model1"] || []

      assert Enum.any?(history, fn entry ->
               is_map(entry.content) and entry.content[:content] == "queued before error"
             end)

      # Queue should be empty
      assert new_state.queued_messages == []
    end
  end

  describe "race condition scenarios (R9-R11)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R9: Concurrent Message During Action
    test "message during action execution included in consensus", %{infra: infra} do
      # Setup: Agent executing action (pending_actions non-empty)
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :execute_shell, started_at: DateTime.utc_now()}
          }
        )

      # Action: Send external message during execution
      {:noreply, state_after_msg} =
        MessageHandler.handle_agent_message(state, :parent, "concurrent msg")

      # Verify message was queued, not added to history
      assert length(state_after_msg.queued_messages) == 1

      # Action: Complete action
      {:noreply, final_state} =
        MessageHandler.handle_action_result(
          state_after_msg,
          "action-1",
          {:ok, "done"},
          continue: false
        )

      # Assert: Both result and message in history for next consensus
      history = final_state.model_histories["model1"] || []

      has_result = Enum.any?(history, fn e -> e.type == :result end)

      has_msg =
        Enum.any?(history, fn e ->
          is_map(e.content) and e.content[:content] == "concurrent msg"
        end)

      assert has_result, "Action result should be in history"
      assert has_msg, "Concurrent message should be in history"
    end

    # R10: Multiple Messages During Action
    test "multiple messages during action all included in consensus", %{infra: infra} do
      # Setup: Agent executing action
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :fetch_web, started_at: DateTime.utc_now()}
          }
        )

      # Action: Send 3 external messages during execution
      {:noreply, state1} = MessageHandler.handle_agent_message(state, :parent, "msg1")
      {:noreply, state2} = MessageHandler.handle_agent_message(state1, "child-1", "msg2")
      {:noreply, state3} = MessageHandler.handle_agent_message(state2, :parent, "msg3")

      # Verify all 3 queued
      assert length(state3.queued_messages) == 3

      # Action: Complete action
      {:noreply, final_state} =
        MessageHandler.handle_action_result(state3, "action-1", {:ok, "web data"},
          continue: false
        )

      # Assert: All messages in history
      history = final_state.model_histories["model1"] || []

      msg1_found =
        Enum.any?(history, fn e -> is_map(e.content) and e.content[:content] == "msg1" end)

      msg2_found =
        Enum.any?(history, fn e -> is_map(e.content) and e.content[:content] == "msg2" end)

      msg3_found =
        Enum.any?(history, fn e -> is_map(e.content) and e.content[:content] == "msg3" end)

      assert msg1_found, "msg1 should be in history"
      assert msg2_found, "msg2 should be in history"
      assert msg3_found, "msg3 should be in history"

      # Queue should be empty after flush
      assert final_state.queued_messages == []
    end

    # R11: No Alternation Error
    test "race scenario does not cause alternation error", %{infra: infra} do
      # Setup: Agent executing action
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :execute_shell, started_at: DateTime.utc_now()}
          }
        )

      # Simulate race: message arrives during action
      {:noreply, state_with_queued} =
        MessageHandler.handle_agent_message(state, :parent, "race msg")

      # Complete action (triggers flush)
      {:noreply, final_state} =
        MessageHandler.handle_action_result(
          state_with_queued,
          "action-1",
          {:ok, "result"},
          continue: false
        )

      # Assert: History is valid - ends with user-role content (event), not assistant
      history = final_state.model_histories["model1"] || []

      # The last entry should be the queued message (user-role event)
      # Not the action result (which could be seen as assistant-role)
      [latest_entry | _] = history

      # Event type = user role in LLM parlance
      assert latest_entry.type == :event,
             "Latest history entry should be :event type (user role), not #{latest_entry.type}"

      # No alternation error means we can safely call consensus
      # (We don't actually call it here since skip_auto_consensus is true)
      assert is_list(history)
      assert length(history) >= 2
    end
  end

  describe "dead code removal (R12)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R12: No pending_batch in State
    test "pending_batch dead code removed from request_consensus" do
      state = %{
        agent_id: unique_id(),
        model_histories: %{"default" => []},
        models: ["model1"],
        pubsub: :test_pubsub,
        test_mode: true
      }

      # Send some messages to mailbox that would trigger pending_batch creation
      send(self(), {:action_result, "id-1", {:ok, "result"}})
      send(self(), {:agent_message, :parent, "hello"})

      # Call request_consensus with a mock consensus_fn that captures state
      table_name = :"captured_state_#{System.unique_integer([:positive])}"
      captured_state = :ets.new(table_name, [:set, :public])

      mock_consensus_fn = fn state_with_pending ->
        :ets.insert(captured_state, {:state, state_with_pending})
        {:ok, %{action: :wait, params: %{}, wait: true}}
      end

      MessageHandler.request_consensus(state, consensus_fn: mock_consensus_fn)

      # Retrieve the state that was passed to consensus
      [{:state, actual_state}] = :ets.lookup(captured_state, :state)
      :ets.delete(captured_state)

      # Assert: State does NOT contain :pending_batch key
      refute Map.has_key?(actual_state, :pending_batch),
             "pending_batch should be removed from request_consensus (dead code)"
    end
  end

  # ==========================================================================
  # v3.0 Tests: Deferred Consensus for Idle Agents (fix-20260116-234557)
  # ==========================================================================

  describe "deferred consensus for idle agents (v3.0)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R70: Idle Agent Defers Consensus
    test "idle agent defers consensus via :trigger_consensus message", %{infra: infra} do
      # Setup: Agent with empty pending_actions AND consensus_scheduled=false
      # We use skip_auto_consensus: true initially to verify the state setup
      state = create_test_state(infra, pending_actions: %{})

      # Manually set skip_auto_consensus to false to test the deferred path
      # After the fix, this should set consensus_scheduled=true and send :trigger_consensus
      # instead of calling consensus synchronously
      state = %{state | skip_auto_consensus: false, consensus_scheduled: false}

      # Action: Call handle_agent_message (idle agent path)
      # NOTE: This will FAIL with current impl because consensus runs synchronously
      # After the fix, it should return immediately with consensus_scheduled=true
      {:noreply, new_state} = MessageHandler.handle_agent_message(state, :parent, "test msg")

      # Assert: consensus_scheduled should be true (deferred, not immediate)
      # This will FAIL because current impl doesn't set this flag for idle agents
      assert new_state.consensus_scheduled == true,
             "Idle agent should set consensus_scheduled=true to defer consensus"

      # Assert: :trigger_consensus message should be in process mailbox
      assert_receive :trigger_consensus,
                     100,
                     "Idle agent should send :trigger_consensus to self"
    end

    # R71: User Message Broadcasts to UI
    test "handle_send_user_message broadcasts to UI for root agent", %{infra: infra} do
      # Setup: Root agent (parent_pid = nil is default in create_test_state)
      state = create_test_state(infra, pending_actions: %{})
      task_id = state.task_id

      # Subscribe to UI broadcasts
      # AgentEvents.broadcast_log uses "agents:#{agent_id}:logs"
      # AgentEvents.broadcast_user_message uses "tasks:#{task_id}:messages"
      Phoenix.PubSub.subscribe(infra.pubsub, "agents:#{state.agent_id}:logs")
      Phoenix.PubSub.subscribe(infra.pubsub, "tasks:#{task_id}:messages")

      # Action: Call handle_send_user_message
      {:noreply, _new_state} = MessageHandler.handle_send_user_message(state, "Hello user!")

      # Assert: AgentEvents.broadcast_log called (log event received)
      # Format is {:log_entry, %{...}} per AgentEvents implementation
      assert_receive {:log_entry, log_event}, 500
      assert log_event.level == :info
      assert log_event.message =~ "Sending message to user"

      # Assert: AgentEvents.broadcast_user_message called
      # Format is {:agent_message, %{...}} per AgentEvents implementation
      assert_receive {:agent_message, msg_event}, 500
      assert msg_event.content == "Hello user!"
    end

    # R72: User Message Delegates to handle_agent_message
    test "handle_send_user_message delegates to handle_agent_message", %{infra: infra} do
      # Setup: Agent with skip_auto_consensus: true (to observe state change without consensus)
      state = create_test_state(infra, pending_actions: %{})

      # Action: Call handle_send_user_message
      {:noreply, new_state} = MessageHandler.handle_send_user_message(state, "delegated msg")

      # Assert: History contains message with from: "user"
      # This proves delegation because handle_send_user_message should use :user sender_id
      # Current impl uses from: "parent" - this test will FAIL until delegation is implemented
      history = new_state.model_histories["model1"] || []

      user_msg =
        Enum.find(history, fn entry ->
          is_map(entry.content) and entry.content[:from] == "user"
        end)

      assert user_msg != nil,
             "History should contain message with from: 'user' (delegation to handle_agent_message with :user sender_id)"

      assert user_msg.content[:content] == "delegated msg"
    end

    # R73: User Sender Formatting
    test "format_sender_id handles :user atom", %{infra: infra} do
      # Test private function indirectly via handle_agent_message
      # Setup: Agent with skip_auto_consensus: true
      state = create_test_state(infra, pending_actions: %{})

      # Action: Call handle_agent_message with :user sender_id
      {:noreply, new_state} = MessageHandler.handle_agent_message(state, :user, "user message")

      # Assert: History entry has from: "user"
      history = new_state.model_histories["model1"] || []

      user_entry =
        Enum.find(history, fn entry ->
          is_map(entry.content) and entry.content[:from] == "user"
        end)

      assert user_entry != nil, "History should contain entry with from: 'user'"
      assert user_entry.content[:content] == "user message"
    end

    # R75: Non-Blocking Return
    test "handle_agent_message returns immediately when deferring consensus", %{infra: infra} do
      # Setup: Idle agent (no pending actions, no consensus scheduled)
      state = create_test_state(infra, pending_actions: %{})
      state = %{state | skip_auto_consensus: false, consensus_scheduled: false}

      # Action: Call handle_agent_message, measure time
      # With current impl, this BLOCKS on consensus - test will FAIL
      # After fix, should return in < 10ms with consensus_scheduled=true
      {elapsed_microseconds, {:noreply, new_state}} =
        :timer.tc(fn ->
          MessageHandler.handle_agent_message(state, :parent, "timing test")
        end)

      # Assert: Returns in < 10ms (10_000 microseconds)
      # This will FAIL because current impl calls consensus synchronously
      assert elapsed_microseconds < 10_000,
             "handle_agent_message should return immediately (#{elapsed_microseconds}µs), not block on consensus"

      # After fix: should have set consensus_scheduled and sent :trigger_consensus
      assert new_state.consensus_scheduled == true
      assert_receive :trigger_consensus, 100
    end
  end

  describe "rapid message batching (v3.0)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R74: Rapid Messages Batched
    # This test verifies that when M1 sets consensus_scheduled=true, M2 is queued
    test "two rapid messages to idle agent batched into single consensus", %{infra: infra} do
      # Setup: Idle agent
      state = create_test_state(infra, pending_actions: %{})
      state = %{state | skip_auto_consensus: false, consensus_scheduled: false}

      # Action: Send first message (should trigger deferred consensus)
      # With current impl, this BLOCKS - test will FAIL
      {:noreply, state_after_m1} =
        MessageHandler.handle_agent_message(state, :parent, "first message")

      # M1 should set consensus_scheduled = true (NEW BEHAVIOR)
      # This will FAIL because current impl doesn't set this flag
      assert state_after_m1.consensus_scheduled == true,
             "First message to idle agent should set consensus_scheduled=true"

      # Action: Send second message rapidly (should be QUEUED because consensus_scheduled)
      {:noreply, state_after_m2} =
        MessageHandler.handle_agent_message(state_after_m1, :parent, "second message")

      # Assert: Second message should be queued (because consensus_scheduled is true)
      assert length(state_after_m2.queued_messages) == 1,
             "Second message should be queued when consensus_scheduled is true"

      [queued] = state_after_m2.queued_messages
      assert queued.content == "second message"

      # Assert: First message should be in history already
      history = state_after_m2.model_histories["model1"] || []

      first_in_history =
        Enum.any?(history, fn e ->
          is_map(e.content) and e.content[:content] == "first message"
        end)

      assert first_in_history, "First message should be in history"

      # Drain :trigger_consensus
      assert_receive :trigger_consensus, 500
    end

    test "three rapid messages all batched together", %{infra: infra} do
      # Setup: Idle agent
      state = create_test_state(infra, pending_actions: %{})
      state = %{state | skip_auto_consensus: false, consensus_scheduled: false}

      # Action: Send three messages rapidly
      # With current impl, msg1 BLOCKS on consensus - test will FAIL
      {:noreply, s1} = MessageHandler.handle_agent_message(state, :parent, "msg1")

      # This will FAIL because s1 never returns (consensus blocks)
      assert s1.consensus_scheduled == true, "msg1 should set consensus_scheduled=true"

      {:noreply, s2} = MessageHandler.handle_agent_message(s1, :parent, "msg2")
      {:noreply, s3} = MessageHandler.handle_agent_message(s2, :parent, "msg3")

      # Assert: msg1 in history, msg2 and msg3 queued
      history = s3.model_histories["model1"] || []

      msg1_in_history =
        Enum.any?(history, fn e -> is_map(e.content) and e.content[:content] == "msg1" end)

      assert msg1_in_history, "msg1 should be in history"

      # msg2 and msg3 should be queued
      assert length(s3.queued_messages) == 2, "msg2 and msg3 should be queued"
      contents = Enum.map(s3.queued_messages, & &1.content)
      assert "msg2" in contents
      assert "msg3" in contents

      # Drain :trigger_consensus
      assert_receive :trigger_consensus, 500
    end

    test "message order preserved in batched consensus", %{infra: infra} do
      # Setup: Idle agent
      state = create_test_state(infra, pending_actions: %{})
      state = %{state | skip_auto_consensus: false, consensus_scheduled: false}

      # Action: Send M1, M2, M3 rapidly
      # With current impl, M1 BLOCKS on consensus - test will FAIL
      {:noreply, s1} = MessageHandler.handle_agent_message(state, :parent, "M1")

      assert s1.consensus_scheduled == true, "M1 should set consensus_scheduled=true"

      {:noreply, s2} = MessageHandler.handle_agent_message(s1, "child-1", "M2")
      {:noreply, s3} = MessageHandler.handle_agent_message(s2, :parent, "M3")

      # Assert: Queue maintains FIFO order (M2 before M3)
      assert length(s3.queued_messages) == 2
      [first_queued, second_queued] = s3.queued_messages
      assert first_queued.content == "M2", "First queued should be M2"
      assert second_queued.content == "M3", "Second queued should be M3"

      # Drain :trigger_consensus
      assert_receive :trigger_consensus, 500
    end
  end

  describe "mixed event batching (v3.0)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # A14: User Message After Action Result
    # This test verifies existing v16.0 behavior - action result sets consensus_scheduled
    test "user message during action result processing batched together", %{infra: infra} do
      # Setup: Agent with pending action
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :execute_shell, started_at: DateTime.utc_now()}
          }
        )

      state = %{state | skip_auto_consensus: false, consensus_scheduled: false}

      # Action: Send action result (sets consensus_scheduled via deferred consensus)
      # This is EXISTING v16.0 behavior and should work
      {:noreply, state_after_result} =
        MessageHandler.handle_action_result(state, "action-1", {:ok, "done"})

      # After action result, consensus_scheduled should be true (v16.0 behavior)
      assert state_after_result.consensus_scheduled == true,
             "Action result should set consensus_scheduled for deferred consensus"

      # Action: Send user message (should be queued because consensus_scheduled)
      {:noreply, state_after_msg} =
        MessageHandler.handle_agent_message(state_after_result, :user, "follow-up")

      # Assert: User message should be queued
      assert length(state_after_msg.queued_messages) == 1
      [queued] = state_after_msg.queued_messages
      assert queued.content == "follow-up"
      assert queued.sender_id == :user

      # Assert: Action result should be in history
      history = state_after_msg.model_histories["model1"] || []
      has_result = Enum.any?(history, fn e -> e.type == :result end)
      assert has_result, "Action result should be in history"

      # Drain :trigger_consensus messages
      assert_receive :trigger_consensus, 500
    end

    test "multiple user messages during action result all batched", %{infra: infra} do
      # Setup: Agent with pending action
      state =
        create_test_state(infra,
          pending_actions: %{
            "action-1" => %{type: :fetch_web, started_at: DateTime.utc_now()}
          }
        )

      state = %{state | skip_auto_consensus: false, consensus_scheduled: false}

      # Action: Send action result (v16.0 behavior - sets consensus_scheduled)
      {:noreply, s1} = MessageHandler.handle_action_result(state, "action-1", {:ok, "data"})

      assert s1.consensus_scheduled == true

      # Action: Send M1, M2 user messages rapidly (should be queued)
      {:noreply, s2} = MessageHandler.handle_agent_message(s1, :user, "question 1")
      {:noreply, s3} = MessageHandler.handle_agent_message(s2, :user, "question 2")

      # Assert: Both user messages queued
      assert length(s3.queued_messages) == 2
      contents = Enum.map(s3.queued_messages, & &1.content)
      assert "question 1" in contents
      assert "question 2" in contents

      # Drain :trigger_consensus
      assert_receive :trigger_consensus, 500
    end
  end

  # ==========================================================================
  # v4.0 Tests: Trigger Drain for Message Batching (fix-20260118-trigger-drain-pause)
  # ==========================================================================

  describe "trigger drain (v4.0)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # R94: Drain Function Exists and Is Called
    test "R94: drain_trigger_messages/0 is called during handle_trigger_consensus", %{
      infra: infra
    } do
      # Setup: Agent with consensus_scheduled = true (valid trigger)
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      # Send multiple :trigger_consensus messages to the mailbox BEFORE processing
      send(self(), :trigger_consensus)
      send(self(), :trigger_consensus)
      send(self(), :trigger_consensus)

      # Action: Call handle_trigger_consensus (processes first, should drain rest)
      {:noreply, _result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: All additional :trigger_consensus messages should have been drained
      # If drain works, mailbox should be empty of :trigger_consensus messages
      refute_receive :trigger_consensus, 0, "All :trigger_consensus messages should be drained"
    end

    # R95: Empty Mailbox Returns Zero
    test "R95: drain returns 0 when no triggers pending", %{infra: infra} do
      # This test MUST fail without drain implementation.
      # Structure: First prove drain works, then test empty mailbox case.

      # CONTROL: Prove drain works when triggers exist (must fail without drain)
      control_state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      send(self(), :trigger_consensus)
      {:noreply, _} = MessageInfoHandler.handle_trigger_consensus(control_state)

      # This assertion FAILS without drain implementation
      refute_receive :trigger_consensus, 0, "CONTROL: Drain must consume triggers when they exist"

      # NOW test empty mailbox case
      empty_state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      # Ensure mailbox is empty of triggers
      receive do
        :trigger_consensus -> flunk("Mailbox should be empty")
      after
        0 -> :ok
      end

      # Add non-trigger message to verify drain is selective even with empty trigger mailbox
      send(self(), {:agent_message, :parent, "preserved"})

      # Action: Call handle_trigger_consensus with empty trigger mailbox
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(empty_state)

      # Assert: No error, consensus_scheduled cleared, other messages preserved
      assert result_state.consensus_scheduled == false

      assert_receive {:agent_message, :parent, "preserved"},
                     0,
                     "Non-trigger messages must be preserved"
    end

    # R96: Single Trigger Drained
    test "R96: drain consumes single pending trigger", %{infra: infra} do
      # Setup: Agent with consensus_scheduled = true
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      # Send 1 extra :trigger_consensus
      send(self(), :trigger_consensus)

      # Action: Process first trigger (which is the handle_trigger_consensus call itself)
      {:noreply, _result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: Extra trigger consumed
      refute_receive :trigger_consensus, 0, "Extra :trigger_consensus should be drained"
    end

    # R97: Multiple Triggers Drained
    test "R97: drain consumes all pending triggers", %{infra: infra} do
      # Setup: Agent with consensus_scheduled = true
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      # Send 5 :trigger_consensus messages
      for _ <- 1..5 do
        send(self(), :trigger_consensus)
      end

      # Action: Process first trigger (drains rest)
      {:noreply, _result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: All 5 consumed - mailbox empty of triggers
      for _ <- 1..5 do
        refute_receive :trigger_consensus, 0, "All :trigger_consensus messages should be drained"
      end
    end

    # R98: Selective Drain - Only Triggers
    test "R98: drain only consumes :trigger_consensus messages", %{infra: infra} do
      # Setup: Agent with consensus_scheduled = true
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      # Send mixed mailbox: trigger, agent_message, trigger
      send(self(), :trigger_consensus)
      send(self(), {:agent_message, :parent, "important message"})
      send(self(), :trigger_consensus)

      # Action: Process trigger (should drain only :trigger_consensus)
      {:noreply, _result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Assert: Both triggers consumed
      refute_receive :trigger_consensus, 0

      # Assert: :agent_message still in mailbox (not drained)
      assert_receive {:agent_message, :parent, "important message"},
                     0,
                     ":agent_message should NOT be drained"
    end

    # R99: Stale Message Doesn't Drain
    test "R99: stale trigger_consensus does not drain subsequent messages", %{infra: infra} do
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

      # This assertion FAILS without drain implementation (trigger still in mailbox)
      refute_receive :trigger_consensus,
                     0,
                     "CONTROL: Valid trigger should drain subsequent messages"

      # PART 2: Now test stale message DOESN'T drain (only meaningful if Part 1 passes)
      stale_state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      send(self(), :trigger_consensus)
      send(self(), :trigger_consensus)

      {:noreply, _result_state} = MessageInfoHandler.handle_trigger_consensus(stale_state)

      # Stale message returns early WITHOUT draining - triggers remain
      assert_receive :trigger_consensus,
                     0,
                     "Stale trigger should NOT drain - trigger 1 should remain"

      assert_receive :trigger_consensus,
                     0,
                     "Stale trigger should NOT drain - trigger 2 should remain"
    end

    # R100: Drain Before Consensus
    test "R100: drain happens before consensus cycle starts", %{infra: infra} do
      # Setup: Agent with skip_auto_consensus = true to verify drain behavior
      # without consensus continuation sending new triggers
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true,
          # Add required fields for consensus to not crash
          model_histories: %{"model1" => []},
          models: ["model1"]
        )

      # Send 3 :trigger_consensus messages
      send(self(), :trigger_consensus)
      send(self(), :trigger_consensus)
      send(self(), :trigger_consensus)

      # Attach telemetry handler to count consensus cycles
      test_pid = self()
      handler_id = {:consensus_counter, System.unique_integer([:positive])}

      :telemetry.attach(
        handler_id,
        [:quoracle, :agent, :consensus, :start],
        fn _event, _measurements, _metadata, _config ->
          send(test_pid, :consensus_started)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Action: Process first trigger (drains rest, runs ONE consensus)
      # Note: This may fail/timeout if consensus tries to call LLM
      # With skip_auto_consensus: true, we avoid this by not running consensus
      # For this test, we use a mock consensus_fn or accept it may return early
      try do
        MessageInfoHandler.handle_trigger_consensus(state)
      rescue
        # Consensus may fail due to missing LLM config - that's OK for this test
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

      # Assert: All triggers drained (regardless of consensus success)
      refute_receive :trigger_consensus,
                     0,
                     "All triggers should be drained before consensus starts"
    end
  end

  describe "trigger drain property (v4.0)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    # P4: Property - Drain Count Matches Mailbox
    @tag :property
    property "P4: drain count equals number of pending triggers", %{infra: infra} do
      check all(n <- StreamData.integer(0..20)) do
        # Setup: Agent with consensus_scheduled = true (valid trigger)
        state =
          create_test_state(infra,
            consensus_scheduled: true,
            wait_timer: nil,
            skip_auto_consensus: true
          )

        # Add n :trigger_consensus messages to mailbox (guard for n=0)
        if n > 0 do
          for _ <- 1..n, do: send(self(), :trigger_consensus)
        end

        # Action: Process trigger (drains rest)
        {:noreply, _result_state} = MessageInfoHandler.handle_trigger_consensus(state)

        # Assert: Mailbox has no triggers left
        remaining_triggers =
          Stream.repeatedly(fn ->
            receive do
              :trigger_consensus -> :found
            after
              0 -> :none
            end
          end)
          |> Stream.take_while(&(&1 == :found))
          |> Enum.count()

        assert remaining_triggers == 0,
               "All #{n} triggers should be drained, but #{remaining_triggers} remain"
      end
    end
  end
end
