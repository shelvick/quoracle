defmodule Quoracle.Agent.MessageHandler do
  @moduledoc """
  Handles message processing for Agent.Core.
  Extracted to keep Core under 500 lines while maintaining all functionality.
  """
  require Logger
  alias Quoracle.PubSub.AgentEvents

  alias Quoracle.Agent.{
    ConsensusHandler,
    StateUtils,
    MessageFormatter,
    MessageBatcher,
    TestHelpers,
    ContextHelpers,
    InternalMessageHandler,
    ConsensusContinuationHandler
  }

  alias Quoracle.Agent.MessageHandler.{ActionResultHandler, Persistence, MessageProcessor}

  @doc "Drain all pending messages from mailbox (FIFO ordering)."
  @spec drain_mailbox() :: [any()]
  def drain_mailbox(), do: MessageBatcher.drain_mailbox()

  @doc "Format batched messages as XML for LLM consumption."
  @spec format_batch_message([any()]) :: String.t()
  def format_batch_message(messages), do: MessageFormatter.format_batch_message(messages)

  @doc "Request consensus with mailbox draining and batch formatting."
  @spec request_consensus(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_consensus(state, opts \\ []) do
    # v12.0: Drain mailbox but don't use pending_batch (dead code removed)
    # Messages are now queued via handle_agent_message when actions pending
    _pending_messages = drain_mailbox()

    state_with_defaults =
      state
      |> Map.put_new(:context_summary, nil)
      |> Map.put_new(:model_histories, %{})

    consensus_fn = Keyword.get(opts, :consensus_fn, &ConsensusHandler.get_action_consensus/1)
    consensus_fn.(state_with_defaults)
  end

  @doc "Process a message using pubsub from state. Delegated to MessageProcessor."
  @spec process_message(any(), map()) :: map()
  defdelegate process_message(message, state), to: MessageProcessor

  @doc """
  Handle agent message with sender attribution (v10.0, v12.0).
  Stores structured content with sender info for LLM context.

  v12.0: Queue messages when actions are pending to prevent history alternation errors.
  Messages are queued and flushed atomically when action results arrive.
  """
  @spec handle_agent_message(map(), atom() | String.t(), String.t()) :: {:noreply, map()}
  def handle_agent_message(state, sender_id, content) do
    # R29: Cancel any active wait timer (consensus-triggering message)
    state = cancel_wait_timer(state)

    # Ensure context is loaded and manage size
    state = ContextHelpers.ensure_context_ready(state)

    # v12.0 R1 + v16.0 R57: Queue message when UN-ACKED actions pending OR consensus scheduled
    # v20.0: Acked async actions (e.g., long-running shell) don't block messages
    has_unacked_actions =
      state
      |> Map.get(:pending_actions, %{})
      |> Map.values()
      |> Enum.any?(fn action -> not Map.get(action, :acked, false) end)

    if has_unacked_actions or Map.get(state, :consensus_scheduled, false) do
      # Queue the message - will be flushed when action result arrives
      queued_message = %{
        sender_id: sender_id,
        content: content,
        queued_at: DateTime.utc_now()
      }

      queued_messages = Map.get(state, :queued_messages, [])
      new_state = Map.put(state, :queued_messages, queued_messages ++ [queued_message])
      {:noreply, new_state}
    else
      # v18.0 R70: Idle agent - DEFER consensus to allow message batching
      # R26-R28: Store structured content with sender info
      message_content = %{
        from: ActionResultHandler.format_sender_id(sender_id),
        content: content
      }

      # v10.0: Store structured content instead of plain string
      state = StateUtils.add_history_entry(state, :event, message_content)

      # R30: Trigger consensus (skip for tests that need manual control)
      if state.skip_auto_consensus do
        {:noreply, state}
      else
        # v18.0: Defer consensus via :trigger_consensus for event batching
        # This allows rapid messages to batch into single consensus cycle
        state = Map.put(state, :consensus_scheduled, true)
        send(self(), :trigger_consensus)
        {:noreply, state}
      end
    end
  end

  @doc """
  Unified consensus cycle: flush queued messages, get consensus, merge state, execute action.
  Called by all consensus entry points for consistent message handling.

  v15.0: Bug fix - ensures queued messages are flushed at ALL consensus entry points,
  not just the async action result path.

  Returns {:noreply, state} for GenServer callbacks.
  """
  @spec run_consensus_cycle(map(), fun()) :: {:noreply, map()}
  def run_consensus_cycle(state, execute_action_fn) do
    # Step 1: Flush queued messages into history (THE BUG FIX)
    state = ActionResultHandler.flush_queued_messages(state)

    # Step 2: Get consensus (handles per-model histories, condensation, etc.)
    case ConsensusHandler.get_action_consensus(state) do
      {:ok, action, updated_state, accumulator} ->
        # Step 3: Flush accumulated costs (v23.0 - embedding cost batching)
        flush_costs(accumulator, state)
        # Step 4: Merge ACE state updates
        merged_state = StateUtils.merge_consensus_state(state, updated_state)
        # Step 5: Reset retry counter on success
        merged_state = Map.put(merged_state, :consensus_retry_count, 0)
        # Step 6: Execute action via callback
        final_state = execute_action_fn.(merged_state, action)
        {:noreply, final_state}

      {:error, reason, accumulator} ->
        # Step 7: Flush costs even on error (work was done)
        flush_costs(accumulator, state)
        # Step 8: Handle errors consistently (with retry for transient failures)
        handle_consensus_error(state, reason, "cycle")
    end
  end

  @doc "Handle generic message processing. Extracts pubsub from state for broadcasts."
  @spec handle_message(map(), any()) :: {:noreply, map()} | {:ok, map()}
  def handle_message(state, {:wait_expired, timer_ref} = message) do
    state =
      case state.wait_timer do
        {^timer_ref, _type} -> cancel_wait_timer(state)
        {^timer_ref, _timer_id, _gen} -> cancel_wait_timer(state)
        _ -> state
      end

    handle_message_impl(state, message)
  end

  def handle_message(state, message) do
    state = cancel_wait_timer(state)
    handle_message_impl(state, message)
  end

  defp handle_message_impl(state, message) do
    pubsub = Map.get(state, :pubsub)

    # Broadcast state change if message is from another agent
    new_state =
      case message do
        {_from_pid, _content} ->
          AgentEvents.broadcast_state_change(state.agent_id, state.state, :processing, pubsub)
          %{state | state: :processing}

        _ ->
          state
      end

    # Extract content from message tuple
    content =
      case message do
        {_from_pid, msg_content} -> msg_content
        msg -> msg
      end

    # Add to history
    new_state = StateUtils.add_history_entry(new_state, :event, content)

    # Skip consensus mode: broadcast events only (for unit tests that don't need consensus)
    # Note: test_mode controls mock LLM responses, skip_consensus controls whether to run consensus
    if Map.get(state, :skip_consensus, false) do
      broadcast_test_events(new_state, pubsub)
      {:noreply, new_state}
    else
      # Production: trigger consensus
      case ConsensusHandler.get_action_consensus(new_state) do
        {:ok, action, updated_state, accumulator} ->
          # v23.0: Flush accumulated costs before action execution
          flush_costs(accumulator, new_state)
          merged_state = StateUtils.merge_consensus_state(new_state, updated_state)
          merged_state = Map.put(merged_state, :consensus_retry_count, 0)
          {:noreply, execute_consensus_action(merged_state, action)}

        {:error, reason, accumulator} ->
          # v23.0: Flush costs even on error
          flush_costs(accumulator, new_state)
          handle_consensus_error(new_state, reason, "during processing")
      end
    end
  end

  defp broadcast_test_events(state, pubsub) do
    Phoenix.PubSub.broadcast(
      pubsub,
      "messages:#{state.agent_id}",
      {:message_received, %{agent_id: state.agent_id}}
    )

    Phoenix.PubSub.broadcast(
      pubsub,
      "agents:#{state.agent_id}:messages",
      {:message_processed, %{agent_id: state.agent_id}}
    )

    Phoenix.PubSub.broadcast(
      pubsub,
      "messages:all",
      {:message_event, %{agent_id: state.agent_id}}
    )
  end

  @doc """
  Handle action result processing. Delegates to ActionResultHandler.

  Cancels wait timer before delegating (R11).
  """
  @spec handle_action_result(map(), String.t(), any(), keyword()) :: {:noreply, map()}
  def handle_action_result(state, action_id, result, opts \\ []) do
    # R11: Cancel any active wait timer (consensus-triggering message)
    state = cancel_wait_timer(state)
    ActionResultHandler.handle_action_result(state, action_id, result, opts)
  end

  @doc """
  Handle batch sub-action result. Delegates to ActionResultHandler.
  """
  @spec handle_batch_action_result(map(), String.t(), atom(), any()) :: {:noreply, map()}
  defdelegate handle_batch_action_result(state, action_id, action_type, result),
    to: ActionResultHandler

  @doc "Handle user message sending."
  @spec handle_send_user_message(map(), String.t()) :: {:noreply, map()}
  def handle_send_user_message(state, content) do
    # R71: Broadcast user message to UI if root agent (parent_pid == nil)
    if Map.get(state, :parent_pid) == nil do
      Logger.info("Agent #{state.agent_id} sending message to user: #{content}")
      pubsub = Map.get(state, :pubsub)

      # Broadcast log to UI
      AgentEvents.broadcast_log(
        state.agent_id,
        :info,
        "Sending message to user",
        %{content: content},
        pubsub
      )

      # Broadcast user message event for UI updates
      AgentEvents.broadcast_user_message(state.task_id, state.agent_id, content, pubsub)
    end

    # R72: Delegate to handle_agent_message with :user sender_id
    # This ensures user messages follow same queueing/batching logic as agent messages
    handle_agent_message(state, :user, content)
  end

  @doc "Handle internal process messages. Delegates to InternalMessageHandler."
  @spec handle_internal_message(map(), atom(), any()) :: {:noreply, map()}
  def handle_internal_message(state, type, data) do
    InternalMessageHandler.handle_internal_message(state, type, data)
  end

  @doc "Handle wait timer timeout."
  @spec handle_wait_timeout(map(), String.t()) :: {:noreply, map()}
  def handle_wait_timeout(state, timer_id) do
    # v2.0: 4-arity (removed get_consensus_fn - delegates directly to ConsensusHandler)
    ConsensusContinuationHandler.handle_wait_timeout(
      state,
      timer_id,
      &ConsensusContinuationHandler.cancel_wait_timer/1,
      &execute_consensus_action/2
    )
  end

  @doc "Handle consensus continuation after wait: false or timed wait expiration."
  @spec handle_consensus_continuation(map()) :: {:noreply, map()}
  def handle_consensus_continuation(state) do
    # v2.0: 2-arity (removed request_consensus_fn - delegates directly to ConsensusHandler)
    ConsensusContinuationHandler.handle_consensus_continuation(
      state,
      &execute_consensus_action/2
    )
  end

  @doc "Cancel any active wait timer."
  @spec cancel_wait_timer(map()) :: map()
  def cancel_wait_timer(state) do
    ConsensusContinuationHandler.cancel_wait_timer(state)
  end

  # R10-R13: execute_consensus_action now always returns state (defaults wait: false)
  # Kept as helper because it's passed as function reference (&execute_consensus_action/2)
  defp execute_consensus_action(state, decision) do
    ConsensusHandler.execute_consensus_action(state, decision, self())
  end

  @retryable_consensus_errors [:all_responses_invalid, :all_models_failed]
  @max_consensus_attempts 3

  # v15.0 REFACTOR: DRY consensus error handling (5 call sites -> 1 helper)
  # v22.0: Added retry logic for transient failures
  defp handle_consensus_error(state, reason, context, extra_metadata \\ %{}) do
    Logger.error("Consensus failed #{context}: #{inspect(reason)}")
    pubsub = Map.get(state, :pubsub)
    metadata = Map.merge(%{reason: reason, action: "consensus"}, extra_metadata)

    AgentEvents.broadcast_log(
      state.agent_id,
      :error,
      "Consensus failed #{context}",
      metadata,
      pubsub
    )

    retry_count = Map.get(state, :consensus_retry_count, 0)
    retryable? = reason in @retryable_consensus_errors

    cond do
      retryable? and retry_count + 1 < @max_consensus_attempts ->
        state = Map.put(state, :consensus_retry_count, retry_count + 1)
        state = StateUtils.schedule_consensus_continuation(state)
        {:noreply, state}

      retryable? ->
        notify_parent_of_stall(state, reason, retry_count + 1)
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  defp notify_parent_of_stall(state, reason, attempts) do
    parent_pid = Map.get(state, :parent_pid)

    if parent_pid && Process.alive?(parent_pid) do
      message = "Consensus failed after #{attempts} attempts: #{inspect(reason)}"
      send(parent_pid, {:agent_message, state.agent_id, message})
    end
  end

  @doc "Broadcast that a message was received (for tests)."
  @spec broadcast_message_received(any(), map()) :: :ok
  defdelegate broadcast_message_received(message, state), to: TestHelpers

  @doc "Broadcast that a message was sent (for tests)."
  @spec broadcast_message_sent(any(), map()) :: :ok
  defdelegate broadcast_message_sent(message, state), to: TestHelpers

  @doc "Handle threaded messages with pubsub from state (for tests)."
  @spec handle_threaded_message(map(), map()) :: {:ok, map()}
  defdelegate handle_threaded_message(message, state), to: TestHelpers

  @doc "Persist inter-agent message to database."
  @spec persist_message(map(), String.t()) :: :ok
  defdelegate persist_message(state, content), to: Persistence

  @doc "Flush accumulated costs to the database."
  @spec flush_costs(Quoracle.Costs.Accumulator.t() | nil, map()) :: :ok
  defdelegate flush_costs(accumulator, state), to: Persistence
end
