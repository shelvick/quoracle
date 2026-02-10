defmodule Quoracle.Tasks.FieldProcessor do
  @moduledoc """
  Processes and validates form data from the New Task modal.

  Splits task-level fields (global_context, global_constraints) from agent-level
  fields, handling defaults for optional fields.
  """

  alias Quoracle.Fields.Schemas

  @task_fields [:global_context, :global_constraints, :budget_limit, :profile, :skills]
  @agent_fields [
    :task_description,
    :success_criteria,
    :immediate_context,
    :approach_guidance,
    :role,
    :cognitive_style,
    :output_style,
    :delegation_strategy
  ]

  @enum_fields [:cognitive_style, :output_style, :delegation_strategy]

  @type field_result :: %{
          task_fields: map(),
          agent_fields: map()
        }

  @doc """
  Processes and validates form parameters from the New Task modal.

  Takes raw form params (string keys) and returns a map with `task_fields` and
  `agent_fields` separated, normalized, and validated.

  ## Parameters
    - `params` - Map with string keys from form submission

  ## Returns
    - `{:ok, %{task_fields: map(), agent_fields: map()}}` on success
    - `{:error, {:missing_required, [:task_description]}}` if required field missing
    - `{:error, {:invalid_enum, field, value, allowed}}` if enum validation fails

  ## Examples

      iex> process_form_params(%{"task_description" => "Build app"})
      {:ok, %{task_fields: %{}, agent_fields: %{task_description: "Build app"}}}

      iex> process_form_params(%{})
      {:error, {:missing_required, [:task_description]}}
  """
  @spec process_form_params(map()) :: {:ok, field_result()} | {:error, term()}
  def process_form_params(params) when is_map(params) do
    with {:ok, validated_params} <- validate_required(params),
         normalized_params <- normalize_params(validated_params),
         {:ok, validated_enums} <- validate_enums(normalized_params) do
      split_fields(validated_enums)
    end
  end

  # Validates that task_description and profile are present and non-empty
  defp validate_required(params) do
    task_description =
      params
      |> Map.get("task_description")
      |> normalize_string()

    profile =
      params
      |> Map.get("profile")
      |> normalize_string()

    cond do
      is_nil(task_description) or task_description == "" ->
        {:error, {:missing_required, [:task_description]}}

      is_nil(profile) or profile == "" ->
        {:error, {:missing_required, [:profile]}}

      true ->
        {:ok, params}
    end
  end

  # Normalizes all params: trim whitespace, convert empty to nil
  defp normalize_params(params) do
    params
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      # Safe atom conversion - only for known fields
      case safe_to_atom(key) do
        {:ok, field_key} when field_key in @task_fields or field_key in @agent_fields ->
          normalized_value = normalize_field_value(field_key, value)

          if normalized_value do
            Map.put(acc, field_key, normalized_value)
          else
            acc
          end

        _ ->
          # Ignore unexpected fields
          acc
      end
    end)
  end

  # Safely converts string to existing atom, returns :error if atom doesn't exist
  defp safe_to_atom(string) when is_binary(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end

  # Normalizes a single field value based on its type
  defp normalize_field_value(:budget_limit, value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      case Decimal.parse(trimmed) do
        {decimal, ""} -> decimal
        _ -> {:invalid, trimmed}
      end
    end
  end

  defp normalize_field_value(:budget_limit, nil), do: nil

  defp normalize_field_value(:global_constraints, value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end
  end

  defp normalize_field_value(:global_constraints, value) when is_list(value) do
    case value do
      [] -> nil
      list -> list
    end
  end

  defp normalize_field_value(:global_constraints, nil), do: nil

  # Skills parsing - same pattern as global_constraints (comma-separated list)
  defp normalize_field_value(:skills, value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end
  end

  defp normalize_field_value(:skills, value) when is_list(value) do
    case value do
      [] -> nil
      list -> list
    end
  end

  defp normalize_field_value(:skills, nil), do: nil

  defp normalize_field_value(field, value) when field in @enum_fields do
    normalize_string(value)
  end

  defp normalize_field_value(_field, value) when is_binary(value) do
    normalize_string(value)
  end

  defp normalize_field_value(_field, nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(nil), do: nil

  # Validates enum fields against Schema definitions
  defp validate_enums(params) do
    Enum.reduce_while(@enum_fields, {:ok, params}, fn field, {:ok, acc} ->
      case Map.get(acc, field) do
        nil ->
          {:cont, {:ok, acc}}

        value when is_binary(value) ->
          case validate_and_convert_enum(field, value) do
            {:ok, atom_value} ->
              {:cont, {:ok, Map.put(acc, field, atom_value)}}

            {:error, allowed} ->
              {:halt, {:error, {:invalid_enum, field, value, allowed}}}
          end

        _other ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  # Validates a single enum value and converts to atom
  defp validate_and_convert_enum(field, value) when is_binary(value) do
    case Schemas.get_schema(field) do
      {:ok, %{type: {:enum, allowed_values}}} ->
        # Try to convert string to existing atom
        try do
          atom_value = String.to_existing_atom(value)

          if atom_value in allowed_values do
            {:ok, atom_value}
          else
            {:error, Enum.map(allowed_values, &Atom.to_string/1)}
          end
        rescue
          ArgumentError ->
            # String doesn't correspond to existing atom
            {:error, Enum.map(allowed_values, &Atom.to_string/1)}
        end

      _other ->
        {:error, []}
    end
  end

  # Splits normalized params into task_fields and agent_fields
  defp split_fields(params) do
    # Check for invalid budget_limit
    case Map.get(params, :budget_limit) do
      {:invalid, _value} ->
        {:error, :invalid_budget_format}

      _ ->
        task_fields =
          params
          |> Map.take(@task_fields)
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        agent_fields =
          params
          |> Map.take(@agent_fields)
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        {:ok, %{task_fields: task_fields, agent_fields: agent_fields}}
    end
  end
end
