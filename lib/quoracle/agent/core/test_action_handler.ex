defmodule Quoracle.Agent.Core.TestActionHandler do
  @moduledoc """
  Test-only handlers for Core GenServer.

  Extracted from Core.ex to keep the main module under 500 lines.
  These handlers are only used by integration tests.
  """

  alias Quoracle.Agent.ConsensusHandler.Helpers

  @doc """
  Simple test handler that returns success.
  Used for basic test scenarios.
  """
  @spec handle_execute_action(any(), map()) :: {:reply, {:ok, map()}, map()}
  def handle_execute_action(_action, state) do
    {:reply, {:ok, %{result: "test_success"}}, state}
  end

  @doc """
  Test synchronization helper that forces mailbox processing.
  """
  @spec handle_sync(map()) :: {:reply, :ok, map()}
  def handle_sync(state) do
    {:reply, :ok, state}
  end

  @doc """
  Integration test handler that executes actions through Router.

  This handler:
  1. Normalizes action format (string → atom)
  2. Extracts action type and params
  3. Spawns per-action Router and executes through Router.execute/5
  4. Returns the direct result (execute/5 is synchronous with timeout)
  5. Transforms spawn results for test compatibility
  """
  @spec handle_process_action(map(), String.t(), map()) ::
          {:reply, {:ok, map()} | {:error, term()}, map()}
  def handle_process_action(action_map, _action_id, state) do
    # Convert string action to atom if needed
    # Uses String.to_existing_atom/1 to ensure action atoms are predefined in Schema
    # This provides fail-fast behavior for typos/invalid action names in tests
    action_atom =
      case Map.get(action_map, :action) do
        action when is_binary(action) -> String.to_existing_atom(action)
        action when is_atom(action) -> action
      end

    raw_params = Map.get(action_map, :params, %{})

    # Convert atom keys to string keys for Spawn compatibility
    params =
      for {k, v} <- raw_params, into: %{} do
        {to_string(k), v}
      end

    # Build opts for Router.execute/5
    # Include parent config for child spawning (needed by spawn action)
    # For spawn_child, add spawn_complete_notify so we can wait for the async result
    base_opts = [
      agent_pid: self(),
      agent_id: state.agent_id,
      task_id: state.task_id,
      registry: state.registry,
      pubsub: state.pubsub,
      dynsup: state.dynsup,
      sandbox_owner: state.sandbox_owner,
      mcp_client: state.mcp_client,
      timeout: 5000,
      # Pass dismissing state to avoid GenServer callback deadlock in Spawn
      dismissing: state.dismissing,
      # Pass capability_groups for permission enforcement in Router
      capability_groups: state.capability_groups,
      # Parent config for child agent inheritance
      parent_config: %{
        models: state.models,
        sandbox_owner: state.sandbox_owner,
        test_mode: state.test_mode,
        pubsub: state.pubsub,
        skip_auto_consensus: state.skip_auto_consensus
      }
    ]

    # Add spawn_complete_notify for spawn_child to support async pattern
    opts =
      if action_atom == :spawn_child do
        Keyword.put(base_opts, :spawn_complete_notify, self())
      else
        base_opts
      end

    # Generate action_id for per-action Router (v28.0)
    action_id = "action_#{state.agent_id}_test_#{:erlang.unique_integer([:positive])}"

    # v25.0: Route check_id through existing Router from shell_routers,
    # or spawn a new per-action Router for normal actions
    check_id = Helpers.extract_shell_check_id(params, action_atom)

    {router_pid, state} =
      if check_id do
        case Map.get(state.shell_routers, check_id) do
          nil ->
            spawn_and_monitor_router(state, action_atom, action_id, opts)

          existing_pid ->
            {existing_pid, state}
        end
      else
        spawn_and_monitor_router(state, action_atom, action_id, opts)
      end

    # Execute through Router.execute/5 (synchronous when timeout provided)
    # v30.0: Catch exits from Router dying mid-execution (e.g., when killed for cleanup testing)
    result =
      try do
        Quoracle.Actions.Router.execute(
          router_pid,
          action_atom,
          params,
          state.agent_id,
          opts
        )
      catch
        :exit, reason ->
          {:error, {:router_exit, reason}}
      end

    # v25.0: Track shell_routers keyed by command_id from result (not action_id)
    # command_id is what the LLM uses in check_id requests
    shell_routers =
      case {action_atom, result} do
        {:execute_shell, {:ok, %{command_id: cmd_id, async: true}}} when is_binary(cmd_id) ->
          Map.put(state.shell_routers, cmd_id, router_pid)

        {:execute_shell, {:ok, %{command_id: cmd_id, status: :running}}} when is_binary(cmd_id) ->
          Map.put(state.shell_routers, cmd_id, router_pid)

        _ ->
          state.shell_routers
      end

    state = %{state | shell_routers: shell_routers}

    # Transform result format for spawn compatibility
    # For async spawn pattern: wait for spawn_complete notification to get pid
    transformed_result =
      case result do
        {:ok, %{agent_id: id, pid: pid}} ->
          # Legacy sync pattern (if still present)
          {:ok, %{agent_id: id, pid: pid}}

        {:ok, %{agent_id: child_id, action: "spawn"}} ->
          # Async spawn pattern: wait for spawn_complete notification
          receive do
            {:spawn_complete, ^child_id, {:ok, child_pid}} ->
              {:ok, %{agent_id: child_id, pid: child_pid}}

            {:spawn_complete, ^child_id, {:error, reason}} ->
              {:error, reason}
          after
            5000 ->
              {:error, :spawn_complete_timeout}
          end

        other ->
          other
      end

    {:reply, transformed_result, state}
  end

  # v25.0: Spawn a new Router and monitor it, adding to active_routers
  @spec spawn_and_monitor_router(map(), atom(), String.t(), keyword()) :: {pid(), map()}
  defp spawn_and_monitor_router(state, action_atom, action_id, _opts) do
    {:ok, router_pid} =
      Quoracle.Actions.Router.start_link(
        action_type: action_atom,
        action_id: action_id,
        agent_id: state.agent_id,
        agent_pid: self(),
        pubsub: state.pubsub,
        sandbox_owner: state.sandbox_owner
      )

    monitor_ref = Process.monitor(router_pid)
    active_routers = Map.put(state.active_routers, monitor_ref, router_pid)
    state = %{state | active_routers: active_routers}
    {router_pid, state}
  end
end
