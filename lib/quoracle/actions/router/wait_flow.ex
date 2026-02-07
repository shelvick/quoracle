defmodule Quoracle.Actions.Router.WaitFlow do
  @moduledoc """
  Wait flow control logic for action execution.
  Handles timer notifications for timed waits.

  NOTE: Consensus triggers are handled by ActionExecutor (Agent layer) which sets
  consensus_scheduled flag. WaitFlow (Router layer) only handles timer setup.
  """

  @doc """
  Handle wait flow control before action execution.

  Sends timer notification for timed wait values.
  Consensus triggers are handled by ActionExecutor after action completion.

  ## Parameters
    - task_ref: Reference for the task being executed
    - wait_value: false (immediate), 0 (immediate), integer (seconds), true (wait for result)
    - agent_pid: PID of the agent to send continuation messages to
  """
  @spec handle_immediate(reference(), any(), pid()) :: :ok
  def handle_immediate(task_ref, seconds, agent_pid) when is_integer(seconds) and seconds > 0 do
    # Send timer notification - consensus trigger handled by ActionExecutor
    timer_ref = make_ref()
    send(agent_pid, {:wait_timer_started, task_ref, timer_ref})
    :ok
  end

  def handle_immediate(_task_ref, _wait_value, _agent_pid), do: :ok

  @doc """
  Handle wait flow control after action result.

  Consensus triggers are handled by ActionExecutor (Agent layer).
  This function is kept for interface compatibility but performs no action.

  ## Parameters
    - task_ref: Reference for the task being executed (unused)
    - wait_value: The wait parameter value from the action (unused)
    - agent_pid: PID of the agent (unused)
    - result: The action result (unused)
  """
  @spec handle_after_result(reference(), any(), pid(), any()) :: :ok
  def handle_after_result(_task_ref, _wait_value, _agent_pid, _result) do
    # Consensus triggers are handled by ActionExecutor which sets consensus_scheduled flag
    :ok
  end
end
