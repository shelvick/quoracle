defmodule Quoracle.Providers.ReqLLMCredentials do
  @moduledoc """
  Formats credentials from CredentialManager for req_llm per-request injection.

  This module bridges the gap between Quoracle's credential storage and
  req_llm's expected credential format for each provider.
  """

  alias Quoracle.Models.CredentialManager

  @doc """
  Formats Google Vertex AI credentials for req_llm.

  Returns keyword list with:
  - `:service_account_json` - The service account JSON string
  - `:project_id` - The GCP project ID
  - `:region` - The Vertex AI region (defaults to "global" for Gemini 3 support)
  """
  @spec for_google(String.t()) :: {:ok, keyword()} | {:error, atom()}
  def for_google(model_id) do
    case CredentialManager.get_credentials(model_id) do
      {:ok, creds} ->
        region = creds.region || "global"

        {:ok,
         [
           service_account_json: creds.api_key,
           project_id: creds.resource_id,
           region: region
         ]}

      error ->
        error
    end
  end

  @doc """
  Formats AWS Bedrock credentials for req_llm.

  Returns keyword list with:
  - `:access_key_id` - The AWS access key ID
  - `:secret_access_key` - The AWS secret access key
  - `:region` - The AWS region extracted from endpoint URL
  """
  @spec for_bedrock(String.t()) :: {:ok, keyword()} | {:error, atom()}
  def for_bedrock(model_id) do
    with {:ok, creds} <- CredentialManager.get_credentials(model_id) do
      case String.split(creds.api_key, ":") do
        [access_key, secret_key] ->
          region = extract_region(creds.endpoint_url)

          {:ok,
           [
             access_key_id: access_key,
             secret_access_key: secret_key,
             region: region
           ]}

        _ ->
          {:error, :invalid_credential}
      end
    end
  end

  @doc """
  Formats Azure OpenAI credentials for req_llm.

  Returns keyword list with:
  - `:api_key` - The Azure API key
  - `:resource_name` - The Azure resource name
  - `:deployment_name` - The deployment/model name
  - `:api_version` - The API version (defaults to "2024-02-15-preview")
  """
  @spec for_azure(String.t()) :: {:ok, keyword()} | {:error, atom()}
  def for_azure(model_id) do
    with {:ok, creds} <- CredentialManager.get_credentials(model_id) do
      {:ok,
       [
         api_key: creds.api_key,
         resource_name: creds.resource_id,
         deployment_name: creds.deployment_id,
         api_version: "2024-02-15-preview"
       ]}
    end
  end

  # Private helpers

  defp extract_region(nil), do: "us-east-1"

  defp extract_region(endpoint_url) when is_binary(endpoint_url) do
    # Extract region from AWS endpoint URLs like:
    # https://bedrock-runtime.us-west-2.amazonaws.com
    # https://bedrock.ap-northeast-1.amazonaws.com
    case Regex.run(~r/\.([a-z]{2}-[a-z]+-\d)\.amazonaws\.com/, endpoint_url) do
      [_, region] -> region
      nil -> "us-east-1"
    end
  end
end
