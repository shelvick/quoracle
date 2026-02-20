defmodule Quoracle.Repo.Migrations.MakeApiKeyNullable do
  @moduledoc "Make api_key nullable for local model support (v3.0)."
  use Ecto.Migration

  def change do
    alter table(:credentials) do
      modify :api_key, :binary, null: true, from: {:binary, null: false}
    end
  end
end
