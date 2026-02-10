defmodule Quoracle.Fields.Schemas do
  @moduledoc """
  Field schema definitions for hierarchical prompt management.

  Defines all field types, validation rules, and propagation semantics.
  """

  @field_schemas %{
    # Injected fields (system-managed)
    global_context: %{
      type: :string,
      required: false,
      category: :injected
    },
    # Provided fields (parent-generated)
    task_description: %{
      type: :string,
      required: true,
      category: :provided
    },
    success_criteria: %{
      type: :string,
      required: true,
      category: :provided
    },
    immediate_context: %{
      type: :string,
      required: true,
      category: :provided
    },
    approach_guidance: %{
      type: :string,
      required: true,
      category: :provided
    },
    role: %{
      type: :string,
      required: false,
      category: :provided
    },
    delegation_strategy: %{
      type: {:enum, [:sequential, :parallel, :none]},
      required: false,
      category: :provided
    },
    sibling_context: %{
      type: {:list, :map},
      required: false,
      category: :provided
    },
    output_style: %{
      type: {:enum, [:detailed, :concise, :technical, :narrative]},
      required: false,
      category: :provided
    },
    cognitive_style: %{
      type: {:enum, [:efficient, :exploratory, :problem_solving, :creative, :systematic]},
      required: false,
      category: :provided
    },
    # Provided fields for spawning (parent can specify)
    downstream_constraints: %{
      type: :string,
      required: false,
      category: :provided
    },
    # Transformed fields (modified during propagation)
    accumulated_narrative: %{
      type: :string,
      required: false,
      category: :transformed
    },
    constraints: %{
      type: {:list, :string},
      required: false,
      category: :transformed
    }
  }

  @spec get_schema(atom()) :: {:ok, map()} | {:error, :unknown_field}
  def get_schema(field) when is_atom(field) do
    case Map.fetch(@field_schemas, field) do
      {:ok, schema} -> {:ok, schema}
      :error -> {:error, :unknown_field}
    end
  end

  def get_schema(_), do: {:error, :unknown_field}

  @spec validate_field(atom(), any()) :: {:ok, any()} | {:error, String.t()}
  def validate_field(field, value) do
    case get_schema(field) do
      {:ok, schema} -> validate_against_schema(value, schema)
      {:error, :unknown_field} -> {:error, "Unknown field: #{inspect(field)}"}
    end
  end

  @spec list_fields() :: [atom()]
  def list_fields do
    Map.keys(@field_schemas)
  end

  @spec get_fields_by_category(atom()) :: [atom()]
  def get_fields_by_category(category) do
    @field_schemas
    |> Enum.filter(fn {_field, schema} -> schema.category == category end)
    |> Enum.map(fn {field, _schema} -> field end)
  end

  @spec required_fields() :: [atom()]
  def required_fields do
    @field_schemas
    |> Enum.filter(fn {_field, schema} -> schema.required == true end)
    |> Enum.map(fn {field, _schema} -> field end)
    |> Enum.sort()
  end

  # Private validation functions

  defp validate_against_schema(value, %{type: :string}) do
    if is_binary(value) do
      {:ok, value}
    else
      {:error, "Expected string, got #{type_name(value)}"}
    end
  end

  defp validate_against_schema(value, %{type: {:enum, allowed_values}}) do
    if value in allowed_values do
      {:ok, value}
    else
      {:error,
       "Invalid enum value: #{inspect(value)}. Allowed values: #{inspect(allowed_values)}"}
    end
  end

  defp validate_against_schema(value, %{type: {:list, :string}}) when is_list(value) do
    case validate_list_elements(value, :string) do
      :ok -> {:ok, value}
      {:error, index} -> {:error, "List element at index #{index} is not a string"}
    end
  end

  defp validate_against_schema(value, %{type: {:list, :string}}) do
    {:error, "Expected list of strings, got #{type_name(value)}"}
  end

  defp validate_against_schema(value, %{type: {:list, :map}}) when is_list(value) do
    case validate_list_elements(value, :map) do
      :ok -> {:ok, value}
      {:error, index} -> {:error, "List element at index #{index} is not a map"}
    end
  end

  defp validate_against_schema(value, %{type: {:list, :map}}) do
    {:error, "Expected list of maps, got #{type_name(value)}"}
  end

  defp validate_list_elements(list, :string) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {element, index}, :ok ->
      if is_binary(element) do
        {:cont, :ok}
      else
        {:halt, {:error, index}}
      end
    end)
  end

  defp validate_list_elements(list, :map) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {element, index}, :ok ->
      if is_map(element) do
        {:cont, :ok}
      else
        {:halt, {:error, index}}
      end
    end)
  end

  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "float"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(value) when is_map(value), do: "map"
  defp type_name(value) when is_atom(value), do: "atom"
  defp type_name(_), do: "unknown type"
end
