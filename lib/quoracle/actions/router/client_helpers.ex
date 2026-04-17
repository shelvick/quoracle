defmodule Quoracle.Actions.Router.ClientHelpers do
  @moduledoc """
  Helper functions for Router client API operations.
  Extracted to keep Router.ex under 500 lines.
  """

  @default_timeout 5000

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
