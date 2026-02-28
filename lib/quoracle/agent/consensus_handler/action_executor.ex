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

    # Persist updated conversation history to database (skip in test mode for speed)
    unless Map.get(state, :test_mode, false) && !force_persist?(state) do
      Core.persist_conversation(state)
    end

    # Generate action ID using current counter
    # Use Map.get for optional fields (works with both structs and maps)
    counter = Map.get(state, :action_counter, 0)
    action_id = "action_#{state.agent_id}_#{counter + 1}"

    # Update action counter after generating ID
    state = Map.update(state, :action_counter, 1, &(&1 + 1))

    execute_opts = build_execute_opts(state, action_id, agent_pid, action_response)

    execute_opts = apply_timeout_override(execute_opts, action_atom)

    # v25.0: Route check_id through existing Router from shell_routers,
    # or spawn a new per-action Router for normal actions
    check_id = Helpers.extract_shell_check_id(params, action_atom)

    {router_pid, state} =
      if check_id do
        # Route through existing Router that has shell_command state
        shell_routers = Map.get(state, :shell_routers, %{})

        case Map.get(shell_routers, check_id) do
          nil ->
            # No Router found — spawn new one (will correctly get :command_not_found)
            spawn_and_monitor_router(state, action_atom, action_id, agent_pid)

          existing_pid ->
            # Verify Router is still alive — race between handle_down cleanup and check_id dispatch
            if Process.alive?(existing_pid) do
              {existing_pid, state}
            else
              spawn_and_monitor_router(state, action_atom, action_id, agent_pid)
            end
        end
      else
        # Normal flow: spawn new per-action Router
        spawn_and_monitor_router(state, action_atom, action_id, agent_pid)
      end

    # v35.0: Add to pending_actions BEFORE dispatch (non-blocking pattern)
    pending =
      Map.put(state.pending_actions, action_id, %{
        type: action_atom,
        params: params,
        timestamp: DateTime.utc_now()
      })

    state = %{state | pending_actions: pending}

    # Broadcast action execution to UI log panel (restored after async refactor)
    pubsub = Map.get(state, :pubsub)

    if is_atom(pubsub) and pubsub != :test_pubsub do
      LogHelper.safe_broadcast_log(
        state.agent_id,
        :info,
        "Executing action: #{action_atom}",
        %{action: action_atom, params: params},
        pubsub
      )
    end

    # v35.0: Dispatch to Task.Supervisor instead of blocking on Router.execute
    # Core returns immediately - result arrives via GenServer.cast({:action_result, ...})
    crash_in_task = Map.get(state, :crash_in_task)

    dispatch_action(
      router_pid,
      action_atom,
      params,
      state.agent_id,
      execute_opts,
      action_response,
      agent_pid,
      action_id,
      crash_in_task
    )

    # Return state immediately - action running in background
    state
  end

  # v35.0: Dispatch action execution to Task.Supervisor (non-blocking)
  # v36.0: Outer try/rescue/catch guarantees error delivery on task crash
  # Result sent back to Core via GenServer.cast
  @spec dispatch_action(
          pid(),
          atom(),
          map(),
          String.t(),
          keyword(),
          map(),
          pid(),
          String.t(),
          atom() | nil
        ) ::
          {:ok, pid()}
  defp dispatch_action(
         router_pid,
         action_atom,
         params,
         agent_id,
         execute_opts,
         action_response,
         agent_pid,
         action_id,
         crash_in_task
       ) do
    sandbox_owner = Keyword.get(execute_opts, :sandbox_owner)

    Task.Supervisor.start_child(Quoracle.SpawnTaskSupervisor, fn ->
      try do
        # Allow DB access in background task (test isolation)
        if sandbox_owner do
          Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, sandbox_owner, self())
        end

        # Crash injection for testing (FIX_DispatchTaskCrashPropagation)
        case crash_in_task do
          :raise -> raise "Injected crash for testing"
          :throw -> throw("Injected throw for testing")
          :exit -> exit("Injected exit for testing")
          _ -> :ok
        end

        result =
          try do
            Quoracle.Actions.Router.execute(
              router_pid,
              action_atom,
              params,
              agent_id,
              execute_opts
            )
          catch
            :exit, reason ->
              {:error, {:router_exit, Exception.format_exit(reason)}}
          end

        # Compute wait handling opts for result processing in Core
        wait_value = action_response |> Map.get(:wait) |> Helpers.coerce_wait_value()
        always_sync_list = Quoracle.Actions.Router.ClientAPI.always_sync_actions()

        result_opts = [
          action_atom: action_atom,
          wait_value: wait_value,
          always_sync: action_atom in always_sync_list,
          action_response: action_response,
          router_pid: router_pid,
          crash_protected: true
        ]

        # Send result back to Core via cast
        GenServer.cast(agent_pid, {:action_result, action_id, result, result_opts})
      rescue
        e ->
          Logger.error("Action dispatch task crashed: #{Exception.message(e)}")

          GenServer.cast(
            agent_pid,
            {:action_result, action_id, {:error, {:task_crash, Exception.message(e)}},
             [action_atom: action_atom]}
          )
      catch
        kind, value ->
          Logger.error("Action dispatch task crashed: #{kind} #{inspect(value)}")

          GenServer.cast(
            agent_pid,
            {:action_result, action_id, {:error, {:task_crash, "#{kind}: #{inspect(value)}"}},
             [action_atom: action_atom]}
          )
      end
    end)
  end

  # Force synchronous execution for actions whose latency exceeds the 100ms
  # smart_threshold.  Without an explicit timeout the Router enters "smart mode",
  # yields for only 100ms, and returns {:async_task, ...}.  The ActionExecutor
  # background Task then casts that opaque tuple as the "result", the agent
  # removes the action from pending_actions, and the *real* result arriving
  # later is silently discarded (unknown action_id).
  #
  # v36.0: :call_mcp — MCP retry delays (500ms+) exceed threshold.
  # v28.0: :adjust_budget — GenServer.call(parent, ..., :infinity) blocks.
  # v39.0: :answer_engine, :fetch_web, :call_api, :generate_images — HTTP
  #        API calls routinely exceed 100ms (DNS + TLS + server processing).
  @doc """
  Applies action-specific timeout overrides to execute_opts.

  Actions that exceed the Router's 100ms smart_threshold need explicit timeouts
  to prevent premature async dispatch. Returns opts with `:timeout` added via
  `Keyword.put_new/3` (existing timeout values are preserved).
  """
  @spec apply_timeout_override(keyword(), atom()) :: keyword()
  def apply_timeout_override(execute_opts, action_atom) do
    case action_atom do
      :call_mcp -> Keyword.put_new(execute_opts, :timeout, 600_000)
      :adjust_budget -> Keyword.put_new(execute_opts, :timeout, :infinity)
      :answer_engine -> Keyword.put_new(execute_opts, :timeout, 120_000)
      :fetch_web -> Keyword.put_new(execute_opts, :timeout, 60_000)
      :call_api -> Keyword.put_new(execute_opts, :timeout, 120_000)
      :generate_images -> Keyword.put_new(execute_opts, :timeout, 300_000)
      _ -> execute_opts
    end
  end

  defp build_execute_opts(state, action_id, agent_pid, _action_response) do
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

  # v25.0: Spawn a new Router and monitor it, adding to active_routers
  @spec spawn_and_monitor_router(map(), atom(), String.t(), pid()) :: {pid(), map()}
  defp spawn_and_monitor_router(state, action_atom, action_id, agent_pid) do
    {:ok, router_pid} =
      Quoracle.Actions.Router.start_link(
        action_type: action_atom,
        action_id: action_id,
        agent_id: state.agent_id,
        agent_pid: agent_pid,
        pubsub: Map.get(state, :pubsub),
        sandbox_owner: Map.get(state, :sandbox_owner)
      )

    monitor_ref = Process.monitor(router_pid)
    active_routers = Map.get(state, :active_routers, %{})
    state = Map.put(state, :active_routers, Map.put(active_routers, monitor_ref, router_pid))
    {router_pid, state}
  end

  defp force_persist?(state) do
    state |> Map.get(:test_opts, []) |> Keyword.get(:force_persist, false)
  end
end
