defmodule Quoracle.Actions.AnswerEngine do
  @moduledoc """
  Action module for getting web-grounded answers using Google Gemini.
  Uses Gemini's grounding feature to provide up-to-date information from the web.
  Calls ReqLLM directly (no provider wrapper needed).
  """

  alias Quoracle.Models.ModelQuery.UsageHelper
  require Logger

  @doc """
  Executes a grounded answer query using Google Gemini.

  ## Parameters
  - `params`: Map with:
    - `:prompt` (required, string) - Question to answer with web grounding
  - `agent_id`: ID of requesting agent (unused for this action)
  - `opts`: Keyword list with:
    - `:model_config` - Optional model config map (for testing)
    - `:plug` - Optional Req plug for HTTP stubbing (for testing)
    - `:access_token` - Optional GCP access token (for testing, skips JWT signing)

  ## Returns
  - `{:ok, result_map}` - Success with answer, sources, model, execution_time_ms
  - `{:error, reason}` - Validation or execution errors
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def execute(%{prompt: prompt} = _params, _agent_id, opts)
      when is_binary(prompt) and prompt != "" do
    with {:ok, model_config} <- get_model_config(opts),
         {:ok, credentials} <- get_credentials(model_config, opts),
         {:ok, response} <- call_gemini_with_grounding(prompt, credentials, opts) do
      # Extract content and grounding metadata from ReqLLM.Response
      content = extract_content(response)
      grounding_metadata = extract_grounding_metadata(response)
      sources = extract_sources(grounding_metadata)

      # Log warning if no grounding data
      if grounding_metadata == nil or sources == [] do
        Logger.warning("No grounding metadata available for answer engine query")
      end

      # Record cost if context provided (R11-R14)
      record_cost(response, model_config, sources, opts)

      {:ok,
       %{
         action: "answer_engine",
         answer: content,
         sources: sources,
         model_used: to_string(model_config.model_spec)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%{prompt: ""}, _agent_id, _opts), do: {:error, :missing_required_param}
  def execute(%{prompt: nil}, _agent_id, _opts), do: {:error, :missing_required_param}

  def execute(%{prompt: prompt}, _agent_id, _opts) when not is_binary(prompt),
    do: {:error, :invalid_param_type}

  def execute(_params, _agent_id, _opts), do: {:error, :missing_required_param}

  @doc """
  Extracts text content from ReqLLM.Response or normalized map.
  """
  @spec extract_content(map()) :: String.t()
  def extract_content(%ReqLLM.Response{} = response), do: ReqLLM.Response.text(response) || ""
  def extract_content(%{content: content}) when is_binary(content), do: content
  def extract_content(_), do: ""

  @doc """
  Extracts grounding metadata from ReqLLM.Response or normalized map.
  """
  @spec extract_grounding_metadata(map()) :: map() | nil
  def extract_grounding_metadata(%ReqLLM.Response{provider_meta: provider_meta}) do
    extract_grounding_from_meta(provider_meta)
  end

  def extract_grounding_metadata(%{provider_meta: provider_meta}) do
    extract_grounding_from_meta(provider_meta)
  end

  def extract_grounding_metadata(_), do: nil

  defp extract_grounding_from_meta(nil), do: nil

  defp extract_grounding_from_meta(%{"google" => google_meta}) do
    Map.get(google_meta, "groundingMetadata") || Map.get(google_meta, "grounding_metadata")
  end

  defp extract_grounding_from_meta(_), do: nil

  @doc """
  Extracts source URLs and titles from grounding metadata.
  """
  @spec extract_sources(map() | nil) :: list(map())
  def extract_sources(nil), do: []

  def extract_sources(grounding_metadata) when is_map(grounding_metadata) do
    grounding_metadata
    |> Map.get("groundingChunks", [])
    |> Enum.map(fn chunk ->
      web = get_in(chunk, ["web"]) || %{}

      %{
        url: Map.get(web, "uri", ""),
        title: Map.get(web, "title", ""),
        snippet: ""
      }
    end)
    |> Enum.reject(fn source -> source.url == "" end)
  end

  # Private functions

  defp get_model_config(opts) do
    case Keyword.get(opts, :model_config) do
      nil -> get_configured_model()
      model_config when is_map(model_config) -> {:ok, model_config}
    end
  end

  defp get_configured_model do
    alias Quoracle.Models.ConfigModelSettings

    case ConfigModelSettings.get_answer_engine_model() do
      {:ok, model_id} ->
        # Fetch credentials to get proper model_spec and GCP config for ReqLLM
        case Quoracle.Models.CredentialManager.get_credentials(model_id) do
          {:ok, creds} ->
            {:ok,
             %{
               model_id: model_id,
               model_spec: Map.get(creds, :model_spec, model_id),
               resource_id: Map.get(creds, :resource_id),
               region: Map.get(creds, :region)
             }}

          {:error, _} ->
            {:ok, %{model_id: model_id, model_spec: model_id}}
        end

      {:error, :not_configured} ->
        raise RuntimeError, "Answer engine model not configured in CONFIG_ModelSettings"
    end
  end

  defp get_credentials(model_config, opts) do
    # For tests with force_error, return error immediately
    if Map.get(model_config, :force_error) do
      {:error, :provider_error}
    else
      # Test can pass access_token directly to skip JWT signing
      if access_token = Keyword.get(opts, :access_token) do
        {:ok, %{access_token: access_token, model_config: model_config}}
      else
        # Get credentials from database
        model_id_str = to_string(model_config.model_id)

        case Quoracle.Models.CredentialManager.get_credentials(model_id_str) do
          {:ok, creds} -> {:ok, Map.put(creds, :model_config, model_config)}
          {:error, _} -> {:error, :provider_error}
        end
      end
    end
  end

  defp call_gemini_with_grounding(prompt, credentials, opts) do
    # Get model spec from credentials (already includes provider prefix)
    model_spec = get_model_spec(credentials)

    # Build messages
    messages = [ReqLLM.Context.user(prompt)]

    # Build ReqLLM options with conditional grounding
    req_opts = build_req_opts(credentials, model_spec, opts)

    case ReqLLM.generate_text(model_spec, messages, req_opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, %ReqLLM.Error.API.Request{status: status}} when status in [401, 403] ->
        {:error, :authentication_failed}

      {:error, %ReqLLM.Error.API.Request{status: 429}} ->
        {:error, :rate_limit_exceeded}

      {:error, %ReqLLM.Error.API.Request{status: status}} when status >= 500 ->
        {:error, :service_unavailable}

      {:error, _} ->
        {:error, :provider_error}
    end
  end

  defp get_model_spec(%{model_config: %{model_spec: model_spec}}) when is_binary(model_spec) do
    model_spec
  end

  defp get_model_spec(%{model_spec: model_spec}) when is_binary(model_spec) do
    model_spec
  end

  defp get_model_spec(_), do: "google-vertex:gemini-2.0-flash"

  defp google_model?(model_spec) do
    String.starts_with?(model_spec, "google_vertex:") or
      String.starts_with?(model_spec, "google-vertex:") or
      String.starts_with?(model_spec, "google:")
  end

  defp build_req_opts(credentials, model_spec, opts) do
    base_opts = []

    # Add auth - either access_token or service_account_json
    base_opts =
      cond do
        Map.has_key?(credentials, :access_token) ->
          Keyword.put(base_opts, :access_token, credentials.access_token)

        Map.has_key?(credentials, :api_key) ->
          # api_key contains the service account JSON string
          Keyword.put(base_opts, :service_account_json, credentials.api_key)

        true ->
          base_opts
      end

    # Add project_id and region (check both credentials and nested model_config)
    model_config = credentials[:model_config] || %{}
    project_id = credentials[:resource_id] || model_config[:resource_id]
    region = credentials[:region] || model_config[:region] || "global"

    base_opts =
      base_opts
      |> maybe_add(:project_id, project_id)
      |> maybe_add(:region, region)

    # Add grounding for Google models only
    # google_grounding is a top-level option in the GoogleVertex provider schema
    base_opts =
      if google_model?(model_spec) do
        Keyword.put(base_opts, :google_grounding, %{enable: true})
      else
        base_opts
      end

    # Add plug for testing if provided
    if plug = Keyword.get(opts, :plug) do
      Keyword.put(base_opts, :req_http_options, plug: plug)
    else
      base_opts
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp record_cost(response, model_config, sources, opts) do
    options = %{
      agent_id: Keyword.get(opts, :agent_id),
      task_id: Keyword.get(opts, :task_id),
      pubsub: Keyword.get(opts, :pubsub),
      model_spec: to_string(model_config.model_spec)
    }

    extra_metadata = %{grounded: true, sources_count: length(sources)}
    UsageHelper.record_single_request(response, "llm_answer", options, extra_metadata)
  end
end
