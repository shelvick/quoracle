defmodule QuoracleWeb.DashboardLive.MessageHandlers.Helpers do
  @moduledoc """
  Helper functions for Dashboard message handlers.
  Extracted from MessageHandlers to reduce module size.
  """

  @doc """
  Load task from state or create from DB if not present.
  """
  @spec load_or_create_task(map(), String.t() | nil) :: map()
  def load_or_create_task(tasks, task_id) do
    case Map.get(tasks, task_id) do
      nil when not is_nil(task_id) ->
        load_task_from_db(task_id)

      nil ->
        create_minimal_task_entry(nil)

      task ->
        task
    end
  end

  @doc """
  Load task from database by ID.
  """
  @spec load_task_from_db(String.t()) :: map()
  def load_task_from_db(task_id) do
    # Wrap in try/catch to handle test cleanup race condition where
    # sandbox_owner dies between LiveView receiving message and DB call
    try do
      case Quoracle.Tasks.TaskManager.get_task(task_id) do
        {:ok, db_task} ->
          # Convert to map format expected by Dashboard
          # Note: live is not a DB field, it's computed at runtime
          %{
            id: db_task.id,
            status: db_task.status,
            result: db_task.result,
            prompt: db_task.prompt,
            live: false,
            inserted_at: db_task.inserted_at,
            updated_at: db_task.updated_at,
            root_agent_id: nil,
            error_message: db_task.error_message
          }

        {:error, _} ->
          create_minimal_task_entry(task_id)
      end
    catch
      :exit, {:noproc, _} -> create_minimal_task_entry(task_id)
      :exit, {:shutdown, _} -> create_minimal_task_entry(task_id)
    end
  end

  @doc """
  Create a minimal task entry when task is not found.
  """
  @spec create_minimal_task_entry(String.t() | nil) :: map()
  def create_minimal_task_entry(task_id) do
    %{
      id: task_id,
      status: "running",
      result: nil,
      prompt: if(is_nil(task_id), do: "Agent without task", else: "Unknown task"),
      live: false,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now(),
      root_agent_id: nil,
      error_message: nil
    }
  end

  @doc """
  Links orphaned children to a parent that arrived after them.
  During task restoration, child agent broadcasts may arrive before their parent's
  broadcast. When the parent arrives, this function finds all agents that claim
  this parent and adds them to the parent's children list.
  """
  @spec link_orphaned_children(map(), String.t()) :: map()
  def link_orphaned_children(agents, parent_id) do
    # Find all agents that have this parent_id but aren't in parent's children yet
    orphaned_children =
      agents
      |> Enum.filter(fn {child_id, child} ->
        child_id != parent_id and
          Map.get(child, :parent_id) == parent_id and
          child_id not in Map.get(agents[parent_id], :children, [])
      end)
      |> Enum.map(fn {child_id, _} -> child_id end)

    if Enum.empty?(orphaned_children) do
      agents
    else
      Map.update!(agents, parent_id, fn parent ->
        existing_children = Map.get(parent, :children, [])
        Map.put(parent, :children, orphaned_children ++ existing_children)
      end)
    end
  end

  @doc """
  Query EventHistory buffer for a specific agent's logs and task's messages.
  Merges with existing socket assigns, deduplicating by id.
  """
  @spec query_agent_buffer(Phoenix.LiveView.Socket.t(), String.t(), String.t() | nil) ::
          {map(), list()}
  def query_agent_buffer(socket, agent_id, task_id) do
    event_history_pid = socket.assigns[:event_history_pid]

    if event_history_pid && Process.alive?(event_history_pid) do
      try do
        alias Quoracle.UI.EventHistory

        # Query logs for this agent (EventHistory returns oldest-first, reverse for newest-first)
        buffered_logs = EventHistory.get_logs(event_history_pid, [agent_id])
        agent_logs = Map.get(buffered_logs, agent_id, []) |> Enum.reverse()

        # Merge with existing logs, deduplicating by id
        existing_agent_logs = Map.get(socket.assigns.logs, agent_id, [])
        existing_ids = MapSet.new(Enum.map(existing_agent_logs, & &1[:id]))

        new_logs =
          agent_logs
          |> Enum.reject(fn log -> log[:id] && MapSet.member?(existing_ids, log[:id]) end)

        merged_agent_logs = existing_agent_logs ++ new_logs

        logs =
          if merged_agent_logs == [] do
            socket.assigns.logs
          else
            Map.put(socket.assigns.logs, agent_id, merged_agent_logs)
          end

        # Query messages for this task
        messages =
          if task_id do
            buffered_messages = EventHistory.get_messages(event_history_pid, [task_id])

            # Merge with existing messages, deduplicating by id
            existing_ids = MapSet.new(Enum.map(socket.assigns.messages, & &1[:id]))

            new_messages =
              buffered_messages
              # Filter out inter-agent messages (only user↔root should appear in mailbox)
              |> Enum.reject(&Map.has_key?(&1, :recipient_id))
              |> Enum.reject(fn msg -> msg[:id] && MapSet.member?(existing_ids, msg[:id]) end)

            socket.assigns.messages ++ new_messages
          else
            socket.assigns.messages
          end

        {logs, messages}
      catch
        :exit, _ -> {socket.assigns.logs, socket.assigns.messages}
      end
    else
      {socket.assigns.logs, socket.assigns.messages}
    end
  end
end
