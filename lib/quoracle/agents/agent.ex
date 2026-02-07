defmodule Quoracle.Agents.Agent do
  @moduledoc """
  Ecto schema for storing agent instances with hierarchy, configuration, and state.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agents" do
    field(:agent_id, :string)
    field(:parent_id, :string)
    field(:config, :map)
    field(:status, :string)
    field(:prompt_fields, Quoracle.Agents.JSONBMap, default: %{})
    field(:state, :map, default: %{})
    field(:profile_name, :string)

    belongs_to(:task, Quoracle.Tasks.Task)

    timestamps()
  end

  @doc """
  Changeset for creating or updating an agent.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :task_id,
      :agent_id,
      :parent_id,
      :config,
      :status,
      :prompt_fields,
      :state,
      :profile_name
    ])
    |> validate_required([:task_id, :agent_id, :config, :status])
    |> validate_inclusion(:status, ["starting", "running", "idle", "paused", "stopped"])
    |> unique_constraint(:agent_id)
    |> foreign_key_constraint(:task_id)
  end

  @doc """
  Changeset for creating agent with prompt_fields.
  """
  @spec prompt_fields_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def prompt_fields_changeset(agent, attrs) do
    changeset(agent, attrs)
  end

  @doc """
  Changeset for updating only prompt_fields.
  """
  @spec update_prompt_fields_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_prompt_fields_changeset(agent, prompt_fields) do
    agent
    |> cast(%{prompt_fields: prompt_fields}, [:prompt_fields])
  end

  @doc """
  Changeset for updating agent state (ACE context_lessons, model_states).
  """
  @spec update_state_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_state_changeset(agent, state) do
    agent
    |> change(state: state)
  end

  @doc """
  Query all agents from the database.
  Used by LiveView to enrich Registry data with task_id.
  """
  @spec query_all() :: [%__MODULE__{}]
  def query_all do
    Quoracle.Repo.all(__MODULE__)
  end
end
