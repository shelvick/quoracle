defmodule Quoracle.Repo.Migrations.AddPromptFields do
  use Ecto.Migration

  def change do
    # Add prompt_fields JSONB column to agents table
    alter table(:agents) do
      add :prompt_fields, :jsonb, default: "{}", null: false
    end

    # Create GIN index for efficient JSONB queries
    create index(:agents, [:prompt_fields], using: :gin)

    # Add global_context and initial_constraints to tasks table
    alter table(:tasks) do
      add :global_context, :text
      add :initial_constraints, :jsonb
    end
  end
end
