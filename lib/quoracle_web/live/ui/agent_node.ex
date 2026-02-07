defmodule QuoracleWeb.UI.AgentNode do
  @moduledoc """
  Live component for rendering individual agent nodes in the task tree.
  Supports status display, expand/collapse, and selection.
  """

  use QuoracleWeb, :live_component

  alias QuoracleWeb.UI.BudgetBadge

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div 
      id={"agent-node-#{@agent[:agent_id]}"} 
      class="agent-node"
      data-depth={@depth}
      phx-hook="AgentNode"
    >
      <div 
        class={"agent-row flex items-center p-1 hover:bg-gray-50 cursor-pointer #{if @selected, do: "bg-blue-100 agent-selected"}"}
        phx-click="select_agent"
        phx-value-agent-id={@agent[:agent_id]}
        phx-target={@myself}
      >
        <!-- Expand/Collapse Icon -->
        <%= if length(@agent[:children] || []) > 0 do %>
          <button
            phx-click="toggle_expand"
            phx-value-agent-id={@agent[:agent_id]}
            phx-target={@myself}
            class="mr-2"
          >
            <%= if @expanded do %>
              <span class="icon-collapse">▼</span>
            <% else %>
              <span class="icon-expand">▶</span>
            <% end %>
          </button>
        <% else %>
          <span class="mr-2 invisible">▶</span>
        <% end %>
        
        <!-- Loading Indicator -->
        <%= if @agent[:status] == :initializing do %>
          <span class="loading-spinner mr-2">⟳</span>
        <% end %>
        
        <!-- Agent Info -->
        <span class={"agent-info flex-1 status-#{@agent[:status] || :idle}"}>
          <%= @agent[:agent_id] %>
          <%= if @agent[:status] == :working and @agent[:current_action] do %>
            <span class="text-sm text-gray-500 ml-2">(<%= @agent[:current_action] %>)</span>
          <% end %>
        </span>
        
        <!-- Avatar/Initial -->
        <span class={"avatar-agent mr-2 w-6 h-6 rounded-full bg-gray-300 flex items-center justify-center text-xs #{status_color(@agent[:status])}"}>
          <%= String.first(@agent[:agent_id] || "A") |> String.upcase() %>
        </span>
        
        <!-- Status Indicator -->
        <span class={"status-indicator px-2 py-1 text-xs rounded status-#{@agent[:status] || :idle} #{status_class(@agent[:status])}"}>
          <%= @agent[:status] || :idle %>
        </span>

        <!-- Cost Badge -->
        <.live_component
          module={QuoracleWeb.Live.UI.CostDisplay}
          id={"cost-badge-#{@agent[:agent_id]}"}
          mode={:badge}
          agent_id={@agent[:agent_id]}
          costs_updated_at={@costs_updated_at}
        />

        <!-- Budget Badge -->
        <%= if @agent[:budget_data] do %>
          <BudgetBadge.budget_badge summary={build_budget_summary(@agent)} class="ml-2" />
        <% end %>
      </div>

      <!-- Direct Message Button (only for alive root agents) -->
      <%= if @agent_alive and is_nil(@agent[:parent_id]) do %>
        <%= if @message_form_expanded do %>
          <!-- Inline message form -->
          <div class="message-form ml-4 mt-2 p-2 bg-blue-50 rounded">
            <form phx-submit="send_direct_message" phx-target={@myself}>
              <textarea
                name="content"
                phx-change="update_message_input"
                phx-target={@myself}
                placeholder="Type your message..."
                class="w-full p-2 border rounded text-sm"
                rows="3"
              ><%= @message_input %></textarea>
              <div class="flex gap-2 mt-2">
                <button
                  type="submit"
                  class="px-3 py-1 bg-blue-500 text-white rounded text-sm hover:bg-blue-600"
                >
                  Send
                </button>
                <button
                  type="button"
                  phx-click="cancel_message"
                  phx-target={@myself}
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
              phx-value-agent-id={@agent[:agent_id]}
              phx-target={@myself}
              class="px-2 py-1 bg-blue-500 text-white rounded text-xs hover:bg-blue-600"
            >
              Send Message
            </button>
          </div>
        <% end %>
      <% end %>

      <!-- TODO display (Packet 3) -->
      <%= if @expanded and @agent[:todos] do %>
        <div class="todos-section ml-4 mt-2 p-2 bg-gray-50 rounded">
          <h4 class="text-xs font-semibold text-gray-600 mb-1">TODOs</h4>
          <%= if Enum.empty?(@agent[:todos]) do %>
            <p class="text-xs text-gray-400">No current tasks</p>
          <% else %>
            <ul class="space-y-1">
              <%= for {todo, _idx} <- Enum.with_index(@agent[:todos]) do %>
                <li class={"todo-item text-xs flex items-start gap-2 #{todo_state_class(todo.state)}"}>
                  <span class="state-badge"><%= state_icon(todo.state) %></span>
                  <span class="flex-1"><%= todo.content %></span>
                </li>
              <% end %>
            </ul>
          <% end %>
        </div>
      <% end %>

      <!-- Cost Summary and Detail (expanded view) -->
      <%= if @expanded do %>
        <div class="cost-section ml-4 mt-2">
          <.live_component
            module={QuoracleWeb.Live.UI.CostDisplay}
            id={"cost-summary-#{@agent[:agent_id]}"}
            mode={:summary}
            agent_id={@agent[:agent_id]}
            costs_updated_at={@costs_updated_at}
          />
        </div>
        <div class="cost-detail ml-4 mt-2">
          <.live_component
            module={QuoracleWeb.Live.UI.CostDisplay}
            id={"cost-detail-#{@agent[:agent_id]}"}
            mode={:detail}
            agent_id={@agent[:agent_id]}
            costs_updated_at={@costs_updated_at}
            expanded={true}
          />
        </div>
      <% end %>

      <!-- Children (recursive) -->
      <%= if @expanded and @agent[:children] do %>
        <div class="children ml-4 expanding">
          <%= for child_id <- @agent[:children] do %>
            <% child = get_child_agent(child_id, assigns) %>
            <.live_component
              module={__MODULE__}
              id={"agent-node-#{child_id}"}
              agent={child}
              depth={@depth + 1}
              expanded={false}
              selected={child[:agent_id] == assigns[:selected_agent_id]}
              target={@myself}
              agent_alive={Map.get(assigns[:agent_alive_map] || %{}, child_id, false)}
              root_pid={assigns[:root_pid]}
              costs_updated_at={@costs_updated_at}
            />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    # Filter out reserved assigns
    safe_assigns = Map.drop(assigns, [:myself])

    {:ok,
     socket
     |> assign(safe_assigns)
     |> assign_new(:expanded, fn -> false end)
     |> assign_new(:selected, fn -> false end)
     |> assign_new(:depth, fn -> 0 end)
     |> assign_new(:agent_alive, fn -> false end)
     |> assign_new(:message_form_expanded, fn -> false end)
     |> assign_new(:message_input, fn -> "" end)
     |> assign_new(:costs_updated_at, fn -> nil end)}
  end

  @doc """
  Handles expand/collapse toggle for the agent node.
  """
  @impl true
  @spec handle_event(binary(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_expand", %{"agent-id" => agent_id}, socket) do
    send(self(), {:toggle_expand, agent_id})
    send(self(), {:toggle_expand_requested, agent_id})
    {:noreply, assign(socket, expanded: !socket.assigns.expanded)}
  end

  @impl true
  def handle_event("select_agent", %{"agent-id" => agent_id}, socket) do
    send(self(), {:select_agent, agent_id})
    send(self(), {:select_agent_requested, agent_id})
    {:noreply, socket}
  end

  @impl true
  def handle_event("mouseenter", _params, socket) do
    {:noreply, assign(socket, :hover, true)}
  end

  @impl true
  def handle_event("mouseleave", _params, socket) do
    {:noreply, assign(socket, :hover, false)}
  end

  @impl true
  def handle_event("show_message_form", _params, socket) do
    {:noreply, assign(socket, message_form_expanded: true)}
  end

  @impl true
  def handle_event("cancel_message", _params, socket) do
    {:noreply, assign(socket, message_form_expanded: false, message_input: "")}
  end

  @impl true
  def handle_event("update_message_input", %{"content" => content}, socket) do
    {:noreply, assign(socket, message_input: content)}
  end

  @impl true
  def handle_event("send_direct_message", %{"content" => content}, socket) do
    agent_id = socket.assigns.agent[:agent_id]
    root_pid = socket.assigns[:root_pid]

    if root_pid do
      send(root_pid, {:send_direct_message, agent_id, content})
    end

    {:noreply, assign(socket, message_form_expanded: false, message_input: "")}
  end

  # Private helpers

  defp get_child_agent(child_id, _assigns) do
    # In real implementation, would look up child from agents map
    # For now, create a stub
    %{
      agent_id: child_id,
      status: :idle,
      children: []
    }
  end

  defp status_class(:idle), do: "bg-gray-100 text-gray-600"
  defp status_class(:working), do: "bg-blue-100 text-blue-600"
  defp status_class(:completed), do: "bg-green-100 text-green-600"
  defp status_class(:failed), do: "bg-red-100 text-red-600"
  defp status_class(:initializing), do: "bg-yellow-100 text-yellow-600"
  defp status_class(_), do: "bg-gray-100 text-gray-600"

  defp status_color(:idle), do: "bg-gray-300"
  defp status_color(:working), do: "bg-blue-300"
  defp status_color(:completed), do: "bg-green-300"
  defp status_color(:failed), do: "bg-red-300"
  defp status_color(:initializing), do: "bg-yellow-300"
  defp status_color(_), do: "bg-gray-300"

  # Todo state helpers (Packet 3)
  defp state_icon(:todo), do: "⏳"
  defp state_icon(:pending), do: "⏸️"
  defp state_icon(:done), do: "✅"

  defp todo_state_class(:todo), do: "text-gray-700"
  defp todo_state_class(:pending), do: "text-yellow-600"
  defp todo_state_class(:done), do: "text-green-600 line-through opacity-60"

  # Budget badge helpers
  defp build_budget_summary(agent) do
    budget_data = agent[:budget_data]
    spent = agent[:spent] || Decimal.new(0)
    over_budget = agent[:over_budget] || false

    allocated = budget_data[:allocated] || Decimal.new(0)
    committed = budget_data[:committed] || Decimal.new(0)
    available = Decimal.sub(Decimal.sub(allocated, spent), committed)

    status = determine_budget_status(available, allocated, over_budget)

    %{
      status: status,
      allocated: allocated,
      spent: spent,
      committed: committed,
      available: available
    }
  end

  defp determine_budget_status(_available, _allocated, true), do: :over_budget

  defp determine_budget_status(available, allocated, false) do
    percentage_used =
      if Decimal.compare(allocated, Decimal.new(0)) == :gt do
        Decimal.div(Decimal.sub(allocated, available), allocated)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.to_float()
      else
        0.0
      end

    cond do
      percentage_used >= 100 -> :over_budget
      percentage_used >= 80 -> :warning
      true -> :ok
    end
  end
end
