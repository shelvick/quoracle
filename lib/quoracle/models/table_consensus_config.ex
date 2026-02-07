defmodule Quoracle.Models.TableConsensusConfig do
  @moduledoc """
  Ecto schema for model_settings table.
  Provides key-value JSONB storage for model configuration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Quoracle.Repo

  @type t :: %__MODULE__{
          id: binary() | nil,
          key: String.t() | nil,
          value: map() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "model_settings" do
    field(:key, :string)
    field(:value, :map)

    timestamps()
  end

  @required_fields [:key, :value]

  @doc """
  Changeset for creating/updating config entries.
  """
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs), do: changeset(%__MODULE__{}, attrs)

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, attrs) do
    config
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_length(:key, min: 1, max: 255)
    |> unique_constraint(:key)
  end

  @doc """
  Gets a config entry by key.
  """
  @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(key) when is_binary(key) do
    case Repo.get_by(__MODULE__, key: key) do
      nil -> {:error, :not_found}
      config -> {:ok, config}
    end
  end

  @doc """
  Inserts or updates a config entry (upsert).
  Uses atomic INSERT ON CONFLICT to avoid race conditions in parallel tests.
  """
  @spec upsert(String.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def upsert(key, value) when is_binary(key) and is_map(value) do
    %__MODULE__{}
    |> changeset(%{key: key, value: value})
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key,
      returning: true
    )
  end

  @doc """
  Deletes a config entry by key.
  """
  @spec delete(String.t()) :: {:ok, t()} | {:error, :not_found}
  def delete(key) when is_binary(key) do
    case get(key) do
      {:ok, config} -> Repo.delete(config)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Lists all config entries.
  """
  @spec list_all() :: [t()]
  def list_all do
    Repo.all(__MODULE__)
  end
end
