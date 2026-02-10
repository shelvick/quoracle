defmodule Quoracle.Repo.Migrations.AddProfileToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :profile_name, :string
    end

    create index(:tasks, [:profile_name])
  end
end
