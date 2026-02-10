defmodule Quoracle.PubSub.AgentEvents do
  @moduledoc """
  Centralized event broadcasting for agent lifecycle and actions.

  This module provides a consistent interface for PubSub messaging throughout
  the application. All functions require an explicit pubsub parameter to
  ensure test isolation and prevent cross-test message interference.

  ## Topics

  - `agents:lifecycle` - Agent spawn/termination events
  - `agents:[id]:state` - Agent state changes
  - `agents:[id]:logs` - Agent log entries
  - `agents:[id]:metrics` - Agent metrics updates
  - `actions:all` - Action start/complete/error events
  - `tasks:[id]:messages` - Task-specific messages
  """

  # Defensive wrapper for all PubSub broadcasts
  # Prevents crashes when PubSub stops during test cleanup (race condition)
  defp safe_broadcast(pubsub, topic, message) do
    try do
      Phoenix.PubSub.broadcast(pubsub, topic, message)
    rescue
      ArgumentError ->
        # PubSub registry not running (test cleanup race) - skip silently
        :ok
    end
  end

  @doc """
  Broadcast agent spawned event to lifecycle topic.
  """
  @spec broadcast_agent_spawned(String.t(), String.t() | nil, String.t() | pid() | nil, atom()) ::
          :ok
  @spec broadcast_agent_spawned(
          String.t(),
          String.t() | nil,
          String.t() | pid() | nil,
          String.t(),
          atom()
        ) :: :ok
  # 5-param version for root agents with budget_data
  @spec broadcast_agent_spawned(
          String.t(),
          String.t() | nil,
          String.t() | pid() | nil,
          atom(),
          map() | nil
        ) :: :ok
  # 6-param version for child agents with budget_data
  @spec broadcast_agent_spawned(
          String.t(),
          String.t() | nil,
          String.t() | pid() | nil,
          String.t(),
          atom(),
          map() | nil
        ) :: :ok

  # 4-param version for root agents (backward compatible)
  def broadcast_agent_spawned(agent_id, task_id, parent_id_or_pid, pubsub)
      when is_atom(pubsub) or is_pid(pubsub) do
    safe_broadcast(pubsub, "agents:lifecycle", {
      :agent_spawned,
      %{
        agent_id: agent_id,
        task_id: task_id,
        parent_id: parent_id_or_pid,
        task: task_id,
        timestamp: DateTime.utc_now()
      }
    })
  end

  # 5-param version for root agents with budget_data (distinguished by map/nil guard)
  def broadcast_agent_spawned(agent_id, task_id, parent_id_or_pid, pubsub, budget_data)
      when (is_atom(pubsub) or is_pid(pubsub)) and (is_map(budget_data) or is_nil(budget_data)) do
    safe_broadcast(pubsub, "agents:lifecycle", {
      :agent_spawned,
      %{
        agent_id: agent_id,
        task_id: task_id,
        parent_id: parent_id_or_pid,
        task: task_id,
        budget_data: budget_data,
        timestamp: DateTime.utc_now()
      }
    })
  end

  # 5-param version for child agents (separate task_id and task)
  def broadcast_agent_spawned(agent_id, task_id, parent_id_or_pid, task, pubsub)
      when is_binary(task) and (is_atom(pubsub) or is_pid(pubsub)) do
    safe_broadcast(pubsub, "agents:lifecycle", {
      :agent_spawned,
      %{
        agent_id: agent_id,
        task_id: task_id,
        parent_id: parent_id_or_pid,
        task: task,
        timestamp: DateTime.utc_now()
      }
    })
  end

  # 6-param version for child agents with budget_data
  def broadcast_agent_spawned(agent_id, task_id, parent_id_or_pid, task, pubsub, budget_data)
      when is_binary(task) and (is_atom(pubsub) or is_pid(pubsub)) and
             (is_map(budget_data) or is_nil(budget_data)) do
    safe_broadcast(pubsub, "agents:lifecycle", {
      :agent_spawned,
      %{
        agent_id: agent_id,
        task_id: task_id,
        parent_id: parent_id_or_pid,
        task: task,
        budget_data: budget_data,
        timestamp: DateTime.utc_now()
      }
    })
  end

  @doc """
  Broadcast agent terminated event.
  """
  @spec broadcast_agent_terminated(String.t(), atom(), atom()) :: :ok
  def broadcast_agent_terminated(agent_id, reason, pubsub) do
    safe_broadcast(pubsub, "agents:lifecycle", {
      :agent_terminated,
      %{
        agent_id: agent_id,
        reason: reason,
        timestamp: DateTime.utc_now()
      }
    })
  end

  @doc """
  Broadcast action started event.
  """
  @spec broadcast_action_started(String.t(), atom(), String.t(), map(), atom()) :: :ok
  def broadcast_action_started(agent_id, action_type, action_id, params, pubsub) do
    safe_broadcast(pubsub, "actions:all", {
      :action_started,
      %{
        agent_id: agent_id,
        action_type: action_type,
        action_id: action_id,
        params: params,
        timestamp: DateTime.utc_now()
      }
    })
  end

  @doc """
  Broadcast action completed event.
  """
  @spec broadcast_action_completed(String.t(), String.t(), term(), atom()) :: :ok
  def broadcast_action_completed(agent_id, action_id, result, pubsub) do
    safe_broadcast(pubsub, "actions:all", {
      :action_completed,
      %{
        agent_id: agent_id,
        action_id: action_id,
        result: result,
        timestamp: DateTime.utc_now()
      }
    })
  end

  @doc """
  Broadcast action error event.
  """
  @spec broadcast_action_error(String.t(), String.t(), term(), atom()) :: :ok
  def broadcast_action_error(agent_id, action_id, error, pubsub) do
    safe_broadcast(pubsub, "actions:all", {
      :action_error,
      %{
        agent_id: agent_id,
        action_id: action_id,
        error: error,
        timestamp: DateTime.utc_now()
      }
    })
  end

  @doc """
  Broadcast log entry to agent-specific topic.
  """
  @spec broadcast_log(String.t() | nil, atom(), String.t(), map(), atom()) :: :ok
  def broadcast_log(agent_id, level, message, metadata, pubsub) do
    case agent_id do
      nil ->
        :ok

      id ->
        safe_broadcast(pubsub, "agents:#{id}:logs", {
          :log_entry,
          %{
            id: System.unique_integer([:positive, :monotonic]),
            agent_id: id,
            level: level,
            message: message,
            metadata: metadata,
            timestamp: DateTime.utc_now()
          }
        })
    end
  end

  @doc """
  Broadcast user message to task-specific topic.
  """
  @spec broadcast_user_message(String.t(), String.t(), String.t(), atom()) :: :ok
  def broadcast_user_message(task_id, agent_id, content, pubsub) do
    safe_broadcast(pubsub, "tasks:#{task_id}:messages", {
      :agent_message,
      %{
        id: System.unique_integer([:positive]),
        task_id: task_id,
        from: :user,
        sender_id: agent_id,
        content: content,
        timestamp: DateTime.utc_now(),
        status: :received
      }
    })
  end

  @doc """
  Broadcast state change to agent-specific topic.
  """
  @spec broadcast_state_change(String.t(), atom(), atom(), atom()) :: :ok
  def broadcast_state_change(agent_id, old_state, new_state, pubsub) do
    safe_broadcast(pubsub, "agents:#{agent_id}:state", {
      :state_changed,
      %{
        agent_id: agent_id,
        old_state: old_state,
        new_state: new_state,
        timestamp: DateTime.utc_now()
      }
    })
  end

  @doc """
  Broadcast todos updated event to agent-specific todos topic.
  """
  @spec broadcast_todos_updated(String.t(), list(), atom()) :: :ok
  def broadcast_todos_updated(agent_id, todos, pubsub) do
    safe_broadcast(pubsub, "agents:#{agent_id}:todos", {
      :todos_updated,
      %{
        agent_id: agent_id,
        todos: todos,
        timestamp: DateTime.utc_now()
      }
    })
  end

  @doc """
  Subscribe to all agent-specific topics for a given agent.
  """
  @spec subscribe_to_agent(String.t(), atom()) :: :ok
  def subscribe_to_agent(agent_id, pubsub) do
    Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:state")
    Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:logs")
    :ok
  end

  @doc """
  Subscribe to task-specific message topic.
  """
  @spec subscribe_to_task(String.t(), atom()) :: :ok
  def subscribe_to_task(task_id, pubsub) do
    Phoenix.PubSub.subscribe(pubsub, "tasks:#{task_id}:messages")
  end

  @doc """
  Subscribe to lifecycle and action topics.
  """
  @spec subscribe_to_all_agents(atom()) :: :ok
  def subscribe_to_all_agents(pubsub) do
    Phoenix.PubSub.subscribe(pubsub, "agents:lifecycle")
    Phoenix.PubSub.subscribe(pubsub, "actions:all")
    :ok
  end
end
