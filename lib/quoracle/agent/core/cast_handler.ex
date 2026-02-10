defmodule Quoracle.Agent.Core.CastHandler do
  @moduledoc """
  Handles cast message processing for Agent.Core.
  Extracted to keep Core under 500 lines.
  """

  alias Quoracle.Agent.Core.State
  alias Quoracle.Agent.MessageHandler
  alias Quoracle.Agent.StateUtils
  alias Quoracle.PubSub.AgentEvents

  @doc """
  Handle legacy agent_message cast - uses :parent as default sender.
  """
  @spec handle_agent_message(String.t(), State.t()) :: {:noreply, State.t()}
  def handle_agent_message(content, state) do
    MessageHandler.persist_message(state, content)
    MessageHandler.handle_agent_message(state, :parent, content)
  end

  @doc """
  Handle generic message cast.
  """
  @spec handle_message(any(), State.t()) :: {:noreply, State.t()} | {:ok, State.t()}
  def handle_message(message, state) do
    MessageHandler.handle_message(state, message)
  end

  @doc """
  Handle add_pending_action cast - tracks pending actions.
  """
  @spec handle_add_pending_action(String.t(), atom(), map(), State.t()) :: {:noreply, State.t()}
  def handle_add_pending_action(action_id, type, params, state) do
    action = %{type: type, params: params, timestamp: DateTime.utc_now()}
    AgentEvents.broadcast_action_started(state.agent_id, type, action_id, params, state.pubsub)
    new_pending = Map.put(state.pending_actions, action_id, action)
    {:noreply, %State{state | pending_actions: new_pending}}
  end

  @doc """
  Handle action_result cast - processes completed action results.
  """
  @spec handle_action_result(String.t(), any(), keyword(), State.t()) :: {:noreply, State.t()}
  def handle_action_result(action_id, result, opts, state) do
    MessageHandler.handle_action_result(state, action_id, result, opts)
  end

  @doc """
  Handle batch_action_result cast - records batch sub-action results directly.

  Unlike handle_action_result, this doesn't require the action_id to be in pending_actions.
  Used by BatchSync which spawns Routers directly and can't add to pending_actions
  (would cause deadlock since we're already inside a GenServer.call).
  """
  @spec handle_batch_action_result(String.t(), atom(), any(), State.t()) :: {:noreply, State.t()}
  def handle_batch_action_result(action_id, action_type, result, state) do
    MessageHandler.handle_batch_action_result(state, action_id, action_type, result)
  end

  @doc """
  Handle set_wait_timer cast - sets timer with generation for race prevention.
  """
  @spec handle_set_wait_timer(non_neg_integer(), String.t(), State.t()) :: {:noreply, State.t()}
  def handle_set_wait_timer(duration, timer_id, state) do
    new_gen = state.timer_generation + 1

    # Cancel old timer if exists
    case state.wait_timer do
      {old_ref, _, _} -> Process.cancel_timer(old_ref)
      _ -> :ok
    end

    timer_ref = Process.send_after(self(), {:wait_timeout, timer_id, new_gen}, duration)

    {:noreply,
     %State{state | wait_timer: {timer_ref, timer_id, new_gen}, timer_generation: new_gen}}
  end

  @doc """
  Handle send_user_message cast.
  """
  @spec handle_send_user_message(String.t(), State.t()) :: {:noreply, State.t()}
  def handle_send_user_message(content, state) do
    MessageHandler.handle_send_user_message(state, content)
  end

  @doc """
  Handle log cast - broadcasts log entry to PubSub.
  """
  @spec handle_log(atom(), String.t(), State.t()) :: {:noreply, State.t()}
  def handle_log(level, message, state) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      "agents:#{state.agent_id}:logs",
      {:log_entry, %{agent_id: state.agent_id, level: level, message: message}}
    )

    {:noreply, state}
  end

  @doc """
  Handle internal message cast.
  """
  @spec handle_internal(atom(), any(), State.t()) :: {:noreply, State.t()}
  def handle_internal(type, data, state) do
    MessageHandler.handle_internal_message(state, type, data)
  end

  @doc """
  Handle store_mcp_client cast - stores MCP client pid in state.
  """
  @spec handle_store_mcp_client(pid(), State.t()) :: {:noreply, State.t()}
  def handle_store_mcp_client(mcp_client_pid, state) do
    {:noreply, %{state | mcp_client: mcp_client_pid}}
  end

  @doc """
  Handle batch_completed cast - notification when batch finishes.

  Individual results are already recorded via :batch_action_result casts.
  This adds a completion summary to history and triggers consensus continuation.
  """
  @spec handle_batch_completed(String.t(), list(), State.t()) :: {:noreply, State.t()}
  def handle_batch_completed(batch_id, results, state) do
    require Logger
    Logger.debug("Batch #{batch_id} completed with #{length(results)} results")

    # Count successes and failures (results are keyword list like [ok: %{}, error: {...}])
    succeeded = Enum.count(results, fn {status, _} -> status == :ok end)
    failed = length(results) - succeeded

    # Add completion summary to history
    completion = %{
      action: "batch_async",
      batch_id: batch_id,
      status: :completed,
      total: length(results),
      succeeded: succeeded,
      failed: failed
    }

    content = Jason.encode!(completion, pretty: true)
    state = StateUtils.add_history_entry(state, :result, content)

    # Trigger consensus continuation - batch is done, agent can proceed
    new_state = StateUtils.schedule_consensus_continuation(state)
    {:noreply, new_state}
  end
end
