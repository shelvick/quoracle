defmodule Quoracle.Models.TableSecrets do
  @moduledoc """
  Encrypted secret storage with template resolution support.

  Secrets are stored with Cloak encryption and can be referenced in action
  parameters using {{SECRET:name}} syntax.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Quoracle.Repo

  @primary_key {:id, :id, autogenerate: true}
  schema "secrets" do
    field(:name, :string)
    field(:value, :string, virtual: true)
    field(:encrypted_value, :binary)
    field(:description, :string)

    timestamps()
  end

  @doc """
  Creates a new secret with encrypted storage.

  ## Parameters
  - attrs: Map with :name, :value, and optional :description
  - opts: Keyword list with optional :pubsub for broadcasting and :topic for PubSub topic

  ## Returns
  - {:ok, secret} on success
  - {:error, changeset} on validation failure
  """
  @spec create(map(), keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs, opts \\ []) do
    result =
      %__MODULE__{}
      |> changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, secret} ->
        # Broadcast creation event if pubsub and topic provided
        if pubsub = opts[:pubsub] do
          if topic = opts[:topic] do
            Phoenix.PubSub.broadcast(pubsub, topic, {
              :secret_created,
              %{
                id: secret.id,
                name: secret.name,
                type: :secret,
                description: secret.description
              }
            })
          end
        end

        {:ok, secret}

      error ->
        error
    end
  end

  @doc """
  Retrieves and decrypts a secret by name.

  ## Returns
  - {:ok, secret} on success
  - {:error, :not_found} if secret doesn't exist
  - {:error, :decryption_failed} if decryption fails
  """
  @spec get_by_name(String.t()) :: {:ok, t()} | {:error, :not_found | :decryption_failed}
  def get_by_name(name) do
    case Repo.get_by(__MODULE__, name: name) do
      nil ->
        {:error, :not_found}

      secret ->
        try do
          {:ok, decrypt_value(secret)}
        rescue
          _ -> {:error, :decryption_failed}
        end
    end
  end

  @doc """
  Lists all secret names without values.

  ## Returns
  - {:ok, list of names}
  """
  @spec list_names() :: {:ok, [String.t()]}
  def list_names do
    names =
      __MODULE__
      |> select([s], s.name)
      |> Repo.all()

    {:ok, names}
  end

  @doc """
  Searches for secret names containing any of the provided terms.

  ## Parameters
  - terms: List of search strings (case-insensitive substring matching)

  ## Returns
  - {:ok, [matching_names]} - List of secret names matching any term

  ## Behavior
  - Empty terms list → returns {:ok, []}
  - Empty strings in terms list → filtered out before search
  - Case-insensitive matching (ILIKE)
  - PostgreSQL wildcards (% and _) are escaped for literal matching
  - Returns names only, never values
  """
  @spec search_by_terms([String.t()]) :: {:ok, [String.t()]}
  def search_by_terms(terms) when is_list(terms) do
    # Filter out empty strings
    valid_terms = Enum.filter(terms, &(&1 != "" and is_binary(&1)))

    case valid_terms do
      [] ->
        {:ok, []}

      terms ->
        # Escape PostgreSQL LIKE wildcards for literal matching
        escaped_terms = Enum.map(terms, &escape_like_wildcards/1)
        patterns = Enum.map(escaped_terms, &"%#{&1}%")

        names =
          __MODULE__
          |> where([s], fragment("? ILIKE ANY(?)", s.name, ^patterns))
          |> select([s], s.name)
          |> order_by([s], asc: s.name)
          |> Repo.all()

        {:ok, names}
    end
  end

  # Escapes PostgreSQL LIKE wildcards for literal matching
  defp escape_like_wildcards(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  Updates an existing secret.

  ## Parameters
  - name: Secret name to update
  - attrs: Map with fields to update
  - opts: Keyword list with optional :pubsub for broadcasting and :topic for PubSub topic

  ## Returns
  - {:ok, secret} on success
  - {:error, :not_found} if secret doesn't exist
  - {:error, changeset} on validation failure
  """
  @spec update(String.t(), map(), keyword()) ::
          {:ok, t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update(name, attrs, opts \\ []) do
    case Repo.get_by(__MODULE__, name: name) do
      nil ->
        {:error, :not_found}

      secret ->
        result =
          secret
          |> changeset(attrs)
          |> Repo.update()

        case result do
          {:ok, updated_secret} ->
            # Broadcast update event if pubsub and topic provided
            if pubsub = opts[:pubsub] do
              if topic = opts[:topic] do
                Phoenix.PubSub.broadcast(pubsub, topic, {
                  :secret_updated,
                  %{
                    id: updated_secret.id,
                    name: updated_secret.name,
                    type: :secret,
                    description: updated_secret.description
                  }
                })
              end
            end

            {:ok, updated_secret}

          error ->
            error
        end
    end
  end

  @doc """
  Deletes a secret by name.

  ## Parameters
  - name: Secret name to delete
  - opts: Keyword list with optional :pubsub for broadcasting and :topic for PubSub topic

  ## Returns
  - {:ok, deleted_secret} on success
  - {:error, :not_found} if secret doesn't exist
  """
  @spec delete(String.t(), keyword()) :: {:ok, t()} | {:error, :not_found}
  def delete(name, opts \\ []) do
    case Repo.get_by(__MODULE__, name: name) do
      nil ->
        {:error, :not_found}

      secret ->
        {:ok, _} = Repo.delete(secret)

        # Broadcast deletion event if pubsub and topic provided
        if pubsub = opts[:pubsub] do
          if topic = opts[:topic] do
            Phoenix.PubSub.broadcast(pubsub, topic, {
              :secret_deleted,
              %{
                id: secret.id,
                name: secret.name,
                type: :secret
              }
            })
          end
        end

        {:ok, secret}
    end
  end

  @doc """
  Lists all secrets.

  ## Returns
  - List of all secrets
  """
  @spec list_all() :: [t()]
  def list_all do
    __MODULE__
    |> order_by([s], desc: s.updated_at, asc: s.id)
    |> Repo.all()
  end

  @doc """
  Resolves multiple secrets in a single batch query.

  ## Parameters
  - names: List of secret names to resolve

  ## Returns
  - {:ok, map of name => value} on success
  - {:error, :secret_not_found, name} if any secret is missing
  """
  @spec resolve_secrets([String.t()]) ::
          {:ok, %{String.t() => String.t()}} | {:error, :secret_not_found, String.t()}
  def resolve_secrets(names) do
    unique_names = Enum.uniq(names)

    secrets =
      __MODULE__
      |> where([s], s.name in ^unique_names)
      |> Repo.all()

    found_names = MapSet.new(secrets, & &1.name)
    requested_names = MapSet.new(unique_names)

    case MapSet.difference(requested_names, found_names) |> MapSet.to_list() do
      [missing | _] ->
        {:error, :secret_not_found, missing}

      [] ->
        resolved =
          secrets
          |> Enum.map(fn secret ->
            decrypted = decrypt_value(secret)
            {decrypted.name, decrypted.value}
          end)
          |> Map.new()

        {:ok, resolved}
    end
  end

  @doc """
  Validates secret attributes.

  Used by both the model layer and LiveView for consistent validation.

  ## Returns
  - Ecto.Changeset.t()
  """
  @spec changeset(t() | Ecto.Changeset.t(), any()) :: Ecto.Changeset.t()
  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [:name, :value, :description])
    |> validate_required([:name, :value])
    |> validate_length(:name, min: 2, max: 64)
    |> validate_length(:description, max: 500)
    |> validate_format(:name, ~r/^[a-zA-Z0-9_]+$/,
      message: "must be alphanumeric with underscores only"
    )
    |> unique_constraint(:name)
    |> put_encrypted_value()
  end

  # Copy virtual :value to :encrypted_value and encrypt using Cloak
  defp put_encrypted_value(changeset) do
    case get_change(changeset, :value) do
      nil ->
        changeset

      value ->
        encrypted = Quoracle.Vault.encrypt!(value)
        put_change(changeset, :encrypted_value, encrypted)
    end
  end

  # Decrypts :encrypted_value into virtual :value field
  defp decrypt_value(secret) do
    decrypted = Quoracle.Vault.decrypt!(secret.encrypted_value)
    %{secret | value: decrypted}
  end

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: integer() | nil,
          name: String.t() | nil,
          value: String.t() | nil,
          encrypted_value: binary() | nil,
          description: String.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }
end
