defmodule QuoracleWeb.DashboardLive.MessageHandlers do
  @moduledoc "Handles incoming messages (handle_info callbacks) for the Dashboard LiveView."

  alias Phoenix.PubSub
  alias Phoenix.LiveView.Socket
  alias QuoracleWeb.DashboardLive.Subscriptions
  alias QuoracleWeb.DashboardLive.MessageHandlers.Helpers

  @doc "Handle agent selection from TaskTree component."
  @spec handle_select_agent(String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_select_agent(agent_id, socket) do
    socket =
      socket
      |> Phoenix.Component.assign(selected_agent_id: agent_id)
      |> recompute_filtered_logs()

    {:noreply, socket}
  end

  @doc "Handle agent spawn event — subscribe to logs, update task/agent state."
  @spec handle_agent_spawned(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_agent_spawned(payload, socket) do
    %{agent_id: agent_id, task_id: task_id, parent_id: parent_id} = payload

    socket = Subscriptions.safe_subscribe(socket, "agents:#{agent_id}:logs")
    socket = Subscriptions.safe_subscribe(socket, "agents:#{agent_id}:todos")
    socket = Subscriptions.safe_subscribe(socket, "agents:#{agent_id}:costs")

    socket =
      if task_id do
        Subscriptions.safe_subscribe(socket, "tasks:#{task_id}:costs")
      else
        socket
      end

    pid =
      case payload[:pid] do
        nil ->
          case Registry.lookup(socket.assigns.registry, {:agent, agent_id}) do
            [{p, _}] -> p
            [] -> nil
          end

        p ->
          p
      end

    budget_data = payload[:budget_data]
    todos = fetch_agent_todos(pid)

    agent = %{
      agent_id: agent_id,
      task_id: task_id,
      parent_id: parent_id,
      pid: pid,
      status: :running,
      children: [],
      todos: todos,
      budget_data: budget_data,
      timestamp: payload[:timestamp] || System.system_time(:millisecond)
    }

    agents = Map.put(socket.assigns.agents, agent_id, agent)

    agents =
      if parent_id && Map.has_key?(agents, parent_id) do
        Map.update!(agents, parent_id, fn parent ->
          children = Map.get(parent, :children, [])

          if agent_id in children do
            parent
          else
            Map.put(parent, :children, [agent_id | children])
          end
        end)
      else
        agents
      end

    agents = Helpers.link_orphaned_children(agents, agent_id)
    task = Helpers.load_or_create_task(socket.assigns.tasks, task_id)

    {tasks, socket, current_task_id} =
      if is_nil(task_id) do
        {socket.assigns.tasks, socket, socket.assigns[:current_task_id]}
      else
        # First-writer-wins guard: only set root_agent_id if not already set
        updated_task =
          if is_nil(parent_id) do
            base =
              task
              |> Map.put(:status, "running")
              |> Map.put(:live, true)

            if is_nil(task[:root_agent_id]) do
              Map.put(base, :root_agent_id, agent_id)
            else
              base
            end
          else
            task
            |> Map.put(:status, "running")
            |> Map.put(:live, true)
          end

        new_tasks = Map.put(socket.assigns.tasks, task_id, updated_task)

        new_socket =
          if is_nil(parent_id) do
            Subscriptions.safe_subscribe(socket, "tasks:#{task_id}:messages")
          else
            socket
          end

        new_current_task_id =
          if is_nil(parent_id), do: task_id, else: socket.assigns[:current_task_id]

        {new_tasks, new_socket, new_current_task_id}
      end

    agent_alive_map = Map.put(socket.assigns.agent_alive_map, agent_id, true)
    {logs, messages} = Helpers.query_agent_buffer(socket, agent_id, task_id)

    socket =
      socket
      |> Phoenix.Component.assign(
        agents: agents,
        tasks: tasks,
        current_task_id: current_task_id,
        agent_alive_map: agent_alive_map,
        logs: logs,
        messages: messages
      )
      |> recompute_filtered_logs()

    {:noreply, socket}
  end

  @doc "Handle agent termination — unsubscribe from logs and update state."
  @spec handle_agent_terminated(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_agent_terminated(payload, socket) do
    %{agent_id: agent_id} = payload
    pubsub = socket.assigns.pubsub
    PubSub.unsubscribe(pubsub, "agents:#{agent_id}:logs")
    PubSub.unsubscribe(pubsub, "agents:#{agent_id}:todos")

    case Map.get(socket.assigns.agents, agent_id) do
      %{task_id: task_id, parent_id: parent_id} = agent ->
        agents = Map.put(socket.assigns.agents, agent_id, %{agent | status: :terminated})

        agents =
          if parent_id && Map.has_key?(agents, parent_id) do
            Map.update!(agents, parent_id, fn parent ->
              children = Map.get(parent, :children, [])
              Map.put(parent, :children, List.delete(children, agent_id))
            end)
          else
            agents
          end

        other_live_agents =
          agents
          |> Enum.filter(fn {aid, a} ->
            aid != agent_id and a.task_id == task_id and a.status == :running
          end)

        tasks =
          if Enum.empty?(other_live_agents) and not is_nil(task_id) and
               Map.has_key?(socket.assigns.tasks, task_id) do
            current_task = Map.get(socket.assigns.tasks, task_id)

            final_status =
              cond do
                current_task[:status] == "pausing" ->
                  try do
                    Quoracle.Tasks.TaskManager.update_task_status(task_id, "paused")
                  catch
                    :exit, _ -> :ok
                  end

                  "paused"

                current_task[:status] in ["paused", "completed", "failed"] ->
                  current_task[:status]

                true ->
                  "completed"
              end

            Map.update!(socket.assigns.tasks, task_id, fn task ->
              task
              |> Map.put(:live, false)
              |> Map.put(:root_agent_id, nil)
              |> Map.put(:status, final_status)
            end)
          else
            socket.assigns.tasks
          end

        agent_alive_map = Map.put(socket.assigns.agent_alive_map, agent_id, false)

        {:noreply,
         Phoenix.Component.assign(socket,
           agents: agents,
           tasks: tasks,
           agent_alive_map: agent_alive_map
         )}

      _ ->
        agent_alive_map = Map.put(socket.assigns.agent_alive_map, agent_id, false)
        {:noreply, Phoenix.Component.assign(socket, agent_alive_map: agent_alive_map)}
    end
  end

  @doc "Handle agent deletion — remove agent and its logs."
  @spec handle_delete_agent(String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_delete_agent(agent_id, socket) do
    PubSub.unsubscribe(socket.assigns.pubsub, "agents:#{agent_id}:logs")
    agents = Map.delete(socket.assigns.agents, agent_id)
    logs = Map.delete(socket.assigns.logs, agent_id)

    socket =
      socket
      |> Phoenix.Component.assign(agents: agents, logs: logs)
      |> recompute_filtered_logs()

    {:noreply, socket}
  end

  @doc "Handle agent state change event."
  @spec handle_state_changed(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_state_changed(payload, socket) do
    %{agent_id: agent_id, new_state: new_state} = payload

    agents =
      Map.update(socket.assigns.agents, agent_id, nil, fn agent ->
        if agent, do: %{agent | status: new_state}, else: nil
      end)

    {:noreply, Phoenix.Component.assign(socket, agents: agents)}
  end

  @doc "Handle setting the current task."
  @spec handle_set_current_task(String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_set_current_task(task_id, socket) do
    {:noreply, Phoenix.Component.assign(socket, current_task_id: task_id)}
  end

  @doc "Handle incoming agent message (filters inter-agent, deduplicates by id)."
  @spec handle_agent_message(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_agent_message(message, socket) do
    if Map.has_key?(message, :recipient_id) do
      {:noreply, socket}
    else
      message = Map.put_new_lazy(message, :id, fn -> System.unique_integer([:positive]) end)
      message_id = message[:id]

      already_exists =
        message_id != nil and Enum.any?(socket.assigns.messages, &(&1[:id] == message_id))

      if already_exists do
        {:noreply, socket}
      else
        messages = socket.assigns.messages ++ [message]
        {:noreply, Phoenix.Component.assign(socket, messages: messages)}
      end
    end
  end

  @default_log_debounce_ms 300

  @doc "Handle incoming log entry (deduplicates by id, buffers for debounced flush)."
  @spec handle_log_entry(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_log_entry(log, socket) do
    agent_id = log[:agent_id]
    log_id = log[:id]

    # Dedup against BOTH persisted logs AND the pending buffer
    agent_logs = Map.get(socket.assigns.logs, agent_id, [])
    in_persisted = log_id != nil and Enum.any?(agent_logs, &(&1[:id] == log_id))
    in_buffer = log_id != nil and Enum.any?(socket.assigns.log_buffer, &(&1[:id] == log_id))

    if in_persisted or in_buffer do
      {:noreply, socket}
    else
      # Buffer the log entry instead of immediately assigning
      buffer = [log | socket.assigns.log_buffer]

      if socket.assigns[:log_refresh_timer] do
        # Timer already pending — just buffer
        {:noreply, Phoenix.Component.assign(socket, log_buffer: buffer)}
      else
        debounce_ms = socket.assigns[:log_debounce_ms] || @default_log_debounce_ms
        timer = schedule_log_flush(debounce_ms)

        {:noreply, Phoenix.Component.assign(socket, log_buffer: buffer, log_refresh_timer: timer)}
      end
    end
  end

  @doc "Handle task message events from PubSub."
  @spec handle_task_message(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_task_message(message, socket) do
    handle_agent_message(message, socket)
  end

  @doc "Handle todos updated event."
  @spec handle_todos_updated(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_todos_updated(payload, socket) do
    case payload do
      %{agent_id: agent_id, todos: todos} when not is_nil(agent_id) and is_list(todos) ->
        agents =
          Map.update(socket.assigns.agents, agent_id, nil, fn agent ->
            if agent, do: Map.put(agent, :todos, todos), else: nil
          end)

        {:noreply, Phoenix.Component.assign(socket, agents: agents)}

      _ ->
        {:noreply, socket}
    end
  end

  @doc "Handle reconnection - resubscribe to topics."
  @spec handle_reconnection(Socket.t()) :: {:noreply, Socket.t()}
  def handle_reconnection(socket) do
    Subscriptions.subscribe_to_core_topics(socket.assigns.pubsub)
    {:noreply, socket}
  end

  @doc "Handle action started event."
  @spec handle_action_started(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_action_started(payload, socket) do
    agent_id = payload[:agent_id] || payload.agent_id

    agent = %{
      agent_id: agent_id,
      task_id: payload[:task_id],
      parent_id: payload[:parent_id],
      status: :running,
      action_type: payload[:action_type],
      timestamp: payload[:timestamp] || DateTime.utc_now()
    }

    agents = Map.put(socket.assigns.agents, agent_id, agent)
    {:noreply, Phoenix.Component.assign(socket, agents: agents)}
  end

  @doc "Handle test event."
  @spec handle_test_event(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_test_event(payload, socket),
    do: {:noreply, Phoenix.Component.assign(socket, test_event: payload)}

  @doc "Handle reply from Message component to agent."
  @spec handle_send_reply(String.t(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_send_reply(message_id, content, socket) do
    message = Enum.find(socket.assigns.messages, &(&1.id == message_id))

    if message do
      case Registry.lookup(socket.assigns.registry, {:agent, message.sender_id}) do
        [{agent_pid, _}] ->
          Quoracle.Agent.Core.send_user_message(agent_pid, content)
          {:noreply, socket}

        [] ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @doc "Handle direct message from AgentNode component to agent."
  @spec handle_send_direct_message(String.t(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_send_direct_message(agent_id, content, socket) do
    case Registry.lookup(socket.assigns.registry, {:agent, agent_id}) do
      [{agent_pid, _}] ->
        Quoracle.Agent.Core.send_user_message(agent_pid, content)
        {:noreply, socket}

      [] ->
        {:noreply, socket}
    end
  end

  @doc "Handle selected grove update from TaskTree component."
  @spec handle_selected_grove_updated(String.t() | nil, Socket.t()) :: {:noreply, Socket.t()}
  def handle_selected_grove_updated(grove_name, socket),
    do: {:noreply, Phoenix.Component.assign(socket, selected_grove: grove_name)}

  @doc "Cache loaded grove struct from TaskTree to avoid redundant file I/O on task creation."
  @spec handle_loaded_grove_updated(map() | nil, Socket.t()) :: {:noreply, Socket.t()}
  def handle_loaded_grove_updated(grove, socket),
    do: {:noreply, Phoenix.Component.assign(socket, loaded_grove: grove)}

  @doc "Handle grove skills path update from TaskTree component (SEC-2a)."
  @spec handle_grove_skills_path_updated(String.t() | nil, Socket.t()) :: {:noreply, Socket.t()}
  def handle_grove_skills_path_updated(path, socket),
    do: {:noreply, Phoenix.Component.assign(socket, grove_skills_path: path)}

  @doc "Handle grove error from TaskTree component."
  @spec handle_grove_error(String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_grove_error(message, socket),
    do: {:noreply, Phoenix.LiveView.put_flash(socket, :error, message)}

  @doc "Catch-all for unhandled messages."
  @spec handle_unknown_message(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_unknown_message(_message, socket), do: {:noreply, socket}

  @spec schedule_log_flush(non_neg_integer()) :: reference() | :immediate
  defp schedule_log_flush(0) do
    send(self(), :flush_log_updates)
    :immediate
  end

  defp schedule_log_flush(ms) do
    Process.send_after(self(), :flush_log_updates, ms)
  end

  @spec recompute_filtered_logs(Socket.t()) :: Socket.t()
  defp recompute_filtered_logs(socket) do
    filtered_logs =
      QuoracleWeb.DashboardLive.DataLoader.get_filtered_logs(
        socket.assigns.logs,
        socket.assigns.selected_agent_id
      )

    Phoenix.Component.assign(socket, filtered_logs: filtered_logs)
  end

  # Best-effort fetch of agent todos (single GenServer.call with short timeout).
  @spec fetch_agent_todos(pid() | nil) :: list()
  defp fetch_agent_todos(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.call(pid, :get_todos, 1000)
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp fetch_agent_todos(_), do: []
end
