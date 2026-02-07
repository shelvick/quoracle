defmodule Quoracle.Actions.Router.Persistence do
  @moduledoc """
  Database persistence for action execution results.

  Handles logging of action executions to TABLE_Logs for audit trail.
  """

  require Logger

  @doc """
  Execute an action and persist the result to database.

  This is the main entry point for action execution with persistence.
  Extracts agent_id and other metadata from opts, executes the action,
  and logs the result to TABLE_Logs.
  """
  @spec execute_with_persistence(
          GenServer.server(),
          atom(),
          map(),
          keyword(),
          (GenServer.server(), atom(), map(), String.t(), keyword() ->
             {:ok, any()} | {:error, any()} | {:async, reference()})
        ) ::
          {:ok, any()} | {:error, any()} | {:async_task, Task.t(), reference(), integer()}
  def execute_with_persistence(router, action_type, params, opts, execute_fn) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    # Execute the action using provided execute function
    result = execute_fn.(router, action_type, params, agent_id, opts)

    # Persist the result (defensive - don't crash on persistence failure)
    persist_action_result(action_type, params, result, opts)

    # Return the action result unchanged
    result
  end

  @doc """
  Persist action execution result to database.

  Called after action completes.
  Logs both successful and failed executions for audit trail.
  """
  @spec persist_action_result(atom(), map(), any(), keyword()) :: :ok
  def persist_action_result(action_type, params, result, opts) do
    # Extract metadata from opts
    task_id = Keyword.get(opts, :task_id)
    agent_id = Keyword.get(opts, :agent_id)

    # Skip persistence if task_id missing (warning case per spec)
    if task_id && agent_id do
      # Determine status and result map based on action outcome
      {status, result_map} =
        case result do
          {:ok, data} ->
            {"success", %{data: sanitize_for_json(data)}}

          {:error, reason} ->
            {"error", %{error: sanitize_for_json(reason)}}

          {:async, _ref} ->
            {"success", %{async: true}}

          {:async_task, _task, _ref, _timeout} ->
            {"success", %{async: true}}

          _ ->
            # Unknown result format - log as success with raw data
            {"success", %{data: sanitize_for_json(result)}}
        end

      attrs = %{
        agent_id: agent_id,
        task_id: task_id,
        action_type: to_string(action_type),
        params: sanitize_for_json(params),
        result: result_map,
        status: status
      }

      # Defensive - log error but don't crash router if persistence fails
      # try/catch handles test cleanup race where sandbox dies mid-operation
      try do
        case Quoracle.Tasks.TaskManager.save_log(attrs) do
          {:ok, _log} ->
            :ok

          {:error, %Ecto.Changeset{errors: errors} = reason} ->
            # Use debug level for foreign key errors (invalid task_id from tests)
            if Keyword.has_key?(errors, :task_id) do
              Logger.debug("Skipping action persistence: invalid task_id")
            else
              Logger.error("Failed to persist action result: #{inspect(reason)}")
            end

            :ok

          {:error, reason} ->
            Logger.error("Failed to persist action result: #{inspect(reason)}")
            :ok
        end
      catch
        :exit, _ -> :ok
      end
    else
      # Log warning if task_id missing
      if !task_id do
        Logger.warning("Skipping action persistence: task_id missing for agent #{agent_id}")
      end

      :ok
    end
  end

  # Remove non-JSON-serializable values (References, PIDs, etc.)
  # Recursively sanitizes nested structures
  defp sanitize_for_json(data) when is_struct(data) do
    # Structs (DateTime, etc.) are already JSON-serializable if they are
    # Just pass them through without recursive processing
    data
  end

  defp sanitize_for_json(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} -> {k, sanitize_for_json(v)} end)
    |> Enum.filter(fn {_k, v} -> json_serializable?(v) end)
    |> Map.new()
  end

  defp sanitize_for_json(data) when is_list(data) do
    data
    |> Enum.map(&sanitize_for_json/1)
    |> Enum.filter(&json_serializable?/1)
  end

  defp sanitize_for_json(data), do: data

  defp json_serializable?(value) when is_reference(value), do: false
  defp json_serializable?(value) when is_pid(value), do: false
  defp json_serializable?(value) when is_port(value), do: false
  defp json_serializable?(value) when is_function(value), do: false
  defp json_serializable?(_), do: true
end
