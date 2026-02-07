defmodule QuoracleWeb.DashboardLive.MessageHandlers do
  @moduledoc """
  Handles incoming messages (handle_info callbacks) for the Dashboard LiveView.
  Extracted from DashboardLive to reduce module size below 500 lines.
  """

  alias Phoenix.PubSub
  alias Phoenix.LiveView.Socket
  alias QuoracleWeb.DashboardLive.Subscriptions
  alias QuoracleWeb.DashboardLive.MessageHandlers.Helpers

  @doc """
  Handle agent selection from TaskTree component.
  """
  @spec handle_select_agent(String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_select_agent(agent_id, socket) do
    # Note: Already subscribed to agent logs in handle_agent_spawned
    # No need to subscribe again here - just update the selected agent
    {:noreply, Phoenix.Component.assign(socket, selected_agent_id: agent_id)}
  end

  @doc """
  Handle agent spawn event - auto-subscribe to logs and update state.
  Packet 4: Tasks come from database, so update existing task to mark as running/live.
  If task is not in state (e.g., agent spawned before Dashboard loaded), load from DB.
  """
  @spec handle_agent_spawned(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_agent_spawned(payload, socket) do
    # Update agent_alive_map to mark this agent as alive
    %{agent_id: agent_id, task_id: task_id, parent_id: parent_id} = payload

    # Auto-subscribe to this agent's log, todos, and cost topics (safe - won't duplicate)
    socket = Subscriptions.safe_subscribe(socket, "agents:#{agent_id}:logs")
    socket = Subscriptions.safe_subscribe(socket, "agents:#{agent_id}:todos")
    socket = Subscriptions.safe_subscribe(socket, "agents:#{agent_id}:costs")

    # Subscribe to task cost topic if task_id present
    socket =
      if task_id do
        Subscriptions.safe_subscribe(socket, "tasks:#{task_id}:costs")
      else
        socket
      end

    # Look up pid from registry if not in payload (broadcast doesn't include pid)
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

    # Use budget_data from payload (avoids blocking GenServer.call in LiveView)
    budget_data = payload[:budget_data]

    # Update agents map
    agent = %{
      agent_id: agent_id,
      task_id: task_id,
      parent_id: parent_id,
      pid: pid,
      status: :running,
      children: [],
      budget_data: budget_data,
      timestamp: payload[:timestamp] || System.system_time(:millisecond)
    }

    agents = Map.put(socket.assigns.agents, agent_id, agent)

    # Update parent's children list if child has a parent
    agents =
      if parent_id && Map.has_key?(agents, parent_id) do
        Map.update!(agents, parent_id, fn parent ->
          children = Map.get(parent, :children, [])
          # Prevent duplicate children (can occur if agent_spawned received twice)
          if agent_id in children do
            parent
          else
            Map.put(parent, :children, [agent_id | children])
          end
        end)
      else
        agents
      end

    # Link any orphaned children that arrived before this parent
    # This handles the race condition during restoration where child broadcasts
    # can arrive before their parent's broadcast
    agents = Helpers.link_orphaned_children(agents, agent_id)

    # Get task from state, or load from DB if not present
    # This handles cases where agents are spawned before Dashboard loads
    task = Helpers.load_or_create_task(socket.assigns.tasks, task_id)

    # Only update tasks map if task_id is present
    {tasks, socket, current_task_id} =
      if is_nil(task_id) do
        # Agent without task - don't update tasks map or subscribe
        {socket.assigns.tasks, socket, socket.assigns.current_task_id}
      else
        # Update task status and subscribe
        updated_task =
          if is_nil(parent_id) do
            task
            |> Map.put(:status, "running")
            |> Map.put(:live, true)
            |> Map.put(:root_agent_id, agent_id)
          else
            task
            |> Map.put(:status, "running")
            |> Map.put(:live, true)
          end

        new_tasks = Map.put(socket.assigns.tasks, task_id, updated_task)

        # Subscribe to task messages for root agents
        new_socket =
          if is_nil(parent_id) do
            Subscriptions.safe_subscribe(socket, "tasks:#{task_id}:messages")
          else
            socket
          end

        # Set current_task_id for root agents, preserve existing for children
        new_current_task_id =
          if is_nil(parent_id) do
            task_id
          else
            # Use safe access - current_task_id may not exist yet if child arrives before root
            socket.assigns[:current_task_id]
          end

        {new_tasks, new_socket, new_current_task_id}
      end

    # Update agent_alive_map
    agent_alive_map = Map.put(socket.assigns.agent_alive_map, agent_id, true)

    # Query EventHistory buffer for this agent's logs and task's messages
    # This enables page refresh replay when agents are restored
    {logs, messages} = Helpers.query_agent_buffer(socket, agent_id, task_id)

    {:noreply,
     Phoenix.Component.assign(socket,
       agents: agents,
       tasks: tasks,
       current_task_id: current_task_id,
       agent_alive_map: agent_alive_map,
       logs: logs,
       messages: messages
     )}
  end

  @doc """
  Handle agent termination - unsubscribe from logs and update state.
  """
  @spec handle_agent_terminated(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_agent_terminated(payload, socket) do
    %{agent_id: agent_id} = payload

    # Auto-unsubscribe from terminated agent's logs and todos
    pubsub = socket.assigns.pubsub
    PubSub.unsubscribe(pubsub, "agents:#{agent_id}:logs")
    PubSub.unsubscribe(pubsub, "agents:#{agent_id}:todos")

    case Map.get(socket.assigns.agents, agent_id) do
      %{task_id: task_id, parent_id: parent_id} = agent ->
        # Mark agent as terminated (keep for Mailbox lifecycle tracking)
        agents = Map.put(socket.assigns.agents, agent_id, %{agent | status: :terminated})

        # Remove from parent's children list
        agents =
          if parent_id && Map.has_key?(agents, parent_id) do
            Map.update!(agents, parent_id, fn parent ->
              children = Map.get(parent, :children, [])
              Map.put(parent, :children, List.delete(children, agent_id))
            end)
          else
            agents
          end

        # Packet 4: Check if any other live agents exist for this task
        other_live_agents =
          agents
          |> Enum.filter(fn {aid, a} ->
            aid != agent_id and a.task_id == task_id and a.status == :running
          end)

        # If no more live agents, mark task as not live (only if task exists)
        # R31/R32/R33: Distinguish pause completion from natural completion
        tasks =
          if Enum.empty?(other_live_agents) and not is_nil(task_id) and
               Map.has_key?(socket.assigns.tasks, task_id) do
            current_task = Map.get(socket.assigns.tasks, task_id)

            # R32: Natural completion preserved - only set "paused" if currently "pausing"
            # R31/R33: Pause completion detection - update to "paused" when all agents terminate
            # Idempotent: skip transition if task already reached a terminal state
            # (duplicate {:agent_terminated} can arrive when Mailbox + Dashboard both
            # subscribe to "agents:lifecycle" in the same LiveView process)
            final_status =
              cond do
                current_task[:status] == "pausing" ->
                  # Update DB to "paused" (R33)
                  # Wrap in try/catch to handle test cleanup race condition where
                  # sandbox_owner dies between alive check and DB call
                  try do
                    Quoracle.Tasks.TaskManager.update_task_status(task_id, "paused")
                  catch
                    # Catch all exit reasons - sandbox may die with various error types
                    :exit, _ -> :ok
                  end

                  "paused"

                current_task[:status] in ["paused", "completed", "failed"] ->
                  # Already terminal — don't overwrite (idempotent for duplicate messages)
                  current_task[:status]

                true ->
                  # Natural completion - keep as "completed"
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

        # Update agent_alive_map to mark agent as not alive
        agent_alive_map = Map.put(socket.assigns.agent_alive_map, agent_id, false)

        {:noreply,
         Phoenix.Component.assign(socket,
           agents: agents,
           tasks: tasks,
           agent_alive_map: agent_alive_map
         )}

      _ ->
        # Agent not found - still update agent_alive_map
        agent_alive_map = Map.put(socket.assigns.agent_alive_map, agent_id, false)
        {:noreply, Phoenix.Component.assign(socket, agent_alive_map: agent_alive_map)}
    end
  end

  @doc """
  Handle agent deletion - completely remove agent and its logs.
  """
  @spec handle_delete_agent(String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_delete_agent(agent_id, socket) do
    # Delete agent completely including logs
    pubsub = socket.assigns.pubsub
    PubSub.unsubscribe(pubsub, "agents:#{agent_id}:logs")

    # Remove agent from agents map
    agents = Map.delete(socket.assigns.agents, agent_id)

    # Remove agent's logs from logs map
    logs = Map.delete(socket.assigns.logs, agent_id)

    {:noreply, Phoenix.Component.assign(socket, agents: agents, logs: logs)}
  end

  @doc """
  Handle agent state change event.
  """
  @spec handle_state_changed(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_state_changed(payload, socket) do
    %{agent_id: agent_id, new_state: new_state} = payload

    agents =
      Map.update(socket.assigns.agents, agent_id, nil, fn agent ->
        if agent, do: %{agent | status: new_state}, else: nil
      end)

    {:noreply, Phoenix.Component.assign(socket, agents: agents)}
  end

  @doc """
  Handle setting the current task.
  """
  @spec handle_set_current_task(String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_set_current_task(task_id, socket) do
    {:noreply, Phoenix.Component.assign(socket, current_task_id: task_id)}
  end

  @doc """
  Handle incoming agent message.
  Filters out inter-agent messages (only shows user-targeted messages).
  Deduplicates by id to prevent duplicates from buffer replay.
  """
  @spec handle_agent_message(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_agent_message(message, socket) do
    # Filter: Inter-agent messages have recipient_id field, user messages don't
    # Only show messages targeted at user in the mailbox
    if Map.has_key?(message, :recipient_id) do
      {:noreply, socket}
    else
      # Dashboard must handle agent messages and update its messages assign
      # Otherwise Mailbox's messages get overwritten on every Dashboard re-render
      # Deduplicate by id to handle buffer replay (page refresh)
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

  @doc """
  Handle incoming log entry.
  Deduplicates by id to prevent duplicates from buffer replay.
  """
  @spec handle_log_entry(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_log_entry(log, socket) do
    # Store log entry in per-agent Map structure
    agent_id = log[:agent_id]
    log_id = log[:id]

    # Check if log already exists (deduplication for buffer replay)
    agent_logs = Map.get(socket.assigns.logs, agent_id, [])
    already_exists = log_id != nil and Enum.any?(agent_logs, &(&1[:id] == log_id))

    if already_exists do
      {:noreply, socket}
    else
      # Store in per-agent Map with 100 log limit per agent
      new_logs =
        socket.assigns.logs
        |> Map.update(agent_id, [log], fn existing_logs ->
          # Prepend new log and keep only last 100
          [log | existing_logs] |> Enum.take(100)
        end)

      {:noreply, Phoenix.Component.assign(socket, logs: new_logs)}
    end
  end

  @doc """
  Handle task message events from PubSub.
  Delegates to handle_agent_message which filters inter-agent messages.
  """
  @spec handle_task_message(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_task_message(message, socket) do
    # Delegate to handle_agent_message which has proper recipient_id filtering
    handle_agent_message(message, socket)
  end

  @doc """
  Handle todos updated event - update agent's todos in the agents map.
  """
  @spec handle_todos_updated(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_todos_updated(payload, socket) do
    case payload do
      %{agent_id: agent_id, todos: todos} when not is_nil(agent_id) and is_list(todos) ->
        # Valid payload - update agents map
        agents =
          Map.update(socket.assigns.agents, agent_id, nil, fn agent ->
            if agent, do: Map.put(agent, :todos, todos), else: nil
          end)

        {:noreply, Phoenix.Component.assign(socket, agents: agents)}

      _ ->
        # Malformed payload - ignore gracefully without crashing
        {:noreply, socket}
    end
  end

  @doc """
  Handle reconnection - resubscribe to topics.
  """
  @spec handle_reconnection(Socket.t()) :: {:noreply, Socket.t()}
  def handle_reconnection(socket) do
    # Resubscribe on reconnection using the isolated pubsub from socket assigns
    Subscriptions.subscribe_to_core_topics(socket.assigns.pubsub)
    {:noreply, socket}
  end

  @doc """
  Handle action started event.
  """
  @spec handle_action_started(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_action_started(payload, socket) do
    # Add agent to the agents map so it shows in the view
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

  @doc """
  Handle test event.
  """
  @spec handle_test_event(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_test_event(payload, socket) do
    # For test events, trigger a state update
    {:noreply, Phoenix.Component.assign(socket, test_event: payload)}
  end

  @doc """
  Handle reply from Message component to agent.
  """
  @spec handle_send_reply(String.t(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_send_reply(message_id, content, socket) do
    # Handle reply from Message component to agent
    message = Enum.find(socket.assigns.messages, &(&1.id == message_id))

    if message do
      sender_id = message.sender_id

      case Registry.lookup(socket.assigns.registry, {:agent, sender_id}) do
        [{agent_pid, _}] ->
          # Send the user message to the agent
          Quoracle.Agent.Core.send_user_message(agent_pid, content)
          {:noreply, socket}

        [] ->
          # Agent no longer registered
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @doc """
  Handle direct message from AgentNode component to agent.
  """
  @spec handle_send_direct_message(String.t(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_send_direct_message(agent_id, content, socket) do
    case Registry.lookup(socket.assigns.registry, {:agent, agent_id}) do
      [{agent_pid, _}] ->
        # Send the user message to the agent
        Quoracle.Agent.Core.send_user_message(agent_pid, content)
        {:noreply, socket}

      [] ->
        # Agent no longer registered
        {:noreply, socket}
    end
  end

  @doc "Catch-all for unhandled messages."
  @spec handle_unknown_message(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_unknown_message(_message, socket), do: {:noreply, socket}
end
