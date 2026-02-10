defmodule Quoracle.Messages.Message do
  @moduledoc """
  Ecto schema for storing inter-agent communication messages.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field(:from_agent_id, :string)
    field(:to_agent_id, :string)
    field(:content, :string)
    field(:read_at, :utc_datetime_usec)

    belongs_to(:task, Quoracle.Tasks.Task)

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for creating a new message.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:task_id, :from_agent_id, :to_agent_id, :content, :read_at])
    |> validate_required([:task_id, :from_agent_id, :to_agent_id, :content])
    |> foreign_key_constraint(:task_id)
  end

  @doc """
  Changeset for marking a message as read.
  """
  @spec mark_read_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def mark_read_changeset(message) do
    message
    |> change(read_at: DateTime.utc_now())
  end
end
