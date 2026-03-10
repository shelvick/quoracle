defmodule QuoracleWeb.UI.TaskTree.BudgetHelpers do
  @moduledoc """
  Extracted budget display helpers for TaskTree LiveComponent.
  Provides task and agent budget summary calculation and CSS class helpers.
  """

  @doc """
  Calculates task budget summary with spent amount and percentage.
  """
  @spec calculate_task_budget_summary(String.t(), Decimal.t(), any()) :: %{
          spent: Decimal.t(),
          percentage: float()
        }
  def calculate_task_budget_summary(task_id, budget_limit, _costs_updated_at) do
    cost_summary = Quoracle.Costs.Aggregator.by_task(task_id)
    spent_decimal = cost_summary.total_cost || Decimal.new(0)

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
  """
  @spec build_agent_budget_summary(map()) :: map()
  def build_agent_budget_summary(%{budget_data: %{mode: :na}}) do
    %{status: :na}
  end

  def build_agent_budget_summary(%{budget_data: %{allocated: nil}}) do
    %{status: :na}
  end

  def build_agent_budget_summary(%{agent_id: agent_id, budget_data: budget_data}) do
    allocated = budget_data.allocated
    committed = budget_data.committed || Decimal.new(0)
    spent = Quoracle.Costs.Aggregator.by_agent(agent_id).total_cost || Decimal.new(0)
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

  def build_agent_budget_summary(_agent) do
    %{status: :na}
  end
end
