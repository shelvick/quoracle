defmodule Quoracle.Models.ModelQuery.CacheHelper do
  @moduledoc """
  Helper functions for Anthropic prompt caching on Bedrock.
  Extracted from ModelQuery to maintain <500 line modules.
  """

  require Logger

  @doc """
  Add Anthropic prompt caching options for Bedrock if prompt_cache option present.

  ## Options
  - `nil` - No caching (returns opts unchanged)
  - `true` - Enable caching for all messages
  - `integer` - Enable caching with offset (e.g., -2 for second-to-last message)

  ## Returns
  Updated keyword list with provider_options for caching.
  """
  @spec maybe_add_cache_options(keyword(), map()) :: keyword()
  def maybe_add_cache_options(opts, options) do
    case Map.get(options, :prompt_cache) do
      nil ->
        opts

      true ->
        merge_provider_options(opts,
          anthropic_prompt_cache: true,
          anthropic_cache_messages: true
        )

      offset when is_integer(offset) ->
        merge_provider_options(opts,
          anthropic_prompt_cache: true,
          anthropic_cache_messages: offset
        )
    end
  end

  # Merges new provider_options with existing ones instead of overwriting.
  # This preserves options like thinking config set by earlier pipeline stages.
  defp merge_provider_options(opts, new_options) do
    existing = Keyword.get(opts, :provider_options, [])
    merged = Keyword.merge(existing, new_options)
    Keyword.put(opts, :provider_options, merged)
  end

  @doc """
  Log cache metrics at debug level when present in response.
  """
  @spec log_cache_metrics(map()) :: :ok
  def log_cache_metrics(response) do
    usage = Map.get(response, :usage, %{})
    cache_read = Map.get(usage, :cache_read_input_tokens) || Map.get(usage, :cached_tokens)
    cache_write = Map.get(usage, :cache_creation_input_tokens)

    if cache_read || cache_write do
      Logger.debug("Cache metrics: read=#{cache_read || 0}, write=#{cache_write || 0}")
    end

    :ok
  end
end
