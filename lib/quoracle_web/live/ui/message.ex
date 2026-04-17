defmodule QuoracleWeb.UI.Message do
  use QuoracleWeb, :live_component

  @moduledoc """
  Message component with accordion display and optional reply form.
  """

  @doc false
  @impl true
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:reply_input, fn -> "" end)

    {:ok, socket}
  end

  @doc false
  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
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
            <div class="text-gray-800 prose prose-sm max-w-none"><%= render_markdown(@message.content) %></div>
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
          <form
            phx-submit="send_reply"
            phx-target={@myself}
            phx-value-message-id={@message.id}
          >
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

  @doc false
  @impl true
  @spec handle_event(binary(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_message", %{"message-id" => message_id}, socket) do
    message_id = String.to_integer(message_id)
    send(socket.assigns.target, {:toggle_message, message_id})
    {:noreply, socket}
  end

  @doc false
  def handle_event("send_reply", params, socket) do
    if socket.assigns.agent_alive do
      content = params["content"] || ""
      message_id = socket.assigns.message.id

      case send_reply_message(socket, socket.assigns.target, message_id, content) do
        :ok -> {:noreply, assign(socket, :reply_input, "")}
        :error -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @doc false
  def handle_event("update_reply", %{"content" => content}, socket) do
    {:noreply, assign(socket, :reply_input, content)}
  end

  # Send to PID directly (used in standalone component tests)
  defp send_reply_message(_socket, target, message_id, content) when is_pid(target) do
    send(target, {:send_reply, message_id, content})
    :ok
  end

  # Send directly to the agent when registry is available (used in Mailbox/Dashboard)
  defp send_reply_message(socket, _target, _message_id, content) do
    case socket.assigns[:registry] do
      nil ->
        send_reply_via_root(socket, socket.assigns.target, socket.assigns.message.id, content)

      registry ->
        send_reply_via_registry(socket.assigns.message, registry, content)
    end
  end

  defp send_reply_via_registry(%{sender_id: sender_id}, registry, content) do
    case Registry.lookup(registry, {:agent, sender_id}) do
      [{agent_pid, _}] ->
        Quoracle.Agent.Core.send_user_message(agent_pid, content)
        :ok

      [] ->
        :error
    end
  end

  defp send_reply_via_root(socket, target, message_id, content) when not is_nil(target) do
    send(socket.root_pid, {:send_reply, message_id, content})
    :ok
  end

  defp send_reply_via_root(_socket, nil, _message_id, _content), do: :error

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

  defp badge_text(%{from: :system, sender_id: sender_id}) when not is_nil(sender_id),
    do: sender_id

  defp badge_text(%{from: :system}), do: "System"
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

  defp render_markdown(nil), do: "(empty message)"
  defp render_markdown(""), do: "(empty message)"

  defp render_markdown(content) when is_binary(content) do
    case Earmark.as_html(content, compact_output: true) do
      {:ok, html, _} -> Phoenix.HTML.raw(sanitize_html(html))
      {:error, html, _} -> Phoenix.HTML.raw(sanitize_html(html))
    end
  end

  defp render_markdown(_), do: "(empty message)"

  defp sanitize_html(html) do
    html
    |> String.replace(~r/<script[\s>].*?<\/script>/is, "")
    |> String.replace(~r/<iframe[\s>].*?<\/iframe>/is, "")
    |> String.replace(~r/<object[\s>].*?<\/object>/is, "")
    |> String.replace(~r/<embed[^>]*\/?>/is, "")
    |> String.replace(~r/\s+on\w+=\s*"[^"]*"/i, "")
    |> String.replace(~r/\s+on\w+=\s*'[^']*'/i, "")
    |> String.replace(~r/href\s*=\s*"javascript:[^"]*"/i, "href=\"#\"")
  end

  defp format_timestamp(nil), do: "No timestamp"

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_timestamp(_), do: "No timestamp"
end
