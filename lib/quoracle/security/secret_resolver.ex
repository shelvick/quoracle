defmodule Quoracle.Security.SecretResolver do
  @moduledoc """
  Resolves {{SECRET:name}} templates in action parameters.

  Finds template references in nested data structures, resolves them
  from encrypted storage, and tracks which secrets were used.
  """

  alias Quoracle.Models.TableSecrets

  require Logger

  @template_pattern ~r/\{\{SECRET:([a-zA-Z0-9_]+)\}\}/

  @doc """
  Resolves all {{SECRET:name}} templates in params.

  ## Parameters
  - params: Map or nested structure containing templates

  ## Returns
  - {:ok, resolved_params, secret_values_map} on success where secret_values_map is %{name => value}

  Templates referencing non-existent secrets are left as literal text and a warning is logged.
  This allows agents to use example syntax like {{SECRET:example_name}} without causing errors.

  ## Examples

      iex> resolve_params(%{"key" => "{{SECRET:api_key}}"})
      {:ok, %{"key" => "actual_value"}, %{"api_key" => "actual_value"}}

      iex> resolve_params(%{"key" => "{{SECRET:missing}}"})
      # Logs warning, returns literal
      {:ok, %{"key" => "{{SECRET:missing}}"}, %{}}
  """
  @spec resolve_params(map() | list() | any()) :: {:ok, any(), %{String.t() => String.t()}}
  def resolve_params(params) do
    # Find all template names
    template_names = find_templates(params)

    case template_names do
      [] ->
        {:ok, params, %{}}

      names ->
        # Batch resolve all secrets
        case TableSecrets.resolve_secrets(names) do
          {:ok, secret_values} ->
            resolved = replace_templates(params, secret_values)
            {:ok, resolved, secret_values}

          {:error, :secret_not_found, _name} ->
            # Fall back to partial resolution - resolve what exists, warn about missing
            resolve_partial(params, names)
        end
    end
  end

  # Resolves secrets individually, warning about missing ones and leaving them as literals
  defp resolve_partial(params, names) do
    {found, missing} =
      Enum.reduce(names, {%{}, []}, fn name, {found_acc, missing_acc} ->
        case TableSecrets.get_by_name(name) do
          {:ok, secret} -> {Map.put(found_acc, name, secret.value), missing_acc}
          {:error, _} -> {found_acc, [name | missing_acc]}
        end
      end)

    # Warn about each missing secret
    for name <- Enum.reverse(missing) do
      Logger.warning(
        "Secret '#{name}' not found - {{SECRET:#{name}}} kept as literal. " <>
          "If this was intentional (e.g., an example), you can ignore this warning."
      )
    end

    # Replace only the found secrets, leaving missing ones as literal templates
    resolved = replace_templates(params, found)
    {:ok, resolved, found}
  end

  @doc """
  Finds all {{SECRET:name}} template names in data.

  ## Returns
  List of unique secret names found
  """
  @spec find_templates(any()) :: [String.t()]
  def find_templates(data) when is_binary(data) do
    Regex.scan(@template_pattern, data)
    |> Enum.map(fn [_, name] -> name end)
  end

  def find_templates(data) when is_map(data) do
    data
    |> Enum.flat_map(fn {_k, v} -> find_templates(v) end)
    |> Enum.uniq()
  end

  def find_templates(data) when is_list(data) do
    data
    |> Enum.flat_map(&find_templates/1)
    |> Enum.uniq()
  end

  def find_templates(_data), do: []

  @doc """
  Lists all available secret names.

  ## Returns
  {:ok, list of names}
  """
  @spec list_available_secrets() :: {:ok, [String.t()]}
  def list_available_secrets do
    TableSecrets.list_names()
  end

  @doc """
  Validates a single template string.

  ## Returns
  - {:ok, name} if valid
  - {:error, :invalid_template} if invalid
  """
  @spec validate_template(String.t()) :: {:ok, String.t()} | {:error, :invalid_template}
  def validate_template(template) when is_binary(template) do
    case Regex.run(@template_pattern, template) do
      [^template, name] -> {:ok, name}
      _ -> {:error, :invalid_template}
    end
  end

  @doc """
  Resolves a single template name to its value.

  ## Returns
  - {:ok, value} on success
  - {:error, :secret_not_found} if not found
  """
  @spec resolve_template(String.t()) :: {:ok, String.t()} | {:error, :secret_not_found}
  def resolve_template(name) when is_binary(name) do
    case TableSecrets.get_by_name(name) do
      {:ok, secret} -> {:ok, secret.value}
      {:error, :not_found} -> {:error, :secret_not_found}
      {:error, _} -> {:error, :secret_not_found}
    end
  end

  # Replace templates in data structure with actual values
  defp replace_templates(data, secret_values) when is_binary(data) do
    Enum.reduce(secret_values, data, fn {name, value}, acc ->
      String.replace(acc, "{{SECRET:#{name}}}", value)
    end)
  end

  defp replace_templates(data, secret_values) when is_map(data) do
    Map.new(data, fn {k, v} ->
      {k, replace_templates(v, secret_values)}
    end)
  end

  defp replace_templates(data, secret_values) when is_list(data) do
    Enum.map(data, &replace_templates(&1, secret_values))
  end

  defp replace_templates(data, _secret_values), do: data
end
