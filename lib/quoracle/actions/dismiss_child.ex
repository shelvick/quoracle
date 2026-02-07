defmodule Quoracle.Actions.DismissChild do
  @moduledoc """
  Dismiss child action that recursively terminates a child agent and all its descendants.

  Parent agents use this action to clean up child agents when they are no longer needed.
  Termination happens in the background with immediate return to the caller.
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias Quoracle.Agent.Core
  alias Quoracle.Agent.TreeTerminator
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

    Task.Supervisor.start_child(
      Quoracle.SpawnTaskSupervisor,
      fn ->
        # Wrap entire task in try/catch to handle sandbox owner exit race condition
        # This happens when test exits before TreeTerminator Task completes
        try do
          # Allow DB access in background task (test isolation)
          if deps.sandbox_owner do
            Sandbox.allow(Repo, deps.sandbox_owner, self())
          end

          # Get child's budget_data BEFORE termination (for budget release)
          child_budget_data = get_child_budget_data(child_id, registry)

          TreeTerminator.terminate_tree(child_id, parent_id, reason, deps)

          # Release budget from parent's committed (v3.0)
          release_budget_from_parent(parent_pid, child_budget_data)

          # Notify test process that background task is complete
          if notify_pid do
            send(notify_pid, {:dismiss_complete, child_id})
          end
        catch
          # Handle sandbox owner exit - test process died before task completed
          # Various exit formats from DBConnection when sandbox owner dies:
          # The :stop tuple wraps the actual shutdown reason from DBConnection
          :exit, {:stop, _reason} -> :ok
          :exit, {:shutdown, _reason} -> :ok
          :exit, :killed -> :ok
        end
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

  # Release budget from parent's committed when child is dismissed (v3.0)
  defp release_budget_from_parent(parent_pid, child_budget_data) do
    # Only release if child had allocated budget
    case child_budget_data do
      %{mode: :allocated, allocated: allocated} when not is_nil(allocated) ->
        if parent_pid && Process.alive?(parent_pid) do
          try do
            Core.release_budget_committed(parent_pid, allocated)
          catch
            :exit, _ -> :ok
          end
        end

      _ ->
        # N/A or no budget - nothing to release
        :ok
    end
  end
end
