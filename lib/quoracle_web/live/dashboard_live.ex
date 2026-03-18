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

  @doc "Returns PubSub instance (session-injected for test isolation, global for production)."
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

    event_history_pid = DataLoader.get_event_history_pid(session)

    # Grant sandbox access in tests (LiveView doesn't inherit with live_isolated)
    sandbox_owner = session["sandbox_owner"] || session[:sandbox_owner]

    if sandbox_owner do
      Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, sandbox_owner, self())
    end

    profiles = load_profiles()

    groves_path = session["groves_path"] || session[:groves_path]
    groves_opts = if groves_path, do: [groves_path: groves_path], else: []
    groves = load_groves(groves_opts)

    skills_path = session["skills_path"] || session[:skills_path]
    task_manager_test_opts = session["task_manager_test_opts"] || session[:task_manager_test_opts]
    cost_debounce_ms = session["cost_debounce_ms"] || session[:cost_debounce_ms]
    log_debounce_ms = session["log_debounce_ms"] || session[:log_debounce_ms]
    mailbox_test_pid = session["mailbox_test_pid"] || session[:mailbox_test_pid]

    base_assigns = [
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner,
      event_history_pid: event_history_pid,
      profiles: profiles,
      groves: groves,
      groves_path: groves_path,
      skills_path: skills_path,
      task_manager_test_opts: task_manager_test_opts,
      selected_agent_id: nil,
      selected_grove: nil,
      cost_data: %{agents: %{}, tasks: %{}},
      cost_debounce_ms: cost_debounce_ms,
      log_debounce_ms: log_debounce_ms,
      log_buffer: [],
      log_refresh_timer: nil,
      mailbox_test_pid: mailbox_test_pid,
      grove_skills_path: nil,
      budget_editor_visible: false,
      budget_editor_task_id: nil,
      budget_editor_current: nil,
      budget_editor_spent: nil,
      current_task_id: nil,
      loaded_grove: nil
    ]

    if connected?(socket) do
      Subscriptions.subscribe_to_core_topics(pubsub)

      load_opts = extract_load_opts(session)
      %{tasks: tasks, agents: agents} = DataLoader.load_tasks_from_db(registry, pubsub, load_opts)
      Subscriptions.subscribe_to_existing_agents(pubsub, session)

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

      agent_alive_map = DataLoader.build_agent_alive_map(agents)

      agent_ids = Map.keys(agents)
      task_ids = Map.keys(tasks)

      {buffered_logs, buffered_messages} =
        DataLoader.query_event_history(event_history_pid, agent_ids, task_ids)

      # Defer per-agent data fetch to after mount (avoids longpoll timeout with many agents)
      send(self(), {:fetch_agent_data, load_opts})

      # Hydrate cost_data immediately so existing costs don't show N/A until first cost_recorded
      send(self(), :flush_cost_updates)

      connected_assigns = [
        tasks: tasks,
        agents: agents,
        logs: buffered_logs,
        messages: buffered_messages,
        subscribed_topics: subscribed_topics,
        agent_alive_map: agent_alive_map,
        filtered_logs: DataLoader.get_filtered_logs(buffered_logs, nil)
      ]

      {:ok, assign(socket, base_assigns ++ connected_assigns)}
    else
      disconnected_assigns = [
        tasks: %{},
        agents: %{},
        logs: %{},
        messages: [],
        subscribed_topics: MapSet.new(),
        agent_alive_map: %{},
        filtered_logs: []
      ]

      {:ok, assign(socket, base_assigns ++ disconnected_assigns)}
    end
  end

  defp extract_load_opts(session) do
    case session["agent_fetch_timeout"] || session[:agent_fetch_timeout] do
      timeout when is_integer(timeout) -> [agent_fetch_timeout: timeout]
      _ -> []
    end
  end

  defp load_groves(opts) do
    {:ok, groves} = Quoracle.Groves.Loader.list_groves(opts)
    groves
  end

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
          groves={@groves}
          groves_path={@groves_path}
          selected_agent_id={@selected_agent_id}
          pubsub={@pubsub}
          registry={@registry}
          dynsup={@dynsup}
          agent_alive_map={@agent_alive_map}
          cost_data={@cost_data}
        />
      </div>

      <!-- Panel 2: Logs -->
      <div class="w-1/3 border-r p-4">
        <h2 class="text-xl font-bold mb-4">Logs</h2>
        <.live_component
          module={QuoracleWeb.UI.LogView}
          id="logs"
          logs={@filtered_logs}
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
          agent_alive_map={@agent_alive_map}
          test_pid={@mailbox_test_pid}
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

  def handle_event("submit_budget_edit", params, socket),
    do: EventHandlers.handle_submit_budget_edit(params, socket)

  def handle_event("cancel_budget_edit", _params, socket),
    do: EventHandlers.handle_cancel_budget_edit(socket)

  def handle_event(event, params, socket),
    do: EventHandlers.handle_child_component_event(event, params, socket)

  @impl true
  @spec handle_info(tuple() | atom(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}

  def handle_info({:pause_task, task_id}, socket),
    do: EventHandlers.handle_pause_task(%{"task-id" => task_id}, socket)

  def handle_info({:resume_task, task_id}, socket),
    do: EventHandlers.handle_resume_task(%{"task-id" => task_id}, socket)

  def handle_info({:delete_task, task_id}, socket),
    do: EventHandlers.handle_delete_task(%{"task-id" => task_id}, socket)

  def handle_info({:submit_prompt, params}, socket),
    do: EventHandlers.handle_submit_prompt(params, socket)

  def handle_info({:show_budget_editor, task_id}, socket),
    do: EventHandlers.handle_show_budget_editor(task_id, socket)

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

  def handle_info({:set_current_task, task_id}, socket),
    do: MessageHandlers.handle_set_current_task(task_id, socket)

  def handle_info({:agent_message, message}, socket),
    do: MessageHandlers.handle_agent_message(message, socket)

  def handle_info({:log_entry, log}, socket),
    do: MessageHandlers.handle_log_entry(log, socket)

  def handle_info({:task_message, message}, socket),
    do: MessageHandlers.handle_task_message(message, socket)

  def handle_info({:todos_updated, payload}, socket),
    do: MessageHandlers.handle_todos_updated(payload, socket)

  @default_cost_debounce_ms 2_000

  def handle_info({:cost_recorded, _payload}, socket) do
    if socket.assigns[:cost_refresh_timer] do
      # Timer already pending — absorb this event
      {:noreply, socket}
    else
      debounce_ms = socket.assigns[:cost_debounce_ms] || @default_cost_debounce_ms
      timer = schedule_cost_flush(debounce_ms)
      {:noreply, assign(socket, cost_refresh_timer: timer)}
    end
  end

  def handle_info(:flush_cost_updates, socket) do
    agent_ids = Map.keys(socket.assigns.agents)
    task_ids = Map.keys(socket.assigns.tasks)
    cost_data = Quoracle.Costs.Aggregator.batch_totals(agent_ids, task_ids)

    {:noreply,
     socket
     |> assign(cost_data: cost_data)
     |> assign(cost_refresh_timer: nil)}
  end

  def handle_info(:flush_log_updates, socket) do
    buffer = socket.assigns.log_buffer

    # Merge buffered logs into the main logs map.
    # Buffer is newest-first (prepend order), so reverse to process oldest-first,
    # preserving newest-first order in the logs list after prepending.
    new_logs =
      Enum.reduce(Enum.reverse(buffer), socket.assigns.logs, fn log, acc ->
        agent_id = log[:agent_id]

        Map.update(acc, agent_id, [log], fn existing ->
          [log | existing] |> Enum.take(100)
        end)
      end)

    filtered_logs =
      DataLoader.get_filtered_logs(new_logs, socket.assigns.selected_agent_id)

    {:noreply,
     socket
     |> assign(
       logs: new_logs,
       filtered_logs: filtered_logs,
       log_buffer: [],
       log_refresh_timer: nil
     )}
  end

  def handle_info({:mount, :reconnected}, socket),
    do: MessageHandlers.handle_reconnection(socket)

  def handle_info({:action_started, payload}, socket),
    do: MessageHandlers.handle_action_started(payload, socket)

  def handle_info({:test_event, payload}, socket),
    do: MessageHandlers.handle_test_event(payload, socket)

  def handle_info({:send_reply, message_id, content}, socket),
    do: MessageHandlers.handle_send_reply(message_id, content, socket)

  def handle_info({:send_direct_message, agent_id, content}, socket),
    do: MessageHandlers.handle_send_direct_message(agent_id, content, socket)

  def handle_info({:selected_grove_updated, grove_name}, socket),
    do: MessageHandlers.handle_selected_grove_updated(grove_name, socket)

  def handle_info({:loaded_grove_updated, grove}, socket),
    do: MessageHandlers.handle_loaded_grove_updated(grove, socket)

  def handle_info({:grove_skills_path_updated, path}, socket),
    do: MessageHandlers.handle_grove_skills_path_updated(path, socket)

  def handle_info({:grove_error, message}, socket),
    do: MessageHandlers.handle_grove_error(message, socket)

  def handle_info({:fetch_agent_data, load_opts}, socket) do
    registry = socket.assigns.registry
    agent_fetch_timeout = Keyword.get(load_opts, :agent_fetch_timeout, 1000)
    live_agents = Quoracle.Agent.RegistryQueries.list_all_agents(registry)

    updated_agents =
      DataLoader.fetch_agent_data_parallel(
        live_agents,
        socket.assigns.agents,
        agent_fetch_timeout
      )

    {:noreply, Phoenix.Component.assign(socket, agents: updated_agents)}
  end

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

  def handle_info(message, socket),
    do: MessageHandlers.handle_unknown_message(message, socket)

  @spec schedule_cost_flush(non_neg_integer()) :: reference() | :immediate
  defp schedule_cost_flush(0) do
    send(self(), :flush_cost_updates)
    :immediate
  end

  defp schedule_cost_flush(ms) do
    Process.send_after(self(), :flush_cost_updates, ms)
  end
end
