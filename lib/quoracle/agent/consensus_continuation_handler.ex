defmodule Quoracle.Agent.ConsensusContinuationHandler do
  @moduledoc """
  Handles consensus continuation after wait timeouts and wait:false actions.

  This module contains logic for requesting consensus after:
  - Timed wait expiration
  - Immediate continuation (wait: false actions)

  All functions return proper GenServer tuples for Core's handle_info callbacks.
  """

  alias Quoracle.Agent.{MessageHandler, StateUtils}

  @doc """
  Handle wait timer timeout.
  Requests consensus after a timed wait expires.
  v4.0: Delegates to MessageHandler.run_consensus_cycle for unified message handling.
  """
  @spec handle_wait_timeout(map(), String.t(), fun(), fun()) :: {:noreply, map()}
  def handle_wait_timeout(state, timer_id, cancel_timer_fn, execute_action_fn) do
    # Cancel timer and add history entry
    state = cancel_timer_fn.(state)
    # v8.0: add_history_entry appends to all model_histories
    new_state = StateUtils.add_history_entry(state, :event, {:wait_timeout, timer_id})

    # v4.0: Delegate to unified consensus cycle (flushes messages, handles ACE merge)
    MessageHandler.run_consensus_cycle(new_state, execute_action_fn)
  end

  @doc """
  Handle consensus continuation after wait: false or timed wait expiration.
  Returns proper GenServer tuple for Core's handle_info callbacks.
  v4.0: Delegates to MessageHandler.run_consensus_cycle for unified message handling.
  """
  @spec handle_consensus_continuation(map(), fun()) :: {:noreply, map()}
  def handle_consensus_continuation(state, execute_action_fn) do
    # v4.0: Delegate to unified consensus cycle (flushes messages, handles ACE merge)
    MessageHandler.run_consensus_cycle(state, execute_action_fn)
  end

  @doc """
  Cancel any active wait timer.
  v5.0: Delegates to StateUtils.cancel_wait_timer/1 for DRY timer cancellation.
  """
  @spec cancel_wait_timer(map()) :: map()
  defdelegate cancel_wait_timer(state), to: StateUtils
end
