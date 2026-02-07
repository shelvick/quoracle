defmodule Quoracle.Models.Embeddings do
  @moduledoc """
  Handles text embeddings with caching and automatic chunking for long text.
  Uses config-driven embedding model via ReqLLM (v3.0).
  """

  alias Quoracle.Models.{ConfigModelSettings, CredentialManager, EmbeddingCache}
  alias Quoracle.Models.ModelQuery.UsageHelper
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
  @max_chunk_size 10_000

  @doc """
  Gets embedding for text using azure_text_embedding_3_large model.
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
    # Check if text needs chunking proactively
    if String.length(text) > @max_chunk_size do
      # Proactively chunk large text
      chunks = chunk_text(text)
      process_chunks(chunks, options)
    else
      # Text is small enough, try as-is
      case call_embedding_api(text, options) do
        {:ok, embedding, body} ->
          {:ok, embedding, 1, body}

        {:error, :context_length_exceeded} ->
          # Unexpected, but handle it by chunking
          chunks = chunk_text(text)
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
      # When credentials are passed, use default azure model for ReqLLM lookup
      if Map.has_key?(options, :credentials) do
        credentials = options.credentials
        # Use azure embedding model for ReqLLM when testing with injected credentials
        model_name = "azure:text-embedding-3-large"
        call_azure_embedding(text, credentials, model_name, options)
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
                  fn -> call_azure_embedding(text, credentials, model_spec, options) end,
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

  defp call_azure_embedding(text, credentials, model_name, options) do
    # Build request to Azure OpenAI embeddings endpoint using ReqLLM
    # We call the Azure provider directly to bypass ReqLLM.embed's validate_model
    # which calls prepare_request with empty opts (causing credential lookup issues)
    api_key = Map.get(credentials, :api_key)
    deployment_id = Map.get(credentials, :deployment_id)
    endpoint_url = Map.get(credentials, :endpoint_url)

    if is_nil(api_key) or is_nil(deployment_id) or is_nil(endpoint_url) do
      {:error, :authentication_failed}
    else
      opts = [
        api_key: api_key,
        base_url: endpoint_url,
        deployment: deployment_id
      ]

      # Support req_cassette plug injection for testing
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
    end
  end

  defp extract_embedding(%{"data" => [%{"embedding" => embedding} | _]}) do
    {:ok, embedding}
  end

  defp extract_embedding(_), do: {:error, :invalid_response}

  defp chunk_text(text) do
    # Simple chunking by splitting at ~4000 chars respecting word boundaries
    # Azure text-embedding-3-large has 8191 token limit
    # OpenAI's rule of thumb: ~4 chars per token for English
    # But actual can vary from 2-6 chars/token depending on text
    # Use 10,000 chars to be safe (10000/4 = 2500 tokens, well under 8191)
    if String.length(text) <= @max_chunk_size do
      [text]
    else
      # Split into chunks
      words = String.split(text, ~r/\s+/)

      chunks =
        Enum.reduce(words, [[]], fn word, [current | rest] ->
          current_text = Enum.join(current, " ")

          if String.length(current_text <> " " <> word) > @max_chunk_size do
            # Start new chunk
            [[word], current | rest]
          else
            # Add to current chunk
            [current ++ [word] | rest]
          end
        end)
        |> Enum.map(&Enum.join(&1, " "))
        |> Enum.reject(&(&1 == ""))
        |> Enum.reverse()

      # If any chunk is still too big, recursively split
      Enum.flat_map(chunks, fn chunk ->
        if String.length(chunk) > @max_chunk_size do
          chunk_text(chunk)
        else
          [chunk]
        end
      end)
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
