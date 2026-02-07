defmodule QuoracleWeb.UI.Message do
  use QuoracleWeb, :live_component

  @moduledoc """
  Message component with accordion design (collapsed/expanded views).

  Packet 1: Display only - chevron, preview, badges
  Packet 2: Reply functionality (TBD)
  """

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:reply_input, fn -> "" end)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    # Use the ID from the message struct (mailbox ensures it exists)
    msg_id = assigns.message.id
    assigns = assign(assigns, :msg_id, msg_id)

    ~H"""
    <div
      id={"message-#{@msg_id}"}
      class={message_row_class(@message, @expanded)}
      data-message-id={@msg_id}
    >
      <div
        class="message-header flex items-start cursor-pointer"
        phx-click="toggle_message"
        phx-value-message-id={@msg_id}
        phx-target={phx_target(@target, @myself)}
      >
        <span class="chevron text-gray-500 mr-2">
          <%= if @expanded, do: "▼", else: "▶" %>
        </span>

        <span class={badge_class(@message)}>
          <%= badge_text(@message) %>
        </span>

        <%= if @expanded do %>
          <div class="full-content flex-1 ml-3">
            <div class="text-gray-800 whitespace-pre-wrap"><%= content_text(@message.content) %></div>
            <div class="timestamp text-xs text-gray-500 mt-1">
              <%= format_timestamp(@message.timestamp) %>
            </div>
          </div>
        <% else %>
          <span class="preview text-gray-600 ml-3 truncate">
            <%= preview_content(@message.content) %>
          </span>
        <% end %>
      </div>

      <%= if @expanded and @reply_form_visible and @message.from == :agent do %>
        <div class="reply-form-container ml-9 mt-3">
          <form phx-submit="send_reply" phx-target={@myself} phx-value-message-id={@message.id}>
            <textarea
              name="content"
              phx-change="update_reply"
              phx-target={@myself}
              value={@reply_input}
              placeholder="Type your reply..."
              class="w-full p-2 border rounded text-sm"
              rows="3"
            ><%= @reply_input %></textarea>
            <button
              type="submit"
              {if not @agent_alive, do: [disabled: true], else: []}
              class={if @agent_alive, do: "mt-2 px-4 py-2 bg-blue-500 text-white rounded text-sm", else: "mt-2 px-4 py-2 bg-gray-300 text-white rounded text-sm"}
            >
              Send
            </button>
            <%= if not @agent_alive do %>
              <span class="ml-2 text-sm text-red-600">Agent no longer active</span>
            <% end %>
          </form>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_message", %{"message-id" => message_id}, socket) do
    message_id = String.to_integer(message_id)
    send(socket.assigns.target, {:toggle_message, message_id})
    {:noreply, socket}
  end

  @impl true
  def handle_event("send_reply", params, socket) do
    if socket.assigns.agent_alive do
      content = params["content"] || ""
      message_id = socket.assigns.message.id

      # Send reply to appropriate destination
      send_reply_message(socket, socket.assigns.target, message_id, content)

      {:noreply, assign(socket, :reply_input, "")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_reply", %{"content" => content}, socket) do
    {:noreply, assign(socket, :reply_input, content)}
  end

  # Send to PID directly (used in tests)
  defp send_reply_message(_socket, target, message_id, content) when is_pid(target) do
    send(target, {:send_reply, message_id, content})
  end

  # Send to LiveView root when target is component ref (used in production)
  defp send_reply_message(socket, target, message_id, content) when not is_nil(target) do
    send(socket.root_pid, {:send_reply, message_id, content})
  end

  # No target specified
  defp send_reply_message(_socket, nil, _message_id, _content), do: :ok

  defp phx_target(target, myself) when is_pid(target), do: myself
  defp phx_target(target, _myself), do: target

  defp message_row_class(%{from: :user}, expanded) do
    base =
      "message-row message-user p-3 hover:bg-gray-50 border-b"

    if expanded, do: "#{base} expanded", else: "#{base} collapsed"
  end

  defp message_row_class(%{from: :agent}, expanded) do
    base =
      "message-row message-agent p-3 hover:bg-blue-50 border-b"

    if expanded, do: "#{base} expanded", else: "#{base} collapsed"
  end

  defp message_row_class(_, expanded) do
    base = "message-row p-3 hover:bg-gray-50 border-b"
    if expanded, do: "#{base} expanded", else: "#{base} collapsed"
  end

  defp badge_class(%{from: :user}) do
    "badge inline-block px-2 py-1 text-xs font-semibold rounded bg-blue-500 text-white"
  end

  defp badge_class(%{from: :agent}) do
    "badge inline-block px-2 py-1 text-xs font-semibold rounded bg-green-500 text-white"
  end

  defp badge_class(_) do
    "badge inline-block px-2 py-1 text-xs font-semibold rounded bg-gray-500 text-white"
  end

  defp badge_text(%{from: :user}), do: "You"
  defp badge_text(%{from: :agent, sender_id: nil}), do: "Unknown Agent"
  defp badge_text(%{from: :agent, sender_id: sender_id}), do: sender_id
  defp badge_text(_), do: "Unknown"

  defp preview_content(nil), do: "(empty message)"
  defp preview_content(""), do: "(empty message)"

  defp preview_content(content) when is_binary(content) do
    if String.length(content) <= 80 do
      content
    else
      String.slice(content, 0, 80) <> "..."
    end
  end

  defp preview_content(_), do: "(empty message)"

  defp content_text(nil), do: "(empty message)"
  defp content_text(""), do: "(empty message)"
  defp content_text(content) when is_binary(content), do: content
  defp content_text(_), do: "(empty message)"

  defp format_timestamp(nil), do: "No timestamp"

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_timestamp(_), do: "No timestamp"
end
