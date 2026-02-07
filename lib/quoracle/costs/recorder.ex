defmodule Quoracle.Costs.Recorder do
  @moduledoc """
  Records agent costs to database and broadcasts via PubSub.

  Called by LLM modules after extracting costs from ReqLLM responses.
  Requires explicit pubsub parameter for test isolation.
  """

  alias Quoracle.Costs.AgentCost
  alias Quoracle.Repo

  @type cost_data :: map()

  @type record_opts :: [pubsub: atom()]

  @doc """
  Records a cost entry and broadcasts to PubSub.

  ## Parameters
    - cost_data: Map with agent_id, task_id, cost_type, and optional cost_usd/metadata
    - opts: Keyword list with :pubsub for broadcast (required)

  ## Returns
    - {:ok, %AgentCost{}} on success
    - {:error, changeset} on validation failure
  """
  @spec record(map(), keyword()) :: {:ok, AgentCost.t()} | {:error, Ecto.Changeset.t()}
  def record(cost_data, opts) when is_map(cost_data) do
    pubsub = Keyword.fetch!(opts, :pubsub)

    case insert_cost(cost_data) do
      {:ok, cost} ->
        broadcast_cost_recorded(cost, pubsub)
        {:ok, cost}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Records a cost entry without broadcasting. For batch operations or testing.
  """
  @spec record_silent(map()) :: {:ok, AgentCost.t()} | {:error, Ecto.Changeset.t()}
  def record_silent(cost_data) when is_map(cost_data) do
    insert_cost(cost_data)
  end

  # Private functions

  @spec insert_cost(map()) :: {:ok, AgentCost.t()} | {:error, Ecto.Changeset.t()}
  defp insert_cost(cost_data) do
    %AgentCost{}
    |> AgentCost.changeset(cost_data)
    |> Repo.insert()
  end

  @doc """
  Broadcasts a cost record event to PubSub.
  Used by UsageHelper.flush_accumulated_costs/2 for batch broadcasts.
  """
  @spec broadcast_cost_recorded(AgentCost.t(), atom()) :: :ok
  def broadcast_cost_recorded(cost, pubsub) do
    # Broadcast to both task and agent topics
    task_topic = "tasks:#{cost.task_id}:costs"
    agent_topic = "agents:#{cost.agent_id}:costs"

    message = {:cost_recorded, format_cost_event(cost)}

    safe_broadcast(pubsub, task_topic, message)
    safe_broadcast(pubsub, agent_topic, message)
    :ok
  end

  defp format_cost_event(cost) do
    %{
      id: cost.id,
      agent_id: cost.agent_id,
      task_id: cost.task_id,
      cost_type: cost.cost_type,
      cost_usd: cost.cost_usd,
      model_spec: get_in(cost.metadata || %{}, ["model_spec"]),
      timestamp: cost.inserted_at
    }
  end

  defp safe_broadcast(pubsub, topic, message) do
    try do
      Phoenix.PubSub.broadcast(pubsub, topic, message)
    rescue
      ArgumentError ->
        # PubSub not running (test cleanup race) - skip silently
        :ok
    end
  end
end
