defmodule Quoracle.Repo.Migrations.CreateLogs do
  use Ecto.Migration

  def change do
    create table(:logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, :string, null: false
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :action_type, :string, null: false
      add :params, :map, null: false
      add :result, :map
      add :status, :string, null: false

      timestamps(updated_at: false)
    end

    create index(:logs, [:agent_id, :inserted_at])
    create index(:logs, [:task_id, :inserted_at])
    create index(:logs, [:action_type])
  end
end
