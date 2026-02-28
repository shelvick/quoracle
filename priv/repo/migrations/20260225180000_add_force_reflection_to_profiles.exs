defmodule Quoracle.Repo.Migrations.AddForceReflectionToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add :force_reflection, :boolean, default: false, null: false
    end
  end
end