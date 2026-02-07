defmodule Quoracle.Models.CredentialManager do
  @moduledoc """
  Manages LLM provider credentials by fetching from database.

  Credentials are stored encrypted and decrypted automatically on fetch.
  """

  alias Quoracle.Models.TableCredentials

  @doc """
  Lists all model_ids from the credentials table.
  Returns a list of string model_ids.
  """
  @spec list_model_ids() :: [String.t()]
  def list_model_ids do
    TableCredentials.list_all()
    |> Enum.map(& &1.model_id)
  end

  @doc """
  Fetches credentials for a model from the database.
  """
  @spec get_credentials(String.t()) :: {:ok, map()} | {:error, atom()}
  def get_credentials(model_id) when is_binary(model_id) do
    result = TableCredentials.get_by_model_id(model_id)

    case result do
      {:ok, credential} ->
        if credential.api_key == "" do
          {:error, :invalid_credential}
        else
          {:ok,
           Map.take(credential, [
             :model_id,
             :model_spec,
             :api_key,
             :deployment_id,
             :resource_id,
             :endpoint_url,
             :region,
             :api_version
           ])}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :decryption_failed} ->
        {:error, :decryption_failed}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, :database_error}

    Cloak.MissingCipher ->
      {:error, :decryption_failed}

    ArgumentError ->
      # Handle invalid encrypted data loading
      {:error, :decryption_failed}
  end
end
