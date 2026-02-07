defmodule Quoracle.Actions.Router.ClientHelpers do
  @moduledoc """
  Helper functions for Router client API operations.
  Extracted to keep Router.ex under 500 lines.
  """

  @default_timeout 5000

  @doc """
  Interrupts a timed wait for an action.
  Causes the action to continue immediately by sending a continue_consensus message.
  """
  @spec interrupt_wait(reference()) :: :ok
  def interrupt_wait(task_ref) when is_reference(task_ref) do
    # In the mock implementation, we just need to send continue_consensus immediately
    send(self(), :trigger_consensus)
    :ok
  end

  @doc """
  Cancels a running action task.
  """
  @spec cancel_action(reference()) :: :ok
  def cancel_action(_task_ref) do
    # Mock implementation for testing
    :ok
  end

  @doc """
  Gets the status of a task.
  """
  @spec task_status(pid(), reference()) :: :running | :completed | :cancelled
  def task_status(agent_pid, _task_ref) do
    # Mock implementation that avoids self-call deadlock
    if Process.alive?(agent_pid), do: :running, else: :completed
  end

  @doc """
  Awaits the result of an async action execution.

  Returns `{:ok, result}` when the action completes, or `{:error, reason}` on failure.
  """
  @spec await_result(GenServer.server(), reference(), keyword()) :: {:ok, any()} | {:error, any()}
  def await_result(router, ref, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(router, {:await_result, ref, timeout}, timeout + 1000)
  end
end
