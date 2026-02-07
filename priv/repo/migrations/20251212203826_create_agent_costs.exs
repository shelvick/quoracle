defmodule Quoracle.Repo.Migrations.CreateAgentCosts do
  use Ecto.Migration

  def change do
    create table(:agent_costs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, :string, null: false
      add :cost_type, :string, null: false
      add :cost_usd, :decimal, precision: 12, scale: 10
      add :metadata, :map

      add :task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(updated_at: false)
    end

    # Primary query patterns
    create index(:agent_costs, [:task_id, :inserted_at])
    create index(:agent_costs, [:agent_id, :inserted_at])

    # Aggregation patterns
    create index(:agent_costs, [:task_id, :cost_type])
    create index(:agent_costs, [:agent_id, :cost_type])

    # Model-based aggregation (via metadata->>'model_spec')
    # Note: GIN index on metadata for JSONB queries
    create index(:agent_costs, [:metadata], using: :gin)
  end
end
