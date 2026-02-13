defmodule Quoracle.Agent.Core.MessageInfoHandler do
  @moduledoc """
  Handle info message processing for Agent.Core.
  Extracted to keep Core under 500 lines while maintaining all functionality.
  """

  require Logger
  alias Quoracle.Agent.{MessageHandler, StateUtils}
  alias Quoracle.PubSub.AgentEvents

  @doc """
  Handle :message info sent via send/2 (for tests).
  Delegates to MessageHandler for processing.
  """
  @spec handle_message_info(any(), map()) :: {:noreply, map()}
  def handle_message_info(message, state) do
    MessageHandler.handle_message(state, message)
  end

  @doc """
  Handle agent error notifications.
  Forwards error to parent if exists.
  """
  @spec handle_agent_error(pid(), term(), map()) :: {:noreply, map()}
  def handle_agent_error(pid, reason, state) do
    # Notify parent if exists
    if state.parent_pid do
      send(state.parent_pid, {:agent_error, pid, reason})
    end

    {:noreply, state}
  end

  @doc """
  Handle wait timer timeout.
  Checks generation to ignore stale timer messages.
  """
  @spec handle_wait_timeout(String.t(), non_neg_integer(), map()) :: {:noreply, map()}
  def handle_wait_timeout(timer_id, gen, state) do
    # Check generation to ignore stale timer messages
    case state.wait_timer do
      {_, ^timer_id, ^gen} ->
        # This is the current timer - process it
        MessageHandler.handle_wait_timeout(state, timer_id)

      _ ->
        # Stale or cancelled timer - ignore
        {:noreply, state}
    end
  end

  @doc """
  Handle wait expired event.
  v21.0: Added staleness check - validates timer_ref against state.wait_timer.
  Triggers consensus continuation unless auto-consensus is disabled.
  """
  @spec handle_wait_expired(reference(), map()) :: {:noreply, map()}
  def handle_wait_expired(timer_ref, state) do
    # v21.0: Staleness check - is this timer still the current one?
    # Matches pattern from MessageHandler.handle_message/2 (lines 163-172)
    is_current =
      case state.wait_timer do
        {^timer_ref, _type} -> true
        {^timer_ref, _id, _gen} -> true
        _ -> false
      end

    if is_current do
      # Clear timer before continuing (use StateUtils for DRY)
      state = StateUtils.cancel_wait_timer(state)

      # Skip auto-consensus for integration tests that need manual control
      if state.skip_auto_consensus do
        {:noreply, state}
      else
        MessageHandler.handle_consensus_continuation(state)
      end
    else
      Logger.debug("Ignoring stale {:wait_expired, ...} message")
      {:noreply, state}
    end
  end

  @doc """
  Handle spawn failure notification from Spawn action.
  Logs warning, records failure in history, removes child if tracked, continues consensus.
  """
  @spec handle_spawn_failed(map(), map()) :: {:noreply, map()}
  def handle_spawn_failed(%{child_id: child_id, reason: reason} = data, state) do
    task = Map.get(data, :task, "unknown")

    Logger.warning(
      "Spawn failed for child #{child_id}: #{inspect(reason)}. Task: #{truncate(task, 100)}"
    )

    # Add to history so LLM knows spawn failed
    failure_content = "Spawn failed for child #{child_id}: #{inspect(reason)}"
    state = StateUtils.add_history_entry(state, :result, failure_content)

    # Remove from children list if it was eagerly tracked
    state =
      case state.children do
        children when is_list(children) ->
          %{state | children: Enum.reject(children, &(&1.agent_id == child_id))}

        _ ->
          state
      end

    # Continue consensus so agent can react to the failure
    new_state = StateUtils.schedule_consensus_continuation(state)
    {:noreply, new_state}
  end

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max,
    do: String.slice(str, 0, max) <> "..."

  defp truncate(str, _max) when is_binary(str), do: str
  defp truncate(other, _max), do: inspect(other)

  @doc """
  Unified handler for all consensus trigger messages.
  v19.0: Replaces handle_request_consensus, handle_continue_consensus, handle_continue_consensus_tuple.

  Staleness check: If consensus_scheduled=false AND wait_timer=nil, message is stale.
  """
  @spec handle_trigger_consensus(map()) :: {:noreply, map()}
  def handle_trigger_consensus(state) do
    # Staleness check - ignore if no active timer AND no scheduled consensus
    # This detects stale messages from cancelled timers or superseded events
    is_stale =
      Map.get(state, :consensus_scheduled, false) == false and
        is_nil(Map.get(state, :wait_timer))

    if is_stale do
      Logger.debug("Ignoring stale :trigger_consensus message (timer cancelled or superseded)")
      {:noreply, state}
    else
      # v20.0: Drain ALL pending :trigger_consensus messages before running cycle
      # This prevents multiple accumulated triggers from causing multiple cycles
      drained_count = drain_trigger_messages()

      if drained_count > 0 do
        Logger.debug("Drained #{drained_count} additional :trigger_consensus messages")
      end

      # Clear both flags since we're processing this message
      # v19.1: Use StateUtils.cancel_wait_timer for DRY timer cancellation
      state =
        state
        |> Map.put(:consensus_scheduled, false)
        |> StateUtils.cancel_wait_timer()

      # Skip auto-consensus for integration tests that need manual control
      if state.skip_auto_consensus do
        {:noreply, state}
      else
        MessageHandler.handle_consensus_continuation(state)
      end
    end
  end

  @doc """
  Drain all pending :trigger_consensus messages from mailbox.
  v20.0: Uses selective receive to only consume trigger messages, leaving others intact.
  Returns count of drained messages.
  """
  @spec drain_trigger_messages() :: non_neg_integer()
  def drain_trigger_messages do
    drain_trigger_messages(0)
  end

  defp drain_trigger_messages(count) do
    receive do
      :trigger_consensus -> drain_trigger_messages(count + 1)
    after
      0 -> count
    end
  end

  @doc """
  Handle 2-tuple agent message (from tests and SendMessage action).
  Persists and processes the message. Uses :parent as default sender for
  backward compatibility with legacy 2-tuple format.
  """
  @spec handle_agent_message_2tuple(String.t(), map()) :: {:noreply, map()}
  def handle_agent_message_2tuple(content, state) do
    # Legacy 2-tuple format - use :parent as default sender
    # (MVP: only parent→child messages used 2-tuple format)
    # Persist message to database (Packet 3)
    MessageHandler.persist_message(state, content)

    # Process message via 3-arity with :parent as sender (v10.0)
    MessageHandler.handle_agent_message(state, :parent, content)
  end

  @doc """
  Handle 3-tuple agent message with sender ID.
  Stores message in mailbox and processes it.
  """
  @spec handle_agent_message_3tuple(String.t(), String.t(), map()) :: {:noreply, map()}
  def handle_agent_message_3tuple(sender_id, content, state) do
    # Store message in agent's mailbox
    message = %{
      from: sender_id,
      content: content,
      timestamp: DateTime.utc_now(),
      read: false
    }

    state = %{state | messages: state.messages ++ [message]}

    # Process message and trigger consensus (v10.0: pass sender_id)
    MessageHandler.handle_agent_message(state, sender_id, content)
  end

  @doc """
  Handle DOWN message for monitored processes.
  Handles parent, child, and Router (v30.0) termination.
  """
  @spec handle_down(reference(), pid(), term(), map()) ::
          {:noreply, map()} | {:stop, atom(), map()}
  def handle_down(ref, pid, reason, state) do
    pubsub = state.pubsub

    # v30.0: Check if this is a Router DOWN message
    active_routers = Map.get(state, :active_routers, %{})

    case Map.get(active_routers, ref) do
      ^pid ->
        # Router died - clean up both tracking maps
        active_routers = Map.delete(state.active_routers, ref)

        # Find and remove from shell_routers (by pid value)
        shell_routers =
          state.shell_routers
          |> Enum.reject(fn {_cmd_id, router_pid} -> router_pid == pid end)
          |> Map.new()

        new_state = %{state | active_routers: active_routers, shell_routers: shell_routers}
        {:noreply, new_state}

      _ ->
        # Not a Router - check other cases
        handle_down_non_router(pid, reason, state, pubsub)
    end
  end

  # Handle non-Router DOWN messages (parent, child, etc.)
  defp handle_down_non_router(pid, reason, state, pubsub) do
    cond do
      pid == state.parent_pid ->
        Logger.info("Agent #{state.agent_id} parent terminated: #{inspect(reason)}")

        # Broadcast to UI (defensive - PubSub may be stopped during cleanup)
        try do
          AgentEvents.broadcast_log(
            state.agent_id,
            :info,
            "Parent agent terminated",
            %{reason: reason},
            pubsub
          )
        rescue
          ArgumentError -> :ok
        end

        # Spawned children (have parent_id) survive parent death
        # Test fixtures and non-spawned agents stop when parent dies
        if Map.has_key?(state, :parent_id) && state.parent_id do
          {:noreply, state}
        else
          {:stop, :normal, state}
        end

      pid in state.children ->
        Logger.info("Agent #{state.agent_id} child terminated: #{inspect(pid)}")

        # Broadcast to UI (defensive - PubSub may be stopped during cleanup)
        try do
          AgentEvents.broadcast_log(
            state.agent_id,
            :info,
            "Child agent terminated",
            %{child_pid: pid},
            pubsub
          )
        rescue
          ArgumentError -> :ok
        end

        new_state = %{state | children: List.delete(state.children, pid)}
        {:noreply, new_state}

      true ->
        {:noreply, state}
    end
  end

  @doc """
  Handle EXIT messages from linked processes.
  With trap_exit enabled, Core receives these as messages instead of crashing.
  """
  @spec handle_exit(pid(), term(), map()) :: {:noreply, map()} | {:stop, atom(), map()}
  def handle_exit(pid, reason, state) do
    # v30.0: Check if this EXIT is from a Router we're tracking
    # Router deaths are handled via DOWN messages from monitor, so ignore EXIT
    active_routers = Map.get(state, :active_routers, %{})
    is_router = pid in Map.values(active_routers)

    cond do
      # v30.0: Router EXIT - ignore, handled via DOWN message
      is_router ->
        {:noreply, state}

      # Supervisor shutdown - propagate for proper restart behavior
      reason == :shutdown ->
        {:stop, :shutdown, state}

      # Any other EXIT - stop cleanly
      reason not in [:normal, :shutdown] ->
        {:stop, :normal, state}

      # Normal exits from other processes - ignore
      true ->
        {:noreply, state}
    end
  end
end
