defmodule Quoracle.Actions.DismissChild do
  @moduledoc """
  Dismiss child action that recursively terminates a child agent and all its descendants.

  Parent agents use this action to clean up child agents when they are no longer needed.
  Termination happens in the background with immediate return to the caller.
  """

  require Logger

  alias Ecto.Adapters.SQL.Sandbox
  alias Quoracle.Actions.DismissChild.CostTransaction
  alias Quoracle.Agent.{Core, RegistryQueries}
  alias Quoracle.Agent.TreeTerminator
  alias Quoracle.Costs.Recorder
  alias Quoracle.Repo

  @doc """
  Executes the dismiss_child action.

  Standard 3-arity signature with optional dependency injection.

  ## Parameters
    - params: Map with :child_id (required) and :reason (optional)
    - agent_id: Agent identifier string (the parent requesting dismissal)
    - opts: Keyword list with :registry, :dynsup, :pubsub, :sandbox_owner

  ## Returns
    - `{:ok, map()}` with dismissal confirmation
    - `{:error, reason}` if dismissal fails
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def execute(params, agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    child_id = get_child_id(params)
    reason = get_reason(params)
    registry = Keyword.get(opts, :registry)

    with {:ok, child_id} <- validate_child_id(child_id),
         {:ok, status} <- check_agent_and_authorization(child_id, agent_id, registry) do
      case status do
        :not_found ->
          {:ok,
           %{
             action: "dismiss_child",
             child_id: child_id,
             status: "already_terminated"
           }}

        :authorized ->
          dispatch_termination(child_id, agent_id, reason, opts)
      end
    end
  end

  # Extract child_id from params (supports both string and atom keys)
  defp get_child_id(params) do
    Map.get(params, "child_id") || Map.get(params, :child_id)
  end

  # Extract reason from params with default
  defp get_reason(params) do
    Map.get(params, "reason") || Map.get(params, :reason, "dismissed by parent")
  end

  # Validate child_id is present and is a string
  @spec validate_child_id(term()) :: {:ok, String.t()} | {:error, atom()}
  defp validate_child_id(nil), do: {:error, :missing_child_id}
  defp validate_child_id(id) when is_binary(id), do: {:ok, id}
  defp validate_child_id(_), do: {:error, :invalid_child_id}

  # Check if agent exists and verify parent authorization
  # Returns :not_found for non-existent agents (idempotent success path)
  @spec check_agent_and_authorization(String.t(), String.t(), atom()) ::
          {:ok, :authorized | :not_found} | {:error, :not_parent}
  defp check_agent_and_authorization(child_id, caller_id, registry) do
    case Registry.lookup(registry, {:agent, child_id}) do
      [{_pid, composite}] when is_map(composite) ->
        # Child exists - verify caller is the parent
        case Map.get(composite, :parent_id) do
          ^caller_id -> {:ok, :authorized}
          _ -> {:error, :not_parent}
        end

      [] ->
        # Child doesn't exist - idempotent success (already terminated)
        {:ok, :not_found}
    end
  end

  # Dispatch termination to TreeTerminator in background task
  @spec dispatch_termination(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()}
  defp dispatch_termination(child_id, parent_id, reason, opts) do
    registry = Keyword.get(opts, :registry)

    deps = %{
      registry: registry,
      dynsup: Keyword.get(opts, :dynsup),
      pubsub: Keyword.get(opts, :pubsub),
      sandbox_owner: Keyword.get(opts, :sandbox_owner)
    }

    # Get parent_pid for budget release and child tracking notifications
    parent_pid = get_parent_pid(parent_id, registry)

    # For test synchronization - notify when background task completes
    notify_pid = Keyword.get(opts, :dismiss_complete_notify)
    task_id = Keyword.get(opts, :task_id)

    Task.Supervisor.start_child(
      Quoracle.SpawnTaskSupervisor,
      fn ->
        do_background_dismissal(
          child_id,
          parent_id,
          parent_pid,
          reason,
          deps,
          task_id,
          notify_pid
        )
      end
    )

    {:ok,
     %{
       action: "dismiss_child",
       child_id: child_id,
       status: "terminating"
     }}
  end

  # Background task body for dismissal: DB setup, atomic cost transaction,
  # process termination, and post-commit escrow release.
  defp do_background_dismissal(child_id, parent_id, parent_pid, reason, deps, task_id, notify_pid) do
    try do
      if deps.sandbox_owner do
        Sandbox.allow(Repo, deps.sandbox_owner, self())
      end

      child_budget_data = get_child_budget_data(child_id, deps.registry)

      # Quiesce currently known subtree agents before the transaction.
      mark_subtree_dismissing(child_id, deps.registry)

      absorption_ctx = %{
        task_id: task_id,
        child_budget_data: child_budget_data
      }

      case CostTransaction.absorb_subtree(parent_id, child_id, absorption_ctx) do
        {:ok, inserted_rows} ->
          if deps.pubsub do
            Enum.each(inserted_rows, &Recorder.broadcast_cost_recorded(&1, deps.pubsub))
          end

          TreeTerminator.terminate_tree(child_id, parent_id, reason, deps)
          maybe_release_escrow(parent_pid, child_budget_data, inserted_rows)

          # Parent child-tracking mutation happens only after successful dismissal.
          if parent_pid && Process.alive?(parent_pid) do
            GenServer.cast(parent_pid, {:child_dismissed, child_id})
          end

          if notify_pid, do: send(notify_pid, {:dismiss_complete, child_id})

        {:error, tx_reason} ->
          Logger.error(
            "DismissChild: Cost transaction rolled back for child #{child_id}: " <>
              "#{inspect(tx_reason)}. Cost rows preserved; child not terminated."
          )

          if notify_pid, do: send(notify_pid, {:dismiss_failed, child_id, tx_reason})
      end
    catch
      # Only absorb sandbox teardown exits.
      :exit, {:shutdown, :sandbox_stop} -> :ok
      :exit, {:shutdown, {:killed, _}} -> :ok
    end
  end

  # Look up parent_pid from registry
  defp get_parent_pid(parent_id, registry) do
    case Registry.lookup(registry, {:agent, parent_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Get child's budget_data from its state (before termination)
  defp get_child_budget_data(child_id, registry) do
    case Registry.lookup(registry, {:agent, child_id}) do
      [{child_pid, _}] ->
        try do
          {:ok, state} = Core.get_state(child_pid)
          state.budget_data
        catch
          :exit, _ -> nil
        end

      [] ->
        nil
    end
  end

  @spec mark_subtree_dismissing(String.t(), atom()) :: :ok
  defp mark_subtree_dismissing(root_id, registry) do
    # Traverse subtree through the same registry relationships used by TreeTerminator.
    mark_subtree_dismissing_bfs([root_id], MapSet.new(), registry)
    :ok
  end

  @spec mark_subtree_dismissing_bfs([String.t()], MapSet.t(String.t()), atom()) :: :ok
  defp mark_subtree_dismissing_bfs([], _seen, _registry), do: :ok

  defp mark_subtree_dismissing_bfs([agent_id | rest], seen, registry) do
    if MapSet.member?(seen, agent_id) do
      mark_subtree_dismissing_bfs(rest, seen, registry)
    else
      set_agent_dismissing(agent_id, registry)

      child_ids =
        case get_agent_pid(agent_id, registry) do
          {:ok, pid} ->
            by_parent_pid =
              RegistryQueries.find_children_by_parent(pid, registry)
              |> Enum.map(fn {_child_pid, composite} -> composite.agent_id end)

            # Fallback keeps traversal robust if parent_pid linkage is temporarily stale.
            by_parent_id =
              Registry.select(registry, [
                {{{:agent, :"$1"}, :"$2", :"$3"},
                 [{:==, {:map_get, :parent_id, :"$3"}, agent_id}], [:"$1"]}
              ])

            Enum.uniq(by_parent_pid ++ by_parent_id)

          :error ->
            []
        end

      mark_subtree_dismissing_bfs(rest ++ child_ids, MapSet.put(seen, agent_id), registry)
    end
  end

  @spec set_agent_dismissing(String.t(), atom()) :: :ok
  defp set_agent_dismissing(agent_id, registry) do
    case get_agent_pid(agent_id, registry) do
      {:ok, pid} ->
        try do
          Core.set_dismissing(pid, true)
        catch
          :exit, _ -> :ok
        end

      :error ->
        :ok
    end
  end

  @spec get_agent_pid(String.t(), atom()) :: {:ok, pid()} | :error
  defp get_agent_pid(agent_id, registry) do
    case Registry.lookup(registry, {:agent, agent_id}) do
      [{pid, _composite}] -> {:ok, pid}
      [] -> :error
    end
  end

  # Release escrow budget back to parent for allocated children with a live parent process.
  @spec maybe_release_escrow(pid() | nil, map() | nil, [map()]) :: :ok
  defp maybe_release_escrow(parent_pid, %{mode: :allocated, allocated: allocated}, inserted_rows)
       when not is_nil(allocated) do
    tree_spent = sum_absorbed_costs(inserted_rows)

    if parent_pid && Process.alive?(parent_pid) do
      try do
        Core.release_child_budget(parent_pid, allocated, tree_spent)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp maybe_release_escrow(_parent_pid, _child_budget_data, _inserted_rows), do: :ok

  @spec sum_absorbed_costs([map()]) :: Decimal.t()
  defp sum_absorbed_costs(inserted_rows) do
    Enum.reduce(inserted_rows, Decimal.new("0"), fn row, acc ->
      case Map.get(row, :cost_usd) || Map.get(row, "cost_usd") do
        nil -> acc
        cost -> Decimal.add(acc, cost)
      end
    end)
  end
end
