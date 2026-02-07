defmodule Quoracle.Repo.Migrations.CreateProfiles do
  use Ecto.Migration

  def change do
    create table(:profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :model_pool, {:array, :string}, null: false, default: []
      add :capability_groups, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:profiles, [:name])
    create index(:profiles, [:capability_groups], using: :gin)
  end
end
