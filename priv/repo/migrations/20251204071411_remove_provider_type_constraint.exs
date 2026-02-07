defmodule Quoracle.Repo.Migrations.RemoveProviderTypeConstraint do
  @moduledoc """
  Removes the provider_type column from credentials table.
  Provider is now derived from model_spec prefix (e.g., "azure:o1" -> azure).
  """
  use Ecto.Migration

  def change do
    alter table(:credentials) do
      remove :provider_type, :string, null: false
    end
  end
end
