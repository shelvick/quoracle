defmodule Quoracle.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, :string, null: false
      add :parent_id, :string
      add :config, :map, null: false
      add :conversation_history, :map, null: false
      add :status, :string, null: false

      timestamps()
    end

    create unique_index(:agents, [:agent_id])
    create index(:agents, [:task_id, :inserted_at])
    create index(:agents, [:parent_id])
  end
end
