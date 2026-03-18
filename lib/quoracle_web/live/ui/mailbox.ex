defmodule QuoracleWeb.UI.Mailbox do
  @moduledoc """
  Live component for displaying messages in accordion-style inbox.
  """

  use QuoracleWeb, :live_component

  @doc false
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
       agent_alive_map: %{},
       component_pid: self(),
       test_pid: nil
     )}
  end

  @doc false
  @impl true
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    safe_assigns = Map.drop(assigns, [:myself])

    pubsub = safe_assigns[:pubsub] || socket.assigns[:pubsub] || Quoracle.PubSub
    registry = safe_assigns[:registry] || socket.assigns[:registry] || Quoracle.Registry
    agent_alive_map = safe_assigns[:agent_alive_map] || socket.assigns[:agent_alive_map] || %{}
    expanded_messages = socket.assigns[:expanded_messages] || MapSet.new()

    socket =
      socket
      |> assign(safe_assigns)
      |> assign(:pubsub, pubsub)
      |> assign(:registry, registry)
      |> assign(:expanded_messages, expanded_messages)
      |> assign(:agent_alive_map, agent_alive_map)
      |> assign(:component_pid, self())

    notify_test_pid(socket.assigns[:test_pid], {:mailbox_updated, Map.keys(safe_assigns)})

    {:ok, socket}
  end

  @doc false
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
              registry={@registry}
              pubsub={@pubsub}
            />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  @doc false
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

  @doc false
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

  @doc false
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
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

  defp get_agent_alive(message, agent_alive_map) do
    case message do
      %{from: :agent, sender_id: sender_id} -> Map.get(agent_alive_map, sender_id, false)
      _ -> true
    end
  end

  defp notify_test_pid(nil, _message), do: :ok

  defp notify_test_pid(test_pid, message) when is_pid(test_pid) do
    send(test_pid, message)
  end
end
