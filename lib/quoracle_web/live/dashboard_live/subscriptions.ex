defmodule QuoracleWeb.DashboardLive.Subscriptions do
  @moduledoc """
  Handles PubSub subscription logic for the Dashboard LiveView.
  Extracted from DashboardLive to reduce module size below 500 lines.
  """

  alias Phoenix.PubSub
  alias Phoenix.LiveView.Socket

  @doc """
  Subscribe to core PubSub topics needed by the dashboard.
  """
  @spec subscribe_to_core_topics(atom()) :: :ok
  def subscribe_to_core_topics(pubsub) do
    # Only subscribe to agents:lifecycle (agent spawns/terminations)
    # Note: Individual agent topics (logs, state) are subscribed dynamically
    PubSub.subscribe(pubsub, "agents:lifecycle")
  end

  @doc """
  Subscribe to a topic only if not already subscribed.
  Updates the socket's subscribed_topics tracking.
  """
  @spec safe_subscribe(Socket.t(), String.t()) :: Socket.t()
  def safe_subscribe(socket, topic) do
    if MapSet.member?(socket.assigns.subscribed_topics, topic) do
      socket
    else
      pubsub = socket.assigns.pubsub
      PubSub.subscribe(pubsub, topic)
      Phoenix.Component.update(socket, :subscribed_topics, &MapSet.put(&1, topic))
    end
  end

  @doc """
  Subscribe to existing agents' log topics on mount.
  Queries the Registry to find all existing agents.
  """
  @spec subscribe_to_existing_agents(atom(), map()) :: :ok
  def subscribe_to_existing_agents(pubsub, session) do
    registry =
      session["registry"] || session[:registry] || Quoracle.AgentRegistry

    existing_agents =
      try do
        Registry.select(registry, [
          {{{:agent, :"$1"}, :"$2", :"$3"}, [], [:"$1"]}
        ])
      rescue
        _ -> []
      end

    Enum.each(existing_agents, fn agent_id ->
      PubSub.subscribe(pubsub, "agents:#{agent_id}:logs")
      PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")
    end)
  end

  @doc """
  Subscribe to existing tasks' message topics on mount.
  """
  @spec subscribe_to_existing_tasks(atom(), list()) :: :ok
  def subscribe_to_existing_tasks(pubsub, tasks) do
    Enum.each(tasks, fn task ->
      PubSub.subscribe(pubsub, "tasks:#{task.id}:messages")
      PubSub.subscribe(pubsub, "tasks:#{task.id}:costs")
    end)
  end

  @doc """
  Unsubscribe from an agent's log topic.
  """
  @spec unsubscribe_from_agent(atom(), String.t()) :: :ok | {:error, term()}
  def unsubscribe_from_agent(pubsub, agent_id) do
    PubSub.unsubscribe(pubsub, "agents:#{agent_id}:logs")
  end
end
