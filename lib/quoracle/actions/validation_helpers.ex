defmodule Quoracle.Actions.ValidationHelpers do
  @moduledoc """
  Common validation utilities for the Actions system.
  Provides reusable validation functions for UUIDs, URLs, and safe atom conversion.
  """

  # Ensure common action param atoms exist for String.to_existing_atom/1
  _ = [
    # Orient action params
    :current_situation,
    :goal_clarity,
    :available_resources,
    :key_challenges,
    :assumptions,
    :unknowns,
    :approach_options,
    :parallelization_opportunities,
    :risk_factors,
    :success_criteria,
    :next_steps,
    :constraints_impact,
    # Other action params
    :duration,
    :to,
    :content,
    :task,
    :wait,
    :prompt,
    :message,
    :command,
    :url
  ]

  @doc """
  Validates a UUID string format.
  Returns {:ok, uuid} if valid, {:error, :invalid_uuid_format} otherwise.
  """
  @spec validate_uuid(String.t()) :: {:ok, String.t()} | {:error, :invalid_uuid_format}
  def validate_uuid(uuid) when is_binary(uuid) do
    if Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, uuid) do
      {:ok, uuid}
    else
      {:error, :invalid_uuid_format}
    end
  end

  def validate_uuid(_), do: {:error, :invalid_uuid_format}

  @doc """
  Validates a URL string has http or https scheme.
  Returns {:ok, url} if valid, {:error, :invalid_url_format} otherwise.
  """
  @spec validate_url(String.t()) :: {:ok, String.t()} | {:error, :invalid_url_format}
  def validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        {:ok, url}

      _ ->
        {:error, :invalid_url_format}
    end
  end

  def validate_url(_), do: {:error, :invalid_url_format}

  @doc """
  Safely converts a string to an existing atom.
  Returns the atom if it exists, or the original string if not.
  Never creates new atoms to prevent memory leaks.
  """
  @spec safe_string_to_atom(String.t() | atom()) :: atom() | String.t()
  def safe_string_to_atom(atom) when is_atom(atom), do: atom

  def safe_string_to_atom(string) when is_binary(string) do
    try do
      String.to_existing_atom(string)
    rescue
      ArgumentError -> string
    end
  end

  def safe_string_to_atom(other), do: other

  @doc """
  Converts map keys from strings to atoms safely.
  Only converts keys that already exist as atoms.
  """
  @spec string_keys_to_atoms(map()) :: map()
  def string_keys_to_atoms(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      {safe_string_to_atom(k), v}
    end)
    |> Map.new()
  end

  def string_keys_to_atoms(other), do: other
end
