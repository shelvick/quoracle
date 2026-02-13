defmodule Quoracle.Models.Embeddings do
  @moduledoc """
  Handles text embeddings with caching and automatic chunking for long text.
  Uses config-driven embedding model via ReqLLM (v3.0).
  """

  alias Quoracle.Agent.TokenManager
  alias Quoracle.Models.{ConfigModelSettings, CredentialManager, EmbeddingCache}
  alias Quoracle.Models.Embeddings.TokenChunker
  alias Quoracle.Models.ModelQuery.{OptionsBuilder, UsageHelper}
  alias Quoracle.Providers.RetryHelper
  alias Quoracle.Supervisor.PidDiscovery
  alias Quoracle.Costs.Accumulator
  require Logger

  @type embedding_result :: %{
          embedding: list(float()),
          cached: boolean(),
          chunks: integer()
        }

  # Configuration constants
  # 1 hour in milliseconds
  @default_cache_ttl 3_600_000
  @max_cache_entries 1000

  @doc """
  Gets embedding for text using the configured embedding model.
  Automatically chunks long text and averages embeddings.

  Returns:
  - `{:ok, %{embedding: list(), cached: boolean(), chunks: integer()}}` without accumulator
  - `{:ok, result, updated_accumulator}` when `:cost_accumulator` provided in options
  - Cached results always return 2-tuple (no cost to accumulate)
  """
  @spec get_embedding(String.t()) :: {:ok, embedding_result()} | {:error, atom()}
  @spec get_embedding(String.t(), map() | keyword()) ::
          {:ok, embedding_result()}
          | {:ok, embedding_result(), Accumulator.t()}
          | {:error, atom()}
  def get_embedding(text, options \\ %{}) do
    # Convert keyword list to map if needed
    options = if is_list(options), do: Map.new(options), else: options

    # Validate input
    if text == "" do
      {:error, :invalid_input}
    else
      # Check cache first
      case check_cache(text, options) do
        {:ok, embedding} ->
          # Cached results always return 2-tuple (no cost to accumulate)
          {:ok, %{embedding: embedding, cached: true, chunks: 1}}

        :miss ->
          # Not in cache, fetch from API
          fetch_and_cache_embedding(text, options)
      end
    end
  end

  defp check_cache(text, options) do
    # Generate cache key from text hash
    cache_key = :crypto.hash(:sha256, text)

    # Get TTL from options or use default
    ttl = Map.get(options, :cache_ttl, @default_cache_ttl)

    # Skip cache if TTL is 0
    if ttl == 0 do
      :miss
    else
      table = get_cache_table(options)

      case :ets.lookup(table, cache_key) do
        [{^cache_key, embedding, timestamp, entry_ttl}] ->
          # Check if cache entry is still valid
          now = System.system_time(:millisecond)

          if now - timestamp < entry_ttl do
            {:ok, embedding}
          else
            # Expired, remove from cache
            :ets.delete(table, cache_key)
            :miss
          end

        [] ->
          :miss
      end
    end
  end

  defp get_cache_table(options) do
    # Allow passing cache_pid in options for testing
    cache_pid = Map.get(options, :cache_pid, get_embedding_cache_pid())
    EmbeddingCache.get_table(cache_pid)
  end

  defp get_embedding_cache_pid do
    PidDiscovery.find_child_pid!(EmbeddingCache)
  end

  defp fetch_and_cache_embedding(text, options) do
    # Try to get embedding, handling chunking if needed
    case get_embedding_with_chunking(text, options) do
      {:ok, embedding, chunks, usage} ->
        # Cache the result
        cache_embedding(text, embedding, options)

        result = %{embedding: embedding, cached: false, chunks: chunks}

        # Check if accumulator is provided (R13-R17)
        case Map.get(options, :cost_accumulator) do
          %Accumulator{} = acc ->
            # Accumulate cost instead of recording directly (R14)
            updated_acc = accumulate_cost(acc, options, chunks, usage)
            {:ok, result, updated_acc}

          nil ->
            # Record cost directly for non-cached embedding (R6, R7, R13)
            record_cost(options, chunks, usage)
            {:ok, result}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Computes embedding cost from LLMDB pricing for a model_spec and usage map.
  Returns a Decimal cost or nil if the model has no pricing data.
  """
  @spec compute_embedding_cost(String.t(), map()) :: Decimal.t() | nil
  def compute_embedding_cost(model_spec, usage) when is_binary(model_spec) do
    input_tokens = Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0

    case ReqLLM.model(model_spec) do
      {:ok, %{cost: %{input: cost_per_million}}} when not is_nil(cost_per_million) ->
        "#{cost_per_million}"
        |> Decimal.new()
        |> Decimal.mult(input_tokens)
        |> Decimal.div(1_000_000)

      _ ->
        nil
    end
  end

  defp record_cost(options, chunks, usage) do
    model_spec =
      case ConfigModelSettings.get_embedding_model() do
        {:ok, model_id} -> model_id
        _ -> "unknown"
      end

    # Compute cost from LLMDB pricing and inject into usage for UsageHelper
    input_tokens = get_in(usage, ["usage", "prompt_tokens"]) || 0
    total_cost = compute_embedding_cost(model_spec, %{input_tokens: input_tokens})

    usage_with_cost =
      if total_cost do
        %{usage | "usage" => Map.put(usage["usage"] || %{}, "total_cost", total_cost)}
      else
        usage
      end

    cost_options = %{
      agent_id: Map.get(options, :agent_id),
      task_id: Map.get(options, :task_id),
      pubsub: Map.get(options, :pubsub),
      model_spec: model_spec
    }

    extra_metadata = %{chunks: chunks, cached: false}

    UsageHelper.record_single_request(
      usage_with_cost,
      "llm_embedding",
      cost_options,
      extra_metadata
    )
  end

  # Accumulate cost entry instead of recording directly (R14-R16)
  defp accumulate_cost(acc, options, chunks, usage) do
    model_spec =
      case ConfigModelSettings.get_embedding_model() do
        {:ok, model_id} -> model_id
        _ -> "unknown"
      end

    input_tokens = get_in(usage, ["usage", "prompt_tokens"]) || 0
    total_cost = compute_embedding_cost(model_spec, %{input_tokens: input_tokens})

    entry = %{
      agent_id: Map.get(options, :agent_id),
      task_id: Map.get(options, :task_id),
      cost_type: "llm_embedding",
      cost_usd: total_cost,
      metadata: %{
        "model_spec" => model_spec,
        "chunks" => chunks,
        "cached" => false
      }
    }

    Accumulator.add(acc, entry)
  end

  defp get_embedding_with_chunking(text, options) do
    # Resolve model_spec for token limit lookup
    model_spec = resolve_model_spec(options)
    effective_limit = TokenChunker.effective_token_limit(model_spec)

    token_count = TokenManager.estimate_tokens(text)

    if token_count > effective_limit do
      # Text exceeds token limit - chunk by tokens
      chunks = TokenChunker.chunk_text_by_tokens(text, effective_limit)
      process_chunks(chunks, options)
    else
      # Text is within token limit, try as-is
      case call_embedding_api(text, options) do
        {:ok, embedding, body} ->
          {:ok, embedding, 1, body}

        {:error, :context_length_exceeded} ->
          # API rejected despite our estimate - force chunking at half the
          # text's token count so the text is split into at least 2 pieces (R31)
          reduced_limit = max(div(token_count, 2), 1)
          chunks = TokenChunker.chunk_text_by_tokens(text, reduced_limit)
          process_chunks(chunks, options)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Process multiple chunks and accumulate usage
  defp process_chunks(chunks, options) do
    results =
      Enum.map(chunks, fn chunk ->
        case call_embedding_api(chunk, options) do
          {:ok, embedding, body} -> {embedding, body}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(results) do
      {:error, :all_chunks_failed}
    else
      {embeddings, bodies} = Enum.unzip(results)
      averaged = average_embeddings(embeddings)
      # Sum up token usage across all chunks
      combined_usage = combine_usage(bodies)
      {:ok, averaged, length(embeddings), combined_usage}
    end
  end

  # Combine usage from multiple API responses
  defp combine_usage(bodies) do
    Enum.reduce(bodies, %{"usage" => %{"prompt_tokens" => 0, "total_tokens" => 0}}, fn body,
                                                                                       acc ->
      body_usage = get_in(body, ["usage"]) || %{}
      acc_usage = get_in(acc, ["usage"])

      %{
        "usage" => %{
          "prompt_tokens" =>
            (acc_usage["prompt_tokens"] || 0) + (body_usage["prompt_tokens"] || 0),
          "total_tokens" => (acc_usage["total_tokens"] || 0) + (body_usage["total_tokens"] || 0)
        }
      }
    end)
  end

  defp call_embedding_api(text, options) do
    # Check if we have a mock embedding function first (for testing)
    if Map.has_key?(options, :embedding_fn) do
      case options.embedding_fn.(text) do
        {:ok, embedding} -> {:ok, embedding, %{"usage" => %{}}}
        error -> error
      end
    else
      # Check if credentials were injected via options (for testing)
      if Map.has_key?(options, :credentials) do
        credentials = options.credentials
        # Use model_spec from credentials; when absent, default based on credential shape
        model_name = resolve_model_name(credentials)
        call_embedding_provider(text, credentials, model_name, options)
      else
        # Normal path - get configured model from CONFIG_ModelSettings
        case get_configured_embedding_model() do
          {:error, :not_configured} ->
            {:error, :not_configured}

          {:ok, model_id} ->
            case CredentialManager.get_credentials(model_id) do
              {:ok, credentials} ->
                # Use model_spec from credentials for ReqLLM (model_id is only for lookup)
                model_spec = Map.get(credentials, :model_spec, model_id)

                RetryHelper.with_retry(
                  fn -> call_embedding_provider(text, credentials, model_spec, options) end,
                  max_retries: 3,
                  initial_delay: 1000
                )

              {:error, :not_found} ->
                {:error, :authentication_failed}

              {:error, reason} ->
                {:error, reason}
            end
        end
      end
    end
  end

  defp get_configured_embedding_model do
    ConfigModelSettings.get_embedding_model()
  end

  # Resolve ReqLLM model name from injected credentials.
  # When model_spec is present, use it directly.
  # When absent, check for Azure-specific fields to determine provider.
  @spec resolve_model_name(map()) :: String.t()
  defp resolve_model_name(credentials) do
    case Map.get(credentials, :model_spec) do
      nil ->
        # Backward compatibility: use Azure provider only if Azure-specific fields present
        if Map.get(credentials, :endpoint_url) && Map.get(credentials, :deployment_id) do
          "azure:text-embedding-3-large"
        else
          "openai:text-embedding-3-large"
        end

      model_spec ->
        model_spec
    end
  end

  defp call_embedding_provider(text, credentials, model_name, options) do
    # Ensure credential has model_spec so OptionsBuilder routes to the correct provider
    credentials = Map.put_new(credentials, :model_spec, model_name)

    # Build provider-specific opts via OptionsBuilder
    opts = OptionsBuilder.build_embedding_options(credentials, options)

    # Support req_cassette plug injection for testing (as req_opts, not in provider opts)
    req_opts = if plug = Map.get(options, :plug), do: [plug: plug], else: []

    # Get model and provider, then call prepare_request directly with our opts
    with {:ok, model} <- ReqLLM.model(model_name),
         {:ok, provider} <- ReqLLM.provider(model.provider),
         {:ok, request} <- provider.prepare_request(:embedding, model, text, opts),
         {:ok, %Req.Response{status: status, body: body}} when status in 200..299 <-
           Req.request(request, req_opts),
         {:ok, embedding} <- extract_embedding(body) do
      {:ok, embedding, body}
    else
      {:ok, %Req.Response{status: 401}} ->
        {:error, :authentication_failed}

      {:ok, %Req.Response{status: 429}} ->
        {:error, :rate_limit_exceeded}

      {:ok, %Req.Response{status: 400, body: body}} ->
        body_str = if is_binary(body), do: body, else: inspect(body)

        if String.contains?(body_str, "context_length_exceeded") or
             String.contains?(body_str, "maximum context length") do
          {:error, :context_length_exceeded}
        else
          {:error, :bad_request}
        end

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        {:error, :service_unavailable}

      # Handle ReqLLM error structs with status codes
      {:error, %{status: 401}} ->
        {:error, :authentication_failed}

      {:error, %{status: 429}} ->
        {:error, :rate_limit_exceeded}

      {:error, %{status: status}} when status >= 500 ->
        {:error, :service_unavailable}

      {:error, error} ->
        Logger.error("ReqLLM embedding request failed: #{inspect(error)}")
        {:error, :network_error}
    end
  rescue
    # Provider raises when required credentials are missing (e.g., nil api_key)
    e in [ArgumentError, ReqLLM.Error.Invalid.Parameter] ->
      Logger.debug("Embedding credential validation failed: #{Exception.message(e)}")
      {:error, :authentication_failed}
  end

  defp extract_embedding(%{"data" => [%{"embedding" => embedding} | _]}) do
    {:ok, embedding}
  end

  defp extract_embedding(_), do: {:error, :invalid_response}

  # Resolve model_spec from options for token limit lookup.
  # Checks :model_spec option first, then credentials, then configured model.
  @spec resolve_model_spec(map()) :: String.t() | nil
  defp resolve_model_spec(options) do
    cond do
      Map.has_key?(options, :model_spec) ->
        options.model_spec

      Map.has_key?(options, :credentials) ->
        resolve_model_name(options.credentials)

      true ->
        case get_configured_embedding_model() do
          {:ok, model_id} ->
            case CredentialManager.get_credentials(model_id) do
              {:ok, cred} -> Map.get(cred, :model_spec, model_id)
              _ -> model_id
            end

          _ ->
            nil
        end
    end
  end

  defp average_embeddings(embeddings) do
    # Element-wise average of all embeddings
    dimension = length(List.first(embeddings))

    Enum.map(0..(dimension - 1), fn i ->
      sum =
        Enum.reduce(embeddings, 0, fn embedding, acc ->
          acc + Enum.at(embedding, i)
        end)

      sum / length(embeddings)
    end)
  end

  defp cache_embedding(text, embedding, options) do
    cache_key = :crypto.hash(:sha256, text)
    # Get TTL from options or use default
    ttl = Map.get(options, :cache_ttl, @default_cache_ttl)

    if ttl > 0 do
      table = get_cache_table(options)
      # Enforce cache size limit (max 1000 entries, ~24MB for 3072-dim vectors)
      enforce_cache_limit(table)

      timestamp = System.system_time(:millisecond)
      :ets.insert(table, {cache_key, embedding, timestamp, ttl})
    end

    :ok
  end

  @spec enforce_cache_limit(:ets.tid()) :: :ok
  defp enforce_cache_limit(table) do
    # Max cache size: approximately 24MB for 3072-dim float vectors
    case :ets.info(table, :size) do
      size when size >= @max_cache_entries ->
        # LRU eviction: remove oldest entries
        entries = :ets.tab2list(table)

        # Sort by timestamp (oldest first)
        sorted =
          entries
          |> Enum.sort_by(fn {_key, _embedding, timestamp, _ttl} -> timestamp end)

        # Remove oldest 10% to make room
        entries_to_remove =
          sorted
          |> Enum.take(div(@max_cache_entries, 10))
          |> Enum.map(fn {key, _, _, _} -> key end)

        Enum.each(entries_to_remove, &:ets.delete(table, &1))

      _ ->
        :ok
    end
  end
end
