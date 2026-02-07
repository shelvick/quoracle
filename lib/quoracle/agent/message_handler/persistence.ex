defmodule Quoracle.Agent.MessageHandler.Persistence do
  @moduledoc """
  Database persistence functions for MessageHandler.
  Extracted to keep MessageHandler under 500 lines while maintaining all functionality.
  """

  require Logger

  alias Quoracle.Costs.Accumulator
  alias Quoracle.Models.ModelQuery.UsageHelper

  @doc """
  Flush accumulated costs to the database.

  Called at the end of consensus cycle to batch-insert accumulated
  embedding costs. Skips flush when:
  - accumulator is nil (no costs accumulated)
  - accumulator is empty (no entries)
  - pubsub is not present in state (test isolation)

  ## Returns
  - `:ok` always (flush is best-effort)
  """
  @spec flush_costs(Accumulator.t() | nil, map()) :: :ok
  def flush_costs(nil, _state), do: :ok

  def flush_costs(%Accumulator{} = accumulator, state) do
    pubsub = Map.get(state, :pubsub)

    cond do
      is_nil(pubsub) ->
        # Skip flush when no pubsub (test isolation)
        :ok

      Accumulator.empty?(accumulator) ->
        # Skip flush when accumulator empty
        :ok

      true ->
        # Flush accumulated costs
        UsageHelper.flush_accumulated_costs(accumulator, pubsub)
    end
  end

  @doc """
  Persist inter-agent message to database.

  Called when agent receives a message from another agent (parent→child in MVP).
  Extracts from_agent_id from parent_pid using Registry lookup.
  """
  @spec persist_message(map(), String.t()) :: :ok
  def persist_message(state, content) do
    # Skip if task_id missing
    # Use Map.get for optional fields (works with both structs and maps)
    task_id = Map.get(state, :task_id)

    if task_id do
      # Extract from_agent_id from parent_pid using Registry
      from_agent_id = extract_from_agent_id(state)

      # Only persist if we have a from_agent_id (messages without sender are internal)
      if from_agent_id do
        attrs = %{
          task_id: task_id,
          from_agent_id: from_agent_id,
          to_agent_id: state.agent_id,
          content: content
        }

        # Defensive - log error but don't crash agent if persistence fails
        # try/catch handles test cleanup race where sandbox dies mid-operation
        try do
          case Quoracle.Tasks.TaskManager.save_message(attrs) do
            {:ok, _message} ->
              :ok

            {:error, reason} ->
              Logger.error("Failed to persist message: #{inspect(reason)}")
              :ok
          end
        catch
          :exit, _ -> :ok
        end
      else
        # No from_agent_id - skip persistence (internal message or root agent)
        :ok
      end
    else
      # No task_id - skip persistence
      :ok
    end
  end

  # Extract from_agent_id from parent_pid using Registry
  @spec extract_from_agent_id(map()) :: String.t() | nil
  defp extract_from_agent_id(state) do
    # Use Map.get for optional fields (works with both structs and maps)
    parent_pid = Map.get(state, :parent_pid)

    if parent_pid do
      registry = Map.fetch!(state, :registry)
      Quoracle.Agent.RegistryQueries.get_agent_id_from_pid(parent_pid, registry)
    else
      nil
    end
  end
end
