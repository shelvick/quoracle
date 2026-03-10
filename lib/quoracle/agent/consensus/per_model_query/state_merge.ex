defmodule Quoracle.Agent.Consensus.PerModelQuery.StateMerge do
  @moduledoc """
  State merge utilities for parallel per-model consensus queries.
  Merges disjoint per-model state slices back into a unified agent state.
  Extracted from PerModelQuery to maintain <500 line modules.
  """

  @doc """
  Merge per-model state slices from parallel Tasks back into the initial state.
  Each task returns `{result_tuple, per_model_state}`.
  """
  @spec merge_parallel_results(map(), list({{:ok | :error, String.t(), any()}, map()})) ::
          {list(), map()}
  def merge_parallel_results(initial_state, task_results) do
    results = Enum.map(task_results, fn {result, _state} -> result end)

    # Merge per-model state slices back into initial state
    # Each model only modifies its own key in these three maps
    final_state =
      Enum.reduce(task_results, initial_state, fn {_result, model_state}, acc ->
        acc
        |> merge_per_model_map(:model_histories, initial_state, model_state)
        |> merge_per_model_map(:context_lessons, initial_state, model_state)
        |> merge_per_model_map(:model_states, initial_state, model_state)
      end)

    {results, final_state}
  end

  @doc """
  Check if any of the three per-model maps were modified.
  """
  @spec state_changed?(map(), map()) :: boolean()
  def state_changed?(initial, final) do
    initial.model_histories != final.model_histories ||
      Map.get(initial, :context_lessons) != Map.get(final, :context_lessons) ||
      Map.get(initial, :model_states) != Map.get(final, :model_states)
  end

  @doc """
  Unwrap a Task exit reason and re-raise the original exception.
  Task.await_many wraps crash reasons as `{{exception, stacktrace}, {Task, :await_many, _}}`.
  """
  @spec unwrap_task_exit(term()) :: no_return()
  def unwrap_task_exit(reason) do
    case extract_exception(reason) do
      {exception, stacktrace} -> reraise exception, stacktrace
      nil -> exit(reason)
    end
  end

  @doc """
  Extract an exception and stacktrace from a nested Task exit reason.
  Returns `{exception, stacktrace}` or `nil` if not an exception.
  """
  @spec extract_exception(term()) :: {Exception.t(), list()} | nil
  def extract_exception({exception, stacktrace})
      when is_exception(exception) and is_list(stacktrace),
      do: {exception, stacktrace}

  def extract_exception({inner, {Task, _, _}}), do: extract_exception(inner)
  def extract_exception({%Task{}, inner}), do: extract_exception(inner)
  def extract_exception({:exit, inner}), do: extract_exception(inner)
  def extract_exception(_), do: nil

  # Merge only keys that changed from the initial state for a given field.
  @spec merge_per_model_map(map(), atom(), map(), map()) :: map()
  defp merge_per_model_map(acc, field, initial_state, model_state) do
    initial_map = Map.get(initial_state, field, %{})
    model_map = Map.get(model_state, field, %{})

    # Find keys that differ from initial (i.e., were modified by this model's query)
    changed_entries =
      Enum.filter(model_map, fn {key, value} ->
        Map.get(initial_map, key) != value
      end)

    if changed_entries == [] do
      acc
    else
      current = Map.get(acc, field, %{})
      updated = Map.merge(current, Map.new(changed_entries))
      Map.put(acc, field, updated)
    end
  end
end
