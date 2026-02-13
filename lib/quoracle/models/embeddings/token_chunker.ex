defmodule Quoracle.Models.Embeddings.TokenChunker do
  @moduledoc """
  Token-based text chunking for embedding models.

  Splits text into chunks that respect a model's token limit,
  using tiktoken token counting via TokenManager. Looks up
  model-specific limits from LLMDB with a configurable safety margin.
  """

  alias Quoracle.Agent.TokenManager

  # Default token limit for embedding models not found in LLMDB (OpenAI/Azure standard)
  @default_embedding_token_limit 8191
  # Safety margin applied to model token limits to avoid edge-case rejections
  @token_safety_margin 0.9

  @doc "Returns the default token limit for embedding models not found in LLMDB."
  @spec default_embedding_token_limit() :: integer()
  def default_embedding_token_limit, do: @default_embedding_token_limit

  @doc "Returns the safety margin multiplier applied to model token limits."
  @spec token_safety_margin() :: float()
  def token_safety_margin, do: @token_safety_margin

  @doc """
  Gets the embedding token limit for a model from LLMDB.

  Uses the model's `limits.context` if available, otherwise defaults to 8191.
  """
  @spec get_embedding_token_limit(String.t() | nil) :: integer()
  def get_embedding_token_limit(nil), do: @default_embedding_token_limit

  def get_embedding_token_limit(model_spec) do
    case LLMDB.models()
         |> Enum.find(fn model -> LLMDB.Model.spec(model) == model_spec end) do
      nil ->
        @default_embedding_token_limit

      model ->
        get_in(Map.from_struct(model), [:limits, :context]) || @default_embedding_token_limit
    end
  end

  @doc """
  Computes the effective token limit for a model, applying the safety margin.
  """
  @spec effective_token_limit(String.t() | nil) :: integer()
  def effective_token_limit(model_spec) do
    model_spec
    |> get_embedding_token_limit()
    |> Kernel.*(@token_safety_margin)
    |> trunc()
  end

  @doc """
  Chunks text by token count, splitting at word boundaries.

  Each chunk will have at most `max_tokens` tokens. Uses running token
  estimates per word to avoid O(n^2) re-encoding.
  """
  @spec chunk_text_by_tokens(String.t(), integer()) :: [String.t()]
  def chunk_text_by_tokens(text, max_tokens) do
    if TokenManager.estimate_tokens(text) <= max_tokens do
      [text]
    else
      words = String.split(text, ~r/\s+/)

      # Pre-compute token count per word to avoid repeated tiktoken encoding.
      # Approximate: each word's tokens + 1 for whitespace separator.
      # Final verification via estimate_tokens ensures accuracy.
      word_tokens = Enum.map(words, &TokenManager.estimate_tokens/1)

      {chunks, current_words, _current_tokens} =
        words
        |> Enum.zip(word_tokens)
        |> Enum.reduce({[], [], 0}, fn {word, wtokens}, {chunks, current_words, current_tokens} ->
          # Add 1 token for the space separator (except first word in chunk)
          separator_cost = if current_words == [], do: 0, else: 1
          new_tokens = current_tokens + wtokens + separator_cost

          if new_tokens > max_tokens do
            if current_words == [] do
              # Single word exceeds limit - include it as its own chunk
              {[word | chunks], [], 0}
            else
              # Finish current chunk, start new one with this word
              chunk_text = Enum.join(current_words, " ")
              {[chunk_text | chunks], [word], wtokens}
            end
          else
            {chunks, current_words ++ [word], new_tokens}
          end
        end)

      # Don't forget the last chunk
      final_chunks =
        if current_words != [] do
          [Enum.join(current_words, " ") | chunks]
        else
          chunks
        end

      final_chunks
      |> Enum.reject(&(&1 == ""))
      |> Enum.reverse()
    end
  end
end
