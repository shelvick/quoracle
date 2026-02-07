defmodule Quoracle.Repo.Migrations.CreateSecrets do
  use Ecto.Migration

  def change do
    create table(:secrets) do
      add :name, :string, null: false, size: 64
      add :encrypted_value, :binary, null: false
      add :description, :string, size: 500

      timestamps()
    end

    create unique_index(:secrets, [:name])
  end
end
