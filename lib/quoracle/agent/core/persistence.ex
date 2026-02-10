defmodule Quoracle.Agent.Core.Persistence do
  @moduledoc """
  Database persistence functions for Agent.Core.
  Extracted to keep Core under 500 lines while maintaining all functionality.
  """

  require Logger
  alias Quoracle.Agent.RegistryQueries

  # Ensure history entry type atoms exist for String.to_existing_atom/1
  # during agent restoration from database (prevents ArgumentError after server restart)
  @history_entry_types [:decision, :event, :result, :user, :agent, :system, :image]

  @doc """
  Returns the list of valid history entry types.
  This ensures atoms exist at compile time for String.to_existing_atom/1.
  """
  @spec history_entry_types() :: [atom()]
  def history_entry_types, do: @history_entry_types

  @doc """
  Persist agent to database during initialization.

  Called by handle_continue(:load_context_limit) after agent setup completes.
  Skips persistence if restoration_mode flag is set.
  """
  @spec persist_agent(map()) :: :ok
  def persist_agent(state) do
    # Skip persistence if in restoration mode
    # Use Map.get for optional fields (works with both structs and maps)
    if Map.get(state, :restoration_mode, false) do
      :ok
    else
      # Extract parent agent_id from parent_pid using Registry
      parent_id = extract_parent_agent_id(state.parent_pid, state)

      attrs = %{
        agent_id: state.agent_id,
        task_id: state.task_id,
        parent_id: parent_id,
        status: "running",
        profile_name: state.profile_name,
        config:
          Map.take(state, [
            :test_mode,
            :initial_prompt,
            :model_pool,
            :profile_description
          ]),
        prompt_fields: state.prompt_fields || %{}
      }

      # Defensive - log error but don't crash agent if persistence fails
      try do
        case Quoracle.Tasks.TaskManager.save_agent(attrs) do
          {:ok, _agent} ->
            :ok

          {:error, %Ecto.Changeset{errors: errors} = reason} ->
            # Use debug level for missing task_id (expected for test agents)
            if Keyword.has_key?(errors, :task_id) do
              Logger.debug("Skipping agent persistence for #{state.agent_id}: no task_id")
            else
              Logger.error("Failed to persist agent #{state.agent_id}: #{inspect(reason)}")
            end

            :ok

          {:error, reason} ->
            Logger.error("Failed to persist agent #{state.agent_id}: #{inspect(reason)}")
            :ok
        end
      rescue
        e in Ecto.ChangeError ->
          # Type mismatch errors (e.g., string task_id instead of UUID) - expected in tests
          Logger.debug(
            "Skipping agent persistence for #{state.agent_id}: #{Exception.message(e)}"
          )

          :ok

        e in DBConnection.OwnershipError ->
          Logger.warning(
            "Skipping agent persistence due to DB ownership error (test mode without sandbox_owner?): #{Exception.message(e)}"
          )

          :ok

        e ->
          Logger.error("Failed to persist agent #{state.agent_id}: #{inspect(e)}")
          :ok
      end
    end
  end

  @doc """
  Update agent model histories in database.

  Called after consensus decisions to keep DB in sync with agent state.
  Delegates to persist_ace_state which handles all state persistence
  including model_histories with proper binary data handling.
  """
  @spec persist_conversation(map()) :: :ok
  def persist_conversation(state) do
    # Delegate to ACE state persistence which handles model_histories
    # with proper binary serialization (images, etc.)
    persist_ace_state(state)
  end

  @doc """
  Extract parent agent_id from parent_pid using Registry.

  Returns nil if no parent or parent not found in Registry.
  """
  @spec extract_parent_agent_id(pid() | nil, map()) :: String.t() | nil
  def extract_parent_agent_id(nil, _state), do: nil

  def extract_parent_agent_id(parent_pid, state) do
    registry = state.registry
    RegistryQueries.get_agent_id_from_pid(parent_pid, registry)
  end

  # ========== ACE STATE PERSISTENCE (delegated to ACEState module) ==========

  alias Quoracle.Agent.Core.Persistence.ACEState

  # Delegate ACE state functions to extracted module (for 500-line limit)
  defdelegate lesson_types(), to: ACEState
  defdelegate serialize_ace_state(state), to: ACEState, as: :serialize
  defdelegate deserialize_ace_state(stored_data), to: ACEState, as: :deserialize
  defdelegate persist_ace_state(state), to: ACEState, as: :persist
  defdelegate restore_ace_state(db_agent), to: ACEState, as: :restore
end
