defmodule Quoracle.Repo.Migrations.AddProfileToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :profile_name, :string
    end

    create index(:agents, [:profile_name])
  end
end
