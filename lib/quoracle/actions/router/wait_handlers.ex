defmodule Quoracle.Actions.Router.WaitHandlers do
  @moduledoc """
  Handles wait-related GenServer callbacks for Router.
  """

  alias Quoracle.Actions.Router.TaskManager

  @doc """
  Handle cancel_action cast.
  """
  @spec handle_cancel_action(reference(), map()) :: {:noreply, map()}
  def handle_cancel_action(task_ref, state) do
    {:noreply, TaskManager.cancel_task(state, task_ref)}
  end
end
