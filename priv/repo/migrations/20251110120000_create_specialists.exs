defmodule Quoracle.Repo.Migrations.CreateSpecialists do
  use Ecto.Migration

  def change do
    create table(:specialists, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :long_description, :text
      add :tags, {:array, :string}, default: []
      add :system_prompt, :text, null: false
      add :default_fields, :map, default: %{}
      add :forbidden_actions, {:array, :string}, default: []

      timestamps()
    end

    create unique_index(:specialists, [:name])
    create index(:specialists, [:tags], using: :gin)
  end
end
