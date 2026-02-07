defmodule Quoracle.Fields.FieldValidator do
  @moduledoc """
  Validates prompt fields against defined schemas.

  Provides enhanced validation with field-aware error messages
  and special handling for nested structures.
  """

  alias Quoracle.Fields.Schemas

  @doc """
  Validates a complete field map.

  Checks that all required fields are present and all field values
  pass their individual validations.

  ## Examples

      iex> validate_fields(%{task_description: "Task", success_criteria: "Success", immediate_context: "Context", approach_guidance: "Approach"})
      {:ok, %{task_description: "Task", ...}}

      iex> validate_fields(%{task_description: "Task"})
      {:error, {:missing_required_fields, [:success_criteria, :immediate_context, :approach_guidance]}}
  """
  @spec validate_fields(map()) ::
          {:ok, map()} | {:error, {:missing_required_fields, [atom()]}}
  def validate_fields(fields) when is_map(fields) do
    required = Schemas.required_fields()
    missing = Enum.filter(required, fn field -> not Map.has_key?(fields, field) end)

    if missing == [] do
      # Validate all provided fields
      fields
      |> Enum.reduce_while({:ok, %{}}, fn {field, value}, {:ok, acc} ->
        case validate_field(field, value) do
          {:ok, validated_value} ->
            {:cont, {:ok, Map.put(acc, field, validated_value)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    else
      {:error, {:missing_required_fields, missing}}
    end
  end

  @doc """
  Validates a single field against its schema.

  Performs type checking, length validation, enum validation,
  and nested structure validation with enhanced error messages.

  ## Examples

      iex> validate_field(:task_description, "Valid task")
      {:ok, "Valid task"}

      iex> validate_field(:task_description, 123)
      {:error, "task_description must be a string"}

      iex> validate_field(:unknown_field, "value")
      {:error, "Unknown field: unknown_field"}
  """
  @spec validate_field(atom(), any()) :: {:ok, any()} | {:error, String.t()}
  def validate_field(field, value) when is_atom(field) do
    case Schemas.get_schema(field) do
      {:ok, schema} ->
        validate_with_schema(field, value, schema)

      {:error, :unknown_field} ->
        {:error, "Unknown field: #{field}"}
    end
  end

  # Private validation functions

  defp validate_with_schema(field, value, %{type: :string}) do
    cond do
      not is_binary(value) ->
        {:error, "#{field} must be a string"}

      String.trim(value) == "" ->
        {:error, "#{field} cannot be empty"}

      true ->
        {:ok, value}
    end
  end

  defp validate_with_schema(field, value, %{type: {:enum, allowed_values}}) do
    # Convert string values to atoms for comparison (allowed_values are atoms in schema)
    atom_value =
      cond do
        is_atom(value) -> value
        is_binary(value) -> String.to_existing_atom(value)
        true -> nil
      end

    if atom_value in allowed_values do
      {:ok, value}
    else
      allowed_str = Enum.map_join(allowed_values, ", ", &to_string/1)
      {:error, "#{field} must be one of: #{allowed_str}"}
    end
  rescue
    ArgumentError ->
      # String.to_existing_atom raised error - value is not a valid atom
      allowed_str = Enum.map_join(allowed_values, ", ", &to_string/1)
      {:error, "#{field} must be one of: #{allowed_str}"}
  end

  defp validate_with_schema(field, value, %{type: {:list, :string}}) do
    cond do
      not is_list(value) ->
        {:error, "#{field} must be a list"}

      not all_strings?(value) ->
        {:error, "#{field} elements must be strings"}

      true ->
        {:ok, value}
    end
  end

  defp validate_with_schema(field, value, %{type: {:list, :map}}) do
    cond do
      not is_list(value) ->
        {:error, "#{field} must be a list"}

      field == :sibling_context ->
        validate_sibling_context(value)

      not all_maps?(value) ->
        {:error, "#{field} elements must be maps"}

      true ->
        {:ok, value}
    end
  end

  # Special validation for sibling_context structure
  defp validate_sibling_context([]), do: {:ok, []}

  defp validate_sibling_context(siblings) when is_list(siblings) do
    case Enum.find_index(siblings, &(not valid_sibling?(&1))) do
      nil ->
        {:ok, siblings}

      index ->
        sibling = Enum.at(siblings, index)

        cond do
          not is_map(sibling) ->
            {:error, "sibling_context elements must be maps"}

          not (Map.has_key?(sibling, :agent_id) and Map.has_key?(sibling, :task)) ->
            {:error, "sibling_context elements must have agent_id and task"}

          not (is_binary(Map.get(sibling, :agent_id)) and is_binary(Map.get(sibling, :task))) ->
            {:error, "sibling_context agent_id and task must be strings"}

          true ->
            {:error, "sibling_context elements must have agent_id and task"}
        end
    end
  end

  defp valid_sibling?(sibling) when is_map(sibling) do
    Map.has_key?(sibling, :agent_id) and Map.has_key?(sibling, :task) and
      is_binary(Map.get(sibling, :agent_id)) and is_binary(Map.get(sibling, :task))
  end

  defp valid_sibling?(_), do: false

  defp all_strings?([]), do: true
  defp all_strings?([h | t]) when is_binary(h), do: all_strings?(t)
  defp all_strings?(_), do: false

  defp all_maps?([]), do: true
  defp all_maps?([h | t]) when is_map(h), do: all_maps?(t)
  defp all_maps?(_), do: false
end
