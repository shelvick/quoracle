defmodule Quoracle.Actions.Schema do
  @moduledoc """
  Defines schemas for all 11 core agent actions.
  Each action has required/optional parameters, types, and consensus rules.
  Includes action priorities for deterministic tiebreaking in consensus.
  """

  alias Quoracle.Actions.Schema.Definitions

  # Ensure send_message target atoms exist for String.to_existing_atom/1 in validator
  # Must be defined here (not in SendMessage.ex) because Validator loads Schema before SendMessage
  # Using module attribute ensures atoms are created at compile time
  @send_message_targets [:parent, :children, :announcement]

  @spec __send_message_targets__ :: [atom()]
  def __send_message_targets__, do: @send_message_targets

  @typedoc """
  A TODO item with content and state.

  Used by the :todo action to represent individual tasks in the agent's task list.
  The nested map structure enforces exact field names to prevent LLM field name invention.
  """
  @type todo_item :: Definitions.todo_item()

  @doc """
  Returns the schema for a given action type.
  """
  @spec get_schema(atom()) :: {:ok, map()} | {:error, :unknown_action}
  def get_schema(action) when is_atom(action) do
    case Map.get(Definitions.schemas(), action) do
      nil -> {:error, :unknown_action}
      schema -> {:ok, schema}
    end
  end

  def get_schema(_), do: {:error, :unknown_action}

  @doc """
  Returns a list of all available action types.
  """
  @spec list_actions() :: [atom()]
  def list_actions do
    Definitions.actions()
  end

  @doc """
  Validates if an action type is valid.
  """
  @spec validate_action_type(atom()) :: {:ok, atom()} | {:error, :unknown_action}
  def validate_action_type(action) when is_atom(action) do
    if action in Definitions.actions() do
      {:ok, action}
    else
      {:error, :unknown_action}
    end
  end

  def validate_action_type(_), do: {:error, :unknown_action}

  @doc """
  Returns the description for a given action with WHEN and HOW guidance.
  Used in LLM prompts to clarify action purpose and usage.
  """
  @spec get_action_description(atom()) :: String.t()
  def get_action_description(action) when is_atom(action) do
    Map.get(Definitions.action_descriptions(), action, "No description available")
  end

  def get_action_description(_), do: "No description available"

  @doc """
  Returns the priority for a given action.
  Lower numbers are more conservative, higher numbers are more consequential.
  """
  @spec get_action_priority(atom()) :: integer() | {:error, :unknown_action}
  def get_action_priority(action) when is_atom(action) do
    case Map.get(Definitions.action_priorities(), action) do
      nil -> {:error, :unknown_action}
      priority -> priority
    end
  end

  def get_action_priority(_), do: {:error, :unknown_action}

  @doc """
  Returns the complete map of action priorities.
  """
  @spec get_priorities() :: map()
  def get_priorities do
    Definitions.action_priorities()
  end

  @doc """
  Returns whether the wait parameter is required for this action.
  Only the :wait action itself doesn't require a wait parameter.

  Raises FunctionClauseError for unknown actions.
  """
  @spec wait_required?(atom()) :: boolean()
  def wait_required?(:wait), do: false
  def wait_required?(action) when action in unquote(Definitions.actions()), do: true

  @doc """
  Returns whether the auto_complete_todo parameter is available for this action.
  All actions except :todo support auto_complete_todo.

  Returns false for unknown actions.
  """
  @spec auto_complete_todo_available?(atom()) :: boolean()
  def auto_complete_todo_available?(action) when is_atom(action) do
    action != :todo and action in Definitions.actions()
  end

  @doc """
  Returns the map of parameter descriptions for LLM prompts.
  """
  @spec param_descriptions() :: map()
  def param_descriptions do
    Definitions.param_descriptions()
  end
end
