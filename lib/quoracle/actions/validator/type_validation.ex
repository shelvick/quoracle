defmodule Quoracle.Actions.Validator.TypeValidation do
  @moduledoc """
  Type validation for action parameters.
  Extracted from Validator to keep module under 500 lines.

  Handles type coercion, enum validation, nested maps, union types,
  model list validation, and batch action spec validation.
  """

  alias Quoracle.Actions.ValidationHelpers
  alias Quoracle.Actions.Validator.BatchSync, as: BatchSyncValidator

  @valid_models [
    :"amazon-bedrock:anthropic.claude-sonnet-4-5-20250929-v1:0",
    :"azure:o1",
    :"google-vertex:gemini-2.5-pro",
    :"azure:grok-3",
    :"azure:deepseek-r1"
  ]

  @doc """
  Validates all parameter types against their schema-defined types.
  Returns {:ok, validated_params} with coerced types, or {:error, reason}.
  """
  @spec validate_param_types(map(), map()) :: {:ok, map()} | {:error, atom()}
  def validate_param_types(params, param_types) do
    atom_params = ValidationHelpers.string_keys_to_atoms(params)

    Enum.reduce_while(atom_params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Map.get(param_types, key) do
        nil ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        expected_type ->
          result =
            case {key, expected_type} do
              {:url, :string} -> ValidationHelpers.validate_url(value)
              {:check_id, :string} -> ValidationHelpers.validate_uuid(value)
              {:session_id, :string} -> ValidationHelpers.validate_uuid(value)
              {:models, {:list, :atom}} -> validate_models_list(value)
              _ -> validate_type(value, expected_type)
            end

          case result do
            {:ok, typed_value} ->
              {:cont, {:ok, Map.put(acc, key, typed_value)}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
  end

  @doc """
  Validates a single value against an expected type, with LLM-friendly coercion.
  """
  @spec validate_type(term(), atom() | tuple()) :: {:ok, term()} | {:error, atom()}
  def validate_type(value, :string) when is_binary(value), do: {:ok, value}
  def validate_type(value, :integer) when is_integer(value), do: {:ok, value}
  def validate_type(value, :number) when is_number(value), do: {:ok, value}
  def validate_type(value, :boolean) when is_boolean(value), do: {:ok, value}
  # LLM leniency: coerce string "true"/"false" to boolean (common JSON quirk)
  def validate_type("true", :boolean), do: {:ok, true}
  def validate_type("false", :boolean), do: {:ok, false}
  def validate_type(value, :atom) when is_atom(value), do: {:ok, value}

  def validate_type(value, :atom) when is_binary(value) do
    try do
      {:ok, String.to_existing_atom(value)}
    rescue
      ArgumentError -> {:error, :invalid_param_type}
    end
  end

  def validate_type(value, {:map, properties, :all_optional})
      when is_map(value) and is_map(properties) do
    atom_map = ValidationHelpers.string_keys_to_atoms(value)
    validate_nested_map_fields_optional(atom_map, properties)
  end

  def validate_type(value, {:map, properties}) when is_map(value) and is_map(properties) do
    atom_map = ValidationHelpers.string_keys_to_atoms(value)
    validate_nested_map_fields(atom_map, properties)
  end

  def validate_type(value, :map) when is_map(value), do: {:ok, value}

  # LLM leniency: empty map %{} treated as empty list [] when list expected
  def validate_type(value, {:list, _item_type}) when value == %{}, do: {:ok, []}

  def validate_type(value, {:list, item_type}) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case validate_type(item, item_type) do
        {:ok, typed_item} -> {:cont, {:ok, acc ++ [typed_item]}}
        error -> {:halt, error}
      end
    end)
  end

  def validate_type(value, {:enum, allowed_values}) when is_atom(value) do
    if value in allowed_values do
      {:ok, value}
    else
      {:error, :invalid_enum_value}
    end
  end

  def validate_type(value, {:enum, allowed_values}) when is_binary(value) do
    found =
      Enum.find(allowed_values, fn allowed ->
        to_string(allowed) == value
      end)

    case found do
      nil -> {:error, :invalid_enum_value}
      atom -> {:ok, atom}
    end
  end

  def validate_type(_, {:enum, _}), do: {:error, :invalid_enum_value}

  def validate_type(value, :any), do: {:ok, value}

  # Action spec validation for batch actions
  def validate_type(value, :batchable_action_spec) when is_map(value),
    do: validate_type(value, :action_spec)

  def validate_type(value, :async_action_spec) when is_map(value),
    do: validate_type(value, :action_spec)

  def validate_type(value, :action_spec) when is_map(value) do
    action_type = BatchSyncValidator.get_action_type(value)
    action_params = BatchSyncValidator.get_action_params(value)

    if is_nil(action_type) do
      {:error, :invalid_param_type}
    else
      action_atom =
        case action_type do
          a when is_atom(a) -> a
          s when is_binary(s) -> String.to_existing_atom(s)
        end

      case Quoracle.Actions.Validator.validate_params(action_atom, action_params) do
        {:ok, validated_params} ->
          {:ok, %{action: action_atom, params: validated_params}}

        {:error, _} = error ->
          error
      end
    end
  rescue
    ArgumentError -> {:error, :unknown_action}
  end

  def validate_type(value, {:union, types}) do
    result =
      if :atom in types and is_binary(value) do
        case validate_type(value, :atom) do
          {:ok, _} = success -> success
          _ -> nil
        end
      else
        nil
      end

    result ||
      Enum.find_value(types, {:error, :invalid_param_type}, fn type ->
        case validate_type(value, type) do
          {:ok, _} = success -> success
          _ -> nil
        end
      end)
  end

  def validate_type(_, _), do: {:error, :invalid_param_type}

  # Validates nested map fields: checks for missing/extra fields and validates field types
  @spec validate_nested_map_fields(map(), map()) :: {:ok, map()} | {:error, atom()}
  defp validate_nested_map_fields(atom_map, properties) do
    expected_keys = Map.keys(properties)
    actual_keys = Map.keys(atom_map)

    missing = expected_keys -- actual_keys

    if missing != [] do
      {:error, :missing_required_field}
    else
      extra = actual_keys -- expected_keys

      if extra != [] do
        {:error, :unknown_field}
      else
        Enum.reduce_while(properties, {:ok, %{}}, fn {field, field_type}, {:ok, acc} ->
          value_for_field = Map.get(atom_map, field)

          case validate_type(value_for_field, field_type) do
            {:ok, typed_value} ->
              {:cont, {:ok, Map.put(acc, field, typed_value)}}

            {:error, _reason} = error ->
              {:halt, error}
          end
        end)
      end
    end
  end

  # Validates nested map fields when all fields are optional
  @spec validate_nested_map_fields_optional(map(), map()) :: {:ok, map()} | {:error, atom()}
  defp validate_nested_map_fields_optional(atom_map, properties) do
    expected_keys = Map.keys(properties)
    actual_keys = Map.keys(atom_map)

    extra = actual_keys -- expected_keys

    if extra != [] do
      {:error, :unknown_field}
    else
      Enum.reduce_while(actual_keys, {:ok, %{}}, fn field, {:ok, acc} ->
        field_type = Map.get(properties, field)
        value_for_field = Map.get(atom_map, field)

        case validate_type(value_for_field, field_type) do
          {:ok, typed_value} ->
            {:cont, {:ok, Map.put(acc, field, typed_value)}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
    end
  end

  @spec validate_models_list(term()) :: {:ok, [atom()]} | {:error, atom()}
  defp validate_models_list(models) when is_list(models) do
    Enum.reduce_while(models, {:ok, []}, fn model, {:ok, acc} ->
      atom =
        case model do
          atom when is_atom(atom) ->
            if atom in @valid_models, do: atom, else: nil

          string when is_binary(string) ->
            Enum.find(@valid_models, fn valid_model ->
              to_string(valid_model) == string
            end)

          _ ->
            nil
        end

      if atom != nil do
        {:cont, {:ok, acc ++ [atom]}}
      else
        {:halt, {:error, :invalid_enum_value}}
      end
    end)
  end

  defp validate_models_list(_), do: {:error, :invalid_param_type}
end
