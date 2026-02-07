defmodule Quoracle.Models.ModelQuery.OptionsBuilder do
  @moduledoc """
  Builds provider-specific options for LLM queries.
  Extracted from ModelQuery to keep module under 500 lines.
  """

  alias Quoracle.Models.ModelQuery.CacheHelper

  # Extended thinking config for Claude models on adapters (Bedrock/Vertex)
  @claude_thinking_config %{type: "enabled", budget_tokens: 16_000}

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
            api_key: credential.api_key,
            base_url: credential.endpoint_url,
            deployment: credential.deployment_id
          ]

          if skip_json_mode do
            base
          else
            Keyword.put(base, :provider_options, response_format: %{type: "json_object"})
          end

        "google-vertex" ->
          base = [
            on_unsupported: :ignore,
            service_account_json: credential.api_key,
            project_id: credential.resource_id,
            region: credential.region || "global"
          ]

          provider_opts =
            if claude_model?(credential.model_spec) do
              if skip_json_mode do
                [additional_model_request_fields: %{thinking: @claude_thinking_config}]
              else
                [
                  additional_model_request_fields: %{
                    thinking: @claude_thinking_config,
                    generationConfig: %{responseMimeType: "application/json"}
                  }
                ]
              end
            else
              if skip_json_mode do
                []
              else
                [
                  additional_model_request_fields: %{
                    generationConfig: %{responseMimeType: "application/json"}
                  }
                ]
              end
            end

          base_with_reasoning =
            if claude_model?(credential.model_spec) do
              base
            else
              Keyword.put(base, :reasoning_effort, :high)
            end

          if provider_opts == [] do
            base_with_reasoning
          else
            Keyword.put(base_with_reasoning, :provider_options, provider_opts)
          end

        "amazon-bedrock" ->
          case String.split(credential.api_key || "", ":", parts: 2) do
            [access_key, secret_key] when access_key != "" and secret_key != "" ->
              base_opts = [
                on_unsupported: :ignore,
                access_key_id: access_key,
                secret_access_key: secret_key,
                region: credential.region || "us-east-1"
              ]

              base_opts
              |> maybe_add_claude_thinking(credential.model_spec)
              |> CacheHelper.maybe_add_cache_options(options)

            _ ->
              base_opts = [
                on_unsupported: :ignore,
                api_key: credential.api_key,
                region: credential.region || "us-east-1"
              ]

              base_opts
              |> maybe_add_claude_thinking(credential.model_spec)
              |> CacheHelper.maybe_add_cache_options(options)
          end

        _ ->
          base = [
            on_unsupported: :ignore,
            reasoning_effort: :high,
            api_key: credential.api_key
          ]

          if skip_json_mode do
            base
          else
            Keyword.put(base, :provider_options, response_format: %{type: "json_object"})
          end
      end

    if plug = Map.get(options, :plug) do
      Keyword.put(base_opts, :req_http_options, plug: plug)
    else
      base_opts
    end
  end

  @doc false
  @spec get_provider_prefix(term()) :: String.t()
  def get_provider_prefix(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [prefix, _rest] -> String.replace(prefix, "_", "-")
      _ -> "unknown"
    end
  end

  def get_provider_prefix(_), do: "unknown"

  defp claude_model?(model_spec) when is_binary(model_spec) do
    downcased = String.downcase(model_spec)
    String.contains?(downcased, "claude") or String.contains?(downcased, "anthropic")
  end

  defp claude_model?(_), do: false

  defp maybe_add_claude_thinking(opts, model_spec) do
    if claude_model?(model_spec) do
      existing_provider_opts = Keyword.get(opts, :provider_options, [])

      new_provider_opts =
        Keyword.put(
          existing_provider_opts,
          :additional_model_request_fields,
          %{thinking: @claude_thinking_config}
        )

      Keyword.put(opts, :provider_options, new_provider_opts)
    else
      opts
    end
  end
end
