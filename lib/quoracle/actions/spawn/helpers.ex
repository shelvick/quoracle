defmodule Quoracle.Actions.Spawn.Helpers do
  @moduledoc """
  Helper functions for Spawn action.
  Extracted to keep Spawn under 500 lines.
  """

  # Compile-time map: atoms created at compile time, safe for lookup
  @string_to_atom_map %{
    "task_description" => :task_description,
    "success_criteria" => :success_criteria,
    "immediate_context" => :immediate_context,
    "approach_guidance" => :approach_guidance,
    "role" => :role,
    "cognitive_style" => :cognitive_style,
    "output_style" => :output_style,
    "delegation_strategy" => :delegation_strategy,
    "sibling_context" => :sibling_context,
    "accumulated_narrative" => :accumulated_narrative,
    "constraints" => :constraints,
    "downstream_constraints" => :downstream_constraints
  }

  @doc """
  Normalizes string keys to atoms for known field names.
  Public for ConfigBuilder access.
  """
  @spec normalize_field_keys(map()) :: map()
  def normalize_field_keys(params) do
    Enum.reduce(params, %{}, fn {key, value}, acc ->
      atom_key =
        cond do
          is_atom(key) -> key
          is_binary(key) -> Map.get(@string_to_atom_map, key, key)
          true -> key
        end

      # Special handling for sibling_context - normalize nested maps
      normalized_value =
        if atom_key == :sibling_context and is_list(value) do
          Enum.map(value, fn sibling ->
            if is_map(sibling) do
              %{
                agent_id: Map.get(sibling, "agent_id") || Map.get(sibling, :agent_id),
                task: Map.get(sibling, "task") || Map.get(sibling, :task)
              }
            else
              sibling
            end
          end)
        else
          value
        end

      Map.put(acc, atom_key, normalized_value)
    end)
  end

  @doc """
  Generates a UUID-format child agent ID.
  """
  @spec generate_child_id() :: String.t()
  def generate_child_id do
    <<a1::48, _::4, a2::12, _::2, a3::62>> = :crypto.strong_rand_bytes(16)
    hex = <<a1::48, 4::4, a2::12, 2::2, a3::62>> |> Base.encode16(case: :lower)

    "agent-#{String.slice(hex, 0, 8)}-#{String.slice(hex, 8, 4)}-#{String.slice(hex, 12, 4)}-#{String.slice(hex, 16, 4)}-#{String.slice(hex, 20, 12)}"
  end
end
