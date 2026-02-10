defmodule Quoracle.Tasks.Task do
  @moduledoc """
  Ecto schema for storing root task definitions from user prompts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tasks" do
    field(:prompt, :string)
    field(:status, :string)
    field(:result, :string)
    field(:error_message, :string)
    field(:global_context, :string)
    field(:initial_constraints, Quoracle.Tasks.JSONBArray)
    # Budget limit in USD - NULL means N/A (no limit)
    field(:budget_limit, :decimal)
    # Profile name used to create this task
    field(:profile_name, :string)

    has_many(:agents, Quoracle.Agents.Agent)
    has_many(:logs, Quoracle.Logs.Log)
    has_many(:messages, Quoracle.Messages.Message)

    timestamps()
  end

  @doc """
  Changeset for creating or updating a task.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :prompt,
      :status,
      :result,
      :error_message,
      :global_context,
      :initial_constraints,
      :budget_limit,
      :profile_name
    ])
    |> put_default_constraints()
    |> validate_required([:prompt, :status])
    |> validate_inclusion(:status, ["running", "pausing", "paused", "completed", "failed"])
    |> validate_positive_budget_limit()
  end

  # Apply default empty list for initial_constraints if nil
  defp put_default_constraints(changeset) do
    case get_field(changeset, :initial_constraints) do
      nil -> put_change(changeset, :initial_constraints, [])
      _value -> changeset
    end
  end

  @doc """
  Changeset for updating task status.
  """
  @spec status_changeset(%__MODULE__{}, String.t()) :: Ecto.Changeset.t()
  def status_changeset(task, new_status) do
    task
    |> change(status: new_status)
    |> validate_inclusion(:status, ["running", "pausing", "paused", "completed", "failed"])
  end

  @doc """
  Changeset for completing a task with a result.
  """
  @spec complete_changeset(%__MODULE__{}, String.t()) :: Ecto.Changeset.t()
  def complete_changeset(task, result) do
    task
    |> change(status: "completed", result: result)
  end

  @doc """
  Changeset for failing a task with an error message.
  """
  @spec fail_changeset(%__MODULE__{}, String.t()) :: Ecto.Changeset.t()
  def fail_changeset(task, error_message) do
    task
    |> change(status: "failed", error_message: error_message)
  end

  @doc """
  Changeset for creating task with global_context and initial_constraints.
  """
  @spec global_context_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def global_context_changeset(task, attrs) do
    changeset(task, attrs)
  end

  @doc """
  Changeset for updating only global_context.
  """
  @spec update_global_context_changeset(%__MODULE__{}, String.t()) :: Ecto.Changeset.t()
  def update_global_context_changeset(task, global_context) do
    task
    |> change(global_context: global_context)
  end

  @doc """
  Changeset for updating only initial_constraints.
  """
  @spec update_constraints_changeset(%__MODULE__{}, list()) :: Ecto.Changeset.t()
  def update_constraints_changeset(task, constraints) do
    task
    |> change(initial_constraints: constraints)
  end

  @doc """
  Changeset for updating the budget_limit field.

  Accepts a Decimal or nil (to remove the limit).
  Validates that the value is positive if provided.
  """
  @spec budget_limit_changeset(%__MODULE__{}, Decimal.t() | nil) :: Ecto.Changeset.t()
  def budget_limit_changeset(task, budget_limit) do
    task
    |> change(budget_limit: budget_limit)
    |> validate_positive_budget_limit()
  end

  # Validates that budget_limit is positive if provided (nil is allowed)
  defp validate_positive_budget_limit(changeset) do
    case get_change(changeset, :budget_limit) do
      nil ->
        changeset

      value ->
        if Decimal.compare(value, Decimal.new(0)) == :gt do
          changeset
        else
          add_error(changeset, :budget_limit, "must be positive")
        end
    end
  end
end
