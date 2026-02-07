defmodule Quoracle.Fields.GlobalContextInjector do
  @moduledoc """
  Injects system-managed global fields from root task.
  """

  alias Quoracle.Tasks.Task
  alias Quoracle.Repo

  @doc """
  Injects global context and initial constraints from a task.

  Returns empty defaults if task not found or DB unavailable.

  ## Examples

      iex> inject(task_id)
      %{global_context: "Context", constraints: ["C1", "C2"]}
  """
  @spec inject(String.t()) :: map()
  def inject(task_id) when is_binary(task_id) do
    case fetch_task_fields(task_id) do
      {:ok, task} ->
        %{
          global_context: task.global_context || "",
          constraints: task.initial_constraints || []
        }

      {:error, _} ->
        %{
          global_context: "",
          constraints: []
        }
    end
  end

  defp fetch_task_fields(task_id) do
    try do
      case Repo.get(Task, task_id) do
        nil -> {:error, :not_found}
        task -> {:ok, task}
      end
    rescue
      _e in DBConnection.OwnershipError ->
        {:error, :db_access_required}

      _e in DBConnection.ConnectionError ->
        {:error, :db_error}

      _e in Ecto.Query.CastError ->
        {:error, :invalid_task_id}

      _e in ArgumentError ->
        {:error, :malformed_data}
    end
  end
end
