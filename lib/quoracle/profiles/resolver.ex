defmodule Quoracle.Profiles.Resolver do
  @moduledoc """
  Profile lookup service. Resolves profile name to full profile data at spawn time.
  Provides snapshot semantics - profile data is captured when resolved, not updated dynamically.
  """

  alias Quoracle.Profiles.TableProfiles
  alias Quoracle.Profiles.ProfileNotFoundError
  alias Quoracle.Repo
  import Ecto.Query

  @type profile_data :: %{
          name: String.t(),
          description: String.t() | nil,
          model_pool: [String.t()],
          capability_groups: [atom()]
        }

  @doc """
  Looks up profile by name, returns snapshot of profile data.

  ## Examples

      iex> Resolver.resolve("my-profile")
      {:ok, %{name: "my-profile", description: nil, model_pool: ["gpt-4o"], capability_groups: [:hierarchy, :file_read]}}

      iex> Resolver.resolve("non-existent")
      {:error, :profile_not_found}
  """
  @spec resolve(String.t()) :: {:ok, profile_data()} | {:error, :profile_not_found}
  def resolve(profile_name) do
    case Repo.get_by(TableProfiles, name: profile_name) do
      nil ->
        {:error, :profile_not_found}

      profile ->
        {:ok, to_snapshot(profile)}
    end
  end

  @doc """
  Bang version that raises `ProfileNotFoundError` if not found.
  """
  @spec resolve!(String.t()) :: profile_data()
  def resolve!(profile_name) do
    case resolve(profile_name) do
      {:ok, data} ->
        data

      {:error, :profile_not_found} ->
        raise ProfileNotFoundError, name: profile_name
    end
  end

  @doc """
  Returns true if profile with given name exists.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(profile_name) do
    Repo.exists?(from(p in TableProfiles, where: p.name == ^profile_name))
  end

  @doc """
  Returns list of all profile names (for UI dropdowns).
  """
  @spec list_names() :: [String.t()]
  def list_names do
    Repo.all(from(p in TableProfiles, select: p.name, order_by: p.name))
  end

  @type profile_summary :: %{
          name: String.t(),
          description: String.t() | nil,
          capability_groups: [atom()]
        }

  @doc """
  Converts profile_data snapshot to config fields for agent initialization.

  This is the single source of truth for profile→config field mapping.
  Used by TaskManager (root agents) and Spawn.ConfigBuilder (child agents).

  ## Examples

      iex> profile_data = %{name: "my-profile", description: "desc", model_pool: ["gpt-4o"], capability_groups: [:hierarchy]}
      iex> Resolver.to_config_fields(profile_data)
      %{profile_name: "my-profile", profile_description: "desc", model_pool: ["gpt-4o"], capability_groups: [:hierarchy]}
  """
  @spec to_config_fields(profile_data()) :: map()
  def to_config_fields(%{} = profile_data) do
    %{
      profile_name: profile_data.name,
      profile_description: profile_data.description,
      model_pool: profile_data.model_pool,
      capability_groups: profile_data.capability_groups
    }
  end

  @doc """
  Returns all profiles with name, description, and capability_groups.
  For system prompt injection so agents understand what each profile does.
  """
  @spec list_all() :: [profile_summary()]
  def list_all do
    Repo.all(from(p in TableProfiles, order_by: p.name))
    |> Enum.map(fn profile ->
      %{
        name: profile.name,
        description: profile.description,
        capability_groups: TableProfiles.capability_groups_as_atoms(profile)
      }
    end)
  end

  # Convert DB record to plain map snapshot with capability_groups as atoms
  defp to_snapshot(profile) do
    capability_groups = TableProfiles.capability_groups_as_atoms(profile)

    %{
      name: profile.name,
      description: profile.description,
      model_pool: profile.model_pool,
      capability_groups: capability_groups
    }
  end
end
