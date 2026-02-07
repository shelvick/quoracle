defmodule QuoracleWeb.UI.BudgetBadge do
  @moduledoc """
  Compact budget status badge for agent tree nodes.

  Display format: "$X.XX left" or "N/A"
  Color coding based on status:
  - :ok -> green
  - :warning -> yellow
  - :over_budget -> red (shows negative)
  - :na -> gray
  """

  use Phoenix.Component

  attr(:summary, :map, required: true)
  attr(:class, :string, default: "")

  def budget_badge(assigns) do
    ~H"""
    <span
      class={["budget-badge text-xs px-1.5 py-0.5 rounded", status_class(@summary.status), @class]}
      title={budget_title(@summary)}
    >
      <%= format_available(@summary) %>
    </span>
    """
  end

  defp status_class(:ok), do: "bg-green-100 text-green-800"
  defp status_class(:warning), do: "bg-yellow-100 text-yellow-800"
  defp status_class(:over_budget), do: "bg-red-100 text-red-800"
  defp status_class(:na), do: "bg-gray-100 text-gray-500"

  defp format_available(%{status: :na}), do: "N/A"

  defp format_available(%{available: available}) do
    rounded = Decimal.round(available, 2)

    if Decimal.compare(available, Decimal.new(0)) == :lt do
      "-$#{Decimal.abs(rounded)}"
    else
      "$#{rounded} left"
    end
  end

  defp budget_title(%{status: :na}), do: "Budget: N/A (unlimited)"

  defp budget_title(%{allocated: alloc, spent: spent, committed: comm, available: avail}) do
    "Allocated: $#{Decimal.round(alloc, 2)} | " <>
      "Spent: $#{Decimal.round(spent, 2)} | " <>
      "Committed: $#{Decimal.round(comm, 2)} | " <>
      "Available: $#{Decimal.round(avail, 2)}"
  end
end
