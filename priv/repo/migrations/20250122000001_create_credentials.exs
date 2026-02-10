defmodule Quoracle.Repo.Migrations.CreateCredentials do
  use Ecto.Migration

  def change do
    create table(:credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :model_id, :string, null: false
      add :api_key, :binary, null: false  # Encrypted
      add :deployment_id, :string
      add :resource_id, :string
      add :endpoint_url, :string
      add :provider_type, :string, null: false

      timestamps()
    end

    create unique_index(:credentials, [:model_id])
    
    # Foreign key with CASCADE delete
    alter table(:credentials) do
      modify :model_id, references(:model_configs, column: :model_id, type: :string, on_delete: :delete_all)
    end
  end
end