defmodule QuoracleWeb.LogViewLive do
  @moduledoc """
  LiveView wrapper for LogView component with PubSub isolation support.
  """
  use QuoracleWeb, :live_view
  alias Phoenix.PubSub

  @doc """
  Returns the current PubSub instance to use.
  In tests, uses session-passed pubsub for isolation.
  In production, uses the configured PubSub instance.
  """
  @spec current_pubsub(map()) :: atom()
  def current_pubsub(session \\ %{}) do
    case session do
      %{"pubsub" => pubsub} when not is_nil(pubsub) -> pubsub
      %{pubsub: pubsub} when not is_nil(pubsub) -> pubsub
      _ -> Quoracle.PubSub
    end
  end

  @impl true
  def mount(params, session, socket) do
    # Extract pubsub using helper (follows Ecto.SQL.Sandbox pattern for test isolation)
    pubsub = current_pubsub(session)

    agent_id = params["agent_id"]

    # Subscribe to log topics (needed for both production and tests)
    PubSub.subscribe(pubsub, "logs:all")

    if agent_id do
      PubSub.subscribe(pubsub, "logs:agent:#{agent_id}")
    end

    {:ok,
     socket
     |> assign(:pubsub, pubsub)
     |> assign(:agent_id, agent_id)
     |> assign(:level, params["level"])
     |> assign(:logs, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    old_agent_id = socket.assigns[:agent_id]
    new_agent_id = params["agent_id"]
    pubsub = socket.assigns[:pubsub]

    # Update subscriptions if agent_id changed
    if connected?(socket) && old_agent_id != new_agent_id do
      if old_agent_id do
        PubSub.unsubscribe(pubsub, "logs:agent:#{old_agent_id}")
      end

      if new_agent_id do
        PubSub.subscribe(pubsub, "logs:agent:#{new_agent_id}")
      end
    end

    {:noreply,
     socket
     |> assign(:agent_id, new_agent_id)
     |> assign(:level, params["level"])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="log-view-page">
      <%= for log <- filter_logs(@logs, @level) do %>
        <div class="log-entry">
          <%= log[:message] || log.message %>
        </div>
      <% end %>

      <.live_component
        module={QuoracleWeb.UI.LogView}
        id="log-view"
        logs={@logs}
        agent_id={@agent_id}
        pubsub={@pubsub}
      />
    </div>
    """
  end

  # PubSub message handlers
  @impl true
  def handle_info({:log_entry, log}, socket) do
    # Add the log to our list and update the view
    logs = socket.assigns.logs ++ [log]
    {:noreply, assign(socket, :logs, logs)}
  end

  @impl true
  def handle_info({:test_event, _payload}, socket) do
    # For tests - trigger update
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Helper functions
  defp filter_logs(logs, nil), do: logs

  defp filter_logs(logs, level) when level in ["debug", "info", "warn", "error"] do
    level_atom = String.to_existing_atom(level)
    level_hierarchy = [:debug, :info, :warn, :error]
    min_level_index = Enum.find_index(level_hierarchy, &(&1 == level_atom))

    Enum.filter(logs, fn log ->
      log_level = log[:level] || log.level
      log_level_index = Enum.find_index(level_hierarchy, &(&1 == log_level))
      log_level_index && log_level_index >= min_level_index
    end)
  end

  defp filter_logs(logs, _), do: logs
end
