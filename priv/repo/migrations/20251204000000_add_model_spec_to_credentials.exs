defmodule Quoracle.Repo.Migrations.AddModelSpecToCredentials do
  use Ecto.Migration

  def up do
    # Drop FK constraint to model_configs (table being deleted)
    drop constraint(:credentials, "credentials_model_id_fkey")

    # Add model_spec column as nullable first
    alter table(:credentials) do
      add :model_spec, :string
    end

    # Update existing rows with placeholder (will be fixed by seeds)
    execute "UPDATE credentials SET model_spec = 'legacy:' || model_id WHERE model_spec IS NULL"

    # Now make it NOT NULL
    alter table(:credentials) do
      modify :model_spec, :string, null: false
    end

    # Create index on model_spec for query performance
    create index(:credentials, [:model_spec])
  end

  def down do
    drop index(:credentials, [:model_spec])

    alter table(:credentials) do
      remove :model_spec
    end

    # Restore FK constraint
    alter table(:credentials) do
      modify :model_id, references(:model_configs, column: :model_id, type: :string, on_delete: :delete_all)
    end
  end
end
