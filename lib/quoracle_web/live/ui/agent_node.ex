defmodule QuoracleWeb.UI.AgentNode do
  @moduledoc """
  Recursive LiveComponent for rendering individual agent nodes in the task tree.
  Supports status display, expand/collapse, selection, cost/budget badges,
  TODO display, and direct message forms.

  v7.0: Evolved to replace TaskTree's function component. Now accepts centralized
  state (selected_agent_id, expanded_set) from parent TaskTree and computes
  per-node booleans in update/2 for efficient per-node diffing.
  """

  use QuoracleWeb, :live_component

  alias QuoracleWeb.UI.BudgetBadge
  alias QuoracleWeb.UI.TaskTree.MessageForm
  alias QuoracleWeb.UI.TaskTree.TodoDisplay

  import QuoracleWeb.UI.TaskTree.BudgetHelpers, only: [build_agent_budget_summary: 2]
  import QuoracleWeb.UI.TaskTree.Helpers, only: [state_icon: 1, todo_state_class: 1]

  # Null guard: nil agent renders empty (no crash)
  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(%{agent: nil} = assigns) do
    ~H"""
    <div class="agent-node-empty"></div>
    """
  end

  def render(assigns) do
    ~H"""
    <div
      id={"agent-node-#{@agent[:agent_id]}"}
      class="agent-node"
      data-agent-id={@agent[:agent_id]}
      data-depth={@depth}
    >
      <div
        class={"agent-row flex items-center p-1 hover:bg-gray-50 cursor-pointer #{if @selected, do: "bg-blue-100 agent-selected"}"}
        phx-click="select_agent"
        phx-value-agent-id={@agent[:agent_id]}
        phx-target={@target || @myself}
      >
        <!-- Expand/Collapse Icon -->
        <%= if length(@agent[:children] || []) > 0 do %>
          <button
            phx-click="toggle_expand"
            phx-value-agent-id={@agent[:agent_id]}
            phx-target={@target || @myself}
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
          id={"cost-badge-#{@component_prefix}#{@agent[:agent_id]}"}
          mode={:badge}
          agent_id={@agent[:agent_id]}
          total_cost={agent_total(@cost_data, @agent[:agent_id])}
          precomputed_total_cost?={@use_precomputed_costs}
        />

        <!-- Budget Badge -->
        <%= if @agent[:budget_data] do %>
          <BudgetBadge.budget_badge summary={build_agent_budget_summary(@agent, agent_cost_for_budget(@cost_data, @agent))} />
        <% end %>
      </div>

      <!-- Direct Message Form -->
      <%= if @target do %>
        <MessageForm.render
          agent={@agent}
          agent_alive_map={@agent_alive_map}
          message_forms={@message_forms}
          target={@target}
        />
      <% else %>
        <!-- Legacy: local message form for isolated tests -->
        <%= if @agent_alive and is_nil(@agent[:parent_id]) do %>
          <%= if @message_form_expanded do %>
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
      <% end %>

      <!-- TODO display -->
      <%= if @target do %>
        <!-- When rendered from TaskTree: always show todos (TaskTree pattern) -->
        <TodoDisplay.render agent={@agent} />
      <% else %>
        <!-- Legacy isolated mode: show todos only when expanded -->
        <%= if @expanded and @agent[:todos] do %>
          <div class="todos-section ml-4 mt-2 p-2 bg-gray-50 rounded">
            <h4 class="text-xs font-semibold text-gray-600 mb-1">TODOs</h4>
            <%= if Enum.empty?(@agent[:todos]) do %>
              <p class="text-xs text-gray-400">No current tasks</p>
            <% else %>
              <ul class="space-y-1">
                <%= for todo <- @agent[:todos] do %>
                  <li class={"todo-item text-xs flex items-start gap-2 #{todo_state_class(todo[:state])}"}>
                    <span class="state-badge"><%= state_icon(todo[:state]) %></span>
                    <span class="flex-1"><%= todo[:content] %></span>
                  </li>
                <% end %>
              </ul>
            <% end %>
          </div>
        <% end %>
      <% end %>

      <!-- Children (recursive) -->
      <%= if @expanded and @agent[:children] do %>
        <div class="children ml-4">
          <%= for child_id <- Enum.uniq(@agent[:children]) do %>
            <.live_component
              module={__MODULE__}
              id={"agent-node-#{child_id}"}
              agent={lookup_child(@agents, child_id)}
              agents={@agents}
              selected_agent_id={@selected_agent_id}
              expanded_set={@expanded_set}
              depth={@depth + 1}
              target={@target || @myself}
              agent_alive={Map.get(@agent_alive_map, child_id, false)}
              agent_alive_map={@agent_alive_map}
              root_pid={@root_pid}
              message_forms={@message_forms}
              cost_data={@cost_data}
              use_precomputed_costs={@use_precomputed_costs}
              component_prefix={@component_prefix}
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

    # Check if centralized state (from TaskTree parent) is provided
    has_centralized_state = Map.has_key?(assigns, :expanded_set)

    socket =
      socket
      |> assign(safe_assigns)
      |> assign_new(:depth, fn -> 0 end)
      |> assign_new(:agent_alive, fn -> false end)
      |> assign_new(:agents, fn -> %{} end)
      |> assign_new(:agent_alive_map, fn -> %{} end)
      |> assign_new(:target, fn -> nil end)
      |> assign_new(:root_pid, fn -> nil end)
      |> assign_new(:message_forms, fn -> %{} end)
      |> assign_new(:cost_data, fn -> %{agents: %{}, tasks: %{}} end)
      |> assign_new(:use_precomputed_costs, fn -> false end)
      |> assign_new(:component_prefix, fn -> "" end)
      |> assign_new(:selected_agent_id, fn -> nil end)
      |> assign_new(:expanded_set, fn -> MapSet.new() end)
      # Legacy assigns for isolated tests
      |> assign_new(:message_form_expanded, fn -> false end)
      |> assign_new(:message_input, fn -> "" end)

    # Compute booleans from centralized state when parent passes expanded_set/selected_agent_id.
    # When rendered in isolation (old tests pass expanded/selected directly), preserve those values.
    if has_centralized_state do
      agent = socket.assigns[:agent]
      agent_id = agent && agent[:agent_id]

      selected = agent_id != nil and agent_id == socket.assigns.selected_agent_id
      expanded = agent_id != nil and MapSet.member?(socket.assigns.expanded_set, agent_id)

      {:ok, assign(socket, selected: selected, expanded: expanded)}
    else
      socket =
        socket
        |> assign_new(:expanded, fn -> false end)
        |> assign_new(:selected, fn -> false end)

      {:ok, socket}
    end
  end

  defp agent_total(cost_data, agent_id), do: get_in(cost_data, [:agents, agent_id])

  # For budget badge: use precomputed cost from cost_data, falling back to agent's
  # own spent field (used by isolated tests that set spent directly on agent data)
  defp agent_cost_for_budget(cost_data, agent) do
    agent_total(cost_data, agent[:agent_id]) || agent[:spent]
  end

  # Look up child from agents map, falling back to a minimal stub when agents
  # map doesn't contain the child (legacy isolated mode without agents map)
  defp lookup_child(agents, child_id) do
    Map.get(agents, child_id) ||
      %{agent_id: child_id, status: :idle, children: []}
  end

  # Legacy event handlers for isolated tests (when target is nil / @myself)
  @doc """
  Handles expand/collapse toggle for the agent node (legacy isolated mode).
  """
  @impl true
  @spec handle_event(binary(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_expand", %{"agent-id" => agent_id}, socket) do
    send(self(), {:toggle_expand, agent_id})
    {:noreply, assign(socket, expanded: !socket.assigns.expanded)}
  end

  @impl true
  def handle_event("select_agent", %{"agent-id" => agent_id}, socket) do
    send(self(), {:select_agent, agent_id})
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
end
