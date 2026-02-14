defmodule Quoracle.Agent.MessageHandler.ActionResultHandler do
  @moduledoc """
  Handles action result processing for Agent.Core.
  Extracted from MessageHandler to keep it under 500 lines.

  Processes results from non-blocking action dispatch (v35.0):
  - Records results in history with NO_EXECUTE tracking
  - Tracks spawned children
  - Updates budget_committed for spawn_child results
  - Flushes queued messages after result processing
  - Handles wait parameter continuation logic
  """

  require Logger

  alias Quoracle.Agent.{
    ConsensusHandler,
    ImageDetector,
    StateUtils
  }

  alias Quoracle.Agent.ConsensusHandler.LogHelper
  alias Quoracle.PubSub.AgentEvents

  @doc """
  Handle action result processing.

  ## Options
    * `:continue` - Whether to trigger next consensus cycle (default: true).
      Set to false for always-sync actions with wait: true, where the agent
      wants to wait for an external event rather than continue immediately.
      See AGENT_ConsensusHandler.md S24 for wait parameter semantics.
    * `:action_atom` - Action type atom (v35.0, from non-blocking dispatch)
    * `:wait_value` - Coerced wait value (v35.0, from non-blocking dispatch)
    * `:always_sync` - Whether action is always-sync (v35.0, from non-blocking dispatch)
    * `:action_response` - Original action response map (v35.0, from non-blocking dispatch)
  """
  @spec handle_action_result(map(), String.t(), any(), keyword()) :: {:noreply, map()}
  def handle_action_result(state, action_id, result, opts \\ []) do
    case Map.get(state.pending_actions, action_id) do
      nil ->
        # Action not in pending - either already processed (duplicate) or truly unknown
        # Don't store again to prevent duplicate results in history
        Logger.warning("Received result for unknown/already-processed action: #{action_id}")
        {:noreply, state}

      action_info ->
        process_action_result(state, action_id, result, opts, action_info)
    end
  end

  @doc """
  Handle batch sub-action result - records result directly without pending_actions lookup.

  Used by BatchSync which spawns Routers directly and can't add to pending_actions
  (would cause deadlock since we're already inside a GenServer.call).
  """
  @spec handle_batch_action_result(map(), String.t(), atom(), any()) :: {:noreply, map()}
  def handle_batch_action_result(state, action_id, action_type, result) do
    # Store result in history with action_type for NO_EXECUTE tracking
    new_state =
      case ImageDetector.detect(result, action_type) do
        {:image, multimodal_content} ->
          StateUtils.add_history_entry(state, :image, multimodal_content)

        {:text, _original_result} ->
          StateUtils.add_history_entry_with_action(
            state,
            :result,
            {action_id, result},
            action_type
          )
      end

    {:noreply, new_state}
  end

  @doc """
  Flush queued messages to history in FIFO order.

  Messages are queued during action execution (to prevent history alternation
  errors) and flushed when the action result arrives or when a consensus
  cycle starts.
  """
  @spec flush_queued_messages(map()) :: map()
  def flush_queued_messages(%{queued_messages: []} = state), do: state

  def flush_queued_messages(%{queued_messages: msgs} = state) do
    msgs
    |> Enum.reduce(state, fn msg, acc ->
      StateUtils.add_history_entry(acc, :event, %{
        from: format_sender_id(msg.sender_id),
        content: msg.content
      })
    end)
    |> Map.put(:queued_messages, [])
  end

  def flush_queued_messages(state), do: state

  @doc """
  Format sender_id atoms to strings for LLM context.

  R27: :parent -> "parent"
  R28: binary strings preserved as-is
  R73: :user -> "user" (v18.0)
  """
  @spec format_sender_id(atom() | String.t()) :: String.t()
  def format_sender_id(:parent), do: "parent"
  def format_sender_id(:user), do: "user"
  def format_sender_id(sender_id) when is_binary(sender_id), do: sender_id

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp process_action_result(state, action_id, result, opts, action_info) do
    # Broadcast action completed or error
    pubsub = Map.get(state, :pubsub)
    action_type = Map.get(action_info, :type)

    case result do
      {:ok, _} = success ->
        AgentEvents.broadcast_action_completed(state.agent_id, action_id, success, pubsub)

      {:error, _} = error ->
        AgentEvents.broadcast_action_error(state.agent_id, action_id, error, pubsub)

      _ ->
        AgentEvents.broadcast_action_completed(state.agent_id, action_id, result, pubsub)
    end

    # Broadcast action result to UI log panel
    broadcast_action_result_log(pubsub, state.agent_id, action_type, action_id, result)

    # Route through ImageDetector to handle multimodal content
    # Images are stored as :image type, text results as :result type
    new_state =
      case ImageDetector.detect(result, action_type) do
        {:image, multimodal_content} ->
          # Store image as :image type for multimodal LLM messages
          StateUtils.add_history_entry(state, :image, multimodal_content)

        {:text, _original_result} ->
          # Store non-image results as :result type with action tracking
          if action_type do
            StateUtils.add_history_entry_with_action(
              state,
              :result,
              {action_id, result},
              action_type
            )
          else
            # Fallback for missing action type (shouldn't happen in normal flow)
            StateUtils.add_history_entry(state, :result, {action_id, result})
          end
      end

    # Remove from pending_actions
    new_state = %{
      new_state
      | pending_actions: Map.delete(new_state.pending_actions, action_id)
    }

    # v35.0 R5: Track spawned children when action_atom is :spawn_child
    new_state = maybe_track_child(new_state, result, opts)

    # v35.0 R67: Update budget_committed for spawn_child results
    new_state = maybe_update_budget_committed(new_state, result, opts)

    # v25.0: Track shell Router for check_id routing
    new_state = maybe_track_shell_router(new_state, result, opts)

    # v12.0 R3-R6: Flush queued messages after action result
    # Result is already in history, now add queued messages in FIFO order
    new_state = flush_queued_messages(new_state)

    # v35.0: Extended wait parameter handling from non-blocking dispatch opts
    handle_action_result_continuation(new_state, result, opts)
  end

  # v35.0 R5: Track spawned children from non-blocking dispatch results
  defp maybe_track_child(state, {:ok, child_result}, opts)
       when is_map(child_result) do
    if Keyword.get(opts, :action_atom) == :spawn_child and
         Map.has_key?(child_result, :agent_id) do
      child_data = %{
        agent_id: child_result.agent_id,
        spawned_at: Map.get(child_result, :spawned_at, DateTime.utc_now()),
        budget_allocated: Map.get(child_result, :budget_allocated)
      }

      Map.update(state, :children, [child_data], &[child_data | &1])
    else
      state
    end
  end

  defp maybe_track_child(state, _result, _opts), do: state

  # v35.0 R67: Update budget_committed when spawn_child result includes budget_allocated
  # Replaces the removed Core.update_budget_committed callback from Spawn (FIX_BudgetCallbackElimination)
  defp maybe_update_budget_committed(state, {:ok, child_result}, opts)
       when is_map(child_result) do
    if Keyword.get(opts, :action_atom) == :spawn_child do
      budget_allocated = Map.get(child_result, :budget_allocated)

      if budget_allocated && state.budget_data do
        current_committed = state.budget_data.committed || Decimal.new(0)
        new_committed = Decimal.add(current_committed, budget_allocated)
        %{state | budget_data: %{state.budget_data | committed: new_committed}}
      else
        state
      end
    else
      state
    end
  end

  defp maybe_update_budget_committed(state, _result, _opts), do: state

  # v25.0: Track shell Router PID in shell_routers for check_id routing.
  # Keyed by command_id from async shell result (what the LLM uses in check_id).
  @spec maybe_track_shell_router(map(), any(), keyword()) :: map()
  defp maybe_track_shell_router(state, {:ok, %{command_id: cmd_id, async: true}}, opts)
       when is_binary(cmd_id) do
    router_pid = Keyword.get(opts, :router_pid)

    if router_pid && is_pid(router_pid) && Process.alive?(router_pid) do
      %{state | shell_routers: Map.put(state.shell_routers, cmd_id, router_pid)}
    else
      state
    end
  end

  defp maybe_track_shell_router(state, {:ok, %{command_id: cmd_id, status: :running}}, opts)
       when is_binary(cmd_id) do
    router_pid = Keyword.get(opts, :router_pid)

    if router_pid && is_pid(router_pid) && Process.alive?(router_pid) do
      %{state | shell_routers: Map.put(state.shell_routers, cmd_id, router_pid)}
    else
      state
    end
  end

  defp maybe_track_shell_router(state, _result, _opts), do: state

  # v35.0 R4: Extended wait parameter handling for non-blocking dispatch
  defp handle_action_result_continuation(new_state, result, opts) do
    action_atom = Keyword.get(opts, :action_atom)
    wait_value = Keyword.get(opts, :wait_value)
    always_sync = Keyword.get(opts, :always_sync, false)

    cond do
      # No wait info (legacy async path) -> use existing continue logic
      is_nil(action_atom) ->
        if Keyword.get(opts, :continue, true) do
          new_state = Map.put(new_state, :consensus_scheduled, true)
          send(self(), :trigger_consensus)
          {:noreply, new_state}
        else
          {:noreply, new_state}
        end

      # Always-sync with wait:true AND success -> wait for external event (no consensus)
      # Error results fall through to continue consensus (agent would stall forever otherwise)
      always_sync and wait_value == true and match?({:ok, _}, result) ->
        {:noreply, new_state}

      # :wait action with timer result -> set wait_timer
      action_atom == :wait and map_result_with_timer?(result) ->
        new_state = StateUtils.cancel_wait_timer(new_state)
        timer_id = get_timer_from_result(result)
        {:noreply, %{new_state | wait_timer: {timer_id, :timed_wait}}}

      # wait:false/0 or wait:true (non-always-sync) -> continue consensus
      wait_value in [false, 0] or wait_value == true ->
        new_state = StateUtils.schedule_consensus_continuation(new_state)
        {:noreply, new_state}

      # Timed wait (positive integer) -> set timer via handle_wait_parameter
      is_integer(wait_value) and wait_value > 0 ->
        new_state =
          ConsensusHandler.handle_wait_parameter(new_state, action_atom, wait_value)

        {:noreply, new_state}

      # Default -> continue consensus
      true ->
        new_state = StateUtils.schedule_consensus_continuation(new_state)
        {:noreply, new_state}
    end
  end

  # Check if result contains a timer reference (from :wait action)
  defp map_result_with_timer?({:ok, result}) when is_map(result),
    do: is_reference(result[:timer_id])

  defp map_result_with_timer?(_), do: false

  # Extract timer reference from result
  defp get_timer_from_result({:ok, result}) when is_map(result), do: result.timer_id

  # Broadcast action result to UI log panel (guard-based to satisfy dialyzer)
  defp broadcast_action_result_log(pubsub, agent_id, action_type, action_id, {:error, reason})
       when is_atom(pubsub) and pubsub != :test_pubsub do
    LogHelper.safe_broadcast_log(
      agent_id,
      :error,
      "Action failed: #{action_type}",
      %{action: action_type, action_id: action_id, error: reason},
      pubsub
    )
  end

  defp broadcast_action_result_log(pubsub, agent_id, action_type, action_id, _result)
       when is_atom(pubsub) and pubsub != :test_pubsub do
    LogHelper.safe_broadcast_log(
      agent_id,
      :info,
      "Action completed: #{action_type}",
      %{action: action_type, action_id: action_id},
      pubsub
    )
  end

  defp broadcast_action_result_log(_pubsub, _agent_id, _action_type, _action_id, _result), do: :ok
end
