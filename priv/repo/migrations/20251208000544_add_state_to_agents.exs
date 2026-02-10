defmodule Quoracle.Repo.Migrations.AddStateToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :state, :map, default: %{}
    end
  end
end
