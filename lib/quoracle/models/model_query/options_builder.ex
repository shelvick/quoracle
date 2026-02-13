defmodule Quoracle.Models.ModelQuery.OptionsBuilder do
  @moduledoc """
  Builds provider-specific options for LLM queries.
  Extracted from ModelQuery to keep module under 500 lines.
  """

  alias Quoracle.Models.ModelQuery.CacheHelper

  # Override ReqLLM's default reasoning budget (4,096 for :high) with a
  # larger budget for Claude's extended thinking.  Harmlessly dropped for
  # non-Anthropic providers via on_unsupported: :ignore.
  @reasoning_token_budget 16_000

  @doc false
  @spec build_options(map(), map()) :: keyword()
  def build_options(credential, options) do
    provider_prefix = get_provider_prefix(credential.model_spec)
    skip_json_mode = Map.get(options, :skip_json_mode, false)

    base_opts =
      case provider_prefix do
        "azure" ->
          base = [
            on_unsupported: :ignore,
            reasoning_effort: :high,
            reasoning_token_budget: @reasoning_token_budget,
            api_key: credential.api_key,
            base_url: credential.endpoint_url,
            deployment: credential.deployment_id
          ]

          base = maybe_add_deepseek_thinking(base, credential.model_spec)

          if skip_json_mode do
            base
          else
            merge_provider_options(base, response_format: %{type: "json_object"})
          end

        "google-vertex" ->
          base = [
            on_unsupported: :ignore,
            reasoning_effort: :high,
            reasoning_token_budget: @reasoning_token_budget,
            service_account_json: credential.api_key,
            project_id: credential.resource_id,
            region: credential.region || "global"
          ]

          if skip_json_mode do
            base
          else
            merge_provider_options(base,
              additional_model_request_fields: %{
                generationConfig: %{responseMimeType: "application/json"}
              }
            )
          end

        "amazon-bedrock" ->
          base =
            case String.split(credential.api_key || "", ":", parts: 2) do
              [access_key, secret_key] when access_key != "" and secret_key != "" ->
                [
                  on_unsupported: :ignore,
                  reasoning_effort: :high,
                  reasoning_token_budget: @reasoning_token_budget,
                  access_key_id: access_key,
                  secret_access_key: secret_key,
                  region: credential.region || "us-east-1"
                ]

              _ ->
                [
                  on_unsupported: :ignore,
                  reasoning_effort: :high,
                  reasoning_token_budget: @reasoning_token_budget,
                  api_key: credential.api_key,
                  region: credential.region || "us-east-1"
                ]
            end

          CacheHelper.maybe_add_cache_options(base, options)

        _ ->
          base = [
            on_unsupported: :ignore,
            reasoning_effort: :high,
            reasoning_token_budget: @reasoning_token_budget,
            api_key: credential.api_key
          ]

          if skip_json_mode do
            base
          else
            Keyword.put(base, :provider_options, response_format: %{type: "json_object"})
          end
      end

    base_opts =
      if plug = Map.get(options, :plug) do
        Keyword.put(base_opts, :req_http_options, plug: plug)
      else
        base_opts
      end

    # Pass through caller-provided max_tokens (from dynamic calculation)
    # When present, this overrides ReqLLM's default of injecting LLMDB limits.output
    case Map.get(options, :max_tokens) do
      nil -> base_opts
      max_tokens -> Keyword.put(base_opts, :max_tokens, max_tokens)
    end
  end

  @doc "Builds provider-specific options for embedding requests."
  @spec build_embedding_options(map(), map()) :: keyword()
  def build_embedding_options(credential, options) do
    model_spec = Map.get(credential, :model_spec)
    provider_prefix = get_provider_prefix(model_spec)

    base_opts =
      case provider_prefix do
        "azure" ->
          build_azure_embedding_opts(credential)

        "google-vertex" ->
          [
            service_account_json: Map.get(credential, :api_key),
            project_id: Map.get(credential, :resource_id),
            region: Map.get(credential, :region) || "global"
          ]

        "amazon-bedrock" ->
          build_bedrock_embedding_opts(credential)

        _ ->
          # Default: OpenAI-compatible (just api_key)
          [api_key: Map.get(credential, :api_key)]
      end

    # Support plug injection for testing
    if plug = Map.get(options, :plug) do
      Keyword.put(base_opts, :req_http_options, plug: plug)
    else
      base_opts
    end
  end

  defp build_azure_embedding_opts(credential) do
    api_key = Map.get(credential, :api_key)
    base_url = Map.get(credential, :endpoint_url)
    deployment = Map.get(credential, :deployment_id)

    opts = [api_key: api_key]

    opts =
      if base_url do
        Keyword.put(opts, :base_url, base_url)
      else
        opts
      end

    if deployment do
      Keyword.put(opts, :deployment, deployment)
    else
      opts
    end
  end

  defp build_bedrock_embedding_opts(credential) do
    case String.split(Map.get(credential, :api_key) || "", ":", parts: 2) do
      [access_key, secret_key] when access_key != "" and secret_key != "" ->
        [
          access_key_id: access_key,
          secret_access_key: secret_key,
          region: Map.get(credential, :region) || "us-east-1"
        ]

      _ ->
        [
          api_key: Map.get(credential, :api_key),
          region: Map.get(credential, :region) || "us-east-1"
        ]
    end
  end

  @doc "Extracts the provider prefix from a model_spec string (e.g., `\"azure\"` from `\"azure:gpt-5\"`)."
  @spec get_provider_prefix(term()) :: String.t()
  def get_provider_prefix(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [prefix, _rest] -> String.replace(prefix, "_", "-")
      _ -> "unknown"
    end
  end

  def get_provider_prefix(_), do: "unknown"

  defp deepseek_model?(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [_prefix, model_id] -> String.starts_with?(model_id, "deepseek")
      _ -> false
    end
  end

  defp deepseek_model?(_), do: false

  defp maybe_add_deepseek_thinking(opts, model_spec) do
    if deepseek_model?(model_spec) do
      merge_provider_options(opts,
        additional_model_request_fields: %{thinking: %{type: "enabled"}}
      )
    else
      opts
    end
  end

  defp merge_provider_options(opts, new_provider_opts) do
    existing = Keyword.get(opts, :provider_options, [])
    Keyword.put(opts, :provider_options, Keyword.merge(existing, new_provider_opts))
  end
end
