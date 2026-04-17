defmodule QuoracleWeb.DashboardLive.CostGuard do
  @moduledoc """
  Cost monotonic guard helpers for DashboardLive.
  """

  @spec parse_monotonic_guard(map()) :: boolean()
  def parse_monotonic_guard(session) do
    session
    |> monotonic_guard_session_value()
    |> monotonic_guard_disabled?()
    |> Kernel.not()
  end

  @spec apply_monotonic_guard(map() | nil, %{agents: map(), tasks: map()}) ::
          %{agents: map(), tasks: map()}
  def apply_monotonic_guard(nil, fresh_cost_data), do: fresh_cost_data

  def apply_monotonic_guard(prior_cost_data, fresh_cost_data) do
    prior_tasks = Map.get(prior_cost_data, :tasks, %{})

    guarded_tasks =
      Enum.reduce(fresh_cost_data.tasks, %{}, fn {task_id, fresh_total}, acc ->
        guarded_total =
          case {Map.get(prior_tasks, task_id), fresh_total} do
            {nil, _} ->
              fresh_total

            {prior_total, nil} ->
              prior_total

            {prior_total, fresh} ->
              if Decimal.compare(fresh, prior_total) == :lt, do: prior_total, else: fresh
          end

        Map.put(acc, task_id, guarded_total)
      end)

    %{fresh_cost_data | tasks: guarded_tasks}
  end

  @spec monotonic_guard_session_value(map()) :: term()
  defp monotonic_guard_session_value(session) do
    Map.get(session, "cost_monotonic_guard?", Map.get(session, :cost_monotonic_guard?))
  end

  @spec monotonic_guard_disabled?(term()) :: boolean()
  defp monotonic_guard_disabled?(false), do: true
  defp monotonic_guard_disabled?("false"), do: true
  defp monotonic_guard_disabled?(_), do: false
end
