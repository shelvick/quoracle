defmodule Quoracle.Repo.Migrations.CreateActionsTable do
  use Ecto.Migration

  def change do
    create table(:actions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, :binary_id, null: false
      add :action_type, :string, null: false
      add :params, :map, null: false
      add :reasoning, :text
      add :result, :map
      add :status, :string, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :error_message, :text
      add :parent_action_id, references(:actions, type: :binary_id, on_delete: :restrict)

      timestamps()
    end

    create index(:actions, [:agent_id])
    create index(:actions, [:action_type])
    create index(:actions, [:status])
    create index(:actions, [:started_at])
  end
end