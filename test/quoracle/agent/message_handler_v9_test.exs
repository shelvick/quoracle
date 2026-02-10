defmodule Quoracle.Agent.MessageHandlerV9Test do
  @moduledoc """
  Tests for MessageHandler v9.0 changes (fix-20251209-035351 Packet 3).

  Verifies the consensus query architecture:
  - R21: request_consensus does NOT call ContextManager.build_conversation_messages
  - R22: calls ConsensusHandler.get_action_consensus with state only (1-arity)

  v12.0 Update: pending_batch removed as dead code (fix-20251231-history-alternation R12).
  Messages are now queued via handle_agent_message when actions pending,
  not via mailbox draining in request_consensus.

  Tests use consensus_fn injection to verify the state passed to ConsensusHandler.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.MessageHandler

  # Minimal state required for request_consensus
  defp base_state do
    %{
      agent_id: "test-agent-#{System.unique_integer([:positive])}",
      model_histories: %{},
      context_summary: nil,
      pubsub: nil,
      pending_actions: %{},
      wait_timer: nil,
      test_mode: true
    }
  end

  describe "[UNIT] request_consensus state (v12.0)" do
    # v12.0: pending_batch removed as dead code (R12 from fix-20251231-history-alternation)
    # Messages are now queued via handle_agent_message when actions pending,
    # and flushed atomically when action results arrive.

    test "v12.0: mailbox messages do not add pending_batch to state (dead code removed)" do
      # Setup: Send messages to mailbox before calling request_consensus
      send(self(), {:action_result, "action-1", {:ok, "result"}})
      send(self(), {:agent_message, :parent, "hello from parent"})

      state = base_state()
      test_pid = self()

      consensus_fn = fn passed_state ->
        send(test_pid, {:captured_state, passed_state})
        {:ok, %{action: :orient, params: %{}, wait: false}}
      end

      _result = MessageHandler.request_consensus(state, consensus_fn: consensus_fn)

      assert_receive {:captured_state, captured_state}, 30_000

      # v12.0 R12: pending_batch is dead code and should NOT be added
      refute Map.has_key?(captured_state, :pending_batch),
             "pending_batch should NOT be added (dead code removed in v12.0)"
    end

    test "empty mailbox does not add pending_batch to state" do
      # Setup: Empty mailbox (drain any existing messages first)
      MessageHandler.drain_mailbox()

      state = base_state()
      test_pid = self()

      consensus_fn = fn passed_state ->
        send(test_pid, {:captured_state, passed_state})
        {:ok, %{action: :orient, params: %{}, wait: false}}
      end

      _result = MessageHandler.request_consensus(state, consensus_fn: consensus_fn)

      assert_receive {:captured_state, captured_state}, 30_000

      # State should NOT have :pending_batch key when mailbox was empty
      refute Map.has_key?(captured_state, :pending_batch),
             "State should NOT have :pending_batch key when mailbox was empty"
    end

    test "v12.0: multiple mailbox messages do not add pending_batch (dead code removed)" do
      # Send multiple different message types
      send(self(), {:action_result, "id-1", {:ok, "done"}})
      send(self(), {:agent_message, :child, "status update"})
      send(self(), {:system_event, :ready, %{time: 123}})

      state = base_state()
      test_pid = self()

      consensus_fn = fn passed_state ->
        send(test_pid, {:captured_state, passed_state})
        {:ok, %{action: :orient, params: %{}, wait: false}}
      end

      _result = MessageHandler.request_consensus(state, consensus_fn: consensus_fn)

      assert_receive {:captured_state, captured_state}, 30_000

      # v12.0 R12: pending_batch is dead code and should NOT be added
      refute Map.has_key?(captured_state, :pending_batch),
             "pending_batch should NOT be added (dead code removed in v12.0)"
    end
  end

  describe "[UNIT] request_consensus ConsensusHandler call pattern (R21-R22)" do
    test "R22: calls ConsensusHandler.get_action_consensus with state map (not messages list)" do
      state = base_state()
      test_pid = self()

      # Verify consensus_fn receives a map (state), not a list (messages)
      consensus_fn = fn passed_arg ->
        send(test_pid, {:call_arg_type, passed_arg})
        {:ok, %{action: :orient, params: %{}, wait: false}}
      end

      _result = MessageHandler.request_consensus(state, consensus_fn: consensus_fn)

      assert_receive {:call_arg_type, received_arg}, 30_000

      # R22: Should receive state map, not messages list
      assert is_map(received_arg),
             "ConsensusHandler should receive state map, not messages list"

      assert Map.has_key?(received_arg, :agent_id),
             "State should have :agent_id key"

      assert Map.has_key?(received_arg, :model_histories),
             "State should have :model_histories key"
    end

    test "R21: request_consensus does not include pre-built messages in state" do
      # Old pattern added a :messages key with flattened conversation
      # New pattern uses model_histories directly (ConsensusHandler builds per-model)
      state = base_state()
      test_pid = self()

      consensus_fn = fn passed_state ->
        send(test_pid, {:captured_state, passed_state})
        {:ok, %{action: :orient, params: %{}, wait: false}}
      end

      _result = MessageHandler.request_consensus(state, consensus_fn: consensus_fn)

      assert_receive {:captured_state, captured_state}, 30_000

      # R21: State should NOT have pre-built :messages key (old ContextManager pattern)
      # The new pattern passes model_histories and lets ConsensusHandler build per-model
      refute Map.has_key?(captured_state, :messages),
             "State should NOT have pre-built :messages key (old pattern)"
    end
  end
end
