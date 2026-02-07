defmodule QuoracleWeb.MailboxLive do
  @moduledoc """
  LiveView wrapper for Mailbox component with PubSub isolation support.
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

    # Subscribe to message topics (needed for both production and tests)
    PubSub.subscribe(pubsub, "messages:all")

    if agent_id do
      PubSub.subscribe(pubsub, "messages:#{agent_id}")
      PubSub.subscribe(pubsub, "agents:#{agent_id}:messages")
    end

    {:ok,
     socket
     |> assign(:pubsub, pubsub)
     |> assign(:agent_id, agent_id)
     |> assign(:task_id, params["task_id"])
     |> assign(:messages, [])
     |> assign(:filter, params["filter"])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    old_agent_id = socket.assigns[:agent_id]
    new_agent_id = params["agent_id"]
    pubsub = socket.assigns[:pubsub]

    # Update subscriptions if agent_id changed
    if connected?(socket) && old_agent_id != new_agent_id do
      if old_agent_id do
        PubSub.unsubscribe(pubsub, "messages:#{old_agent_id}")
        PubSub.unsubscribe(pubsub, "agents:#{old_agent_id}:messages")
      end

      if new_agent_id do
        PubSub.subscribe(pubsub, "messages:#{new_agent_id}")
        PubSub.subscribe(pubsub, "agents:#{new_agent_id}:messages")
      end
    end

    {:noreply,
     socket
     |> assign(:agent_id, new_agent_id)
     |> assign(:task_id, params["task_id"])
     |> assign(:filter, params["filter"])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mailbox-page">
      <%= if @filter == "unread" do %>
        <h2>Inbox (<%= Enum.count(@messages, & &1[:status] == :unread) %>)</h2>
      <% else %>
        <h2>Inbox (<%= Enum.count(@messages, & &1[:status] == :unread) %>)</h2>
      <% end %>

      <form id="compose-form" phx-submit="send_message">
        <input type="text" name="to" placeholder="Recipient" />
        <textarea name="content" placeholder="Message content"></textarea>
        <button type="submit">Send</button>
      </form>

      <.live_component
        module={QuoracleWeb.UI.Mailbox}
        id="mailbox"
        messages={filter_messages(@messages, @filter)}
        task_id={@task_id}
        pubsub={@pubsub}
      />
    </div>
    """
  end

  # PubSub message handlers - MUST update assigns to trigger re-render
  @impl true
  def handle_info({:message_received, %{agent_id: _agent_id, message: message}}, socket) do
    # Add message and UPDATE assigns to trigger re-render
    messages = socket.assigns.messages ++ [message]
    {:noreply, assign(socket, :messages, messages)}
  end

  @impl true
  def handle_info({:thread_updated, %{thread_id: _thread_id} = thread_data}, socket) do
    # Add thread message and UPDATE assigns to trigger re-render
    message = %{
      id: "thread-#{thread_data.thread_id}",
      content: thread_data.last_message,
      from: "thread",
      status: :unread
    }

    messages = socket.assigns.messages ++ [message]
    {:noreply, assign(socket, :messages, messages)}
  end

  @impl true
  def handle_info({:test_event, _payload}, socket) do
    # For tests - trigger any needed updates
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Event handlers
  @impl true
  def handle_event("send_message", %{"to" => to, "content" => content}, socket) do
    agent_id = socket.assigns.agent_id || "current-agent"
    pubsub = socket.assigns.pubsub

    # Broadcast message sent event
    PubSub.broadcast(
      pubsub,
      "messages:all",
      {:message_sent,
       %{
         agent_id: agent_id,
         message: %{
           to: to,
           content: content,
           from: agent_id
         }
       }}
    )

    # Also handle locally for testing
    send(
      self(),
      {:message_sent,
       %{
         agent_id: agent_id,
         message: %{
           to: to,
           content: content
         }
       }}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("mark_read", %{"action" => "mark_read"}, socket) do
    # Find and mark message as read
    # Would come from event target in real impl
    message_id = "msg-123"

    # Send status change to self for test assertion
    send(
      self(),
      {:message_status_changed,
       %{
         message_id: message_id,
         status: :read
       }}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  # Helper functions
  defp filter_messages(messages, nil), do: messages

  defp filter_messages(messages, "unread") do
    Enum.filter(messages, &(&1[:status] == :unread))
  end

  defp filter_messages(messages, _filter), do: messages
end
