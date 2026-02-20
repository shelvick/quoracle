defmodule QuoracleWeb.SecretManagementLive.ValidationHelpers do
  @moduledoc """
  Validation helper functions for credential fields.
  Extracted from SecretManagementLive to keep it under 500 lines.
  """

  alias Quoracle.Models.TableCredentials

  @credential_fields [
    :model_id,
    :model_spec,
    :api_key,
    :deployment_id,
    :resource_id,
    :endpoint_url,
    :region
  ]

  @doc """
  Builds a validated credential changeset from params.
  Used by validate_credential event handler.

  v6.0: api_key is conditionally required. When endpoint_url is present
  (local model), api_key becomes optional. Cloud models (no endpoint_url)
  still require api_key with specific error message.
  """
  @spec build_credential_changeset(%TableCredentials{} | nil, map()) :: Ecto.Changeset.t()
  def build_credential_changeset(credential, params) do
    base = credential || %TableCredentials{}

    base
    |> Ecto.Changeset.cast(params, @credential_fields)
    |> Ecto.Changeset.validate_required([:model_id])
    |> validate_api_key_requirement()
    |> validate_azure_credential_fields()
    |> validate_api_key_format()
    |> Map.put(:action, :validate)
  end

  # v6.0: Require api_key only when no endpoint_url is present.
  # Local models with endpoint_url don't need api_key.
  defp validate_api_key_requirement(changeset) do
    endpoint_url = Ecto.Changeset.get_field(changeset, :endpoint_url)
    api_key = Ecto.Changeset.get_field(changeset, :api_key)

    endpoint_blank? = is_nil(endpoint_url) or endpoint_url == ""
    api_key_blank? = is_nil(api_key) or api_key == ""

    if endpoint_blank? and api_key_blank? do
      Ecto.Changeset.add_error(
        changeset,
        :api_key,
        "api_key is required when no endpoint_url is provided"
      )
    else
      changeset
    end
  end

  @doc """
  Validates that Azure-specific fields (deployment_id) are present
  when model_spec starts with "azure:".
  """
  @spec validate_azure_credential_fields(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_azure_credential_fields(changeset) do
    model_spec = Ecto.Changeset.get_field(changeset, :model_spec)
    provider = get_provider_prefix(model_spec)

    if provider == "azure" do
      changeset
      |> Ecto.Changeset.validate_required([:deployment_id],
        message: "can't be blank for Azure models"
      )
    else
      changeset
    end
  end

  @doc """
  Validates API key format based on provider prefix from model_spec.
  Anthropic keys should start with "sk-ant-", OpenAI keys with "sk-".
  """
  @spec validate_api_key_format(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_api_key_format(changeset) do
    endpoint_url = Ecto.Changeset.get_field(changeset, :endpoint_url)

    # v6.0: Skip format check for local models (endpoint_url present)
    if endpoint_url && endpoint_url != "" do
      changeset
    else
      model_spec = Ecto.Changeset.get_field(changeset, :model_spec)
      api_key = Ecto.Changeset.get_field(changeset, :api_key)
      provider = get_provider_prefix(model_spec)

      case {provider, api_key} do
        {"anthropic", key} when is_binary(key) ->
          if String.starts_with?(key, "sk-ant-"),
            do: changeset,
            else: Ecto.Changeset.add_error(changeset, :api_key, "Invalid API key format")

        {"openai", key} when is_binary(key) ->
          if String.starts_with?(key, "sk-"),
            do: changeset,
            else: Ecto.Changeset.add_error(changeset, :api_key, "Invalid API key format")

        _ ->
          changeset
      end
    end
  end

  # Extract provider prefix from model_spec (e.g., "azure:o1" -> "azure")
  defp get_provider_prefix(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [prefix, _rest] -> prefix
      _ -> "unknown"
    end
  end

  defp get_provider_prefix(_), do: "unknown"

  # =============================================================================
  # Credential Param Processing
  # =============================================================================

  @doc """
  Extract and normalize model_spec from params.

  v6.0: Custom model_spec text input takes precedence over known_model_spec
  dropdown. Falls back to known_model_spec, then model_id.
  """
  @spec extract_model_spec(map()) :: String.t() | nil
  def extract_model_spec(params) do
    case non_blank(params["model_spec"]) do
      nil ->
        case non_blank(params["known_model_spec"]) do
          nil -> params["model_id"]
          known -> known
        end

      spec ->
        spec
    end
  end

  defp non_blank(nil), do: nil
  defp non_blank(""), do: nil
  defp non_blank(value), do: value

  @doc """
  Normalize params with extracted model_spec.
  Auto-populates model_id from model_spec if empty.
  """
  @spec normalize_credential_params(map()) :: map()
  def normalize_credential_params(params) do
    model_spec = extract_model_spec(params)

    params
    |> Map.put("model_spec", model_spec)
    |> then(fn p ->
      if p["model_id"] in [nil, ""], do: Map.put(p, "model_id", model_spec), else: p
    end)
  end

  @doc """
  Build credential params map for insert/update.
  """
  @spec build_credential_params(map()) :: map()
  def build_credential_params(params) do
    model_spec = extract_model_spec(params)

    %{
      model_id: params["model_id"] || model_spec,
      model_spec: model_spec,
      api_key: params["api_key"],
      endpoint_url: params["endpoint_url"],
      deployment_id: params["deployment_id"],
      resource_id: params["resource_id"],
      region: params["region"]
    }
  end
end
