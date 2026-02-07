defmodule Quoracle.Budget.Escrow do
  @moduledoc """
  Escrow management for parent-child budget allocations.

  Lock: Parent commits funds when spawning child
  Release: Parent recovers unspent when child dismissed

  All operations are pure functions that return updated budget state.
  Actual state updates happen in AGENT_Core GenServer.
  """

  alias Quoracle.Budget.{Schema, Tracker}

  @type lock_result :: {:ok, Schema.budget_data()} | {:error, :insufficient_budget}
  @type release_result :: {:ok, Schema.budget_data(), Decimal.t()}

  @doc """
  Validates if an allocation amount is available.

  Returns :ok for N/A budgets (unlimited) or if sufficient funds available.
  """
  @spec validate_allocation(Schema.budget_data(), Decimal.t(), Decimal.t()) ::
          :ok | {:error, :insufficient_budget}
  def validate_allocation(%{allocated: nil}, _spent, _amount), do: :ok

  def validate_allocation(budget_data, spent, amount) do
    if Tracker.has_available?(budget_data, spent, amount) do
      :ok
    else
      {:error, :insufficient_budget}
    end
  end

  @doc """
  Locks budget for child allocation.

  For N/A budgets, returns unchanged state.
  For budgeted agents, validates availability and increases committed.
  """
  @spec lock_allocation(Schema.budget_data(), Decimal.t(), Decimal.t()) :: lock_result()
  def lock_allocation(%{allocated: nil} = budget_data, _spent, _amount) do
    {:ok, budget_data}
  end

  def lock_allocation(budget_data, spent, amount) do
    case validate_allocation(budget_data, spent, amount) do
      :ok ->
        updated = Schema.add_committed(budget_data, amount)
        {:ok, updated}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Releases budget when child is dismissed.

  Returns updated budget with decreased committed, plus the unspent amount.
  Unspent is clamped to zero if child overspent.
  """
  @spec release_allocation(Schema.budget_data(), Decimal.t(), Decimal.t()) :: release_result()
  def release_allocation(budget_data, child_allocated, child_spent) do
    unspent = Decimal.sub(child_allocated, child_spent)

    unspent_clamped =
      if Decimal.compare(unspent, Decimal.new(0)) == :lt do
        Decimal.new(0)
      else
        unspent
      end

    updated = Schema.release_committed(budget_data, child_allocated)

    {:ok, updated, unspent_clamped}
  end

  @doc """
  Adjusts a child's budget allocation and parent's committed atomically.

  For N/A parents: Returns unchanged (unlimited budget, no escrow tracking)
  For increase: Validates parent has available funds, increases parent.committed
  For decrease: Decreases parent.committed by abs(delta)
  For no change: Returns unchanged budget_data

  Returns updated parent budget_data with new committed value.
  """
  @spec adjust_child_allocation(Schema.budget_data(), Decimal.t(), Decimal.t(), Decimal.t()) ::
          {:ok, Schema.budget_data()} | {:error, term()}
  # N/A parent - unlimited budget, no escrow tracking needed
  def adjust_child_allocation(%{allocated: nil} = parent_budget, _current, _new, _spent) do
    {:ok, parent_budget}
  end

  def adjust_child_allocation(
        parent_budget,
        current_child_allocated,
        new_child_allocated,
        parent_spent
      ) do
    delta = Decimal.sub(new_child_allocated, current_child_allocated)

    cond do
      # No change
      Decimal.compare(delta, Decimal.new(0)) == :eq ->
        {:ok, parent_budget}

      # Increase: Check parent has funds
      Decimal.compare(delta, Decimal.new(0)) == :gt ->
        if Tracker.has_available?(parent_budget, parent_spent, delta) do
          {:ok, Schema.add_committed(parent_budget, delta)}
        else
          {:error, :insufficient_parent_budget}
        end

      # Decrease: Release from committed
      Decimal.compare(delta, Decimal.new(0)) == :lt ->
        release_amount = Decimal.abs(delta)
        {:ok, Schema.release_committed(parent_budget, release_amount)}
    end
  end
end
