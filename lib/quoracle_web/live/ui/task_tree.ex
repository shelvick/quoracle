defmodule QuoracleWeb.UI.TaskTree do
  @moduledoc """
  Live component for displaying hierarchical agent tree.
  Shows agents organized by task with expand/collapse and selection.
  """

  use QuoracleWeb, :live_component

  alias QuoracleWeb.UI.AgentNode
  alias QuoracleWeb.UI.TaskTree.GroveHandlers
  alias QuoracleWeb.UI.TaskTree.Helpers
  alias QuoracleWeb.UI.TaskTree.NewTaskModal

  import QuoracleWeb.UI.TaskTree.BudgetHelpers

  @impl true
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    {:ok,
     assign(socket,
       expanded: MapSet.new(),
       show_modal: false,
       message_forms: %{},
       selected_grove: nil,
       grove_skills_path: nil
     )}
  end

  @impl true
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    # Simple pure component - just assign the data from parent
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:expanded, fn -> MapSet.new() end)
      |> assign_new(:show_modal, fn -> false end)
      |> assign_new(:agent_alive_map, fn -> %{} end)
      |> assign_new(:root_pid, fn -> nil end)
      |> assign_new(:message_forms, fn -> %{} end)
      |> assign_new(:cost_data, fn -> %{agents: %{}, tasks: %{}} end)
      |> assign_new(:use_precomputed_costs, fn -> true end)
      |> assign_new(:profiles, fn -> [] end)
      |> assign_new(:groves, fn -> [] end)
      |> assign_new(:groves_path, fn -> nil end)
      |> assign(
        :display_agents,
        enrich_display_agents(
          assigns[:agents] || socket.assigns[:agents] || %{},
          assigns[:cost_data] || socket.assigns[:cost_data] || %{agents: %{}, tasks: %{}},
          assigns[:agent_alive_map] || socket.assigns[:agent_alive_map] || %{},
          assigns[:message_forms] || socket.assigns[:message_forms] || %{}
        )
      )

    {:ok, socket}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div id="task-tree" class="task-tree h-full overflow-y-auto p-4">
      <div class="flex justify-between items-center mb-4">
        <h2 class="text-lg font-semibold">Task Tree</h2>
        <button
          phx-click="show_modal"
          phx-target={@myself}
          class="px-3 py-1 bg-blue-500 text-white rounded hover:bg-blue-600"
        >
          New Task
        </button>
      </div>

      <%= if map_size(@tasks) == 0 do %>
        <p class="text-gray-500">No active tasks</p>
      <% else %>
        <%= for {task_id, task} <- @tasks do %>
          <div class="task-section mb-4 border-l-2 border-gray-300 pl-3" data-task-id={task_id}>
            <!-- Task header with prompt snippet -->
            <div class="task-header flex justify-between items-start mb-2">
              <div class="flex-1">
                <div class="font-semibold text-sm mb-1">
                  <%= truncate_prompt(task.prompt, 60) %>
                </div>
                <div class="text-xs text-gray-500">
                  ID: <%= task_id %> • <%= format_timestamp(task.updated_at) %> • <%= count_task_agents(@agents, task_id) %> agents
                </div>
              </div>

              <!-- Status badge -->
              <span class={status_badge_class(task.status)}>
                <%= task.status %>
              </span>
            </div>

            <!-- Task-level cost display with per-model breakdown -->
            <div class="task-cost mb-2 text-sm text-gray-600">
              <span class="font-medium">Total Cost:</span>
              <.live_component
                module={QuoracleWeb.Live.UI.CostDisplay}
                id={"task-cost-#{task_id}"}
                mode={:badge}
                task_id={task_id}
                total_cost={task_total(@cost_data, task_id)}
                precomputed_total_cost?={@use_precomputed_costs}
              />
            </div>
            <!-- Per-model cost breakdown -->
            <div class="task-cost-detail mb-2">
              <.live_component
                module={QuoracleWeb.Live.UI.CostDisplay}
                id={"task-cost-detail-#{task_id}"}
                mode={:detail}
                task_id={task_id}
                total_cost={task_total(@cost_data, task_id)}
                precomputed_total_cost?={@use_precomputed_costs}
              />
            </div>

            <!-- Task Budget Summary -->
            <%= if task[:budget_limit] do %>
              <% budget_summary = calculate_task_budget_summary(task.budget_limit, task_total(@cost_data, task_id)) %>
              <div class={"task-budget-summary mb-2 text-sm #{budget_color_class(budget_summary.percentage)} #{if budget_summary.percentage > 100, do: "over-budget", else: ""}"}>
                <div class="flex items-center gap-2">
                  <span class="font-medium">Budget:</span>
                  <span>$<%= budget_summary.spent %> / $<%= Decimal.round(task.budget_limit, 2) %></span>
                  <!-- Edit Budget button (R37, R39) -->
                  <button
                    phx-click="show_budget_editor"
                    phx-value-task-id={task_id}
                    phx-target={@myself}
                    class="px-2 py-1 text-xs bg-gray-100 hover:bg-gray-200 rounded"
                  >
                    Edit Budget
                  </button>
                </div>
                <div class="task-budget-progress mt-1 h-2 bg-gray-200 rounded overflow-hidden">
                  <div
                    class={"h-full #{budget_progress_color(budget_summary.percentage)}"}
                    style={"width: #{min(budget_summary.percentage, 100)}%"}
                  ></div>
                </div>
              </div>
            <% end %>

            <!-- Control buttons -->
            <div class="task-controls flex gap-2 mb-2">
              <%= if task.status == "running" do %>
                <button
                  phx-click="pause_task"
                  phx-value-task-id={task_id}
                  phx-target={@myself}
                  class="px-2 py-1 text-xs bg-yellow-500 text-white rounded"
                >
                  Pause
                </button>
              <% end %>

              <%= if task.status == "pausing" do %>
                <button
                  disabled
                  class="px-2 py-1 text-xs bg-gray-400 text-white rounded cursor-not-allowed"
                >
                  Pausing...
                </button>
              <% end %>

              <%= if task.status == "paused" do %>
                <button
                  phx-click="resume_task"
                  phx-value-task-id={task_id}
                  phx-target={@myself}
                  class="px-2 py-1 text-xs bg-green-500 text-white rounded"
                >
                  Resume
                </button>
              <% end %>

              <%= if task.status in ["pausing", "paused", "completed", "failed"] do %>
                <button
                  phx-click={QuoracleWeb.UtilityComponents.show("#task-tree-confirm-delete-#{task_id}")}
                  class="px-2 py-1 text-xs bg-red-500 text-white rounded"
                >
                  Delete
                </button>
                <!-- Delete confirmation modal - only render when Delete button is visible -->
                <QuoracleWeb.UtilityComponents.modal
                  id={"task-tree-confirm-delete-#{task_id}"}
                  on_confirm="delete_task"
                  task_id={task_id}
                >
                  <:title>Delete Task?</:title>
                  This will permanently delete "<%= truncate_prompt(task.prompt, 40) %>"
                </QuoracleWeb.UtilityComponents.modal>
              <% end %>
            </div>

            <%= if task[:root_agent_id] do %>
              <div class="agent-tree ml-2 mt-2">
                <.live_component
                  module={AgentNode}
                  id={"agent-node-#{task[:root_agent_id]}"}
                  agent={@display_agents[task[:root_agent_id]]}
                  agents={@display_agents}
                  selected_agent_id={@selected_agent_id}
                  expanded_set={@expanded}
                  depth={0}
                  target={@myself}
                  agent_alive={Map.get(@agent_alive_map || %{}, task[:root_agent_id], false)}
                  root_pid={@root_pid}
                  agent_message_form={Map.get(@message_forms || %{}, task[:root_agent_id], %{})}
                  agent_cost={get_in(@cost_data, [:agents, task[:root_agent_id]])}
                  use_precomputed_costs={@use_precomputed_costs}
                  component_prefix="tasktree-"
                />
              </div>
            <% end %>
          </div>
        <% end %>
      <% end %>

      <NewTaskModal.render
        show_modal={@show_modal}
        target={@myself}
        profiles={@profiles}
        groves={@groves}
        selected_grove={@selected_grove}
      />
    </div>
    """
  end

  defp task_total(cost_data, task_id), do: get_in(cost_data, [:tasks, task_id])

  defp enrich_display_agents(agents, cost_data, agent_alive_map, message_forms) do
    Enum.into(agents, %{}, fn {agent_id, agent} ->
      enriched_agent =
        agent
        |> Map.put(:ui_total_cost, get_in(cost_data, [:agents, agent_id]))
        |> Map.put(:ui_alive, Map.get(agent_alive_map, agent_id, false))
        |> Map.put(:ui_message_form, Map.get(message_forms, agent_id, %{}))

      {agent_id, enriched_agent}
    end)
  end

  @doc """
  Handles expand/collapse toggle for agent nodes.
  """
  @impl true
  @spec handle_event(binary(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_expand", %{"agent-id" => agent_id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, agent_id) do
        MapSet.delete(socket.assigns.expanded, agent_id)
      else
        MapSet.put(socket.assigns.expanded, agent_id)
      end

    {:noreply, assign(socket, expanded: expanded)}
  end

  @impl true
  def handle_event("select_agent", %{"agent-id" => agent_id}, socket) do
    send(socket.root_pid, {:select_agent, agent_id})
    {:noreply, socket}
  end

  @impl true
  def handle_event("expand_all", _params, socket) do
    all_agent_ids =
      socket.assigns.agents
      |> Map.keys()
      |> MapSet.new()

    {:noreply, assign(socket, expanded: all_agent_ids)}
  end

  @impl true
  def handle_event("collapse_all", _params, socket) do
    {:noreply, assign(socket, expanded: MapSet.new())}
  end

  @impl true
  def handle_event("pause_task", %{"task-id" => task_id}, socket) do
    send(socket.root_pid, {:pause_task, task_id})
    {:noreply, socket}
  end

  @impl true
  def handle_event("resume_task", %{"task-id" => task_id}, socket) do
    send(socket.root_pid, {:resume_task, task_id})
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_task", %{"task-id" => task_id}, socket) do
    send(socket.root_pid, {:delete_task, task_id})
    {:noreply, socket}
  end

  # Budget editor event (R39)
  @impl true
  def handle_event("show_budget_editor", %{"task-id" => task_id}, socket) do
    send(socket.root_pid, {:show_budget_editor, task_id})
    {:noreply, socket}
  end

  @impl true
  def handle_event("show_modal", _params, socket) do
    {:noreply, assign(socket, show_modal: true)}
  end

  @impl true
  def handle_event("hide_modal", _params, socket) do
    {:noreply, assign(socket, show_modal: false)}
  end

  @impl true
  def handle_event("grove_selected", %{"grove" => ""}, socket) do
    GroveHandlers.handle_grove_cleared(socket)
  end

  @impl true
  def handle_event("grove_selected", %{"grove" => grove_name}, socket) do
    GroveHandlers.handle_grove_selected(grove_name, socket)
  end

  @impl true
  def handle_event("create_task", params, socket) do
    GroveHandlers.handle_create_task(params, socket)
  end

  @impl true
  def handle_event("show_message_form", %{"agent-id" => agent_id}, socket) do
    message_forms = Map.put(socket.assigns.message_forms, agent_id, %{expanded: true, input: ""})
    {:noreply, assign(socket, message_forms: message_forms)}
  end

  @impl true
  def handle_event("cancel_message_tree", %{"agent-id" => agent_id}, socket) do
    message_forms = Map.delete(socket.assigns.message_forms, agent_id)
    {:noreply, assign(socket, message_forms: message_forms)}
  end

  @impl true
  def handle_event("update_message_input_tree", params, socket) do
    # phx-change doesn't include phx-value-* attributes
    # We need to find which agent's form is expanded
    agent_id =
      socket.assigns.message_forms
      |> Enum.find_value(fn {id, form} -> if form[:expanded], do: id end)

    content = params["content"] || ""

    if agent_id do
      message_forms =
        Map.put(socket.assigns.message_forms, agent_id, %{expanded: true, input: content})

      {:noreply, assign(socket, message_forms: message_forms)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "send_direct_message_tree",
        %{"agent_id" => agent_id, "content" => content},
        socket
      ) do
    send(socket.root_pid, {:send_direct_message, agent_id, content})
    message_forms = Map.delete(socket.assigns.message_forms, agent_id)
    {:noreply, assign(socket, message_forms: message_forms)}
  end

  # Helper functions for task tree display
  # Delegate to helper functions
  defdelegate truncate_prompt(prompt, max_length), to: Helpers
  defdelegate format_timestamp(timestamp), to: Helpers
  defdelegate status_badge_class(status), to: Helpers
  defdelegate state_icon(state), to: Helpers
  defdelegate todo_state_class(state), to: Helpers

  # Count agents belonging to a task
  defp count_task_agents(agents, task_id) do
    agents
    |> Enum.count(fn {_id, agent} -> agent[:task_id] == task_id end)
  end
end
