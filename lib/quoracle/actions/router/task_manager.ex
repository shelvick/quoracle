defmodule Quoracle.Actions.Router.TaskManager do
  @moduledoc """
  Task management for Router action execution.
  Handles task registration, result storage, and cleanup.
  """

  @doc """
  Registers a new task with its metadata.
  """
  @spec register_task(map(), reference(), map()) :: map()
  def register_task(state, ref, task_info) do
    new_tasks = Map.put(state.active_tasks, ref, task_info)
    %{state | active_tasks: new_tasks}
  end

  @doc """
  Stores a task result and removes it from active tasks.
  """
  @spec store_result(map(), reference(), any()) :: map()
  def store_result(state, ref, result) do
    new_results = Map.put(state.results, ref, result)
    new_tasks = Map.delete(state.active_tasks, ref)
    %{state | results: new_results, active_tasks: new_tasks}
  end

  @doc """
  Cancels an active task.
  """
  @spec cancel_task(map(), reference()) :: map()
  def cancel_task(state, task_ref) do
    case Map.get(state.active_tasks, task_ref) do
      %{task: task} ->
        Task.shutdown(task, :brutal_kill)
        new_tasks = Map.delete(state.active_tasks, task_ref)
        %{state | active_tasks: new_tasks}

      nil ->
        state
    end
  end

  @doc """
  Handles interrupting a wait for a task.
  """
  @spec interrupt_wait(map(), reference()) :: map()
  def interrupt_wait(state, task_ref) do
    case Map.get(state.active_tasks, task_ref) do
      %{wait_timer: timer_ref} = task_info when timer_ref != nil ->
        Process.cancel_timer(timer_ref)

        # Send immediate continue message to the agent
        if agent_pid = Map.get(task_info, :agent_pid) do
          send(agent_pid, :trigger_consensus)
        end

        # Clear the timer from the task info
        updated_task = Map.put(task_info, :wait_timer, nil)
        new_tasks = Map.put(state.active_tasks, task_ref, updated_task)
        %{state | active_tasks: new_tasks}

      _ ->
        state
    end
  end

  @doc """
  Cleans up after task completion.
  """
  @spec cleanup_task(map(), reference()) :: map()
  def cleanup_task(state, ref) do
    Map.delete(state.active_tasks, ref)
  end

  @doc """
  Gets the status of a task.
  """
  @spec get_task_status(map(), reference()) :: :running | :completed | :cancelled
  def get_task_status(state, task_ref) do
    case {Map.has_key?(state.active_tasks, task_ref), Map.has_key?(state.results, task_ref)} do
      {true, _} -> :running
      {false, true} -> :completed
      {false, false} -> :cancelled
    end
  end

  @doc """
  Initializes empty task state.
  """
  @spec init_task_state() :: map()
  def init_task_state() do
    %{
      active_tasks: %{},
      results: %{}
    }
  end

  @doc """
  Find shell async info by ref.
  """
  @spec find_shell_async_info(map(), reference()) :: map() | nil
  def find_shell_async_info(shell_async_refs, ref) do
    Enum.find_value(shell_async_refs, fn {_cmd_id, info} ->
      if info.ref == ref, do: info, else: nil
    end)
  end

  @doc """
  Find task by monitor reference.
  Used to remove tasks from active_tasks when task process dies.
  """
  @spec find_task_by_monitor(map(), reference()) :: {reference(), map()} | nil
  def find_task_by_monitor(active_tasks, monitor_ref) do
    Enum.find(active_tasks, fn {_task_ref, task_info} ->
      task_info[:monitor] == monitor_ref
    end)
  end
end
