defmodule Quoracle.Actions.AdjustBudget do
  @moduledoc """
  Adjusts a direct child's budget allocation.

  Allows parent agents to modify how much budget is allocated to their
  direct children at runtime.

  v3.0: Unified code path — always routes through Core.adjust_child_budget.
  No GenServer.call to child (uses cast). Child allocation read from parent state.
  Decrease validation uses spent-only (not spent+committed).

  Increase: Always allowed if parent has available funds
  Decrease: Only if new_allocated >= child's spent (from DB)
  """

  alias Quoracle.Agent.Core

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
    - {:error, map()} with details if decrease would exceed child's spent
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, atom() | map()}
  def execute(params, agent_id, opts) do
    child_id = Map.fetch!(params, :child_id)
    new_budget = params |> Map.fetch!(:new_budget) |> to_decimal()
    registry = Keyword.fetch!(opts, :registry)

    with :ok <- validate_positive(new_budget),
         {:ok, _child_pid} <- find_child(child_id, registry),
         :ok <- Core.adjust_child_budget(agent_id, child_id, new_budget, opts) do
      {:ok,
       %{
         action: "adjust_budget",
         child_id: child_id,
         new_budget: Decimal.to_string(new_budget)
       }}
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
end
