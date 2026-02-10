defmodule QuoracleWeb.DashboardLive do
  @moduledoc """
  Main LiveView dashboard page with 3-panel layout.
  Displays task tree, logs, and mailbox for agent orchestration.

  Implementation is split across modules to maintain code organization:
  - Subscriptions: PubSub subscription management
  - EventHandlers: User event handling (handle_event callbacks)
  - MessageHandlers: Incoming message handling (handle_info callbacks)
  - TestHelpers: Test-specific message handlers
  - DataLoader: Task/agent loading and merging from DB/Registry
  """

  use QuoracleWeb, :live_view

  alias Phoenix.PubSub

  alias QuoracleWeb.DashboardLive.{
    DataLoader,
    EventHandlers,
    MessageHandlers,
    Subscriptions,
    TestHelpers
  }

  alias Quoracle.Profiles.TableProfiles

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
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    pubsub = current_pubsub(session)

    registry =
      session["registry"] || session[:registry] || Quoracle.AgentRegistry

    dynsup = session["dynsup"] || session[:dynsup] || Quoracle.Agent.DynSup.get_dynsup_pid()

    # Extract or discover EventHistory PID for buffer replay
    event_history_pid = DataLoader.get_event_history_pid(session)

    # CRITICAL: Grant sandbox access in tests
    # LiveView processes don't automatically inherit sandbox access with live_isolated
    sandbox_owner = session["sandbox_owner"] || session[:sandbox_owner]

    if sandbox_owner do
      Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, sandbox_owner, self())
    end

    # Load profiles from database (needed for both connected and not connected)
    profiles = load_profiles()

    if connected?(socket) do
      # Subscribe to core topics (only when WebSocket is connected)
      Subscriptions.subscribe_to_core_topics(pubsub)

      # Load persisted tasks and agents from database
      %{tasks: tasks, agents: agents} = DataLoader.load_tasks_from_db(registry, pubsub)

      # Auto-subscribe to existing agents' log topics
      Subscriptions.subscribe_to_existing_agents(pubsub, session)

      # Subscribe to task message and cost topics for tasks with live root agents
      # and track them in subscribed_topics to prevent double-subscription
      subscribed_topics =
        tasks
        |> Map.values()
        |> Enum.filter(& &1.live)
        |> Enum.reduce(MapSet.new(), fn task, acc ->
          PubSub.subscribe(pubsub, "tasks:#{task.id}:messages")
          PubSub.subscribe(pubsub, "tasks:#{task.id}:costs")

          acc
          |> MapSet.put("tasks:#{task.id}:messages")
          |> MapSet.put("tasks:#{task.id}:costs")
        end)

      # Build agent_alive_map for direct message button visibility
      agent_alive_map = DataLoader.build_agent_alive_map(agents)

      # Query EventHistory buffer for logs and messages (page refresh replay)
      agent_ids = Map.keys(agents)
      task_ids = Map.keys(tasks)

      {buffered_logs, buffered_messages} =
        DataLoader.query_event_history(event_history_pid, agent_ids, task_ids)

      {:ok,
       assign(socket,
         pubsub: pubsub,
         registry: registry,
         dynsup: dynsup,
         sandbox_owner: sandbox_owner,
         event_history_pid: event_history_pid,
         tasks: tasks,
         agents: agents,
         profiles: profiles,
         selected_agent_id: nil,
         logs: buffered_logs,
         messages: buffered_messages,
         subscribed_topics: subscribed_topics,
         agent_alive_map: agent_alive_map,
         costs_updated_at: System.monotonic_time(),
         # Budget editor state (R44)
         budget_editor_visible: false,
         budget_editor_task_id: nil,
         budget_editor_current: nil,
         budget_editor_spent: nil
       )}
    else
      # Not connected - minimal state
      {:ok,
       assign(socket,
         pubsub: pubsub,
         registry: registry,
         dynsup: dynsup,
         sandbox_owner: sandbox_owner,
         event_history_pid: event_history_pid,
         tasks: %{},
         agents: %{},
         profiles: profiles,
         selected_agent_id: nil,
         logs: %{},
         messages: [],
         subscribed_topics: MapSet.new(),
         agent_alive_map: %{},
         costs_updated_at: System.monotonic_time(),
         # Budget editor state (R44)
         budget_editor_visible: false,
         budget_editor_task_id: nil,
         budget_editor_current: nil,
         budget_editor_spent: nil
       )}
    end
  end

  # Loads profiles from database ordered by name
  defp load_profiles do
    import Ecto.Query

    Quoracle.Repo.all(from(p in TableProfiles, order_by: p.name))
    |> Enum.map(fn p ->
      groups = TableProfiles.capability_groups_as_atoms(p)

      %{
        name: p.name,
        capability_groups: groups
      }
    end)
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="flex h-screen">
      <!-- Panel 1: Unified TaskTree -->
      <div class="w-5/12 border-r p-4">
        <.live_component
          module={QuoracleWeb.UI.TaskTree}
          id="task-tree"
          tasks={@tasks}
          agents={@agents}
          profiles={@profiles}
          selected_agent_id={@selected_agent_id}
          pubsub={@pubsub}
          registry={@registry}
          dynsup={@dynsup}
          agent_alive_map={@agent_alive_map}
          costs_updated_at={@costs_updated_at}
        />
      </div>

      <!-- Panel 2: Logs -->
      <div class="w-1/3 border-r p-4">
        <h2 class="text-xl font-bold mb-4">Logs</h2>
        <.live_component
          module={QuoracleWeb.UI.LogView}
          id="logs"
          logs={DataLoader.get_filtered_logs(@logs, @selected_agent_id)}
          agent_id={@selected_agent_id}
          pubsub={@pubsub}
        />
      </div>

      <!-- Panel 3: Mailbox -->
      <div class="w-1/4 p-4">
        <h2 class="text-xl font-bold mb-4">Mailbox</h2>
        <.live_component
          module={QuoracleWeb.UI.Mailbox}
          id="mailbox"
          messages={@messages}
          task_id={nil}
          pubsub={@pubsub}
          registry={@registry}
          agents={@agents}
        />
      </div>
    </div>

    <!-- Budget Editor Modal (R45-R49) -->
    <%= if @budget_editor_visible do %>
      <div id="budget-editor-modal" class="fixed inset-0 z-50">
        <div class="fixed inset-0 bg-gray-500/75" phx-click="cancel_budget_edit"></div>
        <div class="fixed inset-0 overflow-y-auto p-4">
          <div class="flex min-h-full items-center justify-center">
            <div class="bg-white rounded-lg shadow-xl max-w-md w-full p-6">
              <h3 class="text-lg font-semibold mb-4">Edit Task Budget</h3>
              <form id="budget-editor-form" phx-submit="submit_budget_edit">
                <input type="hidden" name="task_id" value={@budget_editor_task_id} />
                <div class="mb-4">
                  <label class="block text-sm font-medium text-gray-700 mb-1">Current Spent</label>
                  <div class="text-lg font-semibold text-gray-900">
                    $<%= if @budget_editor_spent, do: Decimal.round(@budget_editor_spent, 2), else: "0.00" %>
                  </div>
                </div>
                <div class="mb-4">
                  <label class="block text-sm font-medium text-gray-700 mb-1">New Budget</label>
                  <input
                    type="text"
                    name="new_budget"
                    value={if @budget_editor_current, do: Decimal.to_string(@budget_editor_current), else: ""}
                    class="w-full px-3 py-2 border border-gray-300 rounded-md"
                    placeholder="Enter new budget..."
                  />
                  <p class="text-xs text-gray-500 mt-1">Must be greater than or equal to spent amount</p>
                </div>
                <div class="flex gap-3 justify-end">
                  <button
                    type="button"
                    id="cancel-budget-edit"
                    class="px-4 py-2 bg-gray-200 hover:bg-gray-300 text-gray-800 rounded"
                    phx-click="cancel_budget_edit"
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded"
                  >
                    Save Budget
                  </button>
                </div>
              </form>
            </div>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  # Event Handlers - delegate to EventHandlers module

  @impl true
  @spec handle_event(binary(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("submit_prompt", params, socket),
    do: EventHandlers.handle_submit_prompt(params, socket)

  def handle_event("select_agent", params, socket),
    do: EventHandlers.handle_select_agent(params, socket)

  def handle_event("delete_agent", params, socket),
    do: EventHandlers.handle_delete_agent(params, socket)

  def handle_event("pause_task", params, socket),
    do: EventHandlers.handle_pause_task(params, socket)

  def handle_event("resume_task", params, socket),
    do: EventHandlers.handle_resume_task(params, socket)

  def handle_event("delete_task", params, socket),
    do: EventHandlers.handle_delete_task(params, socket)

  # Budget editor event handlers (R46, R47, R49)
  def handle_event("submit_budget_edit", params, socket),
    do: EventHandlers.handle_submit_budget_edit(params, socket)

  def handle_event("cancel_budget_edit", _params, socket),
    do: EventHandlers.handle_cancel_budget_edit(socket)

  # Catch-all for deprecated/child component events
  def handle_event(event, params, socket),
    do: EventHandlers.handle_child_component_event(event, params, socket)

  # Message Handlers - delegate to MessageHandlers module

  @impl true
  @spec handle_info(tuple() | atom(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}

  # TaskTree event delegation - TaskTree sends these messages to Dashboard
  def handle_info({:pause_task, task_id}, socket),
    do: EventHandlers.handle_pause_task(%{"task-id" => task_id}, socket)

  def handle_info({:resume_task, task_id}, socket),
    do: EventHandlers.handle_resume_task(%{"task-id" => task_id}, socket)

  def handle_info({:delete_task, task_id}, socket),
    do: EventHandlers.handle_delete_task(%{"task-id" => task_id}, socket)

  def handle_info({:submit_prompt, params}, socket),
    do: EventHandlers.handle_submit_prompt(params, socket)

  # Budget editor message (R45)
  def handle_info({:show_budget_editor, task_id}, socket),
    do: EventHandlers.handle_show_budget_editor(task_id, socket)

  # Agent lifecycle events
  def handle_info({:select_agent, agent_id}, socket),
    do: MessageHandlers.handle_select_agent(agent_id, socket)

  def handle_info({:agent_spawned, payload}, socket),
    do: MessageHandlers.handle_agent_spawned(payload, socket)

  def handle_info({:agent_terminated, payload}, socket),
    do: MessageHandlers.handle_agent_terminated(payload, socket)

  def handle_info({:delete_agent, agent_id}, socket),
    do: MessageHandlers.handle_delete_agent(agent_id, socket)

  def handle_info({:state_changed, payload}, socket),
    do: MessageHandlers.handle_state_changed(payload, socket)

  # Task and message events
  def handle_info({:set_current_task, task_id}, socket),
    do: MessageHandlers.handle_set_current_task(task_id, socket)

  def handle_info({:agent_message, message}, socket),
    do: MessageHandlers.handle_agent_message(message, socket)

  def handle_info({:log_entry, log}, socket),
    do: MessageHandlers.handle_log_entry(log, socket)

  def handle_info({:task_message, message}, socket),
    do: MessageHandlers.handle_task_message(message, socket)

  # Task list (todos) events
  def handle_info({:todos_updated, payload}, socket),
    do: MessageHandlers.handle_todos_updated(payload, socket)

  # Cost recording events - bump costs_updated_at to trigger re-render
  def handle_info({:cost_recorded, _payload}, socket) do
    {:noreply, assign(socket, costs_updated_at: System.monotonic_time())}
  end

  # Connection events
  def handle_info({:mount, :reconnected}, socket),
    do: MessageHandlers.handle_reconnection(socket)

  # Action events
  def handle_info({:action_started, payload}, socket),
    do: MessageHandlers.handle_action_started(payload, socket)

  # Test events
  def handle_info({:test_event, payload}, socket),
    do: MessageHandlers.handle_test_event(payload, socket)

  # Reply from Message component
  def handle_info({:send_reply, message_id, content}, socket),
    do: MessageHandlers.handle_send_reply(message_id, content, socket)

  # Direct message from AgentNode component
  def handle_info({:send_direct_message, agent_id, content}, socket),
    do: MessageHandlers.handle_send_direct_message(agent_id, content, socket)

  # Test support messages - delegate to TestHelpers
  def handle_info({:render_log_entry, log}, socket),
    do: TestHelpers.handle_render_log_entry(log, socket)

  def handle_info({:render_message, message}, socket),
    do: TestHelpers.handle_render_message(message, socket)

  def handle_info({:render_agent_node, agent}, socket),
    do: TestHelpers.handle_render_agent_node(agent, socket)

  def handle_info({:set_messages, messages}, socket),
    do: TestHelpers.handle_set_messages(messages, socket)

  def handle_info({:set_logs, logs}, socket),
    do: TestHelpers.handle_set_logs(logs, socket)

  def handle_info({:set_agents, agents}, socket),
    do: TestHelpers.handle_set_agents(agents, socket)

  def handle_info({:send_message, message}, socket),
    do: TestHelpers.handle_send_message(message, socket)

  # Catch-all for unknown messages
  def handle_info(message, socket),
    do: MessageHandlers.handle_unknown_message(message, socket)
end
