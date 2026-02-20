defmodule Quoracle.Models.LocalModelHelper do
  @moduledoc """
  Shared helper functions for local model routing (vLLM, Ollama, LM Studio, etc.).

  Consolidates provider classification, model_spec parsing, and LLMDB bypass
  logic used by ModelQuery, Embeddings, and UI ModelConfigHelpers.
  """

  require Logger

  # Map of local model provider strings to atoms, ensuring they exist
  # at compile time for safe atom conversion in split_model_spec/1.
  @local_providers %{
    "vllm" => :vllm,
    "ollama" => :ollama,
    "lmstudio" => :lmstudio,
    "llamacpp" => :llamacpp,
    "tgi" => :tgi
  }

  # Cloud provider prefixes that should NOT trigger the local model bypass.
  # These providers use endpoint_url as a standard field but route through LLMDB.
  @cloud_provider_prefixes ["azure", "google", "bedrock", "vertex", "amazon"]

  @doc """
  Check if a model_spec string represents a cloud provider that should NOT
  use the local model bypass. Azure, Vertex, and Bedrock use endpoint_url
  as a standard field but route through LLMDB.
  """
  @spec cloud_provider?(String.t() | nil) :: boolean()
  def cloud_provider?(nil), do: false
  def cloud_provider?(""), do: false

  def cloud_provider?(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [prefix, _] ->
        prefix_lower = String.downcase(prefix)

        Enum.any?(@cloud_provider_prefixes, fn cloud ->
          String.contains?(prefix_lower, cloud)
        end)

      _ ->
        false
    end
  end

  @doc """
  Extract provider and model name from a model_spec string.

  ## Examples

      iex> split_model_spec("vllm:llama3")
      {"vllm", "llama3"}

      iex> split_model_spec("unknown")
      {"unknown", "unknown"}
  """
  @spec split_model_spec(String.t()) :: {String.t(), String.t()}
  def split_model_spec(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [provider, model_name] -> {provider, model_name}
      _ -> {"unknown", model_spec}
    end
  end

  @doc """
  Check if a credential struct represents a local model.

  Local models have a non-empty endpoint_url and are NOT cloud providers
  (Azure/Vertex/Bedrock). Authenticated local models (with api_key) are
  still considered local per R13.
  """
  @spec local_model?(map()) :: boolean()
  def local_model?(%{endpoint_url: url, model_spec: model_spec})
      when is_binary(url) and url != "" do
    not cloud_provider?(model_spec)
  end

  def local_model?(_), do: false

  @doc """
  Resolve the model reference for ReqLLM. When the credential has an
  endpoint_url and is not a cloud provider, constructs a map to bypass
  the LLMDB catalog. Otherwise returns the string model_spec for LLMDB
  routing.

  Returns either a `%{id: model_name, provider: atom}` map or the
  original string model_spec.
  """
  @spec resolve_model_ref(String.t(), map() | struct()) :: map() | String.t()
  def resolve_model_ref(model_spec, credential) do
    if Map.get(credential, :endpoint_url) && not cloud_provider?(model_spec) do
      {provider_str, model_name} = split_model_spec(model_spec)

      case Map.get(@local_providers, provider_str) do
        nil ->
          Logger.warning(
            "Unknown local provider prefix: #{provider_str}, using string model_spec path"
          )

          model_spec

        provider_atom ->
          %{id: model_name, provider: provider_atom}
      end
    else
      model_spec
    end
  end
end
