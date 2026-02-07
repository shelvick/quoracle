defmodule Quoracle.Repo.Migrations.CreateSecretUsage do
  use Ecto.Migration

  def change do
    create table(:secret_usage, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :secret_name, :string, size: 64, null: false
      add :agent_id, :string, size: 255, null: false
      add :task_id, :string, size: 255
      add :action_type, :string, size: 50, null: false
      add :accessed_at, :utc_datetime_usec, null: false
    end

    # Indexes for efficient querying
    create index(:secret_usage, [:secret_name])
    create index(:secret_usage, [:agent_id])
    create index(:secret_usage, [:accessed_at])
    create index(:secret_usage, [:secret_name, :accessed_at],
           name: :idx_secret_usage_composite)
  end
end