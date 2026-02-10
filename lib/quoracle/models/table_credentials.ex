defmodule Quoracle.Models.TableCredentials do
  @moduledoc """
  Ecto schema for storing encrypted model credentials in the database.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias Quoracle.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credentials" do
    field(:model_id, :string)
    field(:model_spec, :string)
    field(:api_key, Quoracle.Encrypted.Binary)
    field(:deployment_id, :string)
    field(:resource_id, :string)
    field(:endpoint_url, :string)
    field(:api_version, :string)
    field(:region, :string)

    timestamps()
  end

  # Provider is derived from model_spec prefix (e.g., "azure:o1" -> azure)
  @required_fields [:model_id, :model_spec, :api_key]
  @optional_fields [:deployment_id, :resource_id, :endpoint_url, :api_version, :region]

  @doc """
  Creates a changeset for credential with validation.
  """
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_model_spec_format()
    |> validate_provider_fields()
    |> unique_constraint(:model_id)
  end

  defp validate_model_spec_format(changeset) do
    validate_change(changeset, :model_spec, fn :model_spec, value ->
      if String.contains?(value, ":") do
        []
      else
        [model_spec: "must be in format provider:model"]
      end
    end)
  end

  # Validate provider-specific fields based on model_spec prefix
  defp validate_provider_fields(changeset) do
    model_spec = get_field(changeset, :model_spec)
    provider_prefix = get_provider_prefix(model_spec)

    case provider_prefix do
      "azure" ->
        changeset
        |> validate_required([:deployment_id],
          message: "can't be blank for Azure models"
        )

      "google-vertex" ->
        # For Google Vertex, we use resource_id for project_id
        changeset
        |> validate_required([:resource_id],
          message: "can't be blank for Google Vertex (used as project_id)"
        )

      _ ->
        changeset
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

  @doc """
  Inserts a new credential into the database.
  """
  def insert(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Fetches a credential by model_id.
  """
  def get_by_model_id(model_id) do
    case Repo.get_by(__MODULE__, model_id: model_id) do
      nil -> {:error, :not_found}
      credential -> {:ok, credential}
    end
  rescue
    Cloak.MissingCipher ->
      {:error, :decryption_failed}

    ArgumentError ->
      # Handle invalid encrypted data loading
      {:error, :decryption_failed}
  end

  @doc """
  Updates an existing credential.
  """
  def update_credential(credential, attrs) do
    credential
    |> changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Creates a new credential (alias for insert).
  """
  @spec create(map()) :: {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def create(%{credential_value: %{api_key: api_key}} = attrs) do
    attrs = Map.put(attrs, :api_key, api_key)
    insert(attrs)
  end

  @doc """
  Lists all credentials with optional pagination and ordering.

  ## Options
  - `:page` - Page number (1-indexed)
  - `:page_size` - Number of items per page
  - `:order_by` - Tuple of {:asc/:desc, field}

  ## Examples
      list_all(page: 1, page_size: 10)
      list_all(order_by: {:desc, :inserted_at})
  """
  @spec list_all(keyword()) :: [%__MODULE__{}]
  def list_all(opts \\ []) do
    query = __MODULE__

    query =
      if order_by = opts[:order_by] do
        import Ecto.Query
        {direction, field} = order_by
        order_by(query, [{^direction, ^field}])
      else
        import Ecto.Query
        # Default to deterministic order matching TableSecrets
        order_by(query, [c], desc: c.updated_at, asc: c.id)
      end

    query =
      if page = opts[:page] do
        import Ecto.Query
        page_size = opts[:page_size] || 20
        offset = (page - 1) * page_size
        query |> limit(^page_size) |> offset(^offset)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Fetches a credential by ID.

  ## Returns
  - {:ok, credential} on success
  - {:error, :not_found} if not found
  """
  @spec get_by_id(String.t()) :: {:ok, %__MODULE__{}} | {:error, :not_found}
  def get_by_id(id) do
    case Repo.get(__MODULE__, id) do
      nil -> {:error, :not_found}
      credential -> {:ok, credential}
    end
  end

  @doc """
  Deletes a credential.
  """
  @spec delete(%__MODULE__{}) :: {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def delete(credential) do
    Repo.delete(credential)
  end

  @doc """
  Updates a credential (alias for update_credential).
  """
  @spec update(%__MODULE__{}, map()) :: {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def update(credential, %{credential_value: %{api_key: api_key}} = attrs) do
    attrs = Map.put(attrs, :api_key, api_key)
    update_credential(credential, attrs)
  end
end
