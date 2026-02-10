defmodule QuoracleWeb.SecretManagementLive.ProfileHelpers do
  @moduledoc """
  Helper functions for profile management tab in SecretManagementLive.
  Handles profile CRUD operations and changeset building.
  """

  alias Quoracle.Profiles.TableProfiles
  alias Quoracle.Repo

  # =============================================================================
  # Changeset Building
  # =============================================================================

  @doc """
  Build a new profile changeset for the create form.
  """
  @spec new_profile_changeset() :: Ecto.Changeset.t()
  def new_profile_changeset do
    %TableProfiles{}
    |> TableProfiles.changeset(%{})
    |> Map.put(:action, :validate)
  end

  @doc """
  Build a changeset for editing an existing profile.
  """
  @spec edit_profile_changeset(TableProfiles.t()) :: Ecto.Changeset.t()
  def edit_profile_changeset(profile) do
    profile
    |> TableProfiles.changeset(%{})
    |> Map.put(:action, :validate)
  end

  @doc """
  Build a validation changeset for form feedback.
  """
  @spec validate_changeset(TableProfiles.t() | nil, map()) :: Ecto.Changeset.t()
  def validate_changeset(nil, params) do
    %TableProfiles{}
    |> TableProfiles.changeset(params)
    |> Map.put(:action, :validate)
  end

  def validate_changeset(profile, params) do
    profile
    |> TableProfiles.changeset(params)
    |> Map.put(:action, :validate)
  end

  # =============================================================================
  # CRUD Operations
  # =============================================================================

  @doc """
  Get a profile by ID.
  """
  @spec get_profile(String.t() | integer()) :: TableProfiles.t() | nil
  def get_profile(id), do: Repo.get(TableProfiles, id)

  @doc """
  List all profiles.
  """
  @spec list_profiles() :: [TableProfiles.t()]
  def list_profiles, do: Repo.all(TableProfiles)

  @doc """
  Create or update a profile based on whether selected_profile is nil.
  Returns {:ok, profile} or {:error, changeset}.
  """
  @spec save_profile(TableProfiles.t() | nil, map()) ::
          {:ok, TableProfiles.t()} | {:error, Ecto.Changeset.t()}
  def save_profile(nil, params) do
    %TableProfiles{}
    |> TableProfiles.changeset(params)
    |> Repo.insert()
  end

  def save_profile(profile, params) do
    profile
    |> TableProfiles.changeset(params)
    |> Repo.update()
  end

  @doc """
  Delete a profile by ID.
  Returns {:ok, profile} or {:error, changeset} or {:error, :not_found}.
  """
  @spec delete_profile(String.t() | integer()) ::
          {:ok, TableProfiles.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def delete_profile(id) do
    case Repo.get(TableProfiles, id) do
      nil -> {:error, :not_found}
      profile -> Repo.delete(profile)
    end
  end

  @doc """
  Reset socket assigns after successful profile save.
  """
  @spec reset_profile_assigns(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset_profile_assigns(socket) do
    import Phoenix.Component, only: [assign: 3]

    socket
    |> assign(:show_modal, :none)
    |> assign(:profile_changeset, new_profile_changeset())
    |> assign(:selected_profile, nil)
    |> assign(:profiles, list_profiles())
  end

  @doc """
  Apply error action to changeset for display.
  """
  @spec apply_error_action(Ecto.Changeset.t(), TableProfiles.t() | nil) :: Ecto.Changeset.t()
  def apply_error_action(changeset, selected_profile) do
    action = if selected_profile, do: :update, else: :insert
    %{changeset | action: action}
  end

  # =============================================================================
  # Capability Groups Display (Packet 5, feat-20260107-capability-groups)
  # =============================================================================

  @all_groups ["file_read", "file_write", "external_api", "hierarchy", "local_execution"]

  @doc """
  Format capability groups for display in profile cards.
  Returns "all" when all 5 groups selected, "none (base only)" when empty,
  or comma-separated list for partial selection.
  """
  @spec format_groups_display([atom()] | [String.t()]) :: String.t()
  def format_groups_display([]), do: "none (base only)"

  def format_groups_display(groups) when is_list(groups) do
    # Normalize to strings for comparison
    string_groups = Enum.map(groups, &to_string/1)

    if Enum.sort(string_groups) == Enum.sort(@all_groups) do
      "all"
    else
      Enum.join(string_groups, ", ")
    end
  end

  @doc """
  Returns capability groups ordered by risk level (safest first).
  Order: file_read → file_write → external_api → hierarchy → local_execution
  """
  @spec ordered_capability_groups() :: [{atom(), String.t()}]
  def ordered_capability_groups do
    [
      {:file_read, "Read files from disk"},
      {:file_write, "Write files, manage secrets"},
      {:external_api, "Call external APIs, record costs"},
      {:hierarchy, "Spawn/dismiss child agents"},
      {:local_execution, "Shell commands, MCP, interactive"}
    ]
  end
end
