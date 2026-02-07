defmodule Quoracle.Actions.Validator do
  @moduledoc """
  Validates action JSON against schemas and enforces parameter constraints.
  Ensures type safety and XOR parameter requirements.
  """

  alias Quoracle.Actions.Schema
  alias Quoracle.Actions.ValidationHelpers
  alias Quoracle.Actions.Validator.BatchAsync, as: BatchAsyncValidator
  alias Quoracle.Actions.Validator.BatchSync, as: BatchSyncValidator

  @valid_models [
    :"amazon-bedrock:anthropic.claude-sonnet-4-5-20250929-v1:0",
    :"azure:o1",
    :"google-vertex:gemini-2.5-pro",
    :"azure:grok-3",
    :"azure:deepseek-r1"
  ]

  @doc """
  Validates an action JSON map against its schema.
  Returns {:ok, validated_action} or {:error, reason}.
  """
  @spec validate_action(map()) :: {:ok, map()} | {:error, atom()}
  def validate_action(%{"action" => action_str, "params" => params} = action_json) do
    with {:ok, action_atom} <- validate_action_name(action_str),
         {:ok, schema} <- Schema.get_schema(action_atom),
         {:ok, validated_params} <- validate_params_with_schema(action_atom, params, schema) do
      result = %{
        action: action_atom,
        params: validated_params
      }

      # Add optional reasoning field if present
      result =
        case Map.get(action_json, "reasoning") do
          nil -> result
          reasoning -> Map.put(result, :reasoning, reasoning)
        end

      {:ok, result}
    end
  end

  def validate_action(%{"action" => _}), do: {:error, :missing_params_field}
  def validate_action(%{"params" => _}), do: {:error, :missing_action_field}
  def validate_action(_), do: {:error, :missing_action_field}

  @doc """
  Validates parameters directly for a given action type.
  """
  @spec validate_params(atom(), map()) :: {:ok, map()} | {:error, atom()}
  def validate_params(action, params) do
    with {:ok, schema} <- Schema.get_schema(action) do
      validate_params_with_schema(action, params, schema)
    end
  end

  # Private functions

  defp validate_action_name(action_str) when is_binary(action_str) do
    try do
      action_atom = String.to_existing_atom(action_str)
      Schema.validate_action_type(action_atom)
    rescue
      ArgumentError -> {:error, :unknown_action}
    end
  end

  defp validate_params_with_schema(action, params, schema) do
    # Special handling for spawn_child required params and call_api protocol-specific validation
    result =
      case action do
        :spawn_child ->
          check_spawn_child_required_params(params, schema)

        :call_api ->
          check_call_api_required_params(params, schema)

        :batch_sync ->
          BatchSyncValidator.validate(params)

        :batch_async ->
          BatchAsyncValidator.validate(params)

        _ ->
          check_required_params(params, schema.required_params)
      end

    with :ok <- result,
         :ok <- check_unknown_params(params, schema),
         :ok <- check_xor_params(params, Map.get(schema, :xor_params, [])),
         {:ok, validated_params} <- validate_param_types(params, schema.param_types) do
      # Normalize HTTP method for call_api
      case action do
        :call_api -> normalize_call_api_method(validated_params)
        _ -> {:ok, validated_params}
      end
    end
  end

  defp normalize_call_api_method(params) do
    case Map.get(params, :method) do
      method when is_binary(method) ->
        {:ok, Map.put(params, :method, String.upcase(method))}

      _ ->
        {:ok, params}
    end
  end

  defp check_required_params(params, required_params) do
    missing = required_params -- Map.keys(string_keys_to_atoms(params))

    case missing do
      [] -> :ok
      _ -> {:error, :missing_required_param}
    end
  end

  defp check_spawn_child_required_params(params, _schema) do
    # All 4 fields + profile required for spawn_child
    check_required_params(params, [
      :task_description,
      :success_criteria,
      :immediate_context,
      :approach_guidance,
      :profile
    ])
  end

  defp check_call_api_required_params(params, schema) do
    atom_params = string_keys_to_atoms(params)

    # Check base required params (api_type, url)
    with :ok <- check_required_params(params, schema.required_params),
         :ok <- validate_call_api_url(atom_params[:url]),
         :ok <- validate_protocol_specific_params(atom_params) do
      validate_call_api_http_method(atom_params)
    end
  end

  defp validate_call_api_http_method(%{method: method}) when is_binary(method) do
    uppercase_method = String.upcase(method)
    valid_methods = ["GET", "POST", "PUT", "DELETE", "PATCH"]

    if uppercase_method in valid_methods do
      :ok
    else
      {:error, :invalid_http_method}
    end
  end

  defp validate_call_api_http_method(_), do: :ok

  defp validate_call_api_url(nil), do: {:error, :missing_required_param}

  defp validate_call_api_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] do
      :ok
    else
      {:error, :invalid_url_scheme}
    end
  end

  defp validate_call_api_url(_), do: {:error, :invalid_url_scheme}

  defp validate_protocol_specific_params(%{api_type: api_type} = params) do
    case api_type do
      "rest" ->
        if Map.has_key?(params, :method), do: :ok, else: {:error, :missing_required_param}

      :rest ->
        if Map.has_key?(params, :method), do: :ok, else: {:error, :missing_required_param}

      "graphql" ->
        if Map.has_key?(params, :query), do: :ok, else: {:error, :missing_required_param}

      :graphql ->
        if Map.has_key?(params, :query), do: :ok, else: {:error, :missing_required_param}

      "jsonrpc" ->
        if Map.has_key?(params, :rpc_method), do: :ok, else: {:error, :missing_required_param}

      :jsonrpc ->
        if Map.has_key?(params, :rpc_method), do: :ok, else: {:error, :missing_required_param}

      _ ->
        :ok
    end
  end

  defp validate_protocol_specific_params(_), do: :ok

  defp check_unknown_params(params, schema) do
    allowed = schema.required_params ++ schema.optional_params
    provided = params |> string_keys_to_atoms() |> Map.keys()
    unknown = provided -- allowed

    case unknown do
      [] -> :ok
      _ -> {:error, :unknown_parameter}
    end
  end

  defp check_xor_params(_params, []), do: :ok

  defp check_xor_params(params, xor_groups) do
    atom_params = string_keys_to_atoms(params)

    # For XOR groups like [[:command], [:check_id]], we need to check if
    # more than one of the groups has params present
    groups_with_params =
      Enum.filter(xor_groups, fn group ->
        Enum.any?(group, &Map.has_key?(atom_params, &1))
      end)

    case length(groups_with_params) do
      # None present - require at least one group
      0 -> {:error, :xor_params_required}
      # Exactly one group has params - good
      1 -> :ok
      # Multiple groups have params - conflict
      _ -> {:error, :xor_params_conflict}
    end
  end

  defp validate_param_types(params, param_types) do
    atom_params = string_keys_to_atoms(params)

    Enum.reduce_while(atom_params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Map.get(param_types, key) do
        nil ->
          # No type specified, pass through
          {:cont, {:ok, Map.put(acc, key, value)}}

        expected_type ->
          # Special validation for certain param names
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

  defp validate_type(value, :string) when is_binary(value), do: {:ok, value}
  defp validate_type(value, :integer) when is_integer(value), do: {:ok, value}
  defp validate_type(value, :number) when is_number(value), do: {:ok, value}
  defp validate_type(value, :boolean) when is_boolean(value), do: {:ok, value}
  # LLM leniency: coerce string "true"/"false" to boolean (common JSON quirk)
  defp validate_type("true", :boolean), do: {:ok, true}
  defp validate_type("false", :boolean), do: {:ok, false}
  defp validate_type(value, :atom) when is_atom(value), do: {:ok, value}

  defp validate_type(value, :atom) when is_binary(value) do
    try do
      {:ok, String.to_existing_atom(value)}
    rescue
      ArgumentError -> {:error, :invalid_param_type}
    end
  end

  defp validate_type(value, {:map, properties, :all_optional})
       when is_map(value) and is_map(properties) do
    # Convert string keys to atoms for validation
    atom_map = string_keys_to_atoms(value)

    # Validate nested map structure with optional fields (all fields can be omitted)
    validate_nested_map_fields_optional(atom_map, properties)
  end

  defp validate_type(value, {:map, properties}) when is_map(value) and is_map(properties) do
    # Convert string keys to atoms for validation
    atom_map = string_keys_to_atoms(value)

    # Validate nested map structure with explicit field checking
    validate_nested_map_fields(atom_map, properties)
  end

  defp validate_type(value, :map) when is_map(value), do: {:ok, value}

  # LLM leniency: empty map %{} treated as empty list [] when list expected
  # Common LLM quirk: JSON {} vs [] confusion
  defp validate_type(value, {:list, _item_type}) when value == %{}, do: {:ok, []}

  defp validate_type(value, {:list, item_type}) when is_list(value) do
    result =
      Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
        case validate_type(item, item_type) do
          {:ok, typed_item} -> {:cont, {:ok, acc ++ [typed_item]}}
          error -> {:halt, error}
        end
      end)

    result
  end

  defp validate_type(value, {:enum, allowed_values}) when is_atom(value) do
    if value in allowed_values do
      {:ok, value}
    else
      {:error, :invalid_enum_value}
    end
  end

  defp validate_type(value, {:enum, allowed_values}) when is_binary(value) do
    # Match against known enum values safely
    found =
      Enum.find(allowed_values, fn allowed ->
        to_string(allowed) == value
      end)

    case found do
      nil -> {:error, :invalid_enum_value}
      atom -> {:ok, atom}
    end
  end

  defp validate_type(_, {:enum, _}), do: {:error, :invalid_enum_value}

  defp validate_type(value, :any), do: {:ok, value}

  # Action spec validation for batch_sync - validates and transforms each action in the list
  defp validate_type(value, :action_spec) when is_map(value) do
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

      case validate_params(action_atom, action_params) do
        {:ok, validated_params} ->
          {:ok, %{action: action_atom, params: validated_params}}

        {:error, _} = error ->
          error
      end
    end
  rescue
    ArgumentError -> {:error, :unknown_action}
  end

  defp validate_type(value, {:union, types}) do
    # Try each type until one succeeds
    # Special handling: if :atom is in union and value is string, try conversion first
    result =
      if :atom in types and is_binary(value) do
        case validate_type(value, :atom) do
          {:ok, _} = success -> success
          _ -> nil
        end
      else
        nil
      end

    # If string-to-atom conversion succeeded, return it
    # Otherwise, try remaining types
    result ||
      Enum.find_value(types, {:error, :invalid_param_type}, fn type ->
        case validate_type(value, type) do
          {:ok, _} = success -> success
          _ -> nil
        end
      end)
  end

  defp validate_type(_, _), do: {:error, :invalid_param_type}

  # Validates nested map fields: checks for missing/extra fields and validates field types
  defp validate_nested_map_fields(atom_map, properties) do
    expected_keys = Map.keys(properties)
    actual_keys = Map.keys(atom_map)

    # Check for missing required fields
    missing = expected_keys -- actual_keys

    if missing != [] do
      {:error, :missing_required_field}
    else
      # Check for extra/unknown fields
      extra = actual_keys -- expected_keys

      if extra != [] do
        {:error, :unknown_field}
      else
        # Validate each field's type recursively
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
  # Only checks for unknown fields and validates types of present fields
  defp validate_nested_map_fields_optional(atom_map, properties) do
    expected_keys = Map.keys(properties)
    actual_keys = Map.keys(atom_map)

    # Check for extra/unknown fields
    extra = actual_keys -- expected_keys

    if extra != [] do
      {:error, :unknown_field}
    else
      # Validate type of each present field
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

  defp validate_models_list(models) when is_list(models) do
    result =
      Enum.reduce_while(models, {:ok, []}, fn model, {:ok, acc} ->
        atom =
          case model do
            atom when is_atom(atom) ->
              if atom in @valid_models, do: atom, else: nil

            string when is_binary(string) ->
              # Match against known valid models safely
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

    result
  end

  defp validate_models_list(_), do: {:error, :invalid_param_type}

  # Helper to convert string keys to atoms safely
  defp string_keys_to_atoms(map) when is_map(map) do
    ValidationHelpers.string_keys_to_atoms(map)
  end
end
