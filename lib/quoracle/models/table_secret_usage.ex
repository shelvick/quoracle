defmodule Quoracle.Models.TableSecretUsage do
  @moduledoc """
  Schema for tracking secret usage across the system.
  Records which agents use which secrets in which actions for audit purposes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "secret_usage" do
    field(:secret_name, :string)
    field(:agent_id, :string)
    field(:task_id, :string)
    field(:action_type, :string)
    field(:accessed_at, :utc_datetime_usec)
  end

  @type t() :: %__MODULE__{
          id: Ecto.UUID.t(),
          secret_name: String.t(),
          agent_id: String.t(),
          task_id: String.t() | nil,
          action_type: String.t(),
          accessed_at: DateTime.t()
        }

  @doc """
  Valid action types that can use secrets.
  """
  @spec valid_action_types() :: [String.t()]
  def valid_action_types do
    [
      "execute_shell",
      "call_api",
      "fetch_web",
      "spawn_child",
      "send_message",
      "wait",
      "orient",
      "todo",
      "call_mcp",
      "answer_engine",
      "generate_secret"
    ]
  end

  @doc """
  Creates a changeset for a secret usage record.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(usage, attrs) do
    usage
    |> cast(attrs, [:secret_name, :agent_id, :task_id, :action_type, :accessed_at])
    |> validate_required([:secret_name, :agent_id, :action_type, :accessed_at])
    |> validate_length(:secret_name, max: 64)
    |> validate_length(:agent_id, max: 255)
    |> validate_length(:action_type, max: 50)
    |> validate_inclusion(:action_type, valid_action_types())
  end
end
