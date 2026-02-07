defmodule Quoracle.Actions.Router do
  @moduledoc """
  Action routing system for agent action execution with smart mode support.

  Per-action Router (v28.0): Each action spawns its own Router that terminates
  after the action completes. This enables proper validation for batched actions
  and simplifies state management.
  """

  use GenServer
  require Logger

  alias Quoracle.Actions.Router.{
    TaskManager,
    Execution,
    Persistence,
    ShellHandlers,
    WaitHandlers,
    ClientHelpers,
    ClientAPI,
    MCPHelpers
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Execute action with action_map format (simplified interface).

  Accepts action map with :action and :params keys, agent_pid, and opts.
  Extracts agent_id from agent_pid and delegates to execute/5.

  ## Parameters
    * `action_map` - Map with :action and :params keys
    * `agent_pid` - Agent process PID
    * `opts` - Keyword list options (registry, pubsub, etc.)
  """
  @spec execute(map(), pid(), keyword()) ::
          {:ok, any()} | {:error, any()} | {:async, reference()} | {:async, reference(), map()}
  def execute(action_map, agent_pid, opts) when is_map(action_map) and is_pid(agent_pid) do
    action_type = Map.fetch!(action_map, :action)
    params = Map.fetch!(action_map, :params)

    # Get agent_id from agent_pid via GenServer call
    agent_id = GenServer.call(agent_pid, :get_agent_id)

    # Get required opts for per-action Router (v28.0)
    pubsub = Keyword.fetch!(opts, :pubsub)
    sandbox_owner = Keyword.get(opts, :sandbox_owner)

    # Spawn per-action Router (v28.0) - Router terminates after action completes
    action_id = "action_#{:erlang.unique_integer([:positive])}"

    {:ok, router_pid} =
      start_link(
        action_type: action_type,
        action_id: action_id,
        agent_id: agent_id,
        agent_pid: agent_pid,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner
      )

    # For :call_mcp, fetch existing mcp_client from agent state (if any) before lazy-init
    existing_mcp_client =
      if action_type == :call_mcp, do: GenServer.call(agent_pid, :get_mcp_client), else: nil

    # Build opts with agent metadata, then lazy-init MCP client only for :call_mcp
    base_opts =
      opts
      |> Keyword.merge(agent_id: agent_id, agent_pid: agent_pid, action_id: action_id)
      |> Keyword.put(:auto_complete_todo, Map.get(action_map, :auto_complete_todo))
      |> Keyword.put(:mcp_client, existing_mcp_client)

    opts_with_meta = MCPHelpers.maybe_lazy_init_mcp_client(action_type, base_opts)

    execute(router_pid, action_type, params, agent_id, opts_with_meta)
  end

  @doc "Execute action with default options. See execute/5."
  @spec execute(GenServer.server(), atom(), map(), String.t()) ::
          {:ok, any()} | {:error, any()} | {:async, reference()} | {:async, reference(), map()}
  def execute(router, action_type, params, agent_id) do
    execute(router, action_type, params, agent_id, [])
  end

  @doc "Execute action through router instance. Options: :smart_threshold, :timeout, :sandbox_owner."
  @spec execute(GenServer.server(), atom(), map(), String.t(), keyword()) ::
          {:ok, any()} | {:error, any()} | {:async, reference()} | {:async, reference(), map()}
  def execute(router, action_type, params, agent_id, opts) do
    # Lazy initialization for 5-arity pathway (used by ConsensusHandler)
    opts = MCPHelpers.maybe_lazy_init_mcp_client(action_type, opts)
    ClientAPI.execute(router, action_type, params, agent_id, opts)
  end

  @doc """
  Awaits the result of an async action execution.

  Returns `{:ok, result}` when the action completes, or `{:error, reason}` on failure.
  """
  @spec await_result(GenServer.server(), reference(), keyword()) :: {:ok, any()} | {:error, any()}
  def await_result(router, ref, opts \\ []) do
    ClientHelpers.await_result(router, ref, opts)
  end

  @doc """
  Interrupts a timed wait for an action.
  Causes the action to continue immediately by sending a continue_consensus message.
  """
  defdelegate interrupt_wait(task_ref), to: ClientHelpers

  @doc """
  Cancels a running action task.
  """
  defdelegate cancel_action(task_ref), to: ClientHelpers

  @doc """
  Gets the status of a task.
  """
  defdelegate task_status(agent_pid, task_ref), to: ClientHelpers

  @impl true
  def init(opts) do
    # Per-action Router (v28.0) - most fields required, agent_pid optional for batch sub-actions
    action_type = Keyword.fetch!(opts, :action_type)
    action_id = Keyword.fetch!(opts, :action_id)
    agent_id = Keyword.fetch!(opts, :agent_id)
    agent_pid = Keyword.get(opts, :agent_pid)
    pubsub = Keyword.fetch!(opts, :pubsub)
    sandbox_owner = Keyword.get(opts, :sandbox_owner)

    # Monitor Core - self-terminate if Core dies (skip for batch sub-actions where agent_pid is nil)
    core_monitor =
      if agent_pid && Process.alive?(agent_pid) do
        Process.monitor(agent_pid)
      else
        nil
      end

    # Simplified state - single action, no multi-action maps
    state = %{
      # Action context (immutable)
      action_type: action_type,
      action_id: action_id,
      agent_id: agent_id,
      agent_pid: agent_pid,
      # For shell commands (single command per Router)
      shell_command: nil,
      shell_task: nil,
      # For wait actions
      wait_timer: nil,
      # For async tasks (MCP, API, etc.) - needed by Execution.handle_task_completion
      active_tasks: %{},
      results: %{},
      # Dependencies
      pubsub: pubsub,
      sandbox_owner: sandbox_owner,
      # Lifecycle
      core_monitor: core_monitor
    }

    if sandbox_owner do
      {:ok, state, {:continue, :setup_sandbox}}
    else
      {:ok, state}
    end
  end

  @impl true
  @spec handle_continue(:setup_sandbox, map()) :: {:noreply, map()}
  def handle_continue(:setup_sandbox, state) do
    # Grant DB access for async tests (handle_continue, not init/1, per project conventions)
    if state.sandbox_owner do
      Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, state.sandbox_owner, self())
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    agent_died = state.agent_pid && !Process.alive?(state.agent_pid)

    if !agent_died do
      if state.shell_task do
        {task, monitor_ref} = state.shell_task

        # CRITICAL: Kill the OS process FIRST, then wait for Task.
        # When Task dies unexpectedly (test failure, brutal_kill), Erlang closes
        # the port's file descriptors but does NOT signal the child process.
        # If the child is blocked on a read (e.g., cat on FIFO), it stays orphaned
        # forever. We must SIGKILL the OS process to unblock the Task.
        ShellHandlers.kill_os_process(state.shell_command)

        # Can't use Task.await - Task was created by Shell, not Router
        # Wait for task process to exit using monitor (or skip if already dead)
        # With OS process killed, Task should receive exit_status quickly.
        if Process.alive?(task.pid) do
          receive do
            {:DOWN, ^monitor_ref, :process, _, _} -> :ok
          after
            30_000 ->
              # Task still stuck after OS kill - force kill Elixir Task
              Process.exit(task.pid, :kill)
              Process.demonitor(monitor_ref, [:flush])
          end
        end
      end

      if state.wait_timer do
        Process.cancel_timer(state.wait_timer)
      end
    end

    :ok
  end

  @impl true
  def handle_call(:get_pubsub, _from, state) do
    {:reply, state.pubsub, state}
  end

  @spec handle_call(:ping, GenServer.from(), map()) :: {:reply, :pong, map()}
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_call({:await_result, _ref, _timeout}, _from, state) do
    # Per-action Router doesn't support await_result - each Router handles one action
    {:reply, {:error, :not_supported}, state}
  end

  def handle_call(
        {:execute, module, params, agent_id, action_id, smart_threshold, timeout, sandbox_owner,
         secrets_used, opts},
        _from,
        state
      ) do
    # For wait actions, override agent_pid to be the Router so timer comes to us.
    # Router will forward {:wait_expired, timer_ref} to Agent before terminating.
    execution_opts =
      if state.action_type == :wait do
        Keyword.put(opts, :agent_pid, self())
      else
        opts
      end

    # Shell commands need direct execution to avoid deadlock:
    # - Shell.execute calls GenServer.call(router, {:register_shell_command, ...})
    # - If wrapped in Execution's Task, Router blocks waiting for Task while Task waits for Router
    # - Shell has its own internal Task for async command execution, doesn't need Execution's wrapper
    is_shell_action = module == Quoracle.Actions.Shell

    has_check_id =
      is_map(params) and (Map.has_key?(params, :check_id) or Map.has_key?(params, "check_id"))

    result =
      if is_shell_action do
        # Direct execution for all Shell operations - Shell handles its own async internally
        shell_opts =
          execution_opts
          |> Keyword.put(:router_pid, self())
          |> Keyword.put(:action_id, action_id)
          |> Keyword.put(:secrets_used, secrets_used)
          |> Keyword.put(:smart_threshold, smart_threshold)
          |> then(fn opts ->
            if has_check_id do
              Keyword.put(opts, :shell_command_state, state.shell_command)
            else
              opts
            end
          end)

        module.execute(params, agent_id, shell_opts)
      else
        Execution.execute_action(
          module,
          params,
          agent_id,
          action_id,
          smart_threshold,
          timeout,
          sandbox_owner,
          state.pubsub,
          state,
          secrets_used,
          execution_opts
        )
      end

    case result do
      {:async_task, task, task_agent_id, task_action_id} ->
        # Async task - register in active_tasks for handle_task_completion
        monitor_ref = Process.monitor(task.pid)

        task_info = %{
          task: task,
          agent_id: task_agent_id,
          action_id: task_action_id,
          agent_pid: state.agent_pid
        }

        new_active_tasks = Map.put(state.active_tasks, task.ref, task_info)
        new_state = %{state | shell_task: {task, monitor_ref}, active_tasks: new_active_tasks}
        ack = %{async: true, action_id: task_action_id, status: :dispatched}
        {:reply, {:async, task.ref, ack}, new_state}

      {:ok, %{timer_id: timer_ref}} = sync_result ->
        # Wait action with timer - stay alive until timer fires
        new_state = %{state | wait_timer: timer_ref}
        {:reply, sync_result, new_state}

      {:ok, %{async: true, command_id: _}} = shell_async_result ->
        # Shell async - stay alive for check_id and completion notifications
        # Router holds command state, receives completion via handle_info
        {:reply, shell_async_result, state}

      sync_result ->
        # For check_id on running command, stay alive
        if match?({:ok, %{status: :running}}, sync_result) do
          {:reply, sync_result, state}
        else
          # Sync completion - scrub secrets from output, then terminate
          # Shell sync results bypass Execution.execute_action, so scrub here
          scrubbed_result =
            if is_shell_action do
              Quoracle.Actions.Router.Security.scrub_output(sync_result, secrets_used)
            else
              sync_result
            end

          # CRITICAL: For shell termination, kill task inline before stopping.
          # The mark_terminated cast won't be processed after {:stop, ...} returns,
          # so we must clean up here to prevent 30s wait in terminate/2.
          final_state =
            if match?({:ok, %{terminated: true}}, sync_result) do
              case state.shell_task do
                {task, monitor} when is_struct(task, Task) ->
                  Task.shutdown(task, :brutal_kill)
                  Process.demonitor(monitor, [:flush])
                  %{state | shell_task: nil}

                _ ->
                  state
              end
            else
              state
            end

          {:stop, :normal, scrubbed_result, final_state}
        end
    end
  end

  def handle_call({:register_shell_command, command_id, command_state}, _from, state) do
    ShellHandlers.handle_register_call(command_id, command_state, state)
  end

  def handle_call({:get_shell_command, command_id}, _from, state) do
    ShellHandlers.handle_get_call(command_id, state)
  end

  # v30.0: Shell status check for per-action Router lifecycle
  def handle_call(:get_shell_status, _from, state) do
    ShellHandlers.handle_get_status(state)
  end

  # v30.0: Shell termination for per-action Router lifecycle
  def handle_call(:terminate_shell, _from, state) do
    ShellHandlers.handle_terminate_shell(state)
  end

  def handle_call({:task_status, _task_ref}, _from, state) do
    # Per-action Router handles one action - always running until terminated
    {:reply, :running, state}
  end

  @impl true
  def handle_cast({:interrupt_wait, task_ref}, state) do
    WaitHandlers.handle_interrupt_wait(task_ref, state)
  end

  def handle_cast({:cancel_action, task_ref}, state) do
    WaitHandlers.handle_cancel_action(task_ref, state)
  end

  def handle_cast({:register_task, ref, task_info}, state) do
    {:noreply, TaskManager.register_task(state, ref, task_info)}
  end

  def handle_cast({:store_result, ref, result}, state) do
    {:noreply, TaskManager.store_result(state, ref, result)}
  end

  def handle_cast({:append_output, command_id, :stdout, data}, state) do
    ShellHandlers.handle_append_output(command_id, :stdout, data, state)
  end

  def handle_cast({:update_check_position, _command_id, _new_position}, state) do
    # Per-action Router - single shell command, position tracked in shell_command
    {:noreply, state}
  end

  def handle_cast({:mark_completed, command_id, exit_code}, state) do
    # Handle completion (notify Core, broadcast, etc.) then terminate
    {:noreply, new_state} =
      ShellHandlers.handle_mark_completed(command_id, exit_code, state, state.pubsub)

    {:stop, :normal, new_state}
  end

  def handle_cast({:mark_terminated, command_id}, state) do
    # Handle termination then stop Router
    {:noreply, new_state} = ShellHandlers.handle_mark_terminated(command_id, state)
    {:stop, :normal, new_state}
  end

  def handle_cast({:register_shell_command, command_id, command_state}, state) do
    ShellHandlers.handle_register_cast(command_id, command_state, state)
  end

  def handle_cast({:register_shell_task, command_id, task}, state) do
    ShellHandlers.handle_register_shell_task(command_id, task, state)
  end

  def handle_cast({:update_shell_port, command_id, port, task_pid}, state) do
    ShellHandlers.handle_update_shell_port(command_id, port, task_pid, state)
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    new_state = Execution.handle_task_completion(ref, result, state, state.pubsub)
    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      state.core_monitor == ref && state.agent_pid == pid ->
        # Core died - terminate Router
        {:stop, :normal, state}

      state.shell_task && elem(state.shell_task, 1) == ref ->
        # Shell task finished
        {:noreply, %{state | shell_task: nil}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:wait_expired, timer_ref}, state) do
    if state.wait_timer == timer_ref do
      # Timer fired - notify Agent then terminate Router
      # Agent's handle_wait_expired will clear wait_timer and trigger consensus
      if state.agent_pid && Process.alive?(state.agent_pid) do
        send(state.agent_pid, {:wait_expired, timer_ref})
      end

      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  # Database Persistence (Packet 3)

  @doc """
  Execute an action and persist the result to database.

  This is the main entry point for action execution with persistence.
  Extracts agent_id and other metadata from opts, executes the action,
  and logs the result to TABLE_Logs.
  """
  @spec execute_action(GenServer.server(), atom(), map(), keyword()) ::
          {:ok, any()} | {:error, any()} | {:async_task, Task.t(), reference(), integer()}
  def execute_action(router, action_type, params, opts) do
    Persistence.execute_with_persistence(router, action_type, params, opts, &execute/5)
  end

  @doc "Persist action execution result to database for audit trail."
  @spec persist_action_result(atom(), map(), any(), keyword(), GenServer.server()) :: :ok
  def persist_action_result(action_type, params, result, opts, _router) do
    Persistence.persist_action_result(action_type, params, result, opts)
  end
end
