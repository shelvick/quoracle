defmodule QuoracleWeb.UI.TaskTree.BudgetHelpers do
  @moduledoc """
  Extracted budget display helpers for TaskTree LiveComponent.
  Provides task and agent budget summary calculation and CSS class helpers.
  """

  @doc """
  Calculates task budget summary with spent amount and percentage.
  Accepts pre-computed total_cost from batch query to avoid N+1 DB queries.
  """
  @spec calculate_task_budget_summary(Decimal.t(), Decimal.t() | nil) :: %{
          spent: Decimal.t(),
          percentage: float()
        }
  def calculate_task_budget_summary(budget_limit, total_cost) do
    spent_decimal = total_cost || Decimal.new(0)

    percentage =
      if Decimal.compare(budget_limit, Decimal.new(0)) == :gt do
        Decimal.div(spent_decimal, budget_limit)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.to_float()
      else
        0.0
      end

    %{
      spent: Decimal.round(spent_decimal, 2),
      percentage: percentage
    }
  end

  @doc """
  Returns CSS color class based on budget percentage.
  """
  @spec budget_color_class(number()) :: String.t()
  def budget_color_class(percentage) when percentage > 100, do: "text-red-600"
  def budget_color_class(percentage) when percentage > 50, do: "text-yellow-600"
  def budget_color_class(_percentage), do: "text-green-600"

  @doc """
  Returns CSS progress bar color class based on budget percentage.
  """
  @spec budget_progress_color(number()) :: String.t()
  def budget_progress_color(percentage) when percentage > 100, do: "bg-red-500"
  def budget_progress_color(percentage) when percentage > 50, do: "bg-yellow-500"
  def budget_progress_color(_percentage), do: "bg-green-500"

  @doc """
  Builds agent budget summary from agent data for badge display.
  Accepts pre-computed total_cost to avoid N+1 DB queries.
  """
  @spec build_agent_budget_summary(map(), Decimal.t() | nil) :: map()
  def build_agent_budget_summary(%{budget_data: %{mode: :na}}, _total_cost) do
    %{status: :na}
  end

  def build_agent_budget_summary(%{budget_data: %{allocated: nil}}, _total_cost) do
    %{status: :na}
  end

  def build_agent_budget_summary(%{agent_id: _agent_id, budget_data: budget_data}, total_cost) do
    allocated = budget_data.allocated
    committed = budget_data.committed || Decimal.new(0)
    spent = total_cost || Decimal.new(0)
    available = Decimal.sub(Decimal.sub(allocated, spent), committed)

    status =
      cond do
        Decimal.compare(available, Decimal.new(0)) == :lt -> :over_budget
        Decimal.compare(available, Decimal.mult(allocated, Decimal.new("0.2"))) == :lt -> :warning
        true -> :ok
      end

    %{
      status: status,
      allocated: allocated,
      spent: spent,
      committed: committed,
      available: available
    }
  end

  def build_agent_budget_summary(_agent, _total_cost) do
    %{status: :na}
  end
end
