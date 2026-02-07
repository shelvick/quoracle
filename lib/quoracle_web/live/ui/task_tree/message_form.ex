defmodule QuoracleWeb.UI.TaskTree.MessageForm do
  @moduledoc """
  Message form component for TaskTree inline messaging.
  Extracted to keep TaskTree module under 500 lines.
  """

  use Phoenix.Component

  @doc """
  Renders inline message form for sending direct messages to agents.
  """
  attr(:agent, :map, required: true)
  attr(:agent_alive_map, :map, required: true)
  attr(:message_forms, :map, default: %{})
  attr(:target, :any, required: true)

  def render(assigns) do
    ~H"""
    <%= if Map.get(@agent_alive_map, @agent.agent_id, false) and is_nil(@agent[:parent_id]) do %>
      <% message_form_expanded = Map.get(@message_forms || %{}, @agent.agent_id, %{expanded: false})[:expanded] || false %>
      <%= if message_form_expanded do %>
        <!-- Inline message form -->
        <div class="message-form ml-4 mt-2 p-2 bg-blue-50 rounded">
          <form phx-submit="send_direct_message_tree" phx-target={@target}>
            <input type="hidden" name="agent_id" value={@agent.agent_id} />
            <textarea
              name="content"
              phx-change="update_message_input_tree"
              phx-value-agent-id={@agent.agent_id}
              phx-target={@target}
              placeholder="Type your message..."
              class="w-full p-2 border rounded text-sm"
              rows="3"
            ><%= Map.get(@message_forms, @agent.agent_id, %{input: ""})[:input] %></textarea>
            <div class="flex gap-2 mt-2">
              <button
                type="submit"
                class="px-3 py-1 bg-blue-500 text-white rounded text-sm hover:bg-blue-600"
              >
                Send
              </button>
              <button
                type="button"
                phx-click="cancel_message_tree"
                phx-value-agent-id={@agent.agent_id}
                phx-target={@target}
                class="px-3 py-1 bg-gray-200 text-gray-700 rounded text-sm hover:bg-gray-300"
              >
                Cancel
              </button>
            </div>
          </form>
        </div>
      <% else %>
        <!-- Send Message button -->
        <div class="ml-4 mt-1">
          <button
            phx-click="show_message_form"
            phx-value-agent-id={@agent.agent_id}
            phx-target={@target}
            class="px-2 py-1 bg-blue-500 text-white rounded text-xs hover:bg-blue-600"
          >
            Send Message
          </button>
        </div>
      <% end %>
    <% end %>
    """
  end
end
