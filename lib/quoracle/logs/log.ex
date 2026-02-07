defmodule Quoracle.Logs.Log do
  @moduledoc """
  Ecto schema for storing action execution audit trail.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "logs" do
    field(:agent_id, :string)
    field(:action_type, :string)
    field(:params, :map)
    field(:result, :map)
    field(:status, :string)

    belongs_to(:task, Quoracle.Tasks.Task)

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for creating a new log entry.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(log, attrs) do
    log
    |> cast(attrs, [:agent_id, :task_id, :action_type, :params, :result, :status])
    |> validate_required([:agent_id, :task_id, :action_type, :params, :status])
    |> validate_inclusion(:status, ["success", "error"])
    |> foreign_key_constraint(:task_id)
  end
end
