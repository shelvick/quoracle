defmodule Quoracle.Agent.Core.BudgetHandler do
  @moduledoc """
  Handles budget-related GenServer callbacks for Agent.Core.

  v23.0: Added adjust_child_budget/4 for ACTION_AdjustBudget.
  v24.0: Extracted handle_call implementations from Core.
  v37.0: Rewrite adjust_child_budget — no child GenServer.call,
         reads allocation from parent's children list, casts to child,
         validates decrease with spent-only (not spent+committed).
  """

  require Logger
  alias Quoracle.Agent.Core.State
  alias Quoracle.Budget.{Escrow, Tracker}

  @doc """
  Adjusts a direct child's budget allocation with atomic escrow update.

  v3.0 flow (no GenServer.call to child):
  1. Validates child is a direct child of this parent
  2. Reads current allocation from parent's children[].budget_allocated
  3. Validates decrease against child's DB-spent only (not committed)
  4. Adjusts parent escrow via Escrow.adjust_child_allocation/4
  5. Casts {:set_budget_allocated, new_budget} to child (fire-and-forget)
  6. Updates parent's children[].budget_allocated

  Returns {:ok, new_state} or {:error, reason}.
  """
  @spec adjust_child_budget(map(), String.t(), Decimal.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def adjust_child_budget(state, child_id, new_budget, opts) do
    registry = Keyword.fetch!(opts, :registry)

    with :ok <- validate_direct_child(state, child_id),
         {:ok, current_allocation} <- get_child_allocation(state, child_id),
         :ok <- validate_decrease_spent_only(child_id, current_allocation, new_budget),
         {:ok, new_parent_budget} <-
           Escrow.adjust_child_allocation(
             state.budget_data,
             current_allocation,
             new_budget,
             Tracker.get_spent(state.agent_id)
           ) do
      # Cast to child (fire-and-forget, no timeout possible)
      cast_budget_to_child(child_id, new_budget, registry)

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

  # Read child's current allocation from parent's children list (not child's state)
  @spec get_child_allocation(map(), String.t()) ::
          {:ok, Decimal.t()} | {:error, :not_direct_child}
  defp get_child_allocation(state, child_id) do
    case Enum.find(state.children || [], &(&1.agent_id == child_id)) do
      %{budget_allocated: allocated} when not is_nil(allocated) -> {:ok, allocated}
      %{budget_allocated: nil} -> {:ok, Decimal.new(0)}
      nil -> {:error, :not_direct_child}
    end
  end

  # Validate decrease against spent-only from DB (not spent+committed).
  # Only checks when new_budget < current_allocation (decrease case).
  @spec validate_decrease_spent_only(String.t(), Decimal.t(), Decimal.t()) ::
          :ok | {:error, map()}
  defp validate_decrease_spent_only(child_id, current_allocation, new_budget) do
    delta = Decimal.sub(new_budget, current_allocation)

    if Decimal.compare(delta, Decimal.new(0)) == :lt do
      # Decrease: validate against spent-only from DB
      child_spent = Tracker.get_spent(child_id)

      if Decimal.compare(new_budget, child_spent) in [:gt, :eq] do
        :ok
      else
        {:error,
         %{
           reason: :would_exceed_spent,
           child_spent: Decimal.to_string(child_spent),
           requested: Decimal.to_string(new_budget),
           minimum: Decimal.to_string(child_spent)
         }}
      end
    else
      # Increase or no change — no decrease validation needed
      :ok
    end
  end

  # Cast {:set_budget_allocated, new_budget} to child (fire-and-forget)
  @spec cast_budget_to_child(String.t(), Decimal.t(), atom()) :: :ok
  defp cast_budget_to_child(child_id, new_budget, registry) do
    case Registry.lookup(registry, {:agent, child_id}) do
      [{child_pid, _}] ->
        GenServer.cast(child_pid, {:set_budget_allocated, new_budget})

      [] ->
        # Child may have died — cast is best-effort
        :ok
    end

    :ok
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
  Handle release_child_budget call - uses Escrow.release_allocation for proper math.
  Decrements committed by child_allocated, re-evaluates over_budget.
  """
  @spec handle_release_child_budget(Decimal.t(), Decimal.t(), State.t()) ::
          {:reply, :ok, State.t()}
  def handle_release_child_budget(child_allocated, child_spent, state) do
    {:ok, updated_budget, _unspent} =
      Escrow.release_allocation(state.budget_data, child_allocated, child_spent)

    new_state = %{state | budget_data: updated_budget}
    # Re-evaluate over_budget (v34.0 removes monotonicity)
    new_state = update_over_budget_status(new_state)
    {:reply, :ok, new_state}
  end

  @doc """
  Handle set_budget_allocated cast - updates allocated and re-evaluates over_budget.
  v37.0: New handler for fire-and-forget budget updates from parent.
  """
  @spec handle_set_budget_allocated(Decimal.t(), State.t()) :: {:noreply, State.t()}
  def handle_set_budget_allocated(new_budget, state) do
    budget_data = state.budget_data
    # Ensure committed is a valid Decimal when transitioning from N/A mode
    committed = budget_data[:committed] || Decimal.new(0)
    new_budget_data = %{budget_data | allocated: new_budget, committed: committed}
    new_state = %{state | budget_data: new_budget_data}
    new_state = update_over_budget_status(new_state)
    {:noreply, new_state}
  end

  @doc """
  Updates over_budget status based on current spent vs allocated.
  Re-evaluates on every call - budget can recover when child absorption
  returns unspent funds.
  """
  @spec update_over_budget_status(State.t()) :: State.t()
  def update_over_budget_status(%State{budget_data: %{allocated: nil}} = state) do
    # N/A budget - never over budget
    state
  end

  def update_over_budget_status(%State{} = state) do
    # Re-evaluate budget status (not monotonic - budget can recover via child absorption)
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
