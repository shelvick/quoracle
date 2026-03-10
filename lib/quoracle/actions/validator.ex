defmodule Quoracle.Actions.Validator do
  @moduledoc """
  Validates action JSON against schemas and enforces parameter constraints.
  Ensures type safety and XOR parameter requirements.
  """

  alias Quoracle.Actions.Schema
  alias Quoracle.Actions.ValidationHelpers
  alias Quoracle.Actions.Validator.BatchAsync, as: BatchAsyncValidator
  alias Quoracle.Actions.Validator.BatchSync, as: BatchSyncValidator
  alias Quoracle.Actions.Validator.TypeValidation
  alias Quoracle.Groves.SpawnContractResolver

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
  @spec validate_params(atom(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def validate_params(action, params, opts \\ []) do
    with {:ok, schema} <- Schema.get_schema(action) do
      validate_params_with_schema(action, params, schema, opts)
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

  defp validate_params_with_schema(action, params, schema, opts \\ []) do
    # Special handling for spawn_child required params and call_api protocol-specific validation
    result =
      case action do
        :spawn_child ->
          check_spawn_child_required_params(params, schema, opts)

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
         {:ok, validated_params} <-
           TypeValidation.validate_param_types(params, schema.param_types) do
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

  defp check_spawn_child_required_params(params, _schema, opts) do
    base_required = [
      :task_description,
      :success_criteria,
      :immediate_context,
      :approach_guidance
    ]

    if spawn_profile_optional?(params, opts) do
      check_required_params(params, base_required)
    else
      check_required_params(params, [:profile | base_required])
    end
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

  @spec spawn_profile_optional?(map(), keyword()) :: boolean()
  defp spawn_profile_optional?(params, opts) do
    parent_config = opts[:parent_config]

    topology =
      opts[:grove_topology] ||
        (is_map(parent_config) && Map.get(parent_config, :grove_topology))

    parent_skill_names =
      if is_map(parent_config) do
        parent_config
        |> Map.get(:active_skills, [])
        |> Enum.map(&Map.get(&1, :name))
        |> Enum.filter(&is_binary/1)
      else
        []
      end

    child_skill_names =
      params
      |> string_keys_to_atoms()
      |> Map.get(:skills, [])
      |> normalize_skill_names()

    case SpawnContractResolver.find_edge(topology, parent_skill_names, child_skill_names) do
      %{"auto_inject" => %{"profile" => profile}} when is_binary(profile) and profile != "" ->
        true

      _ ->
        false
    end
  end

  @spec normalize_skill_names(term()) :: [String.t()]
  defp normalize_skill_names(skills) when is_list(skills), do: Enum.filter(skills, &is_binary/1)
  defp normalize_skill_names(_), do: []

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

  # Helper to convert string keys to atoms safely
  defp string_keys_to_atoms(map) when is_map(map) do
    ValidationHelpers.string_keys_to_atoms(map)
  end
end
