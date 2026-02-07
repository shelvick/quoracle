defmodule Quoracle.Actions.Schema.SchemaDefinitions do
  @moduledoc """
  Aggregates schema definitions from specialized schema modules.

  Merges agent-related actions (AgentSchemas) with API/integration actions (ApiSchemas).
  Split into multiple modules to maintain <500 line size requirement.
  """

  alias Quoracle.Actions.Schema.{AgentSchemas, ApiSchemas}

  @doc """
  Returns all action schema definitions by merging from sub-modules.
  """
  @spec schemas() :: map()
  def schemas do
    Map.merge(AgentSchemas.schemas(), ApiSchemas.schemas())
  end
end
