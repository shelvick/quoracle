defmodule Quoracle.Agent.Core.ChildrenTracker do
  @moduledoc """
  Handles children-related GenServer callbacks for Agent.Core.
  Extracted to keep core.ex under 500-line limit.

  Follows the established TodoHandler pattern.
  """

  @doc """
  Handle child_spawned GenServer cast - add child to children list.
  Uses cast (not call) to avoid deadlock when called from action execution.
  Idempotent - adding existing child is a no-op (supports both ActionExecutor and background task paths).
  """
  @spec handle_child_spawned(map(), map()) :: {:noreply, map()}
  def handle_child_spawned(data, state) do
    # Idempotent: skip if child already tracked (ActionExecutor adds immediately, cast may duplicate)
    if Enum.any?(state.children, &(&1.agent_id == data.agent_id)) do
      {:noreply, state}
    else
      child_data = %{
        agent_id: data.agent_id,
        spawned_at: data.spawned_at,
        budget_allocated: Map.get(data, :budget_allocated)
      }

      {:noreply, %{state | children: [child_data | state.children]}}
    end
  end

  @doc """
  Handle child_dismissed GenServer cast - remove child from children list.
  Idempotent - dismissing non-existent child leaves state unchanged.
  """
  @spec handle_child_dismissed(String.t(), map()) :: {:noreply, map()}
  def handle_child_dismissed(child_id, state) when is_binary(child_id) do
    new_children = Enum.reject(state.children, &(&1.agent_id == child_id))
    {:noreply, %{state | children: new_children}}
  end

  @doc """
  Handle child_restored GenServer cast - add restored child to children list.
  Used during task restoration to rebuild parent's children list.
  Identical logic to handle_child_spawned - explicit message for clarity.
  """
  @spec handle_child_restored(map(), map()) :: {:noreply, map()}
  def handle_child_restored(data, state) do
    child_data = %{
      agent_id: data.agent_id,
      spawned_at: data.spawned_at,
      budget_allocated: Map.get(data, :budget_allocated)
    }

    new_children = [child_data | state.children]
    {:noreply, %{state | children: new_children}}
  end

  @doc """
  Returns total budget committed to active children.
  Ignores N/A children (nil budget_allocated).
  """
  @spec total_children_budget(list()) :: Decimal.t()
  def total_children_budget(children) do
    children
    |> Enum.map(& &1.budget_allocated)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end
end
