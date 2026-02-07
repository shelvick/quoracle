defmodule Quoracle.Security.OutputScrubber do
  @moduledoc """
  Sanitizes action results by removing secret values.

  Recursively searches through data structures and replaces secret values
  with [REDACTED:name] placeholders to prevent leakage.
  """

  @min_secret_length 8

  @doc """
  Scrubs all secret values from result data.

  ## Parameters
  - result: Any data structure (string, map, list, tuple, etc.)
  - secrets_used: Map of %{secret_name => secret_value}

  ## Returns
  Scrubbed data with same structure, secret values replaced

  ## Examples

      iex> scrub_result("API key: secret123", %{"api" => "secret123"})
      "API key: [REDACTED:api]"

      iex> scrub_result(%{"token" => "secret123"}, %{"api" => "secret123"})
      %{"token" => "[REDACTED:api]"}
  """
  @spec scrub_result(any(), %{String.t() => String.t()}) :: any()
  def scrub_result(result, secrets_used) do
    # Filter out short secrets and sort by length (longest first)
    secrets_to_scrub =
      secrets_used
      |> Enum.filter(fn {_name, value} -> String.length(value) >= @min_secret_length end)
      |> Enum.sort_by(fn {_name, value} -> -String.length(value) end)

    scrub_deep(result, secrets_to_scrub)
  end

  @doc """
  Scrubs secrets from a string.

  ## Parameters
  - string: String to scrub
  - secrets_used: Map of secret names to values

  ## Returns
  Scrubbed string
  """
  @spec scrub_string(String.t(), %{String.t() => String.t()}) :: String.t()
  def scrub_string(string, secrets_used) when is_binary(string) do
    # Filter and sort secrets
    secrets_to_scrub =
      secrets_used
      |> Enum.filter(fn {_name, value} -> String.length(value) >= @min_secret_length end)
      |> Enum.sort_by(fn {_name, value} -> -String.length(value) end)

    # Replace each secret
    Enum.reduce(secrets_to_scrub, string, fn {name, value}, acc ->
      String.replace(acc, value, redact_value(value, name))
    end)
  end

  @doc """
  Recursively scrubs secrets from deeply nested structures.

  ## Parameters
  - data: Any nested data structure
  - secrets: List of {name, value} tuples sorted by length

  ## Returns
  Scrubbed data structure
  """
  @spec scrub_deep(any(), [{String.t(), String.t()}]) :: any()
  def scrub_deep(data, secrets) when is_binary(data) do
    Enum.reduce(secrets, data, fn {name, value}, acc ->
      String.replace(acc, value, redact_value(value, name))
    end)
  end

  def scrub_deep(data, _secrets) when is_struct(data) do
    # Structs (DateTime, Date, etc.) should not be scrubbed recursively
    # They don't implement Enumerable and contain no user-controlled strings
    data
  end

  def scrub_deep(data, secrets) when is_map(data) do
    Map.new(data, fn {k, v} ->
      {k, scrub_deep(v, secrets)}
    end)
  end

  def scrub_deep(data, secrets) when is_list(data) do
    Enum.map(data, &scrub_deep(&1, secrets))
  end

  def scrub_deep(data, secrets) when is_tuple(data) do
    data
    |> Tuple.to_list()
    |> Enum.map(&scrub_deep(&1, secrets))
    |> List.to_tuple()
  end

  def scrub_deep(data, _secrets), do: data

  @doc """
  Checks if a string contains a secret value.

  ## Parameters
  - string: String to check
  - secret_value: Secret value to look for

  ## Returns
  Boolean indicating if secret is present
  """
  @spec contains_secret?(String.t(), String.t()) :: boolean()
  def contains_secret?(string, secret_value) when is_binary(string) and is_binary(secret_value) do
    String.contains?(string, secret_value)
  end

  @doc """
  Replaces a secret value with redacted format.

  ## Parameters
  - _value: The secret value (unused, for signature compatibility)
  - name: The secret name

  ## Returns
  Redacted string in format [REDACTED:name]

  ## Examples

      iex> redact_value("secret123", "api_key")
      "[REDACTED:api_key]"
  """
  @spec redact_value(String.t(), String.t()) :: String.t()
  def redact_value(_value, name) do
    "[REDACTED:#{name}]"
  end
end
