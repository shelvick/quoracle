defmodule Quoracle.Agent.Consensus.PerModelQuery.Helpers do
  @moduledoc """
  Helper functions for PerModelQuery module.
  Extracted for 500-line limit compliance.

  Contains:
  - Reflection message formatting
  - Context length error detection
  - Test embedding function
  - Query function resolution and mock responses
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

  # Test embedding function - deterministic vector with low accidental similarity.
  @doc """
  Deterministic test embedding helper used in isolated condensation tests.
  """
  @spec test_embedding_fn(String.t()) :: {:ok, map()}
  def test_embedding_fn(text) do
    embedding =
      :crypto.hash(:sha256, text)
      |> :binary.bin_to_list()
      |> Enum.map(fn byte -> byte / 255 end)

    {:ok, %{embedding: embedding}}
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

  @doc """
  Resolve the query function to use based on opts.
  Returns the injected model_query_fn, a mock function in test mode,
  or the real ModelQuery.query_models/3 in production.
  """
  @spec resolve_query_fn(keyword()) :: function()
  def resolve_query_fn(opts) do
    case Keyword.fetch(opts, :model_query_fn) do
      {:ok, query_fn} ->
        query_fn

      :error ->
        if test_mode?(opts) do
          &mock_query_models/3
        else
          &Quoracle.Models.ModelQuery.query_models/3
        end
    end
  end

  @doc """
  Check if test mode is enabled in opts.
  """
  @spec test_mode?(keyword()) :: boolean()
  def test_mode?(opts), do: Keyword.get(opts, :test_mode, false)

  @doc """
  Lightweight query path: test mode with injected query fn.
  Skips tiktoken BPE encoding, LLMDB scans, and condensation checks
  since test query functions don't depend on accurate token management.
  Tests that specifically verify token management pass force_token_management: true.
  """
  @spec lightweight_test_query?(keyword()) :: boolean()
  def lightweight_test_query?(opts) do
    test_mode?(opts) && Keyword.has_key?(opts, :model_query_fn) &&
      !Keyword.get(opts, :force_token_management, false)
  end

  @doc """
  Merge state-level test options into call-site opts without overriding explicit call opts.
  This keeps spawned-process test settings (e.g., model_query_fn, max_batch_tokens,
  force_token_management) intact across consensus entry paths.
  """
  @spec merge_state_test_opts(map(), keyword()) :: keyword()
  def merge_state_test_opts(state, opts) do
    state_test_opts =
      state
      |> Map.get(:test_opts, [])
      |> List.wrap()

    Keyword.merge(state_test_opts, opts)
  end

  @doc """
  Build test options map for model query options.
  Maps test simulation flags from keyword opts to a map for query behavior.
  """
  @spec build_test_options(keyword()) :: map()
  def build_test_options(opts) do
    %{
      test_mode: true,
      seed: Keyword.get(opts, :seed),
      simulate_tie: Keyword.get(opts, :simulate_tie, false),
      simulate_no_consensus: Keyword.get(opts, :simulate_no_consensus, false),
      simulate_refinement_agreement: Keyword.get(opts, :simulate_refinement_agreement, false),
      simulate_timeout: Keyword.get(opts, :simulate_timeout, false),
      simulate_all_models_fail: Keyword.get(opts, :simulate_all_models_fail, false),
      simulate_failure: Keyword.get(opts, :simulate_failure, false)
    }
  end

  @doc """
  Generate a mock successful response for a model in test mode.
  Returns a map with :model and :content (JSON-encoded orient action).
  """
  @spec mock_successful_response(String.t()) :: map()
  def mock_successful_response(model_id) do
    response_json =
      Jason.encode!(%{
        "action" => "orient",
        "params" => %{
          "current_situation" => "Processing task",
          "goal_clarity" => "Clear objectives",
          "available_resources" => "Full capabilities",
          "key_challenges" => "None identified",
          "delegation_consideration" => "none"
        },
        "reasoning" => "Mock reasoning for #{model_id}",
        "wait" => true
      })

    %{model: model_id, content: response_json}
  end

  # Mock query function for test mode without injected query fn
  @spec mock_query_models(list(map()), list(String.t()), map()) ::
          {:ok, map()}
  defp mock_query_models(_messages, models, _query_opts) do
    {:ok,
     %{
       successful_responses: Enum.map(models, &mock_successful_response/1),
       failed_models: []
     }}
  end
end
