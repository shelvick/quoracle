defmodule Quoracle.Utils.JsonExtractor do
  @moduledoc """
  Extracts JSON objects from text that may contain wrappers like markdown code fences.

  LLMs often wrap JSON responses in markdown (```json ... ```) or include preamble text.
  This module provides robust extraction using reverse brace matching to find the last
  complete JSON object in the content.

  ## Examples

      iex> extract_json(~s({"action": "wait"}))
      {:ok, ~s({"action": "wait"})}

      iex> extract_json(~s(```json\\n{"action": "wait"}\\n```))
      {:ok, ~s({"action": "wait"})}

      iex> extract_json("Here's the response: {\\"a\\": 1}")
      {:ok, ~s({"a": 1})}

      iex> extract_json("no json here")
      :error
  """

  @doc """
  Extracts the last complete JSON object from content.

  Uses reverse brace matching to handle:
  - Markdown code fences (```json ... ```)
  - LLM preambles containing { } characters
  - Multiple JSON objects (extracts the last one)

  ## Parameters

  - `content` - String that may contain JSON wrapped in other text

  ## Returns

  - `{:ok, json_string}` - Extracted JSON string (not parsed)
  - `:error` - No valid JSON object found
  """
  @spec extract_json(String.t()) :: {:ok, String.t()} | :error
  def extract_json(content) when is_binary(content) do
    opening_braces = :binary.matches(content, "{")
    closing_braces = :binary.matches(content, "}")

    case find_last_json_bounds(opening_braces, closing_braces) do
      {:ok, start_pos, end_pos} ->
        length = end_pos - start_pos + 1
        {:ok, :binary.part(content, start_pos, length)}

      :error ->
        :error
    end
  end

  def extract_json(_), do: :error

  @doc """
  Attempts to decode JSON, falling back to extraction if direct decode fails.

  This is the recommended entry point for parsing LLM responses that may
  contain markdown wrappers.

  ## Parameters

  - `content` - String containing JSON (possibly wrapped)

  ## Returns

  - `{:ok, decoded}` - Successfully decoded JSON (as Elixir term)
  - `{:error, reason}` - Failed to decode even after extraction
  """
  @spec decode_with_extraction(String.t()) :: {:ok, any()} | {:error, atom()}
  def decode_with_extraction(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _} ->
        case extract_json(content) do
          {:ok, extracted} ->
            case Jason.decode(extracted) do
              {:ok, decoded} -> {:ok, decoded}
              {:error, _} -> {:error, :invalid_json}
            end

          :error ->
            {:error, :no_json_found}
        end
    end
  end

  def decode_with_extraction(_), do: {:error, :invalid_input}

  # Finds the bounds of the last complete JSON object by reverse brace matching.
  # Starts from the last } and walks backwards tracking depth until depth == 0.
  defp find_last_json_bounds(opening_braces, closing_braces) do
    case closing_braces do
      [] ->
        :error

      _ ->
        # Combine all braces with their type, sorted by position
        all_braces =
          Enum.map(opening_braces, fn {pos, _} -> {pos, :open} end) ++
            Enum.map(closing_braces, fn {pos, _} -> {pos, :close} end)

        # Sort by position descending (reverse order for backwards traversal)
        sorted_desc = Enum.sort_by(all_braces, fn {pos, _} -> pos end, :desc)

        # Last closing brace position
        {last_close_pos, _} = hd(sorted_desc)

        # Walk backwards from last }, tracking depth
        find_matching_open(sorted_desc, last_close_pos, 0)
    end
  end

  # Walks through braces in reverse order, tracking nesting depth.
  # Returns {:ok, start_pos, end_pos} when matching { found (depth == 0).
  defp find_matching_open([{_pos, :close} | rest], end_pos, depth) do
    find_matching_open(rest, end_pos, depth + 1)
  end

  defp find_matching_open([{pos, :open} | rest], end_pos, depth) do
    case depth - 1 do
      0 -> {:ok, pos, end_pos}
      new_depth -> find_matching_open(rest, end_pos, new_depth)
    end
  end

  defp find_matching_open([], _end_pos, _depth), do: :error
end
