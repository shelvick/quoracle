defmodule Quoracle.Repo.Migrations.AddBudgetToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      # NULL = N/A (no budget limit)
      # Precision 12, scale 2 for currency ($XXX,XXX,XXX.XX max)
      add :budget_limit, :decimal, precision: 12, scale: 2, null: true
    end

    # Index for budget-related queries (filter tasks with/without budgets)
    create index(:tasks, [:budget_limit], where: "budget_limit IS NOT NULL")
  end
end
