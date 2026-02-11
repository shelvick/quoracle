defmodule Quoracle.Agent.Core do
  @moduledoc """
  Event-driven GenServer that delegates all decision-making to LLMs via consensus.
  The agent is purely reactive with no internal logic or goals.
  """

  use GenServer
  require Logger
  alias Quoracle.PubSub.AgentEvents

  alias Quoracle.Agent.{TokenManager, HistoryTransfer}

  alias Quoracle.Agent.Core.{
    State,
    Persistence,
    MessageInfoHandler,
    TodoHandler,
    ChildrenTracker,
    Initialization,
    BudgetHandler
  }

  @doc """
  Custom child_spec for Core agents.

  Uses default 5000ms shutdown timeout. Core enables trap_exit to ensure
  terminate/2 runs on EXIT signals, allowing proper Router cleanup.
  The 5000ms timeout is sufficient because Router.terminate completes quickly.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(init_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [init_arg]},
      type: :worker
    }
  end

  @spec start_link(map() | {pid(), String.t()} | {pid(), String.t(), keyword()}) ::
          GenServer.on_start()
  @spec start_link(map() | {pid(), String.t()} | {pid(), String.t(), keyword()}, keyword()) ::
          GenServer.on_start()

  # Production interface - uses global registry
  def start_link(config) do
    start_link(config, [])
  end

  # Dependency injection interface - accepts registry and dynsup options
  def start_link(config, opts) when is_list(config) and is_list(opts) do
    # Handle keyword list config - convert to map and proceed
    GenServer.start_link(__MODULE__, {Map.new(config), opts})
  end

  def start_link(%{} = config, opts) do
    # Pass options through to init
    GenServer.start_link(__MODULE__, {config, opts})
  end

  def start_link({parent_pid, initial_prompt}, opts) do
    # Handle tuple config from tests with options
    GenServer.start_link(__MODULE__, {{parent_pid, initial_prompt}, opts})
  end

  def start_link({parent_pid, initial_prompt, test_opts}, opts) do
    # Handle tuple config with test options from tests
    GenServer.start_link(__MODULE__, {{parent_pid, initial_prompt, test_opts}, opts})
  end

  # Delegate simple client API functions to ClientAPI module
  alias Quoracle.Agent.Core.ClientAPI

  @spec get_agent_id(pid()) :: {:ok, String.t()} | String.t()
  defdelegate get_agent_id(agent), to: ClientAPI
  @spec get_state(pid()) :: {:ok, map()}
  defdelegate get_state(agent), to: ClientAPI
  @spec get_model_histories(pid()) :: {:ok, map()}
  defdelegate get_model_histories(agent), to: ClientAPI

  @spec get_pending_actions(pid()) :: {:ok, map()}
  defdelegate get_pending_actions(agent), to: ClientAPI
  @spec get_wait_timer(pid()) :: {:ok, reference() | nil}
  defdelegate get_wait_timer(agent), to: ClientAPI
  @spec handle_message(pid(), any()) :: :ok
  defdelegate handle_message(agent, message), to: ClientAPI
  @spec add_pending_action(pid(), String.t(), atom(), map()) :: :ok
  defdelegate add_pending_action(agent, action_id, type, params), to: ClientAPI
  @spec handle_action_result(pid(), String.t(), any()) :: :ok
  defdelegate handle_action_result(agent, action_id, result), to: ClientAPI
  @spec set_wait_timer(pid(), non_neg_integer(), String.t()) :: :ok
  defdelegate set_wait_timer(agent, duration, timer_id), to: ClientAPI
  @spec send_user_message(pid(), String.t()) :: :ok
  defdelegate send_user_message(agent, content), to: ClientAPI
  @spec wait_for_ready(pid(), timeout()) :: :ok | {:error, :timeout}
  defdelegate wait_for_ready(agent, timeout \\ :infinity), to: ClientAPI
  @spec handle_agent_message(pid(), String.t()) :: :ok
  defdelegate handle_agent_message(agent, content), to: ClientAPI
  @spec handle_internal_message(pid(), atom(), any()) :: :ok
  defdelegate handle_internal_message(agent, type, data), to: ClientAPI

  # Dismiss child race prevention (v19.0)
  @spec set_dismissing(pid(), boolean()) :: :ok
  defdelegate set_dismissing(agent, value), to: ClientAPI
  @spec dismissing?(pid()) :: boolean()
  defdelegate dismissing?(agent), to: ClientAPI

  # Budget system (v4.0, v22.0)
  @spec update_budget_committed(pid(), Decimal.t()) :: :ok
  defdelegate update_budget_committed(agent, amount), to: ClientAPI
  @spec release_budget_committed(pid(), Decimal.t()) :: :ok
  defdelegate release_budget_committed(agent, amount), to: ClientAPI
  @spec release_child_budget(pid(), Decimal.t(), Decimal.t()) :: :ok
  defdelegate release_child_budget(pid, child_allocated, child_spent), to: ClientAPI
  @spec get_budget(pid()) :: {:ok, %{budget_data: map(), over_budget: boolean()}}
  defdelegate get_budget(agent), to: ClientAPI

  # Budget system (v23.0) - adjust_child_budget, update_budget_data
  @spec adjust_child_budget(String.t(), String.t(), Decimal.t(), keyword()) ::
          :ok | {:error, term()}
  defdelegate adjust_child_budget(parent_id, child_id, new_budget, opts), to: ClientAPI
  @spec update_budget_data(pid(), map()) :: :ok
  defdelegate update_budget_data(pid, budget_data), to: ClientAPI

  # Runtime model pool switching (v21.0)
  @doc """
  Switch the agent's model pool at runtime.

  Blocks until completion. Any in-flight consensus will complete first
  due to GenServer message ordering.

  Returns :ok on success, {:error, reason} on failure.
  """
  @spec switch_model_pool(pid(), [String.t()]) :: :ok | {:error, atom()}
  def switch_model_pool(agent_pid, new_pool) when is_pid(agent_pid) and is_list(new_pool) do
    GenServer.call(agent_pid, {:switch_model_pool, new_pool}, :infinity)
  end

  # Delegate Registry query functions to RegistryQueries
  alias Quoracle.Agent.RegistryQueries

  @doc """
  Find all child agents of a given parent PID by querying composite values.
  Registry is required.
  """
  @spec find_children_by_parent(pid(), atom()) :: [{pid(), map()}]
  defdelegate find_children_by_parent(parent_pid, registry), to: RegistryQueries

  @doc """
  Get the parent PID of an agent from the Registry. Registry is required.
  """
  @spec get_parent_from_registry(String.t(), atom()) :: pid() | nil
  defdelegate get_parent_from_registry(agent_id, registry), to: RegistryQueries

  @doc """
  Find all sibling agents. Registry is required.
  """
  @spec find_siblings(pid(), atom()) :: [{pid(), map()}]
  defdelegate find_siblings(agent_pid, registry), to: RegistryQueries

  # Delegate token counting functions to TokenManager
  defdelegate estimate_tokens(text), to: TokenManager
  defdelegate estimate_history_tokens(history), to: TokenManager
  defdelegate update_token_usage(state, api_response), to: TokenManager
  defdelegate context_usage_percentage(state), to: TokenManager
  defdelegate estimate_total_context_tokens(state, opts \\ []), to: TokenManager

  @impl true
  def init({config, opts}) do
    Initialization.init({config, opts})
  end

  def init(config) do
    # Backward compatibility - no options provided
    init({config, []})
  end

  @impl true
  def handle_continue(:complete_db_setup, state) do
    Initialization.handle_continue_db_setup(state)
  end

  @impl true
  def handle_continue(:load_context_limit, state) do
    Initialization.handle_continue_load_context_limit(state)
  end

  @impl true
  def handle_call(:get_agent_id, _from, state) do
    {:reply, state.agent_id, state}
  end

  def handle_call(:get_task_id, _from, state) do
    {:reply, state.task_id, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call(:get_model_histories, _from, state) do
    {:reply, {:ok, state.model_histories}, state}
  end

  def handle_call(:get_pending_actions, _from, state) do
    {:reply, {:ok, state.pending_actions}, state}
  end

  def handle_call(:get_wait_timer, _from, state) do
    timer =
      case state.wait_timer do
        {ref, _id, _gen} -> ref
        other -> other
      end

    {:reply, {:ok, timer}, state}
  end

  def handle_call(:get_mcp_client, _from, state) do
    {:reply, state.mcp_client, state}
  end

  # Dismiss child race prevention (v19.0)
  def handle_call({:set_dismissing, value}, _from, state) when is_boolean(value) do
    {:reply, :ok, %{state | dismissing: value}}
  end

  def handle_call(:dismissing?, _from, state) do
    {:reply, state.dismissing, state}
  end

  # Budget system (v4.0) - delegated to BudgetHandler (v24.0)
  def handle_call({:update_budget_committed, amount}, _from, state) do
    BudgetHandler.handle_update_budget_committed(amount, state)
  end

  def handle_call({:release_budget_committed, amount}, _from, state) do
    BudgetHandler.handle_release_budget_committed(amount, state)
  end

  # Release child budget with proper escrow math (v34.0)
  def handle_call({:release_child_budget, child_allocated, child_spent}, _from, state) do
    BudgetHandler.handle_release_child_budget(child_allocated, child_spent, state)
  end

  # Get current budget state (v22.0)
  def handle_call(:get_budget, _from, state) do
    BudgetHandler.handle_get_budget(state)
  end

  # Adjust child budget (v23.0)
  def handle_call({:adjust_child_budget, child_id, new_budget, opts}, _from, state) do
    case BudgetHandler.adjust_child_budget(state, child_id, new_budget, opts) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Update budget_data (v23.0)
  def handle_call({:update_budget_data, budget_data}, _from, state) do
    BudgetHandler.handle_update_budget_data(budget_data, state)
  end

  # Runtime model pool switching (v21.0) - delegated to HistoryTransfer (v24.0)
  def handle_call({:switch_model_pool, new_pool}, _from, state) do
    case HistoryTransfer.switch_model_pool(state, new_pool) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Test-specific handlers - delegated to TestActionHandler module
  alias Quoracle.Agent.Core.TestActionHandler

  def handle_call({:execute_action, action}, _from, state) do
    TestActionHandler.handle_execute_action(action, state)
  end

  def handle_call(:sync, _from, state) do
    TestActionHandler.handle_sync(state)
  end

  def handle_call({:process_action, action_map, action_id}, _from, state) do
    TestActionHandler.handle_process_action(action_map, action_id, state)
  end

  # v30.0: Per-action Router shell routing
  def handle_call({:shell_status, command_id}, _from, state),
    do: route_to_shell_router(command_id, :get_shell_status, state)

  def handle_call({:terminate_shell, command_id}, _from, state),
    do: route_to_shell_router(command_id, :terminate_shell, state)

  def handle_call(:wait_for_ready, _from, %State{state: :ready} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:wait_for_ready, from, %State{state: :initializing} = state) do
    # Add caller to waiting list
    {:noreply, %State{state | waiting_for_ready: [from | state.waiting_for_ready]}}
  end

  def handle_call(:wait_for_ready, _from, %State{state: status} = state) do
    {:reply, {:error, {:invalid_state, status}}, state}
  end

  def handle_call(:get_todos, _from, state) do
    TodoHandler.handle_get_todos(state)
  end

  # Skills system (v27.0) - prompt opts for PromptBuilder
  def handle_call(:get_prompt_opts, _from, state) do
    prompt_opts = %{
      active_skills: state.active_skills,
      capability_groups: state.capability_groups
    }

    {:reply, {:ok, prompt_opts}, state}
  end

  def handle_cast(:mark_first_todo_done, state) do
    TodoHandler.handle_mark_first_todo_done(state)
  end

  # Uses cast (not call) to avoid deadlock when called from action execution
  # while agent is blocked in handle_cast(:request_consensus)
  def handle_cast({:update_todos, items}, state) when is_list(items) do
    TodoHandler.handle_update_todos(items, state)
  end

  def handle_cast({:child_spawned, data}, state) do
    ChildrenTracker.handle_child_spawned(data, state)
  end

  def handle_cast({:child_dismissed, child_id}, state) do
    ChildrenTracker.handle_child_dismissed(child_id, state)
  end

  def handle_cast({:child_restored, data}, state) do
    ChildrenTracker.handle_child_restored(data, state)
  end

  # Skills system (v27.0) - append learned skills to active_skills
  def handle_cast({:learn_skills, skills_metadata}, state) when is_list(skills_metadata) do
    updated_skills = state.active_skills ++ skills_metadata
    {:noreply, %{state | active_skills: updated_skills}}
  end

  # Message and action handling - delegated to CastHandler (v24.0)
  alias Quoracle.Agent.Core.CastHandler

  @impl true
  def handle_cast({:agent_message, content}, state),
    do: CastHandler.handle_agent_message(content, state)

  def handle_cast({:message, message}, state), do: CastHandler.handle_message(message, state)

  def handle_cast({:add_pending_action, action_id, type, params}, state),
    do: CastHandler.handle_add_pending_action(action_id, type, params, state)

  def handle_cast({:action_result, action_id, result}, state),
    do: CastHandler.handle_action_result(action_id, result, [], state)

  def handle_cast({:action_result, action_id, result, opts}, state),
    do: CastHandler.handle_action_result(action_id, result, opts, state)

  # Batch sub-action result - includes action_type directly (no pending_actions lookup)
  def handle_cast({:batch_action_result, action_id, action_type, result}, state),
    do: CastHandler.handle_batch_action_result(action_id, action_type, result, state)

  # Batch completed notification - fire-and-forget mode completion
  def handle_cast({:batch_completed, batch_id, results}, state),
    do: CastHandler.handle_batch_completed(batch_id, results, state)

  def handle_cast({:set_wait_timer, duration, timer_id}, state),
    do: CastHandler.handle_set_wait_timer(duration, timer_id, state)

  def handle_cast({:send_user_message, content}, state),
    do: CastHandler.handle_send_user_message(content, state)

  def handle_cast({:log, level, message}, state),
    do: CastHandler.handle_log(level, message, state)

  def handle_cast({:internal, type, data}, state),
    do: CastHandler.handle_internal(type, data, state)

  def handle_cast({:store_mcp_client, mcp_client_pid}, state),
    do: CastHandler.handle_store_mcp_client(mcp_client_pid, state)

  def handle_cast(_msg, state), do: {:noreply, state}

  # Handle info messages - delegated to MessageInfoHandler (v24.0)
  @impl true
  def handle_info({:message, message}, state),
    do: MessageInfoHandler.handle_message_info(message, state)

  def handle_info({:agent_error, pid, reason}, state),
    do: MessageInfoHandler.handle_agent_error(pid, reason, state)

  def handle_info({:wait_timeout, timer_id, gen}, state),
    do: MessageInfoHandler.handle_wait_timeout(timer_id, gen, state)

  def handle_info({:wait_expired, timer_ref}, state),
    do: MessageInfoHandler.handle_wait_expired(timer_ref, state)

  # v19.0: Unified consensus trigger message
  def handle_info(:trigger_consensus, state),
    do: MessageInfoHandler.handle_trigger_consensus(state)

  # v29.0: Stop request from TaskRestorer - drains triggers and terminates gracefully
  def handle_info(:stop_requested, state) do
    # Drain accumulated triggers to prevent extra cycles before stop
    drain_count = MessageInfoHandler.drain_trigger_messages()

    if drain_count > 0 do
      Logger.debug("Drained #{drain_count} triggers during stop_requested")
    end

    # Return {:stop, :normal, state} to terminate gracefully
    # This triggers terminate/2 which cleans up Router and persists state
    {:stop, :normal, state}
  end

  def handle_info({:shell_registered, _command_id}, state), do: {:noreply, state}

  def handle_info({:agent_message, content}, state),
    do: MessageInfoHandler.handle_agent_message_2tuple(content, state)

  def handle_info({:agent_message, sender_id, content}, state),
    do: MessageInfoHandler.handle_agent_message_3tuple(sender_id, content, state)

  def handle_info({:DOWN, ref, :process, pid, reason}, state),
    do: MessageInfoHandler.handle_down(ref, pid, reason, state)

  def handle_info({:cost_recorded, _}, state),
    do: {:noreply, BudgetHandler.update_over_budget_status(state)}

  def handle_info({:EXIT, pid, reason}, state),
    do: MessageInfoHandler.handle_exit(pid, reason, state)

  @impl true
  def terminate(reason, %State{} = state) do
    # v30.0: Stop all active Routers with :infinity timeout to allow DB operations
    for {_ref, router_pid} <- state.active_routers do
      if Process.alive?(router_pid) do
        try do
          GenServer.stop(router_pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end

    Persistence.persist_ace_state(state)

    try do
      AgentEvents.broadcast_agent_terminated(state.agent_id, reason, state.pubsub)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # Database Persistence (Packet 3) - Delegated to Core.Persistence

  @doc """
  Persist agent to database during initialization.
  Delegated to Core.Persistence module.
  """
  @spec persist_agent(State.t()) :: :ok
  defdelegate persist_agent(state), to: Persistence

  @doc """
  Update agent conversation history in database.
  Delegated to Core.Persistence module.
  """
  @spec persist_conversation(State.t()) :: :ok
  defdelegate persist_conversation(state), to: Persistence

  @doc """
  Extract parent agent_id from parent_pid using Registry.
  Delegated to Core.Persistence module.
  """
  @spec extract_parent_agent_id(pid() | nil, State.t()) :: String.t() | nil
  defdelegate extract_parent_agent_id(parent_pid, state), to: Persistence

  # v30.0: Route shell commands to their owning Router
  defp route_to_shell_router(command_id, message, state) do
    case Map.get(state.shell_routers, command_id) do
      nil -> {:reply, {:error, :command_not_found}, state}
      router_pid -> {:reply, GenServer.call(router_pid, message), state}
    end
  end
end
