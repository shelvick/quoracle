defmodule Quoracle.Repo.Migrations.RemoveModelConfigsTable do
  use Ecto.Migration

  def change do
    # Add provider-specific fields to credentials table
    alter table(:credentials) do
      add :api_version, :string
      add :region, :string
    end

    # Drop model_configs table - no longer needed after LLMDB migration
    drop table(:model_configs)
  end
end
