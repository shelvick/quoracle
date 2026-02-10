defmodule QuoracleWeb.DashboardLive.DataLoader do
  @moduledoc """
  Data loading and merging helpers for DashboardLive.
  Extracted to reduce module size below 500 lines.
  """

  @doc """
  Load tasks from database and merge with Registry state.
  """
  @spec load_tasks_from_db(atom(), atom()) :: %{tasks: map(), agents: map()}
  def load_tasks_from_db(registry, _pubsub) do
    # Query all tasks from database
    db_tasks = Quoracle.Tasks.TaskManager.list_tasks()

    # Get all live agents from Registry (already includes task_id in composite value)
    live_agents = Quoracle.Agent.RegistryQueries.list_all_agents(registry)

    # Convert DB tasks to map keyed by task_id
    tasks_map =
      db_tasks
      |> Enum.map(fn task ->
        {task.id,
         %{
           id: task.id,
           prompt: task.prompt,
           status: task.status,
           result: task.result,
           error_message: task.error_message,
           inserted_at: task.inserted_at,
           updated_at: task.updated_at,
           budget_limit: task.budget_limit,
           live: false
         }}
      end)
      |> Enum.into(%{})

    # Merge live agent state with DB tasks
    {tasks_with_state, agents_map} = merge_task_state(tasks_map, live_agents)

    %{
      tasks: tasks_with_state,
      agents: agents_map
    }
  end

  @doc """
  Merge task database state with live Registry state.
  """
  @spec merge_task_state(map(), list()) :: {map(), map()}
  def merge_task_state(tasks_map, live_agents) do
    # Group live agents by task_id
    agents_by_task =
      Enum.group_by(live_agents, fn {_agent_id, meta} ->
        Map.get(meta, :task_id)
      end)

    # Fetch agent data in parallel to avoid sequential blocking during mount
    # This prevents UI timeout when agents are busy (e.g., waiting on LLM)
    agent_data =
      live_agents
      |> Enum.zip(
        Task.async_stream(
          live_agents,
          fn {_agent_id, meta} ->
            pid = Map.get(meta, :pid)
            {fetch_agent_todos(pid), fetch_agent_budget_data(pid)}
          end,
          timeout: 1000,
          on_timeout: :kill_task
        )
      )
      |> Enum.map(fn
        {{agent_id, meta}, {:ok, {todos, budget_data}}} ->
          {agent_id, meta, todos, budget_data}

        {{agent_id, meta}, {:exit, _reason}} ->
          # Timeout - still show agent but with empty data
          {agent_id, meta, [], nil}
      end)

    # Build agents map (flat structure for rendering)
    agents_map =
      agent_data
      |> Enum.map(fn {agent_id, meta, todos, budget_data} ->
        {agent_id,
         %{
           agent_id: agent_id,
           task_id: Map.get(meta, :task_id),
           parent_id: Map.get(meta, :parent_id),
           pid: Map.get(meta, :pid),
           status: :running,
           children: [],
           todos: todos,
           budget_data: budget_data,
           timestamp: System.system_time(:millisecond)
         }}
      end)
      |> Enum.into(%{})

    # Build inverse parent-child relationships
    agents_map = build_parent_child_relationships(agents_map)

    # Update task status based on live agents
    updated_tasks = update_task_status(tasks_map, agents_by_task)

    {updated_tasks, agents_map}
  end

  @doc """
  Extract EventHistory PID from session (tests) or discover from production.
  """
  @spec get_event_history_pid(map()) :: pid() | nil
  def get_event_history_pid(session) do
    case session do
      %{"event_history_pid" => pid} when is_pid(pid) -> pid
      %{event_history_pid: pid} when is_pid(pid) -> pid
      _ -> Quoracle.UI.EventHistory.get_pid()
    end
  end

  @doc """
  Query EventHistory buffer for logs and messages.
  Returns {logs_map, messages_list} or empty defaults if unavailable.
  """
  @spec query_event_history(pid() | nil, list(String.t()), list(String.t())) :: {map(), list()}
  def query_event_history(nil, _agent_ids, _task_ids), do: {%{}, []}

  def query_event_history(pid, agent_ids, task_ids) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        alias Quoracle.UI.EventHistory

        # Query logs for all agents at once (API takes list, returns map)
        # EventHistory returns oldest-first, but UI expects newest-first
        logs_map =
          EventHistory.get_logs(pid, agent_ids)
          |> Enum.reject(fn {_id, logs} -> logs == [] end)
          |> Enum.map(fn {id, logs} -> {id, Enum.reverse(logs)} end)
          |> Enum.into(%{})

        # Query messages for all tasks (messages are task-scoped)
        # Filter out agent-to-agent messages (have recipient_id field)
        # Only user↔root messages should appear in the mailbox
        messages =
          EventHistory.get_messages(pid, task_ids)
          |> Enum.reject(&Map.has_key?(&1, :recipient_id))

        {logs_map, messages}
      catch
        :exit, _ -> {%{}, []}
      end
    else
      {%{}, []}
    end
  end

  @doc """
  Build map of agent_id => alive status for UI components.
  """
  @spec build_agent_alive_map(map()) :: map()
  def build_agent_alive_map(agents) do
    Map.new(agents, fn {agent_id, agent_data} -> {agent_id, agent_data.status != :terminated} end)
  end

  @doc """
  Get filtered logs for LogView component.
  When no agent is selected, shows all logs merged chronologically.
  When an agent is selected, shows only that agent's logs.
  """
  @spec get_filtered_logs(map() | list(), String.t() | nil) :: list()
  def get_filtered_logs(logs_map, nil) when is_map(logs_map) do
    # No selection - show all logs merged chronologically
    logs_map
    |> Map.values()
    |> List.flatten()
    |> Enum.sort_by(& &1[:timestamp])
    # Global display limit
    |> Enum.take(-100)
  end

  def get_filtered_logs(logs_map, agent_id) when is_map(logs_map) do
    Map.get(logs_map, agent_id, [])
  end

  # Backwards compatibility for list format
  def get_filtered_logs(logs_list, _agent_id) when is_list(logs_list), do: logs_list

  # Private helpers

  defp build_parent_child_relationships(agents_map) do
    Enum.reduce(agents_map, agents_map, fn {agent_id, agent}, acc ->
      case agent.parent_id do
        nil ->
          acc

        parent_id when is_map_key(acc, parent_id) ->
          Map.update!(acc, parent_id, fn parent ->
            if agent_id in parent.children do
              parent
            else
              Map.put(parent, :children, [agent_id | parent.children])
            end
          end)

        _ ->
          acc
      end
    end)
  end

  defp update_task_status(tasks_map, agents_by_task) do
    Enum.map(tasks_map, fn {task_id, task} ->
      task_agents = Map.get(agents_by_task, task_id, [])
      has_live_agents = task_agents != []

      # Find root agent (parent_id: nil) for this task
      root_agent_id =
        task_agents
        |> Enum.find(fn {_agent_id, meta} -> is_nil(meta.parent_id) end)
        |> case do
          {agent_id, _meta} -> agent_id
          nil -> nil
        end

      task_with_state =
        if has_live_agents do
          task
          |> Map.put(:status, "running")
          |> Map.put(:live, true)
          |> Map.put(:root_agent_id, root_agent_id)
        else
          # Recover stuck "pausing" state: if no live agents remain but DB
          # still says "pausing", transition to "paused" (agents finished
          # terminating before this mount/refresh).
          recovered_task =
            if task[:status] == "pausing" do
              try do
                Quoracle.Tasks.TaskManager.update_task_status(task_id, "paused")
              catch
                :exit, _ -> :ok
              end

              Map.put(task, :status, "paused")
            else
              task
            end

          recovered_task
          |> Map.put(:live, false)
          |> Map.put(:root_agent_id, nil)
        end

      {task_id, task_with_state}
    end)
    |> Enum.into(%{})
  end

  @spec fetch_agent_todos(pid() | nil) :: list()
  defp fetch_agent_todos(nil), do: []

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

  @spec fetch_agent_budget_data(pid() | nil) :: map() | nil
  defp fetch_agent_budget_data(nil), do: nil

  defp fetch_agent_budget_data(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        {:ok, state} = Quoracle.Agent.Core.get_state(pid)
        state.budget_data
      catch
        :exit, _ -> nil
      end
    else
      nil
    end
  end
end
