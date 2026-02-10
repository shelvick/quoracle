defmodule QuoracleWeb.UI.TaskTree do
  @moduledoc """
  Live component for displaying hierarchical agent tree.
  Shows agents organized by task with expand/collapse and selection.
  """

  use QuoracleWeb, :live_component

  alias QuoracleWeb.UI.TaskTree.Helpers
  alias QuoracleWeb.UI.TaskTree.MessageForm
  alias QuoracleWeb.UI.TaskTree.NewTaskModal
  alias QuoracleWeb.UI.TaskTree.TodoDisplay

  @impl true
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    {:ok,
     assign(socket,
       expanded: MapSet.new(),
       show_modal: false,
       message_forms: %{}
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
      |> assign_new(:costs_updated_at, fn -> nil end)
      |> assign_new(:profiles, fn -> [] end)

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
                costs_updated_at={@costs_updated_at}
              />
            </div>
            <!-- Per-model cost breakdown -->
            <div class="task-cost-detail mb-2">
              <.live_component
                module={QuoracleWeb.Live.UI.CostDisplay}
                id={"task-cost-detail-#{task_id}"}
                mode={:detail}
                task_id={task_id}
                costs_updated_at={@costs_updated_at}
              />
            </div>

            <!-- Task Budget Summary -->
            <%= if task[:budget_limit] do %>
              <% budget_summary = calculate_task_budget_summary(task_id, task.budget_limit, @costs_updated_at) %>
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
                <.render_agent_node
                  agent={@agents[task[:root_agent_id]]}
                  agents={@agents}
                  selected_agent_id={@selected_agent_id}
                  expanded={@expanded}
                  depth={0}
                  target={@myself}
                  agent_alive_map={@agent_alive_map || %{}}
                  root_pid={@root_pid}
                  message_forms={@message_forms}
                  costs_updated_at={@costs_updated_at}
                />
              </div>
            <% end %>
          </div>
        <% end %>
      <% end %>

      <NewTaskModal.render show_modal={@show_modal} target={@myself} profiles={@profiles} />
    </div>
    """
  end

  defp render_agent_node(%{agent: nil} = assigns), do: ~H""

  defp render_agent_node(assigns) do
    ~H"""
    <div class="agent-node" data-agent-id={@agent.agent_id} data-depth={@depth}>
      <div 
        class={"agent-row flex items-center p-1 hover:bg-gray-50 cursor-pointer #{if @agent.agent_id == @selected_agent_id, do: "bg-blue-100 agent-selected"}"}
        phx-click="select_agent"
        phx-value-agent-id={@agent.agent_id}
        phx-target={@target}
      >
        <!-- Expand/Collapse Icon -->
        <%= if length(@agent[:children] || []) > 0 do %>
          <button
            phx-click="toggle_expand"
            phx-value-agent-id={@agent.agent_id}
            phx-target={@target}
            class="mr-2"
          >
            <%= if MapSet.member?(@expanded, @agent.agent_id) do %>
              <span class="icon-collapse">▼</span>
            <% else %>
              <span class="icon-expand">▶</span>
            <% end %>
          </button>
        <% else %>
          <span class="mr-2 invisible">▶</span>
        <% end %>
        
        <!-- Agent Info -->
        <span class={"agent-info flex-1 status-#{@agent[:status] || :idle}"}>
          <%= @agent.agent_id %>
          <%= if @agent[:status] == :working and @agent[:current_action] do %>
            <span class="text-sm text-gray-500 ml-2">(<%= @agent.current_action %>)</span>
          <% end %>
        </span>
        
        <!-- Status Indicator -->
        <span class={"status-indicator ml-2 px-2 py-1 text-xs rounded status-#{@agent[:status] || :idle}"}>
          <%= @agent[:status] || :idle %>
        </span>

        <!-- Cost Badge -->
        <.live_component
          module={QuoracleWeb.Live.UI.CostDisplay}
          id={"cost-badge-tasktree-#{@agent.agent_id}"}
          mode={:badge}
          agent_id={@agent.agent_id}
          costs_updated_at={@costs_updated_at}
        />

        <!-- Budget Badge -->
        <%= if @agent[:budget_data] do %>
          <QuoracleWeb.UI.BudgetBadge.budget_badge summary={build_agent_budget_summary(@agent)} />
        <% end %>
      </div>

      <!-- Direct Message Form -->
      <MessageForm.render
        agent={@agent}
        agent_alive_map={@agent_alive_map}
        message_forms={@message_forms}
        target={@target}
      />

      <!-- Agent task list display -->
      <TodoDisplay.render agent={@agent} />

      <!-- Children -->
      <%= if MapSet.member?(@expanded, @agent.agent_id) and @agent[:children] do %>
        <div class="children ml-4">
          <%= for child_id <- Enum.uniq(@agent.children) do %>
            <.render_agent_node
              agent={@agents[child_id]}
              agents={@agents}
              selected_agent_id={@selected_agent_id}
              expanded={@expanded}
              depth={@depth + 1}
              target={@target}
              agent_alive_map={@agent_alive_map}
              root_pid={@root_pid}
              message_forms={@message_forms}
              costs_updated_at={@costs_updated_at}
            />
          <% end %>
        </div>
      <% end %>
    </div>
    """
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
  def handle_event("create_task", params, socket) do
    send(socket.root_pid, {:submit_prompt, params})
    {:noreply, assign(socket, show_modal: false)}
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

  # Budget summary helpers
  defp calculate_task_budget_summary(task_id, budget_limit, _costs_updated_at) do
    cost_summary = Quoracle.Costs.Aggregator.by_task(task_id)
    spent_decimal = cost_summary.total_cost || Decimal.new(0)

    percentage =
      if Decimal.compare(budget_limit, Decimal.new(0)) == :gt do
        Decimal.div(spent_decimal, budget_limit)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.to_float()
      else
        0.0
      end

    %{
      spent: Decimal.round(spent_decimal, 2),
      percentage: percentage
    }
  end

  defp budget_color_class(percentage) when percentage > 100, do: "text-red-600"
  defp budget_color_class(percentage) when percentage > 50, do: "text-yellow-600"
  defp budget_color_class(_percentage), do: "text-green-600"

  defp budget_progress_color(percentage) when percentage > 100, do: "bg-red-500"
  defp budget_progress_color(percentage) when percentage > 50, do: "bg-yellow-500"
  defp budget_progress_color(_percentage), do: "bg-green-500"

  # Build budget summary for agent budget badge
  defp build_agent_budget_summary(%{budget_data: %{mode: :na}}) do
    %{status: :na}
  end

  defp build_agent_budget_summary(%{budget_data: %{allocated: nil}}) do
    %{status: :na}
  end

  defp build_agent_budget_summary(%{agent_id: agent_id, budget_data: budget_data}) do
    allocated = budget_data.allocated
    committed = budget_data.committed || Decimal.new(0)
    spent = Quoracle.Costs.Aggregator.by_agent(agent_id).total_cost || Decimal.new(0)
    available = Decimal.sub(Decimal.sub(allocated, spent), committed)

    status =
      cond do
        Decimal.compare(available, Decimal.new(0)) == :lt -> :over_budget
        Decimal.compare(available, Decimal.mult(allocated, Decimal.new("0.2"))) == :lt -> :warning
        true -> :ok
      end

    %{
      status: status,
      allocated: allocated,
      spent: spent,
      committed: committed,
      available: available
    }
  end

  defp build_agent_budget_summary(_agent) do
    %{status: :na}
  end
end
