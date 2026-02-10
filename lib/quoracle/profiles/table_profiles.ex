defmodule Quoracle.Profiles.TableProfiles do
  @moduledoc """
  Ecto schema for the profiles table.
  Stores user-defined model configurations with capability groups.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Quoracle.Profiles.CapabilityGroups

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          model_pool: [String.t()] | nil,
          capability_groups: [String.t()] | nil,
          max_refinement_rounds: integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "profiles" do
    field(:name, :string)
    field(:description, :string)
    field(:model_pool, {:array, :string})
    field(:capability_groups, {:array, :string}, default: [])
    field(:max_refinement_rounds, :integer, default: 4)

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name, :description, :model_pool, :capability_groups, :max_refinement_rounds])
    |> validate_required([:name, :model_pool])
    |> put_default_capability_groups()
    |> validate_format(:name, ~r/^[a-zA-Z0-9_-]+$/,
      message: "must be alphanumeric with hyphens/underscores"
    )
    |> validate_length(:name, min: 1, max: 50)
    |> validate_length(:description, max: 500)
    |> validate_length(:model_pool, min: 1, message: "must have at least one model")
    |> validate_model_pool_format()
    |> validate_capability_groups()
    |> validate_number(:max_refinement_rounds,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 9
    )
    |> unique_constraint(:name)
  end

  @doc """
  Converts capability_groups from strings to atoms.
  Returns empty list if capability_groups is nil or empty.
  """
  @spec capability_groups_as_atoms(t()) :: [atom()]
  def capability_groups_as_atoms(%{capability_groups: nil}), do: []
  def capability_groups_as_atoms(%{capability_groups: []}), do: []

  def capability_groups_as_atoms(%{capability_groups: groups}) do
    Enum.map(groups, &String.to_atom/1)
  end

  defp put_default_capability_groups(changeset) do
    case get_field(changeset, :capability_groups) do
      nil -> put_change(changeset, :capability_groups, [])
      _ -> changeset
    end
  end

  defp validate_model_pool_format(changeset) do
    validate_change(changeset, :model_pool, fn :model_pool, models ->
      if Enum.all?(models, &is_binary/1) do
        []
      else
        [model_pool: "all entries must be strings"]
      end
    end)
  end

  defp validate_capability_groups(changeset) do
    validate_change(changeset, :capability_groups, fn :capability_groups, groups ->
      valid_groups = CapabilityGroups.groups() |> Enum.map(&Atom.to_string/1)

      invalid = Enum.filter(groups, fn g -> g not in valid_groups end)

      if invalid == [] do
        []
      else
        [capability_groups: "invalid groups: #{Enum.join(invalid, ", ")}"]
      end
    end)
  end
end
