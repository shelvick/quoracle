defmodule QuoracleWeb.SecretManagementLive.ModelConfigHelpers do
  @moduledoc """
  Helper functions for model configuration tab in SecretManagementLive.
  Handles provider extraction, config validation, and model settings operations.
  """

  alias Quoracle.Models.{ConfigModelSettings, LocalModelHelper, TableCredentials}

  # =============================================================================
  # Provider Extraction
  # =============================================================================

  @doc """
  Extract and normalize provider from model_spec.
  E.g., "azure_openai:gpt-4o" -> "azure"
  """
  @spec extract_provider(String.t() | nil) :: String.t() | nil
  def extract_provider(nil), do: nil
  def extract_provider(""), do: nil

  def extract_provider(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [provider, _] -> normalize_provider(provider)
      _ -> nil
    end
  end

  @doc """
  Normalize provider names to canonical forms for provider-aware form fields.
  """
  @spec normalize_provider(String.t()) :: String.t()
  def normalize_provider(provider) do
    provider_lower = String.downcase(provider)

    cond do
      String.contains?(provider_lower, "azure") -> "azure"
      String.contains?(provider_lower, "google") -> "google-vertex"
      String.contains?(provider_lower, "bedrock") -> "amazon-bedrock"
      true -> provider
    end
  end

  # =============================================================================
  # Credentialed Models
  # =============================================================================

  @doc """
  Load credentials for model config dropdown (only models with credentials).
  Returns list of {label, model_id} tuples for select options.

  v6.0: Local models (those with endpoint_url) get a "(local)" suffix
  in the label to distinguish them from cloud models in dropdowns.
  """
  @spec load_credentialed_models() :: [{String.t(), String.t()}]
  def load_credentialed_models do
    TableCredentials.list_all()
    |> Enum.map(fn cred ->
      label =
        if LocalModelHelper.local_model?(cred) do
          "#{cred.model_id} (local)"
        else
          cred.model_id
        end

      {label, cred.model_id}
    end)
  end

  # =============================================================================
  # Config Validation
  # =============================================================================

  @doc """
  Check if credential is used in active model configuration (R18, R22).
  Returns warning message if in use, nil otherwise.
  """
  @spec check_credential_in_active_config(String.t()) :: String.t() | nil
  def check_credential_in_active_config(model_id) do
    settings = ConfigModelSettings.get_all()

    active_model_ids =
      [
        settings.embedding_model,
        settings.answer_engine_model,
        settings.summarization_model
        | settings.image_generation_models || []
      ]

    if model_id in active_model_ids do
      "This credential is used in active model configuration"
    else
      nil
    end
  end

  # =============================================================================
  # Config Setters
  # =============================================================================

  @doc """
  Set embedding model if provided (non-nil, non-empty).
  """
  @spec maybe_set_embedding(String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def maybe_set_embedding(value), do: maybe_set(value, &ConfigModelSettings.set_embedding_model/1)

  @doc """
  Set answer engine model if provided (non-nil, non-empty).
  """
  @spec maybe_set_answer_engine(String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def maybe_set_answer_engine(value),
    do: maybe_set(value, &ConfigModelSettings.set_answer_engine_model/1)

  @doc """
  Set summarization model if provided (non-nil, non-empty).
  """
  @spec maybe_set_summarization(String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def maybe_set_summarization(value),
    do: maybe_set(value, &ConfigModelSettings.set_summarization_model/1)

  # Generic setter: applies setter_fn only when value is non-nil and non-empty.
  @spec maybe_set(String.t() | nil, (String.t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, String.t() | nil} | {:error, term()}
  defp maybe_set(nil, _setter_fn), do: {:ok, nil}
  defp maybe_set("", _setter_fn), do: {:ok, nil}
  defp maybe_set(value, setter_fn), do: setter_fn.(value)

  # =============================================================================
  # Chat-Capable Model Filtering (R19)
  # =============================================================================

  @doc """
  Load chat-capable models for summarization dropdown.
  Filters out embedding-only models (models with 'embedding' in their spec).
  """
  @spec load_chat_capable_models() :: [{String.t(), String.t()}]
  def load_chat_capable_models do
    TableCredentials.list_all()
    |> Enum.reject(&embedding_only_model?/1)
    |> Enum.map(fn cred -> {cred.model_id, cred.model_id} end)
  end

  # Check if a credential is for an embedding-only model
  defp embedding_only_model?(%{model_spec: nil}), do: false
  defp embedding_only_model?(%{model_spec: ""}), do: false

  defp embedding_only_model?(%{model_spec: spec}) when is_binary(spec) do
    spec_lower = String.downcase(spec)
    String.contains?(spec_lower, "embedding")
  end

  defp embedding_only_model?(_), do: false

  # =============================================================================
  # Image-Capable Model Filtering (R23-R28)
  # =============================================================================

  alias Quoracle.Models.LLMDBModelLoader

  @doc """
  Load image-capable models from LLMDB.
  Returns list of {label, model_spec} tuples.
  """
  @spec load_image_capable_models() :: [{String.t(), String.t()}]
  def load_image_capable_models do
    LLMDBModelLoader.image_generation_models()
  end

  @doc """
  Filter credentialed models to only image-capable ones.

  v6.0: Local models (those with endpoint_url) bypass the LLMDB filter
  and are always included -- the user decides if their local model
  supports image generation.
  """
  @spec filter_image_models([{String.t(), String.t()}], [{String.t(), String.t()}]) ::
          [{String.t(), String.t()}]
  def filter_image_models(credentialed_models, image_capable_models) do
    image_specs = image_capable_models |> Enum.map(fn {_, spec} -> spec end) |> MapSet.new()

    # Single bulk query instead of N individual get_by_model_id calls
    cred_by_model_id =
      TableCredentials.list_all()
      |> Map.new(fn cred -> {cred.model_id, cred} end)

    Enum.filter(credentialed_models, fn {_, model_id} ->
      case Map.get(cred_by_model_id, model_id) do
        nil ->
          false

        cred ->
          # v6.0: Local models bypass LLMDB filter
          LocalModelHelper.local_model?(cred) or MapSet.member?(image_specs, cred.model_spec)
      end
    end)
  end

  @doc """
  Set image generation models. Empty list is valid (feature is optional per R28).
  """
  @spec maybe_set_image_generation([String.t()] | nil) ::
          {:ok, [String.t()] | nil} | {:error, term()}
  def maybe_set_image_generation(nil), do: {:ok, nil}

  def maybe_set_image_generation(model_ids),
    do: ConfigModelSettings.set_image_generation_models(model_ids)

  # =============================================================================
  # Save Model Config
  # =============================================================================

  @doc """
  Save all model configuration settings.
  Returns {:ok, config_map} or {:error, reason}.
  """
  @spec save_model_config(map()) :: {:ok, map()} | {:error, term()}
  def save_model_config(params) do
    embedding_model = params["embedding_model"]
    answer_engine_model = params["answer_engine_model"]
    summarization_model = params["summarization_model"]
    image_generation_models = params["image_generation_models"] || []

    with {:ok, _} <- maybe_set_embedding(embedding_model),
         {:ok, _} <- maybe_set_answer_engine(answer_engine_model),
         {:ok, _} <- maybe_set_summarization(summarization_model),
         {:ok, _} <- maybe_set_image_generation(image_generation_models) do
      {:ok,
       %{
         embedding_model: embedding_model,
         answer_engine_model: answer_engine_model,
         summarization_model: summarization_model,
         image_generation_models: image_generation_models
       }}
    end
  end
end
