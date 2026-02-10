defmodule Quoracle.Budget.Tracker do
  @moduledoc """
  Budget calculation and status tracking.

  Core formula: available = allocated - spent - committed

  Spent is queried from COST_Aggregator (agent_costs table).
  Allocated and committed come from agent's budget state.
  """

  alias Quoracle.Budget.Schema
  alias Quoracle.Costs.Aggregator

  @type budget_status :: :ok | :warning | :over_budget | :na

  @type budget_summary :: %{
          allocated: Decimal.t() | nil,
          spent: Decimal.t(),
          committed: Decimal.t(),
          available: Decimal.t() | nil,
          status: budget_status(),
          mode: Schema.budget_mode()
        }

  @warning_threshold Decimal.new("0.2")

  @doc """
  Returns total spent amount for an agent from the agent_costs table.
  """
  @spec get_spent(String.t()) :: Decimal.t()
  def get_spent(agent_id) do
    case Aggregator.by_agent(agent_id) do
      %{total_cost: cost} when not is_nil(cost) -> cost
      _ -> Decimal.new(0)
    end
  end

  @doc """
  Calculates available budget.

  Returns nil for N/A budgets (unlimited), otherwise allocated - spent - committed.
  """
  @spec calculate_available(Schema.budget_data(), Decimal.t()) :: Decimal.t() | nil
  def calculate_available(%{allocated: nil}, _spent), do: nil

  def calculate_available(%{allocated: allocated, committed: committed}, spent) do
    allocated
    |> Decimal.sub(spent)
    |> Decimal.sub(committed)
  end

  @doc """
  Returns the budget status based on available amount.

  - :na - unlimited budget (allocated is nil)
  - :over_budget - available <= 0
  - :warning - available <= 20% of allocated
  - :ok - available > 20% of allocated
  """
  @spec get_status(Schema.budget_data(), Decimal.t()) :: budget_status()
  def get_status(%{allocated: nil}, _spent), do: :na

  def get_status(%{allocated: allocated} = budget_data, spent) do
    available = calculate_available(budget_data, spent)

    cond do
      Decimal.compare(available, Decimal.new(0)) in [:lt, :eq] ->
        :over_budget

      Decimal.compare(available, Decimal.mult(allocated, @warning_threshold)) in [:lt, :eq] ->
        :warning

      true ->
        :ok
    end
  end

  @doc """
  Returns a complete budget summary for an agent.
  """
  @spec get_summary(String.t(), Schema.budget_data()) :: budget_summary()
  def get_summary(agent_id, budget_data) do
    spent = get_spent(agent_id)
    available = calculate_available(budget_data, spent)
    status = get_status(budget_data, spent)

    %{
      allocated: budget_data.allocated,
      spent: spent,
      committed: budget_data.committed,
      available: available,
      status: status,
      mode: budget_data.mode
    }
  end

  @doc """
  Checks if the budget is exhausted (available <= 0).

  Returns false for N/A budgets (unlimited).
  """
  @spec over_budget?(Schema.budget_data(), Decimal.t()) :: boolean()
  def over_budget?(%{allocated: nil}, _spent), do: false

  def over_budget?(budget_data, spent) do
    available = calculate_available(budget_data, spent)
    Decimal.compare(available, Decimal.new(0)) in [:lt, :eq]
  end

  @doc """
  Checks if sufficient budget is available for a required amount.

  Returns true for N/A budgets (unlimited).
  """
  @spec has_available?(Schema.budget_data(), Decimal.t(), Decimal.t()) :: boolean()
  def has_available?(%{allocated: nil}, _spent, _required), do: true

  def has_available?(budget_data, spent, required) do
    available = calculate_available(budget_data, spent)
    Decimal.compare(available, required) in [:gt, :eq]
  end

  @doc """
  Validates if budget can be decreased to new_allocated.

  Returns :ok if new_allocated >= spent + committed.
  Returns structured error with details if decrease would violate constraints.
  """
  @spec validate_budget_decrease(Schema.budget_data(), Decimal.t(), Decimal.t()) ::
          :ok | {:error, map()}
  def validate_budget_decrease(%{allocated: nil}, _spent, _new_allocated), do: :ok

  def validate_budget_decrease(%{committed: committed}, spent, new_allocated) do
    minimum = Decimal.add(spent, committed)

    if Decimal.compare(new_allocated, minimum) in [:gt, :eq] do
      :ok
    else
      {:error,
       %{
         reason: :would_violate_escrow,
         spent: spent,
         committed: committed,
         minimum: minimum,
         requested: new_allocated
       }}
    end
  end
end
