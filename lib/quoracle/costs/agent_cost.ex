defmodule Quoracle.Costs.AgentCost do
  @moduledoc """
  Ecto schema for tracking all agent-related costs.

  Designed to be future-proof for non-LLM costs (API calls, compute, storage)
  while initially supporting LLM cost types.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @cost_types ~w(llm_consensus llm_embedding llm_answer llm_summarization llm_condensation image_generation external)

  @type t :: %__MODULE__{
          id: binary() | nil,
          agent_id: String.t() | nil,
          task_id: binary() | nil,
          cost_type: String.t() | nil,
          cost_usd: Decimal.t() | nil,
          metadata: map() | nil,
          task: term(),
          inserted_at: DateTime.t() | nil
        }

  schema "agent_costs" do
    field(:agent_id, :string)
    field(:cost_type, :string)
    field(:cost_usd, :decimal)
    field(:metadata, :map)

    belongs_to(:task, Quoracle.Tasks.Task)

    timestamps(updated_at: false)
  end

  @required_fields ~w(agent_id task_id cost_type)a
  @optional_fields ~w(cost_usd metadata)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(cost, attrs) do
    cost
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:cost_type, @cost_types)
    |> foreign_key_constraint(:task_id)
  end

  @spec cost_types() :: [String.t()]
  def cost_types, do: @cost_types
end
