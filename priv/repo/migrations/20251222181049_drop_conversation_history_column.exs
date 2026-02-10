defmodule Quoracle.Repo.Migrations.DropConversationHistoryColumn do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      remove :conversation_history, :map, default: %{}
    end
  end
end
