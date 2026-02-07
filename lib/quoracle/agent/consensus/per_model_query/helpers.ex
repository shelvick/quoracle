defmodule Quoracle.Agent.Consensus.PerModelQuery.Helpers do
  @moduledoc """
  Helper functions for PerModelQuery module.
  Extracted for 500-line limit compliance.

  Contains:
  - Reflection message formatting
  - Context length error detection
  - Test embedding function
  """

  alias Quoracle.Agent.Reflector
  alias Quoracle.Utils.ContentStringifier
  alias Quoracle.Utils.JSONNormalizer

  # Format history entries as messages for Reflector
  @spec format_messages_for_reflection(list(map())) :: list(map())
  def format_messages_for_reflection(history_entries) do
    Enum.map(history_entries, fn entry ->
      role =
        case Map.get(entry, :type) do
          :user -> "user"
          :assistant -> "assistant"
          :decision -> "assistant"
          :result -> "user"
          :prompt -> "user"
          :event -> "user"
          _ -> "user"
        end

      content = format_content_for_reflection(Map.get(entry, :content, ""))
      %{role: role, content: content}
    end)
  end

  # Handle different content types - complex types need JSON normalization, strings pass through
  @spec format_content_for_reflection(term()) :: String.t()
  def format_content_for_reflection(content) when is_map(content) do
    JSONNormalizer.normalize(content)
  end

  def format_content_for_reflection(content) when is_tuple(content) do
    JSONNormalizer.normalize(content)
  end

  def format_content_for_reflection(content) when is_binary(content), do: content

  # Handle multimodal content (list of content parts from MCP)
  # Uses shared ContentStringifier with JSONNormalizer fallback for structured output
  def format_content_for_reflection(content) when is_list(content) do
    ContentStringifier.stringify(content, map_fallback: &JSONNormalizer.normalize/1)
  end

  def format_content_for_reflection(content), do: to_string(content)

  # Default reflector - calls Reflector module
  @spec default_reflector(list(map()), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def default_reflector(messages, model_id, opts) do
    Reflector.reflect(messages, model_id, opts)
  end

  # Test embedding function - returns unique vectors to avoid false deduplication
  @spec test_embedding_fn(String.t()) :: {:ok, map()}
  def test_embedding_fn(text) do
    # Generate a simple hash-based embedding for test isolation
    hash = :erlang.phash2(text)
    # Create a 3-dim vector based on hash for uniqueness
    {:ok,
     %{
       embedding: [
         rem(hash, 100) / 100,
         rem(div(hash, 100), 100) / 100,
         rem(div(hash, 10000), 100) / 100
       ]
     }}
  end

  @doc """
  Checks if an error indicates context length was exceeded.
  Handles both atom format (test mocks) and ReqLLM error structs (production).
  """
  @spec context_length_error?(term()) :: boolean()
  def context_length_error?(:context_length_exceeded), do: true

  def context_length_error?(%ReqLLM.Error.API.Request{reason: reason}) when is_binary(reason) do
    context_length_message?(reason)
  end

  def context_length_error?(%ReqLLM.Error.API.Response{reason: reason}) when is_binary(reason) do
    context_length_message?(reason)
  end

  def context_length_error?(_), do: false

  # Checks if error message indicates context/token limit exceeded
  # Covers: OpenAI, Anthropic, Azure, and Gemini error formats
  @spec context_length_message?(String.t()) :: boolean()
  def context_length_message?(reason) do
    # Gemini: "The input token count (X) exceeds the maximum number of tokens allowed (Y)"
    String.contains?(reason, "context_length_exceeded") or
      String.contains?(reason, "Input is too long") or
      String.contains?(reason, "maximum context length") or
      String.contains?(reason, "exceeds the maximum number of tokens")
  end
end
