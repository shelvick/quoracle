defmodule Quoracle.Agent.ConsensusHandler.ActionExecutor do
  @moduledoc """
  Handles execution of consensus actions for AGENT_Core.
  Extracted from ConsensusHandler to reduce module size.
  """

  require Logger
  alias Quoracle.Agent.Core
  alias Quoracle.Agent.StateUtils
  alias Quoracle.Agent.ConsensusHandler.{Helpers, LogHelper}

  @doc """
  Executes a consensus action and updates agent state.
  """
  @spec execute_consensus_action(map(), map(), pid()) :: map()
  def execute_consensus_action(
        state,
        action_response,
        agent_pid \\ self()
      ) do
    %{action: action} = action_response
    # Validate wait parameter if required
    action_atom =
      if is_atom(action) do
        action
      else
        String.to_existing_atom(action)
      end

    # Check if wait parameter is required for this action
    wait_value = Map.get(action_response, :wait)

    # R10-R13: Default wait to false when nil (defense-in-depth after CONSENSUS_Result fix)
    action_response =
      if action_atom != :wait and is_nil(wait_value) do
        Logger.warning("Missing wait parameter for action: #{action}, defaulting to wait: false")

        Map.put(action_response, :wait, false)
      else
        action_response
      end

    # R14: For :wait action, derive response-level wait from params.wait
    # This prevents LLM confusion between params.wait (action parameter) and response-level wait
    # (consensus control). The params.wait already encodes the semantic intent.
    action_response =
      if action_atom == :wait do
        params_wait =
          get_in(action_response, [:params, :wait]) ||
            get_in(action_response, [:params, "wait"]) ||
            true

        # Coerce string "true"/"false" to boolean (LLMs return strings from JSON)
        # Default for :wait action is true (wait indefinitely)
        params_wait = Helpers.coerce_wait_value(params_wait)

        Map.put(action_response, :wait, params_wait)
      else
        action_response
      end

    # Normalize sibling_context: empty map -> empty list (LLM leniency, prevents learning wrong format)
    action_response = Helpers.normalize_sibling_context(action_response)

    execute_consensus_action_impl(state, action_response, agent_pid)
  end

  defp execute_consensus_action_impl(
         state,
         %{action: action, params: params} = action_response,
         agent_pid
       ) do
    # Ensure model_histories exists
    state = Map.put_new(state, :model_histories, %{})

    # Auto-correct wait:true on self-contained actions (would stall indefinitely)
    action_atom = if is_atom(action), do: action, else: String.to_existing_atom(action)

    # Coerce string "true"/"false" to boolean for wait comparison (LLMs return strings from JSON)
    wait_for_check = action_response |> Map.get(:wait) |> Helpers.coerce_wait_value()

    is_self_contained =
      action_atom in Helpers.self_contained_actions() or
        (action_atom == :batch_sync and Helpers.batch_all_self_contained?(action_response))

    action_response =
      if is_self_contained and wait_for_check == true do
        Logger.warning(
          "Auto-correcting wait:true to wait:false for #{action} action. " <>
            "This action completes instantly and cannot trigger external responses. " <>
            "Use wait:false to continue, or the :wait action if you need to pause."
        )

        Map.put(action_response, :wait, false)
      else
        action_response
      end

    # Add decision to history using StateUtils (with corrected wait value)
    state = StateUtils.add_history_entry(state, :decision, action_response)

    # Persist updated conversation history to database
    Core.persist_conversation(state)

    # Generate action ID using current counter
    # Use Map.get for optional fields (works with both structs and maps)
    counter = Map.get(state, :action_counter, 0)
    action_id = "action_#{state.agent_id}_#{counter + 1}"

    # Update action counter after generating ID
    state = Map.update(state, :action_counter, 1, &(&1 + 1))

    execute_opts = build_execute_opts(state, action_id, agent_pid, action_response)

    # Spawn per-action Router (v28.0) - Router terminates after action completes
    {:ok, router_pid} =
      Quoracle.Actions.Router.start_link(
        action_type: action_atom,
        action_id: action_id,
        agent_id: state.agent_id,
        agent_pid: agent_pid,
        pubsub: Map.get(state, :pubsub),
        sandbox_owner: Map.get(state, :sandbox_owner)
      )

    case Quoracle.Actions.Router.execute(
           router_pid,
           action_atom,
           params,
           state.agent_id,
           execute_opts
         ) do
      {:ok, result} ->
        handle_success(
          state,
          action,
          action_atom,
          action_id,
          params,
          result,
          action_response,
          agent_pid
        )

      {:async, ref} ->
        handle_async(state, action, action_atom, action_id, params, ref, nil, action_response)

      {:async, ref, ack} ->
        handle_async(state, action, action_atom, action_id, params, ref, ack, action_response)

      {:error, reason} ->
        handle_error(state, action_atom, action_id, reason)
    end
  end

  defp build_execute_opts(state, action_id, agent_pid, action_response) do
    budget_data = Map.get(state, :budget_data)

    [
      action_id: action_id,
      agent_id: state.agent_id,
      task_id: Map.get(state, :task_id) || state.agent_id,
      agent_pid: agent_pid,
      pubsub: Map.get(state, :pubsub),
      registry: Map.get(state, :registry),
      dynsup: Map.get(state, :dynsup),
      mcp_client: Map.get(state, :mcp_client),
      parent_config: state,
      # Pass dismissing state to avoid GenServer callback deadlock in Spawn
      dismissing: Map.get(state, :dismissing, false),
      # Pass capability_groups for permission enforcement in Router (v2.0 system)
      capability_groups: Map.get(state, :capability_groups, []),
      # Pass budget_data for BudgetValidation in Spawn (v2.0 budget propagation)
      budget_data: budget_data,
      # Query spent from Tracker only when budget_data has a budgeted mode
      # (avoids unnecessary DB query for non-budgeted agents)
      spent: query_spent_if_budgeted(budget_data, state.agent_id)
    ]
    |> maybe_put(:sandbox_owner, Map.get(state, :sandbox_owner))
    |> maybe_put(:spawn_complete_notify, Map.get(state, :spawn_complete_notify))
    |> maybe_put(:auto_complete_todo, Map.get(action_response, :auto_complete_todo))
  end

  # Conditionally add a key to opts when the value is non-nil
  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Only query DB for spent when the agent has a budgeted mode (:root or :allocated).
  # Non-budgeted agents (nil, :na) don't need spent for any budget checks.
  @spec query_spent_if_budgeted(map() | nil, String.t()) :: Decimal.t()
  defp query_spent_if_budgeted(%{mode: mode}, agent_id)
       when mode in [:root, :allocated] do
    Quoracle.Budget.Tracker.get_spent(agent_id)
  end

  defp query_spent_if_budgeted(_budget_data, _agent_id), do: Decimal.new("0")

  defp handle_success(
         state,
         action,
         action_atom,
         action_id,
         params,
         result,
         action_response,
         agent_pid
       ) do
    Logger.info("Agent #{state.agent_id} executed action: #{action}")

    # Broadcast to UI
    pubsub = Map.get(state, :pubsub)

    if is_atom(pubsub) and pubsub != :test_pubsub do
      LogHelper.safe_broadcast_log(
        state.agent_id,
        :info,
        "Executed action: #{action}",
        %{action: action, params: params},
        pubsub
      )
    end

    # Add to pending actions
    pending =
      Map.put(state.pending_actions, action_id, %{
        type: action,
        params: params,
        timestamp: DateTime.utc_now()
      })

    state = %{state | pending_actions: pending}

    # Track spawned children immediately (don't wait for background task cast)
    # Child appears in <children> list right away; filter_live_children handles failures
    state =
      if action_atom == :spawn_child and is_map(result) and Map.has_key?(result, :agent_id) do
        child_data = %{
          agent_id: result.agent_id,
          spawned_at: Map.get(result, :spawned_at, DateTime.utc_now()),
          budget_allocated: Map.get(result, :budget_allocated)
        }

        Map.update(state, :children, [child_data], &[child_data | &1])
      else
        state
      end

    # Check if this is a synchronous result (completed immediately)
    # DEFAULT TO TRUE - only Shell with async: true explicitly sets sync: false
    is_sync = Map.get(result, :sync, true)
    wait_value = Map.get(action_response, :wait)

    # Coerce string "true"/"false" to boolean (LLMs return strings from JSON)
    wait_value = Helpers.coerce_wait_value(wait_value)

    # Always-sync actions complete instantly - for these, wait: true means
    # "wait for external event", not "wait for this result"
    # See AGENT_ConsensusHandler.md §24 for wait parameter semantics
    always_sync = Quoracle.Actions.Router.ClientAPI.always_sync_actions()

    handle_sync_result(
      state,
      action_atom,
      action_id,
      result,
      wait_value,
      is_sync,
      always_sync,
      agent_pid
    )
  end

  defp handle_sync_result(
         state,
         action_atom,
         action_id,
         result,
         wait_value,
         is_sync,
         always_sync,
         _agent_pid
       ) do
    if is_nil(wait_value) do
      state
    else
      # 1. ALWAYS add result to history (fixes async shell bug where ack was missing)
      state =
        Quoracle.Agent.ConsensusHandler.process_action_result(
          state,
          {action_atom, action_id, result}
        )

      # 2. Handle pending_actions: delete for sync, mark acked for async
      state =
        if is_sync do
          %{state | pending_actions: Map.delete(state.pending_actions, action_id)}
        else
          updated_action = Map.put(state.pending_actions[action_id], :acked, true)
          %{state | pending_actions: Map.put(state.pending_actions, action_id, updated_action)}
        end

      # 3. Handle wait logic
      cond do
        # Always-sync with wait:true → no trigger (wait for external event)
        is_sync and wait_value == true and action_atom in always_sync ->
          state

        # Sync with wait:true → trigger consensus (result is ready)
        is_sync and wait_value == true ->
          StateUtils.schedule_consensus_continuation(state)

        # Sync with wait:false/0 → trigger consensus directly
        # (don't go through handle_wait_parameter which cancels timer)
        is_sync and wait_value in [false, 0] ->
          StateUtils.schedule_consensus_continuation(state)

        # :wait action owns its timer - use it instead of creating another
        action_atom == :wait and is_map(result) and is_reference(result[:timer_id]) ->
          state = StateUtils.cancel_wait_timer(state)
          %{state | wait_timer: {result.timer_id, :timed_wait}}

        # Everything else (async, timed waits) → delegate to handle_wait_parameter
        true ->
          Quoracle.Agent.ConsensusHandler.handle_wait_parameter(state, action_atom, wait_value)
      end
    end
  end

  defp handle_async(state, action, action_atom, action_id, params, ref, ack, action_response) do
    Logger.info(
      "Agent #{state.agent_id} dispatched async action: #{action} (ref: #{inspect(ref)})"
    )

    # Broadcast to UI
    pubsub = Map.get(state, :pubsub)

    if is_atom(pubsub) and pubsub != :test_pubsub do
      LogHelper.safe_broadcast_log(
        state.agent_id,
        :info,
        "Dispatched async action: #{action}",
        %{action: action, params: params, async_ref: ref},
        pubsub
      )
    end

    # Store the async reference in pending actions
    pending =
      Map.put(state.pending_actions, action_id, %{
        type: action,
        params: params,
        async_ref: ref,
        timestamp: DateTime.utc_now()
      })

    state = %{state | pending_actions: pending}

    # If acknowledgement provided, add it to history so LLM sees it
    # This prevents history from ending on an assistant message
    # Also mark as acked - allows messages to flow while keeping action tracked for completion
    # (fixes deadlock where daemon commands like `mix phx.server` block all incoming messages)
    state =
      if ack do
        state =
          Quoracle.Agent.ConsensusHandler.process_action_result(
            state,
            {action_atom, action_id, ack}
          )

        # Mark as acked so MessageHandler doesn't queue messages for this action
        updated_action = Map.put(state.pending_actions[action_id], :acked, true)
        %{state | pending_actions: Map.put(state.pending_actions, action_id, updated_action)}
      else
        state
      end

    # Handle wait parameter for async actions
    wait_value = action_response |> Map.get(:wait) |> Helpers.coerce_wait_value()

    if wait_value do
      Quoracle.Agent.ConsensusHandler.handle_wait_parameter(state, action_atom, wait_value)
    else
      # wait: false or 0 - continue immediately
      StateUtils.schedule_consensus_continuation(state)
    end
  end

  defp handle_error(state, action_atom, action_id, reason) do
    # Log validation errors at warning level (LLM producing invalid actions)
    # Log other errors at error level (system failures)
    LogHelper.log_action_error(reason)

    # Store error in history (LLM memory) - errors bypass wait, continue immediately
    state =
      StateUtils.add_history_entry_with_action(
        state,
        :result,
        {action_id, {:error, reason}},
        action_atom
      )

    # Continue consensus immediately - errors don't wait
    StateUtils.schedule_consensus_continuation(state)
  end
end
