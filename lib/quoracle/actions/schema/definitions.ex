defmodule Quoracle.Actions.Schema.Definitions do
  @moduledoc """
  Contains action schema definitions (parameters, types, descriptions, consensus rules).
  Separated from Schema module to improve maintainability.
  """

  alias Quoracle.Actions.Schema.{ActionList, Metadata, SchemaDefinitions}

  @typedoc """
  A TODO item with content and state.

  Used by the :todo action to represent individual tasks in the agent's task list.
  The nested map structure enforces exact field names to prevent LLM field name invention.
  """
  @type todo_item :: %{
          content: String.t(),
          state: :todo | :pending | :done
        }

  @doc """
  Returns all action names.
  """
  @spec actions() :: [atom()]
  defdelegate actions(), to: ActionList

  @doc """
  Returns all schema definitions.
  """
  @spec schemas() :: map()
  defdelegate schemas(), to: SchemaDefinitions

  @doc """
  Returns all action descriptions.
  """
  @spec action_descriptions() :: map()
  defdelegate action_descriptions(), to: Metadata

  @doc """
  Returns all action priorities.
  """
  @spec action_priorities() :: map()
  defdelegate action_priorities(), to: Metadata

  @doc """
  Returns global parameter descriptions that apply across multiple actions.
  Currently empty - wait and auto_complete_todo are injected at schema formatter level.
  """
  @spec param_descriptions() :: map()
  def param_descriptions do
    %{}
  end
end
