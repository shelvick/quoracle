defmodule Quoracle.Agent.Core.BudgetHandler do
  @moduledoc """
  Handles budget-related GenServer callbacks for Agent.Core.

  v23.0: Added adjust_child_budget/4 for ACTION_AdjustBudget.
  v24.0: Extracted handle_call implementations from Core.
  """

  require Logger
  alias Quoracle.Agent.Core
  alias Quoracle.Agent.Core.State
  alias Quoracle.Budget.{Escrow, Tracker}

  @doc """
  Adjusts a direct child's budget allocation with atomic escrow update.

  1. Validates child is a direct child of this parent
  2. Looks up child in Registry
  3. Calculates delta and adjusts parent escrow
  4. Updates child's budget_data.allocated

  Returns {:ok, new_state} or {:error, reason}.
  """
  @spec adjust_child_budget(map(), String.t(), Decimal.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def adjust_child_budget(state, child_id, new_budget, opts) do
    registry = Keyword.fetch!(opts, :registry)

    with {:ok, child_pid} <- find_child(child_id, registry),
         :ok <- validate_direct_child(state, child_id),
         {:ok, child_state} <- Core.get_state(child_pid),
         :ok <- validate_not_below_committed(new_budget, child_state.budget_data),
         {:ok, new_parent_budget} <-
           Escrow.adjust_child_allocation(
             state.budget_data,
             child_state.budget_data.allocated,
             new_budget,
             Tracker.get_spent(state.agent_id)
           ) do
      # Update child's budget_data
      child_budget_data = %{child_state.budget_data | allocated: new_budget}
      :ok = Core.update_budget_data(child_pid, child_budget_data)

      # Update parent's children list with new budget_allocated
      new_children = update_child_budget_in_list(state.children, child_id, new_budget)

      # Update parent's budget_data with new committed
      {:ok, %{state | budget_data: new_parent_budget, children: new_children}}
    end
  end

  @spec validate_direct_child(map(), String.t()) :: :ok | {:error, :not_direct_child}
  defp validate_direct_child(state, child_id) do
    children_ids = Enum.map(state.children || [], & &1.agent_id)

    if child_id in children_ids do
      :ok
    else
      {:error, :not_direct_child}
    end
  end

  # Validates new budget is not below child's committed amount (escrow for grandchildren)
  @spec validate_not_below_committed(Decimal.t(), map()) :: :ok | {:error, :below_committed}
  defp validate_not_below_committed(_new_budget, %{committed: nil}), do: :ok

  defp validate_not_below_committed(new_budget, %{committed: committed}) do
    if Decimal.compare(new_budget, committed) == :lt do
      {:error, :below_committed}
    else
      :ok
    end
  end

  @spec find_child(String.t(), atom()) :: {:ok, pid()} | {:error, :child_not_found}
  defp find_child(child_id, registry) do
    case Registry.lookup(registry, {:agent, child_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :child_not_found}
    end
  end

  @spec update_child_budget_in_list(list(), String.t(), Decimal.t()) :: list()
  defp update_child_budget_in_list(children, child_id, new_budget) do
    Enum.map(children, fn child ->
      if child.agent_id == child_id do
        %{child | budget_allocated: new_budget}
      else
        child
      end
    end)
  end

  # ============================================================================
  # Handle Call Implementations (extracted from Core v24.0)
  # ============================================================================

  @doc """
  Handle update_budget_committed call - increases committed (escrow) amount.
  """
  @spec handle_update_budget_committed(Decimal.t(), State.t()) ::
          {:reply, :ok, State.t()}
  def handle_update_budget_committed(amount, state) do
    case state.budget_data do
      %{committed: current} = budget_data when not is_nil(current) ->
        new_committed = Decimal.add(current, amount)
        new_budget_data = %{budget_data | committed: new_committed}
        {:reply, :ok, %{state | budget_data: new_budget_data}}

      _ ->
        # No budget tracking or N/A mode (committed is nil) - no-op
        {:reply, :ok, state}
    end
  end

  @doc """
  Handle release_budget_committed call - decreases committed (escrow) amount.
  """
  @spec handle_release_budget_committed(Decimal.t(), State.t()) ::
          {:reply, :ok, State.t()}
  def handle_release_budget_committed(amount, state) do
    case state.budget_data do
      %{committed: current} = budget_data when not is_nil(current) ->
        # Clamp to zero to prevent negative committed
        new_committed = Decimal.max(Decimal.sub(current, amount), Decimal.new("0"))
        new_budget_data = %{budget_data | committed: new_committed}
        {:reply, :ok, %{state | budget_data: new_budget_data}}

      _ ->
        # No budget tracking or N/A mode (committed is nil) - no-op
        {:reply, :ok, state}
    end
  end

  @doc """
  Handle get_budget call - returns budget_data and over_budget status.
  """
  @spec handle_get_budget(State.t()) ::
          {:reply, {:ok, map()}, State.t()}
  def handle_get_budget(state) do
    budget_info = %{
      budget_data: state.budget_data,
      over_budget: state.over_budget
    }

    {:reply, {:ok, budget_info}, state}
  end

  @doc """
  Handle update_budget_data call - replaces budget_data struct.
  """
  @spec handle_update_budget_data(map(), State.t()) ::
          {:reply, :ok, State.t()}
  def handle_update_budget_data(budget_data, state) do
    {:reply, :ok, %{state | budget_data: budget_data}}
  end

  @doc """
  Updates over_budget status based on current spent vs allocated.
  over_budget is monotonic - once true, stays true.
  """
  @spec update_over_budget_status(State.t()) :: State.t()
  def update_over_budget_status(%State{over_budget: true} = state) do
    # Already over budget - stays over budget (monotonic)
    state
  end

  def update_over_budget_status(%State{budget_data: %{allocated: nil}} = state) do
    # N/A budget - never over budget
    state
  end

  def update_over_budget_status(%State{} = state) do
    # Check if spent exceeds available budget
    # Wrap in try/rescue - DB may be unavailable during shutdown or network issues
    try do
      spent = Tracker.get_spent(state.agent_id)
      is_over = Tracker.over_budget?(state.budget_data, spent)
      %State{state | over_budget: is_over}
    rescue
      e in [DBConnection.OwnershipError, DBConnection.ConnectionError] ->
        Logger.warning("Skipping budget update for #{state.agent_id}: #{inspect(e.__struct__)}")
        state
    end
  end
end
