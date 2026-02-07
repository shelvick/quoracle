defmodule Quoracle.Agent.Core.Persistence.ACEState do
  @moduledoc """
  ACE (Agentic Context Engineering) state serialization/deserialization.

  Handles context_lessons, model_states, and model_histories persistence to/from database.
  Extracted from Core.Persistence to maintain 500-line limit.
  """

  require Logger

  # Ensure lesson type atoms exist for String.to_existing_atom/1
  # during ACE state restoration from database
  @lesson_types [:factual, :behavioral]

  @doc """
  Returns the list of valid lesson types.
  This ensures atoms exist at compile time for String.to_existing_atom/1.
  """
  @spec lesson_types() :: [atom()]
  def lesson_types, do: @lesson_types

  @doc """
  Serialize ACE state (context_lessons, model_states) for database storage.

  Converts:
  - Atom lesson types (:factual, :behavioral) to strings
  - DateTime values to ISO8601 strings
  - Handles nil/missing values gracefully
  """
  @spec serialize(map()) :: map()
  def serialize(state) when is_map(state) do
    context_lessons = Map.get(state, :context_lessons) || %{}
    model_states = Map.get(state, :model_states) || %{}
    model_histories = Map.get(state, :model_histories) || %{}

    %{
      "context_lessons" => serialize_context_lessons(context_lessons),
      "model_states" => serialize_model_states(model_states),
      "model_histories" => serialize_model_histories(model_histories)
    }
  end

  def serialize(_),
    do: %{"context_lessons" => %{}, "model_states" => %{}, "model_histories" => %{}}

  @doc """
  Deserialize ACE state from database format back to Elixir format.

  Converts:
  - String lesson types to atoms (:factual, :behavioral)
  - ISO8601 strings to DateTime
  - Handles nil/empty/invalid data gracefully
  """
  @spec deserialize(map() | nil) :: map()
  def deserialize(nil), do: %{context_lessons: %{}, model_states: %{}, model_histories: %{}}

  def deserialize(stored_data) when is_map(stored_data) do
    context_lessons = stored_data["context_lessons"] || %{}
    model_states = stored_data["model_states"] || %{}
    model_histories = stored_data["model_histories"] || %{}

    %{
      context_lessons: deserialize_context_lessons(context_lessons),
      model_states: deserialize_model_states(model_states),
      model_histories: deserialize_model_histories(model_histories)
    }
  end

  def deserialize(_), do: %{context_lessons: %{}, model_states: %{}, model_histories: %{}}

  @doc """
  Persist ACE state to database.

  Called after condensation and on graceful terminate.
  Skips persistence only if task_id is nil (no associated task).

  Note: Unlike persist_agent, this does NOT check restoration_mode.
  ACE state must be persisted after condensation regardless of how
  the agent was started (fresh spawn or restored from DB).
  """
  @spec persist(map()) :: :ok
  def persist(state) when is_map(state) do
    task_id = Map.get(state, :task_id)
    agent_id = Map.get(state, :agent_id)

    # Skip only if no task_id (test agents without task association)
    if is_nil(task_id) do
      :ok
    else
      serialized = serialize(state)

      try do
        case Quoracle.Tasks.TaskManager.update_agent_state(agent_id, serialized) do
          {:ok, _agent} ->
            :ok

          {:error, reason} ->
            Logger.debug("Failed to persist ACE state for #{agent_id}: #{inspect(reason)}")
            :ok
        end
      rescue
        e in [DBConnection.OwnershipError, DBConnection.ConnectionError] ->
          Logger.debug("Zombie agent #{agent_id} ACE persist: #{inspect(e.__struct__)}")
          :ok

        e ->
          Logger.debug("Failed to persist ACE state for #{agent_id}: #{inspect(e)}")
          :ok
      catch
        :exit, {:shutdown, %DBConnection.ConnectionError{}} ->
          # Sandbox owner exited during test cleanup - expected race condition
          :ok

        :exit, reason ->
          Logger.debug("Zombie agent #{agent_id} ACE persist exit: #{inspect(reason)}")
          :ok
      end
    end
  end

  def persist(_), do: :ok

  @doc """
  Restore ACE state from database agent record.

  Takes a db_agent map with :state field and deserializes the ACE data.
  Returns empty defaults for nil/empty state.
  """
  @spec restore(map()) :: map()
  def restore(%{state: state}) when is_map(state) and map_size(state) > 0 do
    deserialize(state)
  end

  def restore(_), do: %{context_lessons: %{}, model_states: %{}, model_histories: %{}}

  # Private helpers for serialization

  defp serialize_context_lessons(lessons) when is_map(lessons) do
    Map.new(lessons, fn {model_id, lesson_list} ->
      {model_id, serialize_lesson_list(lesson_list)}
    end)
  end

  defp serialize_context_lessons(_), do: %{}

  defp serialize_lesson_list(lessons) when is_list(lessons) do
    Enum.map(lessons, &serialize_lesson/1)
  end

  defp serialize_lesson_list(_), do: []

  defp serialize_lesson(%{type: type, content: content, confidence: confidence}) do
    %{
      "type" => Atom.to_string(type),
      "content" => content,
      "confidence" => confidence
    }
  end

  defp serialize_lesson(lesson), do: lesson

  defp serialize_model_states(states) when is_map(states) do
    Map.new(states, fn {model_id, state_entry} ->
      {model_id, serialize_model_state_entry(state_entry)}
    end)
  end

  defp serialize_model_states(_), do: %{}

  defp serialize_model_state_entry(nil), do: nil

  defp serialize_model_state_entry(%{summary: summary, updated_at: updated_at}) do
    %{
      "summary" => summary,
      "updated_at" => DateTime.to_iso8601(updated_at)
    }
  end

  defp serialize_model_state_entry(entry), do: entry

  # Private helpers for deserialization

  defp deserialize_context_lessons(lessons) when is_map(lessons) do
    Map.new(lessons, fn {model_id, lesson_list} ->
      {model_id, deserialize_lesson_list(lesson_list)}
    end)
  end

  defp deserialize_context_lessons(_), do: %{}

  defp deserialize_lesson_list(lessons) when is_list(lessons) do
    Enum.map(lessons, &deserialize_lesson/1)
  end

  defp deserialize_lesson_list(_), do: []

  defp deserialize_lesson(%{"type" => type, "content" => content, "confidence" => confidence}) do
    %{
      type: String.to_atom(type),
      content: content,
      confidence: confidence
    }
  end

  defp deserialize_lesson(lesson), do: lesson

  defp deserialize_model_states(states) when is_map(states) do
    Map.new(states, fn {model_id, state_entry} ->
      {model_id, deserialize_model_state_entry(state_entry)}
    end)
  end

  defp deserialize_model_states(_), do: %{}

  defp deserialize_model_state_entry(nil), do: nil

  defp deserialize_model_state_entry(%{"summary" => summary, "updated_at" => updated_at}) do
    %{
      summary: summary,
      updated_at: parse_datetime(updated_at)
    }
  end

  # Handle missing updated_at (R16: graceful handling of incomplete data)
  defp deserialize_model_state_entry(%{"summary" => summary}) do
    %{
      summary: summary,
      updated_at: nil
    }
  end

  defp deserialize_model_state_entry(entry), do: entry

  defp parse_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_datetime(_), do: DateTime.utc_now()

  # Model histories serialization (v5.0 - fix-history-20251219-033611)

  defp serialize_model_histories(histories) when is_map(histories) do
    Map.new(histories, fn {model_id, history} ->
      {model_id, serialize_history_list(history)}
    end)
  end

  defp serialize_model_histories(_), do: %{}

  defp serialize_history_list(history) when is_list(history) do
    Enum.map(history, &serialize_history_entry/1)
  end

  defp serialize_history_list(_), do: []

  # New format: action_id and result are separate fields, content is pre-wrapped JSON string
  defp serialize_history_entry(
         %{type: :result, action_id: action_id, result: result, content: content} = entry
       )
       when is_binary(content) do
    %{
      "type" => "result",
      "content" => content,
      "action_id" => action_id,
      "result" => serialize_result(result),
      "action_type" => entry[:action_type] && Atom.to_string(entry[:action_type]),
      "timestamp" => serialize_timestamp(entry[:timestamp])
    }
  end

  defp serialize_history_entry(%{type: type, content: content} = entry) when is_atom(type) do
    %{
      "type" => Atom.to_string(type),
      "content" => sanitize_for_json(content),
      "timestamp" => serialize_timestamp(entry[:timestamp])
    }
  end

  defp serialize_history_entry(entry), do: entry

  defp serialize_result({:ok, data}), do: %{"status" => "ok", "data" => sanitize_for_json(data)}
  defp serialize_result({:error, reason}), do: %{"status" => "error", "reason" => reason}
  defp serialize_result(data), do: sanitize_for_json(data)

  # Recursively sanitize data for JSON encoding
  # Handles binary data (like PNG bytes) that isn't valid UTF-8
  defp sanitize_for_json(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      %{"__binary__" => Base.encode64(binary)}
    end
  end

  defp sanitize_for_json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # Handle structs by converting to plain maps first (e.g., Anubis.MCP.Response)
  defp sanitize_for_json(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> sanitize_for_json()
  end

  defp sanitize_for_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {sanitize_key(k), sanitize_for_json(v)} end)
  end

  defp sanitize_for_json(list) when is_list(list) do
    Enum.map(list, &sanitize_for_json/1)
  end

  defp sanitize_for_json(value), do: value

  defp sanitize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp sanitize_key(key), do: key

  defp serialize_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_timestamp(_), do: nil

  defp deserialize_model_histories(histories) when is_map(histories) do
    Map.new(histories, fn {model_id, history} ->
      {model_id, deserialize_history_list(history)}
    end)
  end

  defp deserialize_model_histories(_), do: %{}

  defp deserialize_history_list(history) when is_list(history) do
    Enum.map(history, &deserialize_history_entry/1)
  end

  defp deserialize_history_list(_), do: []

  # New format: action_id and result are separate fields, content is pre-wrapped JSON string
  defp deserialize_history_entry(
         %{
           "type" => "result",
           "content" => content,
           "action_id" => action_id,
           "result" => result
         } = entry
       )
       when is_binary(content) do
    base = %{
      type: :result,
      content: content,
      action_id: action_id,
      result: deserialize_result(result),
      timestamp: deserialize_entry_timestamp(entry)
    }

    case entry["action_type"] do
      nil -> base
      action_type -> Map.put(base, :action_type, String.to_atom(action_type))
    end
  end

  defp deserialize_history_entry(%{"type" => type, "content" => content} = entry)
       when is_binary(type) do
    %{
      type: String.to_atom(type),
      content: desanitize_from_json(content),
      timestamp: deserialize_entry_timestamp(entry)
    }
  end

  defp deserialize_history_entry(entry), do: entry

  defp deserialize_result(%{"status" => "ok", "data" => data}),
    do: {:ok, desanitize_from_json(data)}

  defp deserialize_result(%{"status" => "error", "reason" => reason}), do: {:error, reason}
  defp deserialize_result(data), do: desanitize_from_json(data)

  # Recursively restore data from JSON-safe format
  # Inverse of sanitize_for_json/1
  defp desanitize_from_json(%{"__binary__" => encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, binary} -> binary
      :error -> encoded
    end
  end

  defp desanitize_from_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, desanitize_from_json(v)} end)
  end

  defp desanitize_from_json(list) when is_list(list) do
    Enum.map(list, &desanitize_from_json/1)
  end

  defp desanitize_from_json(value), do: value

  defp deserialize_entry_timestamp(%{"timestamp" => ts}) when is_binary(ts),
    do: parse_datetime(ts)

  defp deserialize_entry_timestamp(%{timestamp: ts}), do: ts
  defp deserialize_entry_timestamp(_), do: DateTime.utc_now()
end
