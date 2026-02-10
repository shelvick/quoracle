defmodule Quoracle.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :prompt, :text, null: false
      add :status, :string, null: false
      add :result, :text
      add :error_message, :text

      timestamps()
    end

    create index(:tasks, [:status, :inserted_at])
    create index(:tasks, [:updated_at])
  end
end
