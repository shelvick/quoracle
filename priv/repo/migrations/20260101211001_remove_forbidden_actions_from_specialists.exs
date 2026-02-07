defmodule Quoracle.Repo.Migrations.RemoveForbiddenActionsFromSpecialists do
  use Ecto.Migration

  def change do
    alter table(:specialists) do
      remove :forbidden_actions, {:array, :string}, default: []
    end
  end
end
