defmodule Quoracle.Repo.Migrations.AddMaxRoundsToProfiles do
  @moduledoc """
  Adds max_refinement_rounds to profiles with a default of 4.
  """

  use Ecto.Migration

  @doc "Add max_refinement_rounds column with default 4."
  @spec change() :: :ok
  def change do
    alter table(:profiles) do
      add :max_refinement_rounds, :integer, default: 4, null: false
    end
  end
end
