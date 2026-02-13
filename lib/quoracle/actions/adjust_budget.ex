defmodule Quoracle.Actions.AdjustBudget do
  @moduledoc """
  Adjusts a direct child's budget allocation.

  Allows parent agents to modify how much budget is allocated to their
  direct children at runtime.

  Increase: Always allowed if parent has available funds
  Decrease: Only if new_allocated >= child's (spent + committed)
  """

  alias Quoracle.Agent.Core
  alias Quoracle.Budget.Tracker

  @doc """
  Executes the adjust_budget action.

  ## Parameters
    - params: Map with :child_id and :new_budget (required)
    - agent_id: The parent agent adjusting the child's budget
    - opts: Keyword list with :registry (required), :pubsub (optional)

  ## Returns
    - {:ok, map()} on success with action details
    - {:error, :child_not_found} if child doesn't exist
    - {:error, :not_direct_child} if target is not a direct child
    - {:error, :insufficient_parent_budget} if parent lacks funds
    - {:error, :invalid_amount} if new_budget <= 0
    - {:error, map()} with details if decrease would violate escrow
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, atom() | map()}
  def execute(params, agent_id, opts) do
    child_id = Map.fetch!(params, :child_id)
    new_budget = params |> Map.fetch!(:new_budget) |> to_decimal()
    registry = Keyword.fetch!(opts, :registry)

    with :ok <- validate_positive(new_budget),
         {:ok, child_pid} <- find_child(child_id, registry),
         {:ok, parent_state} <- get_parent_state(agent_id, registry, opts),
         :ok <- validate_direct_child(parent_state, child_id),
         {:ok, child_state} <- Core.get_state(child_pid),
         :ok <- validate_adjustment(parent_state, child_state, new_budget),
         :ok <- do_adjust(agent_id, child_id, new_budget, opts) do
      {:ok,
       %{
         action: "adjust_budget",
         child_id: child_id,
         new_budget: Decimal.to_string(new_budget)
       }}
    end
  end

  # v2.0: Dispatch budget adjustment based on whether parent_config is available.
  # When parent_config is provided, the parent GenServer may be blocked during action
  # execution and can't service GenServer.call. Update child directly instead.
  # When no parent_config, use Core.adjust_child_budget via Registry (original path).
  defp do_adjust(agent_id, child_id, new_budget, opts) do
    if Keyword.has_key?(opts, :parent_config) do
      adjust_child_directly(child_id, new_budget, opts)
    else
      Core.adjust_child_budget(agent_id, child_id, new_budget, opts)
    end
  end

  # Update child's budget_data directly when parent GenServer is unavailable.
  # Parent's budget_data will be updated by Core when it processes the action result.
  @spec adjust_child_directly(String.t(), Decimal.t(), keyword()) :: :ok | {:error, term()}
  defp adjust_child_directly(child_id, new_budget, opts) do
    registry = Keyword.fetch!(opts, :registry)

    case Registry.lookup(registry, {:agent, child_id}) do
      [{child_pid, _}] ->
        child_budget_data =
          case Core.get_state(child_pid) do
            {:ok, child_state} -> %{child_state.budget_data | allocated: new_budget}
          end

        Core.update_budget_data(child_pid, child_budget_data)

      [] ->
        {:error, :child_not_found}
    end
  end

  # Convert various number formats to Decimal
  @spec to_decimal(number() | String.t() | Decimal.t()) :: Decimal.t()
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  @spec validate_positive(Decimal.t()) :: :ok | {:error, :invalid_amount}
  defp validate_positive(amount) do
    if Decimal.compare(amount, Decimal.new(0)) == :gt do
      :ok
    else
      {:error, :invalid_amount}
    end
  end

  @spec find_child(String.t(), atom()) :: {:ok, pid()} | {:error, :child_not_found}
  defp find_child(child_id, registry) do
    case Registry.lookup(registry, {:agent, child_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :child_not_found}
    end
  end

  @spec get_parent_state(String.t(), atom(), keyword()) ::
          {:ok, map()} | {:error, :parent_not_found}
  defp get_parent_state(parent_id, registry, opts) do
    # v2.0: Use parent_config from opts (passed by ActionExecutor) to avoid
    # calling back to Core via GenServer.call (prevents deadlock)
    case Keyword.get(opts, :parent_config) do
      %{agent_id: ^parent_id} = parent_state ->
        {:ok, parent_state}

      _ ->
        # Fallback to Registry lookup (for direct execution outside ActionExecutor)
        case Registry.lookup(registry, {:agent, parent_id}) do
          [{parent_pid, _}] -> Core.get_state(parent_pid)
          [] -> {:error, :parent_not_found}
        end
    end
  end

  @spec validate_direct_child(map(), String.t()) :: :ok | {:error, :not_direct_child}
  defp validate_direct_child(parent_state, child_id) do
    children_ids = Enum.map(parent_state.children || [], & &1.agent_id)

    if child_id in children_ids do
      :ok
    else
      {:error, :not_direct_child}
    end
  end

  @spec validate_adjustment(map(), map(), Decimal.t()) :: :ok | {:error, term()}
  defp validate_adjustment(parent_state, child_state, new_budget) do
    current_allocation = child_state.budget_data.allocated
    delta = Decimal.sub(new_budget, current_allocation)

    cond do
      # Increase: Check parent has available funds
      Decimal.compare(delta, Decimal.new(0)) == :gt ->
        validate_increase(parent_state, delta)

      # Decrease: Check child can accommodate
      Decimal.compare(delta, Decimal.new(0)) == :lt ->
        validate_decrease(child_state, new_budget)

      # No change
      true ->
        :ok
    end
  end

  @spec validate_increase(map(), Decimal.t()) :: :ok | {:error, :insufficient_parent_budget}
  defp validate_increase(parent_state, delta) do
    # N/A budget (nil allocated) allows any increase
    if parent_state.budget_data.allocated == nil do
      :ok
    else
      parent_spent = Tracker.get_spent(parent_state.agent_id)

      if Tracker.has_available?(parent_state.budget_data, parent_spent, delta) do
        :ok
      else
        {:error, :insufficient_parent_budget}
      end
    end
  end

  @spec validate_decrease(map(), Decimal.t()) :: :ok | {:error, map()}
  defp validate_decrease(child_state, new_budget) do
    child_spent = Tracker.get_spent(child_state.agent_id)
    Tracker.validate_budget_decrease(child_state.budget_data, child_spent, new_budget)
  end
end
