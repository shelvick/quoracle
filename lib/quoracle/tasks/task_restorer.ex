defmodule Quoracle.Tasks.TaskRestorer do
  @moduledoc """
  Orchestrates task pause and restoration operations.

  Handles terminating all agents for a task (pause) and rebuilding
  agent hierarchies from persisted database state (restore).
  """

  require Logger
  alias Quoracle.Tasks.TaskManager
  alias Quoracle.Agent.DynSup
  alias Quoracle.Agent.RegistryQueries

  @doc """
  Pause task by terminating all running agents.

  ## Parameters
  - `task_id` - Task UUID to pause
  - `opts` - Options keyword list:
    - `:registry` - Registry instance to query (required)
    - `:dynsup` - DynamicSupervisor PID for testing (default: application dynsup)

  ## Returns
  - `:ok` - All agents terminated successfully
  - `{:error, reason}` - Termination failed
  """
  @spec pause_task(String.t(), keyword()) :: :ok | {:error, term()}
  def pause_task(task_id, opts \\ []) do
    registry = Keyword.fetch!(opts, :registry)
    dynsup_override = Keyword.get(opts, :dynsup)
    # Step 1: Query Registry for all live agents for this task
    live_agents = RegistryQueries.list_agents_for_task(task_id, registry)

    case live_agents do
      [] ->
        # No agents running - just update DB status
        Logger.info("Task #{task_id} has no running agents")
        TaskManager.update_task_status(task_id, "paused")
        :ok

      agents ->
        # Step 2: Get DynSup PID
        dynsup_pid = dynsup_override || DynSup.get_dynsup_pid()

        if dynsup_pid == nil do
          {:error, :dynsup_not_found}
        else
          # Step 3: Set status to "pausing" IMMEDIATELY (async pause support)
          # This allows UI to respond instantly while terminations happen in background
          TaskManager.update_task_status(task_id, "pausing")

          # Step 4: Sort agents in reverse order (leaves first, root last)
          sorted_agents =
            Enum.sort_by(
              agents,
              fn {_id, meta} ->
                meta.registered_at || System.monotonic_time()
              end,
              :desc
            )

          # Step 5: Send :stop_requested to each agent (deterministic mailbox ordering)
          # Using send/2 directly ensures :stop_requested is processed in FIFO order
          # after any pending :trigger_consensus messages (drain pattern in Core)
          Enum.each(sorted_agents, fn {agent_id, meta} ->
            if Process.alive?(meta.pid) do
              send(meta.pid, :stop_requested)
              Logger.debug("Sent :stop_requested to agent #{agent_id}")
            else
              Logger.debug("Agent #{agent_id} already terminated")
            end
          end)

          # Return immediately - terminations happen asynchronously
          Logger.info("Task #{task_id} pausing (#{length(agents)} agents terminating async)")
          :ok
        end
    end
  end

  @doc """
  Restore task by rebuilding agent tree from database.

  ## Parameters
  - `task_id` - Task UUID to restore
  - `registry` - Registry instance for restored agents (required)
  - `pubsub` - PubSub instance for restored agents (required)
  - `opts` - Options keyword list

  ## Returns
  - `{:ok, root_pid}` - Task restored successfully with root agent PID
  - `{:error, reason}` - Restoration failed
  - `{:error, {:partial_restore, successful_agents, failed_agent, reason}}` - Some agents restored
  """
  @spec restore_task(String.t(), atom(), atom(), keyword()) ::
          {:ok, pid()}
          | {:error, term()}
          | {:error, {:partial_restore, list(String.t()), String.t(), term()}}
  def restore_task(task_id, registry, pubsub, opts \\ []) do
    sandbox_owner = Keyword.get(opts, :sandbox_owner)
    # Step 1: Get DynSup PID (from opts or application)
    dynsup_pid = Keyword.get(opts, :dynsup) || DynSup.get_dynsup_pid()

    if dynsup_pid == nil do
      {:error, :dynsup_not_found}
    else
      # Step 2: Query database for all agents for this task
      db_agents = TaskManager.get_agents_for_task(task_id)

      case db_agents do
        [] ->
          {:error, :no_agents_found}

        agents ->
          # Step 3: Sort by parent-child relationships (topological order)
          # This ensures parents are always restored before children, regardless of timestamps
          sorted_agents = topological_sort(agents)

          # Step 4: Restore agents sequentially
          initial_state = %{
            restored_pids: %{},
            restored_agents: [],
            dynsup_pid: dynsup_pid
          }

          result =
            Enum.reduce_while(
              sorted_agents,
              {:ok, initial_state},
              fn db_agent, {:ok, state} ->
                # Get parent PID if agent has parent
                parent_pid =
                  case db_agent.parent_id do
                    nil -> nil
                    parent_id -> Map.get(state.restored_pids, parent_id)
                  end

                # Restore agent
                agent_opts = [
                  registry: registry,
                  pubsub: pubsub,
                  parent_pid_override: parent_pid,
                  sandbox_owner: sandbox_owner
                ]

                case DynSup.restore_agent(state.dynsup_pid, db_agent, agent_opts) do
                  {:ok, pid} ->
                    Logger.debug("Restored agent #{db_agent.agent_id}")

                    # Track restored PID and agent_id
                    updated_state = %{
                      restored_pids: Map.put(state.restored_pids, db_agent.agent_id, pid),
                      restored_agents: [db_agent.agent_id | state.restored_agents],
                      dynsup_pid: state.dynsup_pid
                    }

                    {:cont, {:ok, updated_state}}

                  {:error, reason} ->
                    Logger.error(
                      "Failed to restore agent #{db_agent.agent_id}: #{inspect(reason)}"
                    )

                    # Return partial success info
                    error = {:partial_restore, state.restored_agents, db_agent.agent_id, reason}
                    {:halt, {:error, error}}
                end
              end
            )

          # Step 5: Handle result
          case result do
            {:ok, state} ->
              # All agents restored successfully
              root_pid = find_root_pid(state.restored_pids, sorted_agents)

              # Step 6: Rebuild children lists in parent agents
              # Use original agents list (not sorted) to catch orphans with missing parents
              rebuild_children_lists(state.restored_pids, agents)

              TaskManager.update_task_status(task_id, "running")

              Logger.info(
                "Task #{task_id} restored successfully (#{length(state.restored_agents)} agents)"
              )

              {:ok, root_pid}

            {:error, _} = error ->
              # Partial or complete failure
              error
          end
      end
    end
  end

  @doc false
  defp topological_sort(agents) do
    # Build parent-child map for quick lookups
    children_map =
      agents
      |> Enum.group_by(& &1.parent_id)

    # Start with roots (parent_id == nil)
    roots = Map.get(children_map, nil, [])

    # Recursively add children in breadth-first order
    sort_recursive(roots, children_map, [])
  end

  @doc false
  defp sort_recursive([], _children_map, acc) do
    # No more agents to process
    Enum.reverse(acc)
  end

  defp sort_recursive([agent | rest], children_map, acc) do
    # Add current agent to result
    new_acc = [agent | acc]

    # Get children of this agent
    children = Map.get(children_map, agent.agent_id, [])

    # Continue with remaining agents at this level, then children
    sort_recursive(rest ++ children, children_map, new_acc)
  end

  @doc false
  defp find_root_pid(restored_pids, sorted_agents) do
    # Root agent is first in sorted list (parent_id = nil)
    case sorted_agents do
      [root | _] -> Map.get(restored_pids, root.agent_id)
      [] -> nil
    end
  end

  @doc false
  defp rebuild_children_lists(restored_pids, db_agents) do
    # Filter to only children (agents with parent_id)
    children = Enum.filter(db_agents, & &1.parent_id)

    Enum.each(children, fn child ->
      parent_pid = Map.get(restored_pids, child.parent_id)

      if parent_pid && Process.alive?(parent_pid) do
        # Extract budget from child's state if present
        budget_allocated = get_child_budget(child)

        GenServer.cast(
          parent_pid,
          {:child_restored,
           %{
             agent_id: child.agent_id,
             spawned_at: child.inserted_at,
             budget_allocated: budget_allocated
           }}
        )
      else
        Logger.warning(
          "Cannot restore child #{child.agent_id} to parent #{child.parent_id}: parent not found or not alive. Stopping orphaned child."
        )

        # Terminate orphaned child process if it was started
        child_pid = Map.get(restored_pids, child.agent_id)

        if child_pid && Process.alive?(child_pid) do
          try do
            GenServer.stop(child_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end

        # Update DB status so Dashboard doesn't show it as active
        case TaskManager.get_agent(child.agent_id) do
          {:ok, agent} ->
            agent
            |> Ecto.Changeset.change(status: "stopped")
            |> Quoracle.Repo.update()

          _ ->
            :ok
        end
      end
    end)

    :ok
  end

  @doc false
  defp get_child_budget(child) do
    case child.state do
      %{"budget" => %{"limit" => limit}} when is_binary(limit) ->
        Decimal.new(limit)

      _ ->
        nil
    end
  end
end
