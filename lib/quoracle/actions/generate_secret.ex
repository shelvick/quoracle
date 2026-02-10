defmodule Quoracle.Actions.GenerateSecret do
  @moduledoc """
  Action module for generating random secrets (passwords, tokens) without
  exposing values to LLMs. Stores generated values in encrypted storage.
  """

  alias Quoracle.Models.TableSecrets

  @default_length 32
  @min_length 8
  @max_length 128

  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def execute(params, _agent_id, _opts) do
    with {:ok, name} <- validate_name(params),
         {:ok, length} <- validate_length(params),
         {:ok, char_opts} <- build_char_options(params),
         {:ok, secret_value} <- generate_secret(length, char_opts),
         {:ok, _secret} <- store_secret(name, secret_value, params) do
      {:ok, %{action: "generate_secret", secret_name: name}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_name(params) when is_map(params) do
    name = Map.get(params, :name) || Map.get(params, "name")

    cond do
      is_nil(name) ->
        {:error, "Name is required"}

      not is_binary(name) ->
        {:error, "Name must be a string"}

      not Regex.match?(~r/^[a-zA-Z0-9_]+$/, name) ->
        {:error, "Name must be alphanumeric with underscores only"}

      true ->
        {:ok, name}
    end
  end

  defp validate_name(_), do: {:error, "Name is required"}

  defp validate_length(params) do
    length = Map.get(params, :length) || Map.get(params, "length", @default_length)

    cond do
      length < @min_length ->
        {:error, "Length must be at least #{@min_length} characters"}

      length > @max_length ->
        {:error, "Length must be at most #{@max_length} characters"}

      true ->
        {:ok, length}
    end
  end

  defp build_char_options(params) do
    {:ok,
     %{
       include_numbers:
         Map.get(params, :include_numbers) || Map.get(params, "include_numbers", true),
       include_symbols:
         Map.get(params, :include_symbols) || Map.get(params, "include_symbols", false)
     }}
  end

  defp generate_secret(length, opts) do
    charset = build_charset(opts)

    if charset == "" do
      {:error, "At least one character set must be enabled"}
    else
      secret = generate_from_charset(length, charset)
      {:ok, secret}
    end
  end

  defp build_charset(opts) do
    base = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    numbers = if opts.include_numbers, do: "0123456789", else: ""
    symbols = if opts.include_symbols, do: "!@#$%^&*-_=+", else: ""

    base <> numbers <> symbols
  end

  defp generate_from_charset(length, charset) do
    charset_list = String.graphemes(charset)
    charset_size = length(charset_list)

    # Generate random bytes and convert to characters from charset
    # Use secure random selection
    chars =
      for _ <- 1..length do
        random_index =
          :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned() |> rem(charset_size)

        Enum.at(charset_list, random_index)
      end

    Enum.join(chars)
  end

  defp store_secret(name, value, params) do
    attrs = %{
      name: name,
      value: value,
      description: Map.get(params, :description) || Map.get(params, "description")
    }

    case TableSecrets.create(attrs) do
      {:ok, secret} ->
        {:ok, secret}

      {:error, changeset} ->
        # Extract error message from changeset
        errors = changeset.errors

        error_msg =
          if Keyword.has_key?(errors, :name) do
            {msg, _} = errors[:name]
            if msg =~ "taken", do: "Secret name already exists", else: to_string(msg)
          else
            "Failed to create secret"
          end

        {:error, error_msg}
    end
  end
end
