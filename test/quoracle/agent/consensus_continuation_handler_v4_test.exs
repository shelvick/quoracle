defmodule Quoracle.Agent.ConsensusContinuationHandlerV4Test do
  @moduledoc """
  Tests for ConsensusContinuationHandler v4.0 (fix-20260115-message-flush).

  v4.0 delegates to MessageHandler.run_consensus_cycle for unified message handling.

  Requirements:
  - R8: handle_consensus_continuation delegates to MessageHandler.run_consensus_cycle
  - R9: handle_wait_timeout delegates to MessageHandler.run_consensus_cycle
  - R10: timer entry added before delegation
  - R11: timer cancelled before delegation
  - R12: messages flushed on continuation [INTEGRATION]
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.ConsensusContinuationHandler

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

  defp create_test_state(infra, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, unique_id())
    queued_messages = Keyword.get(opts, :queued_messages, [])

    %{
      agent_id: agent_id,
      router_pid: self(),
      registry: infra.registry,
      dynsup: infra.dynsup,
      pubsub: infra.pubsub,
      model_histories: %{"model1" => []},
      models: ["model1"],
      pending_actions: %{},
      queued_messages: queued_messages,
      skip_auto_consensus: true,
      test_mode: true,
      wait_timer: nil,
      context_limits_loaded: true,
      context_limit: 4000,
      context_lessons: %{},
      model_states: %{}
    }
  end

  describe "[UNIT] R8: handle_consensus_continuation delegates" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "handle_consensus_continuation delegates to MessageHandler.run_consensus_cycle", %{
      infra: infra
    } do
      # Setup
      state = create_test_state(infra)
      test_pid = self()

      execute_action_fn = fn s, action ->
        send(test_pid, {:executed, action})
        s
      end

      # Action: Call handle_consensus_continuation
      # v4.0 should delegate to MessageHandler.run_consensus_cycle internally
      result =
        ConsensusContinuationHandler.handle_consensus_continuation(state, execute_action_fn)

      # Assert: Should return {:noreply, state}
      assert {:noreply, _} = result

      # Action should have been executed (via run_consensus_cycle)
      assert_receive {:executed, action}, 5000
      assert is_map(action)
    end
  end

  describe "[UNIT] R9: handle_wait_timeout delegates" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "handle_wait_timeout delegates to MessageHandler.run_consensus_cycle", %{infra: infra} do
      # Setup
      state = create_test_state(infra)
      timer_id = "timer-#{System.unique_integer([:positive])}"
      test_pid = self()

      cancel_timer_fn = fn s -> s end

      execute_action_fn = fn s, action ->
        send(test_pid, {:executed, action})
        s
      end

      # Action: Call handle_wait_timeout
      result =
        ConsensusContinuationHandler.handle_wait_timeout(
          state,
          timer_id,
          cancel_timer_fn,
          execute_action_fn
        )

      # Assert: Should return {:noreply, state}
      assert {:noreply, _} = result

      # Action should have been executed (via run_consensus_cycle)
      assert_receive {:executed, action}, 5000
      assert is_map(action)
    end
  end

  describe "[UNIT] R10: timer entry added before delegation" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "wait_timeout event added to history before consensus cycle", %{infra: infra} do
      # Setup
      state = create_test_state(infra)
      timer_id = "timer-event-test"
      test_pid = self()

      cancel_timer_fn = fn s -> s end

      execute_action_fn = fn state_at_execute, _action ->
        # Capture the state when execute is called
        send(test_pid, {:state_at_execute, state_at_execute})
        state_at_execute
      end

      # Action
      _result =
        ConsensusContinuationHandler.handle_wait_timeout(
          state,
          timer_id,
          cancel_timer_fn,
          execute_action_fn
        )

      # Assert: State at execute time should have wait_timeout event in history
      assert_receive {:state_at_execute, state_at_execute}, 5000

      # Check that wait_timeout event was added to history
      history = state_at_execute.model_histories["model1"] || []

      # Should have an entry with {:wait_timeout, timer_id}
      assert Enum.any?(history, fn entry ->
               entry.type == :event and entry.content == {:wait_timeout, timer_id}
             end),
             "wait_timeout event should be in history before consensus cycle"
    end
  end

  describe "[UNIT] R11: timer cancelled before delegation" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "timer cancelled before wait_timeout event added", %{infra: infra} do
      # Setup
      state = create_test_state(infra)
      timer_id = "timer-cancel-test"
      test_pid = self()
      table_name = :"order_tracker_#{System.unique_integer([:positive])}"
      order_tracker = :ets.new(table_name, [:ordered_set, :public])

      # Track order of operations
      cancel_timer_fn = fn s ->
        :ets.insert(order_tracker, {System.monotonic_time(), :timer_cancelled})
        s
      end

      execute_action_fn = fn s, _action ->
        :ets.insert(order_tracker, {System.monotonic_time(), :action_executed})
        send(test_pid, :done)
        s
      end

      # Action
      _result =
        ConsensusContinuationHandler.handle_wait_timeout(
          state,
          timer_id,
          cancel_timer_fn,
          execute_action_fn
        )

      assert_receive :done, 5000

      # Get order of operations
      operations = :ets.tab2list(order_tracker) |> Enum.map(fn {_, op} -> op end)
      :ets.delete(order_tracker)

      # Assert: timer_cancelled should come first
      assert hd(operations) == :timer_cancelled,
             "Timer should be cancelled before any other operation"
    end
  end

  describe "[INTEGRATION] R12: messages flushed on continuation" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "queued messages flushed when request_consensus triggers continuation", %{infra: infra} do
      # Setup: State with queued messages (simulating messages that arrived during action)
      state =
        create_test_state(infra,
          queued_messages: [
            %{sender_id: :parent, content: "queued during action", queued_at: DateTime.utc_now()}
          ]
        )

      test_pid = self()

      execute_action_fn = fn state_at_execute, _action ->
        send(test_pid, {:state_at_execute, state_at_execute})
        state_at_execute
      end

      # Action: Call handle_consensus_continuation (simulating :trigger_consensus handler)
      # v4.0 should flush messages via MessageHandler.run_consensus_cycle
      _result =
        ConsensusContinuationHandler.handle_consensus_continuation(state, execute_action_fn)

      # Assert: Messages should be flushed to history
      assert_receive {:state_at_execute, state_at_execute}, 5000

      # Queue should be empty
      assert state_at_execute.queued_messages == []

      # Message should be in history
      history = state_at_execute.model_histories["model1"] || []

      assert Enum.any?(history, fn entry ->
               is_map(entry.content) and entry.content[:content] == "queued during action"
             end),
             "Queued message should be flushed to history on continuation"
    end

    test "multiple queued messages all flushed on continuation", %{infra: infra} do
      # Setup: Multiple queued messages
      state =
        create_test_state(infra,
          queued_messages: [
            %{sender_id: :parent, content: "msg1", queued_at: DateTime.utc_now()},
            %{sender_id: "child-1", content: "msg2", queued_at: DateTime.utc_now()},
            %{sender_id: :parent, content: "msg3", queued_at: DateTime.utc_now()}
          ]
        )

      test_pid = self()

      execute_action_fn = fn state_at_execute, _action ->
        send(test_pid, {:state_at_execute, state_at_execute})
        state_at_execute
      end

      # Action
      _result =
        ConsensusContinuationHandler.handle_consensus_continuation(state, execute_action_fn)

      # Assert: All messages flushed
      assert_receive {:state_at_execute, state_at_execute}, 5000

      assert state_at_execute.queued_messages == []

      history = state_at_execute.model_histories["model1"] || []

      for content <- ["msg1", "msg2", "msg3"] do
        assert Enum.any?(history, fn entry ->
                 is_map(entry.content) and entry.content[:content] == content
               end),
               "Message '#{content}' should be in history"
      end
    end
  end
end
