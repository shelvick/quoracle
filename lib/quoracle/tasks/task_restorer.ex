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
  alias Quoracle.Tasks.TaskRestorer.ConflictResolver

  @doc """
  Pause task by terminating all running agents.

  ## Parameters
  - `task_id` - Task UUID to pause
  - `opts` - Options keyword list:
    - `:registry` - Registry instance to query (required)
    - `:dynsup` - DynamicSupervisor PID for testing (default: application dynsup)
    - `:kill` - Force-kill via Process.exit(:kill) instead of graceful :stop_requested (default: false)

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

          # Step 5: Terminate each agent and track stopped IDs
          # kill: true -> Process.exit(:kill) for immediate termination (used by delete_task)
          # kill: false -> send(:stop_requested) for graceful shutdown (used by pause)
          kill? = Keyword.get(opts, :kill, false)
          already_stopped = send_stop_to_agents(sorted_agents, kill?)

          # Step 6: Post-pause sweep - catch in-flight spawns that registered after initial query
          sweep_late_registrations(task_id, registry, already_stopped, kill?)

          # Return immediately - terminations happen asynchronously
          Logger.info("Task #{task_id} pausing (#{length(agents)} agents terminating async)")
          :ok
        end
    end
  end

  @doc """
  Restore task by rebuilding agent tree from database.

  Uses resilient restoration (v6.0) that continues past individual agent
  failures, skips failed agents' subtrees, and auto-resolves Registry conflicts.

  ## Parameters
  - `task_id` - Task UUID to restore
  - `registry` - Registry instance for restored agents (required)
  - `pubsub` - PubSub instance for restored agents (required)
  - `opts` - Options keyword list

  ## Returns
  - `{:ok, root_pid}` - Task restored successfully (may be partial success with warnings)
  - `{:error, :all_agents_failed}` - All agents failed to restore
  - `{:error, reason}` - Restoration failed for other reasons
  """
  @spec restore_task(String.t(), atom(), atom(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def restore_task(task_id, registry, pubsub, opts \\ []) do
    sandbox_owner = Keyword.get(opts, :sandbox_owner)
    # Step 1: Get DynSup PID (from opts or application)
    dynsup_pid = Keyword.get(opts, :dynsup) || DynSup.get_dynsup_pid()

    if dynsup_pid == nil do
      {:error, :dynsup_not_found}
    else
      # Step 2: Query database for all agents for this task
      # Only restore agents with "running" status — stopped/paused agents are not restored
      db_agents =
        TaskManager.get_agents_for_task(task_id)
        |> Enum.filter(&(&1.status == "running"))

      case db_agents do
        [] ->
          {:error, :no_agents_found}

        agents ->
          # Step 3: Sort by parent-child relationships (topological order)
          # This ensures parents are always restored before children, regardless of timestamps
          sorted_agents = topological_sort(agents)

          # Step 4: Restore agents sequentially (resilient - continues past failures)
          initial_state = %{
            restored_pids: %{},
            restored_agents: [],
            failed_agents: [],
            skipped_agents: [],
            dynsup_pid: dynsup_pid
          }

          result =
            Enum.reduce(
              sorted_agents,
              initial_state,
              fn db_agent, state ->
                # Skip if parent failed (entire subtree skipped)
                if db_agent.parent_id && db_agent.parent_id in state.failed_agents do
                  Logger.warning(
                    "Skipping agent #{db_agent.agent_id}: parent #{db_agent.parent_id} failed"
                  )

                  %{state | skipped_agents: [db_agent.agent_id | state.skipped_agents]}
                else
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

                  case ConflictResolver.restore_agent_with_retry(
                         state.dynsup_pid,
                         db_agent,
                         agent_opts,
                         registry
                       ) do
                    {:ok, pid} ->
                      Logger.debug("Restored agent #{db_agent.agent_id}")

                      %{
                        state
                        | restored_pids: Map.put(state.restored_pids, db_agent.agent_id, pid),
                          restored_agents: [db_agent.agent_id | state.restored_agents]
                      }

                    {:error, reason} ->
                      Logger.error(
                        "Failed to restore agent #{db_agent.agent_id}: #{inspect(reason)}"
                      )

                      %{state | failed_agents: [db_agent.agent_id | state.failed_agents]}
                  end
                end
              end
            )

          # Step 5: Handle result
          handle_restore_result(result, sorted_agents, agents, task_id, registry)
      end
    end
  end

  # Handle the result of restoration based on success/failure counts
  @spec handle_restore_result(map(), list(), list(), String.t(), atom()) ::
          {:ok, pid()} | {:error, term()}
  defp handle_restore_result(result, sorted_agents, agents, task_id, registry) do
    case result do
      %{restored_agents: [], failed_agents: failed} when failed != [] ->
        # Total failure - no agents restored
        {:error, :all_agents_failed}

      %{failed_agents: []} = state ->
        # Full success - all agents restored
        root_pid = find_root_pid(state.restored_pids, sorted_agents)

        # Step 6: Rebuild children lists in parent agents
        # Use original agents list (not sorted) to catch orphans with missing parents
        rebuild_children_lists(state.restored_pids, agents)

        # Step 7: Cleanup orphans that survived from previous session
        cleanup_orphans(task_id, state.restored_pids, registry)

        TaskManager.update_task_status(task_id, "running")

        Logger.info(
          "Task #{task_id} restored successfully (#{length(state.restored_agents)} agents)"
        )

        {:ok, root_pid}

      %{failed_agents: failed} = state ->
        # Partial success - some agents failed but tree is usable
        root_pid = find_root_pid(state.restored_pids, sorted_agents)

        # Rebuild children lists for successfully restored agents
        rebuild_children_lists(state.restored_pids, agents)

        # Cleanup orphans
        cleanup_orphans(task_id, state.restored_pids, registry)

        TaskManager.update_task_status(task_id, "running")

        Logger.error("Partial restore: #{length(failed)} agents failed: #{inspect(failed)}")

        {:ok, root_pid}
    end
  end

  # Send stop signals to agents and return MapSet of stopped agent IDs
  @spec send_stop_to_agents(list(), boolean()) :: MapSet.t()
  defp send_stop_to_agents(sorted_agents, kill?) do
    Enum.reduce(sorted_agents, MapSet.new(), fn {agent_id, meta}, already_stopped ->
      if Process.alive?(meta.pid) do
        if kill? do
          Process.exit(meta.pid, :kill)
          Logger.debug("Killed agent #{agent_id}")
        else
          send(meta.pid, :stop_requested)
          Logger.debug("Sent :stop_requested to agent #{agent_id}")
        end
      else
        Logger.debug("Agent #{agent_id} already terminated")
      end

      MapSet.put(already_stopped, agent_id)
    end)
  end

  # Post-pause sweep: catch in-flight spawns that registered after initial query
  @spec sweep_late_registrations(String.t(), atom(), MapSet.t(), boolean()) :: :ok
  defp sweep_late_registrations(task_id, registry, already_stopped, kill?) do
    # Re-query Registry for any new agents that registered between first query and stops
    new_agents = RegistryQueries.list_agents_for_task(task_id, registry)

    Enum.each(new_agents, fn {agent_id, meta} ->
      unless MapSet.member?(already_stopped, agent_id) do
        if Process.alive?(meta.pid) do
          if kill? do
            Process.exit(meta.pid, :kill)
          else
            send(meta.pid, :stop_requested)
          end

          Logger.debug("Sweep: sent stop to late-registered agent #{agent_id}")
        end
      end
    end)

    :ok
  end

  # Cleanup orphan agents that survived from previous session.
  # After restoration, find any live agents for this task that were NOT
  # part of the restoration set and terminate them.
  @spec cleanup_orphans(String.t(), map(), atom()) :: :ok
  defp cleanup_orphans(task_id, restored_pids, registry) do
    # Find any live agents for this task that weren't part of the restoration set
    live_agents = RegistryQueries.list_agents_for_task(task_id, registry)
    restored_ids = Map.keys(restored_pids)

    orphans =
      Enum.reject(live_agents, fn {agent_id, _meta} ->
        agent_id in restored_ids
      end)

    Enum.each(orphans, fn {agent_id, meta} ->
      Logger.warning("Terminating orphan agent #{agent_id} (not in restoration set)")

      if Process.alive?(meta.pid) do
        try do
          GenServer.stop(meta.pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end

      # Update DB status so Dashboard doesn't show it as active
      case TaskManager.get_agent(agent_id) do
        {:ok, agent} ->
          agent
          |> Ecto.Changeset.change(status: "stopped")
          |> Quoracle.Repo.update()

        _ ->
          :ok
      end
    end)

    if Enum.any?(orphans) do
      Logger.info("Cleaned up #{length(orphans)} orphan agents for task #{task_id}")
    end

    :ok
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
