defmodule Quoracle.Fields.ConstraintAccumulator do
  @moduledoc """
  Accumulates and merges constraints through agent hierarchy.
  """

  @doc """
  Accumulates constraints from parent and new fields.

  downstream_constraints (string) gets converted to single-item list and merged.

  ## Examples

      iex> accumulate(%{transformed: %{constraints: ["A"]}}, %{downstream_constraints: "B"})
      ["A", "B"]

      iex> accumulate(%{transformed: %{constraints: ["A"]}}, %{})
      ["A"]
  """
  @spec accumulate(map(), map()) :: list(String.t())
  def accumulate(parent_fields, provided_fields) do
    parent_constraints = get_in(parent_fields, [:transformed, :constraints]) || []

    # Convert downstream_constraints string to single-item list if present
    new_constraints =
      case Map.get(provided_fields, :downstream_constraints) do
        nil -> []
        "" -> []
        string when is_binary(string) -> [string]
        _ -> []
      end

    merge_constraints(parent_constraints, new_constraints)
  end

  defp merge_constraints(existing, new) do
    (existing ++ new)
    |> Enum.uniq()
    |> validate_constraints()
  end

  defp validate_constraints(constraints) do
    constraints
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
  end
end
