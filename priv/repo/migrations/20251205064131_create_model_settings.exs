defmodule Quoracle.Repo.Migrations.CreateModelSettings do
  use Ecto.Migration

  def change do
    create table(:model_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :key, :string, null: false
      add :value, :map, null: false, default: fragment("'{}'::jsonb")

      timestamps()
    end

    create unique_index(:model_settings, [:key])
  end
end
