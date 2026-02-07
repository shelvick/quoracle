defmodule Quoracle.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :from_agent_id, :string, null: false
      add :to_agent_id, :string, null: false
      add :content, :text, null: false
      add :read_at, :utc_datetime_usec

      timestamps(updated_at: false)
    end

    create index(:messages, [:to_agent_id, :inserted_at])
    create index(:messages, [:from_agent_id, :inserted_at])
    create index(:messages, [:task_id, :inserted_at])
  end
end
