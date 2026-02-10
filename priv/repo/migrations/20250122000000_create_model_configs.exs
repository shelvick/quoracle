defmodule Quoracle.Repo.Migrations.CreateModelConfigs do
  use Ecto.Migration

  def change do
    create table(:model_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :model_id, :string, null: false
      add :provider_type, :string, null: false
      add :canonical_name, :string, null: false
      add :display_name, :string
      add :api_type, :string, null: false
      add :capabilities, :map, default: %{}
      add :provider_config, :map, default: %{}
      add :limits, :map, default: %{}
      add :metadata, :map, default: %{}

      timestamps()
    end

    create unique_index(:model_configs, [:model_id])
    create index(:model_configs, [:provider_type])
  end
end