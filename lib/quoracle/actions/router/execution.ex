defmodule Quoracle.Actions.Router.Execution do
  @moduledoc """
  Handles action execution logic for the Router.

  This module is responsible for executing action modules in a controlled
  environment with support for timeouts, smart mode (async execution),
  and database sandbox isolation for tests.
  """

  alias Quoracle.PubSub.AgentEvents

  @doc """
  Executes an action module with smart mode support.

  Returns `{:ok, result}` for synchronous completion, `{:error, reason}` on failure,
  or an async task tuple if the action takes longer than smart_threshold.

  ## Parameters
  - module: The action module to execute
  - params: Parameters to pass to the action
  - agent_id: ID of the agent executing the action
  - action_id: Unique ID for this action execution
  - smart_threshold: Milliseconds to wait before returning async
  - timeout: Optional hard timeout in milliseconds
  - sandbox_owner: Process to share database sandbox with (for tests)
  - pubsub: PubSub instance for broadcasting
  - state: Current router state
  """
  @spec execute_action(
          module(),
          map(),
          String.t(),
          String.t(),
          pos_integer(),
          integer() | nil,
          pid() | nil,
          atom(),
          map(),
          map(),
          keyword()
        ) ::
          {:ok, any()} | {:error, any()} | {:async_task, Task.t(), String.t(), String.t()}
  def execute_action(
        module,
        params,
        agent_id,
        action_id,
        smart_threshold,
        timeout,
        sandbox_owner,
        pubsub,
        _state,
        secrets_used,
        opts \\ []
      ) do
    start_time = System.monotonic_time(:millisecond)

    # Start execution in a task owned by this GenServer
    task =
      Task.async(fn ->
        # Setup sandbox access for test environment if needed
        if sandbox_owner do
          Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, sandbox_owner, self())
        end

        try do
          # Pass full opts to action module if it accepts it
          # Include pubsub, smart_threshold, and secrets_used in opts
          full_opts =
            opts
            |> Keyword.put_new(:pubsub, pubsub)
            |> Keyword.put_new(:smart_threshold, smart_threshold)
            |> Keyword.put_new(:secrets_used, secrets_used)

          result =
            execute_action_module(module, params, action_id, agent_id, secrets_used, full_opts)

          # Special case: Shell status checks shouldn't have execution_time_ms added
          # They're quick state queries, not timed operations
          if module == Quoracle.Actions.Shell and Map.has_key?(params, :check_id) do
            result
          else
            execution_time = System.monotonic_time(:millisecond) - start_time

            case result do
              {:ok, data} when is_map(data) ->
                {:ok, Map.put(data, :execution_time_ms, execution_time)}

              {:ok, data} when is_list(data) ->
                # List results (e.g., bulk queries) - don't add execution_time_ms
                {:ok, data}

              {:error, :secret_not_found, _name} = error ->
                error

              other ->
                other
            end
          end
        rescue
          e ->
            {:error, {:action_crashed, Exception.message(e)}}
        catch
          :exit, reason ->
            {:error, {:action_crashed, reason}}
        end
      end)

    # Handle timeout vs smart mode
    if timeout do
      # Explicit timeout - wait and return result or error
      case Task.yield(task, timeout) do
        {:ok, result} ->
          # CRITICAL: Wait for task process to fully exit before returning
          # Task.yield returns result but process might still be cleaning up DB connection
          # Use :infinity to wait for natural cleanup, not :brutal_kill which interrupts it
          Task.shutdown(task, :infinity)
          result

        nil ->
          # Timeout - kill the task
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}
      end
    else
      # Shell commands need special handling because Shell has its own smart mode
      actual_threshold =
        cond do
          # Status checks are quick GenServer.call lookups
          module == Quoracle.Actions.Shell and Map.has_key?(params, :check_id) ->
            500

          # Shell commands: add small buffer so Execution waits slightly longer than Shell's threshold
          # This ensures Execution sees Shell's response (sync or async) before timing out
          module == Quoracle.Actions.Shell ->
            smart_threshold + 50

          true ->
            smart_threshold
        end

      # Smart mode - return async if taking too long
      case Task.yield(task, actual_threshold) do
        {:ok, result} ->
          # Completed within threshold
          # CRITICAL: Wait for task process to fully exit before returning
          # Task.yield returns result but process might still be cleaning up DB connection
          # Use :infinity to wait for natural cleanup, not :brutal_kill which interrupts it
          # This prevents race where test exits before task process dies → Postgrex error
          Task.shutdown(task, :infinity)
          result

        nil ->
          # Still running - return task for tracking
          {:async_task, task, agent_id, action_id}
      end
    end
  end

  # Private helper to dispatch to action modules with appropriate arity
  # All actions now use standard 3-arity signature: execute(params, agent_id, opts)
  defp execute_action_module(module, params, action_id, agent_id, secrets_used, opts)
       when is_list(opts) do
    # Params are already resolved, just execute and scrub
    # Add action_id to opts for actions that need it (SendMessage requires it)
    opts_with_action_id = Keyword.put(opts, :action_id, action_id)

    # Generic dispatch - all actions handle opts internally
    # Orient: extracts :agent_pid, :pubsub
    # Wait: extracts :agent_pid, :pubsub
    # SendMessage: extracts :action_id (required), :task_id (optional), :registry, :pubsub
    # Spawn: extracts :agent_pid, converts opts to deps map
    result = apply(module, :execute, [params, agent_id, opts_with_action_id])

    # Scrub secret values from ALL results (both success and error)
    # Error results can contain secrets in error messages or output fields
    case result do
      {:ok, _} = success ->
        Quoracle.Actions.Router.Security.scrub_output(success, secrets_used)

      error ->
        # Scrub errors too - they can leak secrets in error messages
        Quoracle.Actions.Router.Security.scrub_output(error, secrets_used)
    end
  end

  @doc """
  Handles completion of an async task.

  Processes the result of an async task execution, broadcasting the appropriate
  events and updating the router state accordingly.

  CRITICAL: This stores the result but does NOT remove the task from active_tasks.
  Tasks are only removed when we receive the :DOWN message (process actually died).
  This prevents race condition where Router.terminate runs before task process exits.

  ## Parameters
  - ref: The task reference from the Task module
  - result: The result from the task execution
  - state: The current router state with active_tasks and results
  - pubsub: The PubSub instance for broadcasting events

  ## Returns
  Updated state with the task result stored. Task remains in active_tasks until :DOWN.
  """
  @spec handle_task_completion(reference(), any(), map(), atom()) :: map()
  def handle_task_completion(ref, result, state, pubsub) do
    # Task completed, find our tracking reference
    case Enum.find(state.active_tasks, fn {_k, v} ->
           is_map(v) and is_struct(v.task, Task) and v.task.ref == ref
         end) do
      {tracking_ref, task_info} ->
        # Only notify Core for FINAL results, not intermediate async status
        # Intermediate {:ok, %{async: true}} results are already handled via synchronous return
        if task_info[:agent_pid] && Process.alive?(task_info.agent_pid) do
          unless match?({:ok, %{async: true}}, result) do
            Quoracle.Agent.Core.handle_action_result(
              task_info.agent_pid,
              task_info.action_id,
              result
            )
          end
        end

        # Broadcast completion event - skip intermediate async status like Core notification
        # Shell's final completion will be broadcasted by ShellCompletion.handle_completion
        unless match?({:ok, %{async: true}}, result) do
          case result do
            {:ok, _} = success ->
              AgentEvents.broadcast_action_completed(
                task_info.agent_id,
                task_info.action_id,
                success,
                pubsub
              )

            {:error, _} = error ->
              AgentEvents.broadcast_action_error(
                task_info.agent_id,
                task_info.action_id,
                error,
                pubsub
              )
          end
        end

        # Store result for await_result to retrieve
        # CRITICAL: Keep task in active_tasks until we receive :DOWN message
        # This ensures Router.terminate waits for task process to actually die
        new_results = Map.put(state.results, tracking_ref, result)
        %{state | results: new_results}

      nil ->
        state
    end
  end
end
