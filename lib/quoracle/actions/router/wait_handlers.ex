defmodule Quoracle.Actions.Router.WaitHandlers do
  @moduledoc """
  Handles wait-related GenServer callbacks for Router.
  """

  alias Quoracle.Actions.Router.TaskManager

  @doc """
  Handle interrupt_wait cast.
  """
  @spec handle_interrupt_wait(reference(), map()) :: {:noreply, map()}
  def handle_interrupt_wait(task_ref, state) do
    # Find and cancel any wait timer for this task
    case Map.get(state.wait_timers, task_ref) do
      nil ->
        {:noreply, state}

      timer_ref ->
        Process.cancel_timer(timer_ref)
        send(state.agent_pid, :trigger_consensus)
        new_timers = Map.delete(state.wait_timers, task_ref)
        {:noreply, %{state | wait_timers: new_timers}}
    end
  end

  @doc """
  Handle cancel_action cast.
  """
  @spec handle_cancel_action(reference(), map()) :: {:noreply, map()}
  def handle_cancel_action(task_ref, state) do
    {:noreply, TaskManager.cancel_task(state, task_ref)}
  end
end
