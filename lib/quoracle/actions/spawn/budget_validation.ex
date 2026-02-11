defmodule Quoracle.Actions.Spawn.BudgetValidation do
  @moduledoc """
  Budget validation for spawn action.

  Validates budget parameters and checks parent has sufficient funds
  before spawning child agents.
  """

  @doc """
  Validates and checks budget for spawn action.

  Returns {:ok, %{child_budget_data: map, escrow_amount: Decimal | nil}}
  or {:error, :invalid_budget_format | :insufficient_budget | :budget_required}
  """
  @spec validate_and_check_budget(map(), map()) ::
          {:ok, %{child_budget_data: map(), escrow_amount: Decimal.t() | nil}}
          | {:error, :invalid_budget_format | :insufficient_budget | :budget_required}
  def validate_and_check_budget(params, deps) do
    # Extract budget from params (string from LLM)
    budget_str = Map.get(params, :budget) || Map.get(params, "budget")

    case budget_str do
      nil ->
        # Check if parent has a budget - budgeted parents MUST give budget to children
        parent_budget = Map.get(deps, :budget_data)

        case parent_budget do
          %{mode: mode} when mode in [:root, :allocated] ->
            # Budgeted parent must specify budget for child
            {:error, :budget_required}

          _ ->
            # N/A, nil, or unknown parent - child gets N/A budget (unlimited)
            {:ok,
             %{
               child_budget_data: %{mode: :na, allocated: nil, committed: nil},
               escrow_amount: nil
             }}
        end

      budget_value ->
        # Parse and validate budget
        with {:ok, amount} <- parse_budget(budget_value),
             :ok <- validate_budget_positive(amount),
             :ok <- check_parent_budget_sufficient(amount, deps) do
          child_budget = %{mode: :allocated, allocated: amount, committed: Decimal.new("0")}
          {:ok, %{child_budget_data: child_budget, escrow_amount: amount}}
        end
    end
  end

  @doc """
  Parse budget string to Decimal.
  """
  @spec parse_budget(term()) :: {:ok, Decimal.t()} | {:error, :invalid_budget_format}
  def parse_budget(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      {_decimal, _remainder} -> {:error, :invalid_budget_format}
      :error -> {:error, :invalid_budget_format}
    end
  end

  def parse_budget(%Decimal{} = value), do: {:ok, value}
  def parse_budget(_), do: {:error, :invalid_budget_format}

  @doc """
  Validate budget is positive.
  """
  @spec validate_budget_positive(Decimal.t()) :: :ok | {:error, :invalid_budget_format}
  def validate_budget_positive(amount) do
    if Decimal.compare(amount, Decimal.new("0")) == :gt do
      :ok
    else
      {:error, :invalid_budget_format}
    end
  end

  @doc """
  Check if parent has sufficient budget for child allocation.
  """
  @spec check_parent_budget_sufficient(Decimal.t(), map()) ::
          :ok | {:error, :insufficient_budget}
  def check_parent_budget_sufficient(amount, deps) do
    parent_budget = Map.get(deps, :budget_data)

    case parent_budget do
      nil ->
        # No budget tracking - allow spawn
        :ok

      %{mode: :na} ->
        # N/A parent has unlimited budget
        :ok

      %{mode: mode, allocated: allocated, committed: committed}
      when mode in [:root, :allocated] ->
        # Calculate available = allocated - committed - spent
        spent = Map.get(deps, :spent, Decimal.new("0"))
        available = Decimal.sub(Decimal.sub(allocated, committed), spent)

        if Decimal.compare(available, amount) in [:gt, :eq] do
          :ok
        else
          {:error, :insufficient_budget}
        end

      _ ->
        # Unknown budget structure - allow spawn
        :ok
    end
  end
end
