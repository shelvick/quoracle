defmodule QuoracleWeb.UI.Mailbox do
  @moduledoc """
  Live component for displaying messages in accordion-style inbox.

  Packet 1: Message display with expand/collapse state management
  Packet 2: Reply functionality (TBD)
  """

  use QuoracleWeb, :live_component

  @impl true
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    {:ok,
     assign(socket,
       messages: [],
       expanded_messages: MapSet.new(),
       task_id: nil,
       # Wait for parent to provide isolated pubsub/registry via update/2
       pubsub: nil,
       registry: nil,
       agents: [],
       agent_alive_map: %{},
       component_pid: self(),
       lifecycle_subscribed: false
     )}
  end

  @impl true
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    safe_assigns = Map.drop(assigns, [:myself])

    pubsub = safe_assigns[:pubsub] || socket.assigns[:pubsub] || Quoracle.PubSub
    registry = safe_assigns[:registry] || socket.assigns[:registry] || Quoracle.Registry
    agents = safe_assigns[:agents] || socket.assigns[:agents] || []
    expanded_messages = socket.assigns[:expanded_messages] || MapSet.new()

    # Only subscribe if we have valid pubsub AND haven't subscribed yet
    # This prevents subscribing to global PubSub before parent provides isolated instance
    socket =
      if connected?(socket) && pubsub != nil && !socket.assigns[:lifecycle_subscribed] do
        Phoenix.PubSub.subscribe(pubsub, "agents:lifecycle")
        assign(socket, :lifecycle_subscribed, true)
      else
        socket
      end

    agent_alive_map = build_agent_alive_map(agents)

    socket =
      socket
      |> assign(safe_assigns)
      |> assign(:pubsub, pubsub)
      |> assign(:registry, registry)
      |> assign(:agents, agents)
      |> assign(:expanded_messages, expanded_messages)
      |> assign(:agent_alive_map, agent_alive_map)
      |> assign(:component_pid, self())

    {:ok, socket}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div id="mailbox" data-task-id={@task_id} class="mailbox flex flex-col h-full">
      <div class="messages-container flex-1 overflow-y-auto">
        <%= if @messages == [] do %>
          <p class="text-gray-500 p-4">No messages</p>
        <% else %>
          <%= for message <- sort_messages_newest_first(@messages) do %>
            <.live_component
              module={QuoracleWeb.UI.Message}
              id={"message-#{message.id}"}
              message={message}
              expanded={MapSet.member?(@expanded_messages, message.id)}
              reply_form_visible={Map.get(message, :from) == :agent}
              agent_alive={get_agent_alive(message, @agent_alive_map)}
              target={@myself}
              pubsub={@pubsub}
            />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  @spec handle_event(binary(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_message", %{"message-id" => message_id}, socket) do
    message_id = String.to_integer(message_id)

    expanded_messages =
      if MapSet.member?(socket.assigns.expanded_messages, message_id) do
        MapSet.delete(socket.assigns.expanded_messages, message_id)
      else
        MapSet.put(socket.assigns.expanded_messages, message_id)
      end

    {:noreply, assign(socket, expanded_messages: expanded_messages)}
  end

  @impl true
  def handle_event("send_reply", %{"message-id" => message_id, "content" => content}, socket) do
    message_id = String.to_integer(message_id)
    message = Enum.find(socket.assigns.messages, &(&1.id == message_id))

    if message do
      sender_id = message.sender_id
      registry = socket.assigns.registry

      case Registry.lookup(registry, {:agent, sender_id}) do
        [{agent_pid, _}] ->
          Quoracle.Agent.Core.send_user_message(agent_pid, content)
          {:noreply, socket}

        [] ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:toggle_message, message_id}, socket) do
    expanded_messages =
      if MapSet.member?(socket.assigns.expanded_messages, message_id) do
        MapSet.delete(socket.assigns.expanded_messages, message_id)
      else
        MapSet.put(socket.assigns.expanded_messages, message_id)
      end

    {:noreply, assign(socket, expanded_messages: expanded_messages)}
  end

  def handle_info({:update_messages, messages}, socket) do
    {:noreply, assign(socket, messages: messages)}
  end

  def handle_info({:new_message, message}, socket) do
    messages = socket.assigns.messages ++ [message]
    {:noreply, assign(socket, messages: messages)}
  end

  def handle_info({:agent_terminated, agent_id}, socket) do
    agent_alive_map = Map.put(socket.assigns.agent_alive_map, agent_id, false)
    {:noreply, assign(socket, agent_alive_map: agent_alive_map)}
  end

  def handle_info({:agent_spawned, agent_id, _pid}, socket) do
    agent_alive_map = Map.put(socket.assigns.agent_alive_map, agent_id, true)
    {:noreply, assign(socket, agent_alive_map: agent_alive_map)}
  end

  def handle_info({:send_reply, message_id, content}, socket) do
    # Receive reply from Message component and route to agent
    message = Enum.find(socket.assigns.messages, &(&1.id == message_id))

    if message do
      sender_id = message.sender_id
      registry = socket.assigns.registry

      case Registry.lookup(registry, {:agent, sender_id}) do
        [{agent_pid, _}] ->
          Quoracle.Agent.Core.send_user_message(agent_pid, content)
          {:noreply, socket}

        [] ->
          # Agent no longer registered
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp sort_messages_newest_first(messages) do
    Enum.sort_by(
      messages,
      fn msg -> Map.get(msg, :timestamp, ~U[1970-01-01 00:00:00Z]) end,
      {:desc, DateTime}
    )
  end

  defp build_agent_alive_map(agents) when is_map(agents) do
    Map.new(agents, fn {agent_id, agent_data} -> {agent_id, agent_data.status != :terminated} end)
  end

  defp build_agent_alive_map(_), do: %{}

  defp get_agent_alive(message, agent_alive_map) do
    case message do
      %{from: :agent, sender_id: sender_id} -> Map.get(agent_alive_map, sender_id, false)
      _ -> true
    end
  end
end
