defmodule Quoracle.Models.ConfigModelSettings do
  @moduledoc """
  Runtime configuration for model settings.
  Reads/writes consensus models, embedding model, and answer engine model from DB.
  Raises on missing configuration (no fallback to hardcoded defaults).
  """

  alias Quoracle.Models.CredentialManager
  alias Quoracle.Models.TableConsensusConfig

  @embedding_model_key "embedding_model"
  @answer_engine_model_key "answer_engine_model"
  @summarization_model_key "summarization_model"
  @image_generation_models_key "image_generation_models"
  @skills_path_key "skills_path"

  # =============================================================
  # Embedding Model (single model_id string)
  # =============================================================

  @doc """
  Gets the configured embedding model_id.
  Raises if not configured.
  """
  @spec get_embedding_model!() :: String.t()
  def get_embedding_model! do
    case get_embedding_model() do
      {:ok, model_id} ->
        model_id

      {:error, :not_configured} ->
        raise RuntimeError, "Embedding model not configured. Configure via Settings page."
    end
  end

  @doc """
  Gets embedding model, returns {:ok, model_id} or {:error, :not_configured}.
  """
  @spec get_embedding_model() :: {:ok, String.t()} | {:error, :not_configured}
  def get_embedding_model do
    case TableConsensusConfig.get(@embedding_model_key) do
      {:ok, %{value: %{"model_id" => model_id}}} when is_binary(model_id) ->
        {:ok, model_id}

      _ ->
        {:error, :not_configured}
    end
  end

  @doc """
  Sets the embedding model.
  """
  @spec set_embedding_model(String.t()) :: {:ok, String.t()} | {:error, term()}
  def set_embedding_model(model_id) when is_binary(model_id) do
    case TableConsensusConfig.upsert(@embedding_model_key, %{"model_id" => model_id}) do
      {:ok, _} -> {:ok, model_id}
      {:error, _} = error -> error
    end
  end

  # =============================================================
  # Answer Engine Model (single model_id string)
  # =============================================================

  @doc """
  Gets the configured answer engine model_id.
  Raises if not configured.
  """
  @spec get_answer_engine_model!() :: String.t()
  def get_answer_engine_model! do
    case get_answer_engine_model() do
      {:ok, model_id} ->
        model_id

      {:error, :not_configured} ->
        raise RuntimeError, "Answer engine model not configured. Configure via Settings page."
    end
  end

  @doc """
  Gets answer engine model, returns {:ok, model_id} or {:error, :not_configured}.
  """
  @spec get_answer_engine_model() :: {:ok, String.t()} | {:error, :not_configured}
  def get_answer_engine_model do
    case TableConsensusConfig.get(@answer_engine_model_key) do
      {:ok, %{value: %{"model_id" => model_id}}} when is_binary(model_id) ->
        {:ok, model_id}

      _ ->
        {:error, :not_configured}
    end
  end

  @doc """
  Sets the answer engine model.
  """
  @spec set_answer_engine_model(String.t()) :: {:ok, String.t()} | {:error, term()}
  def set_answer_engine_model(model_id) when is_binary(model_id) do
    case TableConsensusConfig.upsert(@answer_engine_model_key, %{"model_id" => model_id}) do
      {:ok, _} -> {:ok, model_id}
      {:error, _} = error -> error
    end
  end

  # =============================================================
  # Summarization Model (single model_id string)
  # =============================================================

  @doc """
  Gets the configured summarization model_id.
  Raises if not configured.
  """
  @spec get_summarization_model!() :: String.t()
  def get_summarization_model! do
    case get_summarization_model() do
      {:ok, model_id} ->
        model_id

      {:error, :not_configured} ->
        raise RuntimeError, "Summarization model not configured. Configure via Settings page."
    end
  end

  @doc """
  Gets summarization model, returns {:ok, model_id} or {:error, :not_configured}.
  """
  @spec get_summarization_model() :: {:ok, String.t()} | {:error, :not_configured}
  def get_summarization_model do
    case TableConsensusConfig.get(@summarization_model_key) do
      {:ok, %{value: %{"model_id" => model_id}}} when is_binary(model_id) ->
        {:ok, model_id}

      _ ->
        {:error, :not_configured}
    end
  end

  @doc """
  Sets the summarization model.
  """
  @spec set_summarization_model(String.t()) :: {:ok, String.t()} | {:error, term()}
  def set_summarization_model(model_id) when is_binary(model_id) do
    case TableConsensusConfig.upsert(@summarization_model_key, %{"model_id" => model_id}) do
      {:ok, _} -> {:ok, model_id}
      {:error, _} = error -> error
    end
  end

  # =============================================================
  # Image Generation Models (list of model_id strings)
  # =============================================================

  @doc """
  Gets the list of model_ids for image generation.
  Raises if not configured.
  """
  @spec get_image_generation_models!() :: [String.t()]
  def get_image_generation_models! do
    case get_image_generation_models() do
      {:ok, models} ->
        models

      {:error, :not_configured} ->
        raise RuntimeError,
              "Image generation models not configured. Configure via Settings page."
    end
  end

  @doc """
  Gets image generation models, returns {:ok, list} or {:error, :not_configured}.
  Empty list is valid (feature is optional per R28).
  """
  @spec get_image_generation_models() :: {:ok, [String.t()]} | {:error, :not_configured}
  def get_image_generation_models do
    case TableConsensusConfig.get(@image_generation_models_key) do
      {:ok, %{value: %{"models" => models}}} when is_list(models) ->
        {:ok, models}

      _ ->
        {:error, :not_configured}
    end
  end

  @doc """
  Sets the image generation model list. Empty list is valid (feature is optional per R28).
  """
  @spec set_image_generation_models([String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def set_image_generation_models(model_ids) when is_list(model_ids) do
    if Enum.all?(model_ids, &is_binary/1) do
      case TableConsensusConfig.upsert(@image_generation_models_key, %{"models" => model_ids}) do
        {:ok, _} -> {:ok, model_ids}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_model_ids}
    end
  end

  # =============================================================
  # Skills Path (single path string)
  # =============================================================

  @doc """
  Gets the configured skills directory path.
  Returns {:ok, path} or {:error, :not_configured}.
  """
  @spec get_skills_path() :: {:ok, String.t()} | {:error, :not_configured}
  def get_skills_path do
    case TableConsensusConfig.get(@skills_path_key) do
      {:ok, %{value: %{"path" => path}}} when is_binary(path) and path != "" ->
        {:ok, path}

      _ ->
        {:error, :not_configured}
    end
  end

  @doc """
  Sets the skills directory path.
  Rejects empty strings.
  """
  @spec set_skills_path(String.t()) :: {:ok, String.t()} | {:error, :empty_path | term()}
  def set_skills_path(""), do: {:error, :empty_path}

  def set_skills_path(path) when is_binary(path) do
    case TableConsensusConfig.upsert(@skills_path_key, %{"path" => path}) do
      {:ok, _} -> {:ok, path}
      {:error, _} = error -> error
    end
  end

  @doc """
  Deletes the skills path configuration.
  """
  @spec delete_skills_path() :: {:ok, term()} | {:error, :not_found}
  def delete_skills_path do
    TableConsensusConfig.delete(@skills_path_key)
  end

  # =============================================================
  # Bulk Operations
  # =============================================================

  @doc """
  Gets all model settings as a map.
  """
  @spec get_all() :: %{
          embedding_model: String.t() | nil,
          answer_engine_model: String.t() | nil,
          summarization_model: String.t() | nil,
          image_generation_models: [String.t()] | nil,
          skills_path: String.t() | nil
        }
  def get_all do
    %{
      embedding_model: get_value_or_nil(get_embedding_model()),
      answer_engine_model: get_value_or_nil(get_answer_engine_model()),
      summarization_model: get_value_or_nil(get_summarization_model()),
      image_generation_models: get_value_or_nil(get_image_generation_models()),
      skills_path: get_value_or_nil(get_skills_path())
    }
  end

  defp get_value_or_nil({:ok, value}), do: value
  defp get_value_or_nil({:error, _}), do: nil

  @doc """
  Checks if all required settings are configured.
  """
  @spec configured?() :: boolean()
  def configured? do
    case get_all() do
      %{
        embedding_model: emb,
        answer_engine_model: ans,
        summarization_model: sum
      }
      when is_binary(emb) and is_binary(ans) and is_binary(sum) ->
        true

      _ ->
        false
    end
  end

  # =============================================================
  # Model Pool Validation (v4.0)
  # =============================================================

  @doc """
  Validates that all model IDs in the pool exist in credentials.

  Returns :ok if all valid, {:error, :invalid_models} if any invalid or empty.
  """
  @spec validate_model_pool([String.t()]) :: :ok | {:error, :invalid_models}
  def validate_model_pool([]), do: {:error, :invalid_models}

  def validate_model_pool(model_pool) when is_list(model_pool) do
    valid_model_ids = CredentialManager.list_model_ids() |> MapSet.new()

    if Enum.all?(model_pool, &MapSet.member?(valid_model_ids, &1)) do
      :ok
    else
      {:error, :invalid_models}
    end
  end
end
