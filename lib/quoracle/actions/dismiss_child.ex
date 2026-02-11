defmodule Quoracle.Actions.DismissChild do
  @moduledoc """
  Dismiss child action that recursively terminates a child agent and all its descendants.

  Parent agents use this action to clean up child agents when they are no longer needed.
  Termination happens in the background with immediate return to the caller.
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias Quoracle.Agent.Core
  alias Quoracle.Agent.TreeTerminator
  alias Quoracle.Costs.{Aggregator, Recorder}
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

    # Notify parent to remove child from tracking (R13-R16)
    if parent_pid && Process.alive?(parent_pid) do
      GenServer.cast(parent_pid, {:child_dismissed, child_id})
    end

    {:ok,
     %{
       action: "dismiss_child",
       child_id: child_id,
       status: "terminating"
     }}
  end

  # Background task body for dismissal: DB setup, budget snapshot, terminate, reconcile.
  # Wrapped in try/catch to handle sandbox owner exit race condition
  # (test process dies before Task completes).
  defp do_background_dismissal(child_id, parent_id, parent_pid, reason, deps, task_id, notify_pid) do
    try do
      if deps.sandbox_owner do
        Sandbox.allow(Repo, deps.sandbox_owner, self())
      end

      # Snapshot budget state BEFORE termination (TreeTerminator v2.0 deletes cost records)
      child_budget_data = get_child_budget_data(child_id, deps.registry)
      tree_spent = query_child_tree_spent(child_id)

      TreeTerminator.terminate_tree(child_id, parent_id, reason, deps)

      # Reconcile budget: create absorption record, release escrow (v4.0)
      reconcile_child_budget(parent_pid, child_budget_data, child_id, task_id, tree_spent)

      if notify_pid, do: send(notify_pid, {:dismiss_complete, child_id})
    catch
      # Handle sandbox owner exit - various exit formats from DBConnection
      :exit, {:stop, _reason} -> :ok
      :exit, {:shutdown, _reason} -> :ok
      :exit, :killed -> :ok
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

  # Query total tree spent before termination deletes records (v4.0)
  @spec query_child_tree_spent(String.t()) :: Decimal.t()
  defp query_child_tree_spent(child_id) do
    own_costs = Aggregator.by_agent(child_id)
    children_costs = Aggregator.by_agent_children(child_id)

    own_spent = own_costs.total_cost || Decimal.new("0")
    children_spent = children_costs.total_cost || Decimal.new("0")
    Decimal.add(own_spent, children_spent)
  end

  # Reconcile budget with pre-queried spent (after tree termination) (v4.0)
  @spec reconcile_child_budget(pid() | nil, map() | nil, String.t(), binary() | nil, Decimal.t()) ::
          :ok
  defp reconcile_child_budget(parent_pid, child_budget_data, child_id, task_id, tree_spent) do
    case child_budget_data do
      %{mode: :allocated, allocated: allocated} when not is_nil(allocated) ->
        if parent_pid && Process.alive?(parent_pid) do
          try do
            {:ok, parent_state} = Core.get_state(parent_pid)
            parent_agent_id = parent_state.agent_id

            # Create absorption cost record under the PARENT
            Recorder.record_silent(%{
              agent_id: parent_agent_id,
              task_id: task_id,
              cost_type: "child_budget_absorbed",
              cost_usd: tree_spent,
              metadata: %{
                child_agent_id: child_id,
                child_allocated: decimal_to_string(allocated),
                child_tree_spent: decimal_to_string(tree_spent),
                unspent_returned:
                  decimal_to_string(
                    Decimal.max(Decimal.sub(allocated, tree_spent), Decimal.new("0"))
                  ),
                dismissed_at: DateTime.to_iso8601(DateTime.utc_now())
              }
            })

            # Use Escrow.release_allocation to properly update parent
            Core.release_child_budget(parent_pid, allocated, tree_spent)
          catch
            :exit, _ -> :ok
          end
        end

        :ok

      _ ->
        # N/A or no budget - nothing to reconcile
        :ok
    end
  end

  # Convert Decimal to human-readable string for metadata (strips DB trailing zeros)
  @spec decimal_to_string(Decimal.t()) :: String.t()
  defp decimal_to_string(decimal) do
    if Decimal.equal?(decimal, 0) do
      "0"
    else
      decimal |> Decimal.round(2) |> Decimal.to_string()
    end
  end
end
