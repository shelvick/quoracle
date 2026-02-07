defmodule Quoracle.Actions.Router.ShellCompletion do
  @moduledoc """
  Handles Shell command completion notifications for the Router.

  Per-action Router (v28.0): Each Router handles ONE command, so no multi-command
  tracking is needed. Completion builds result, notifies Core, and broadcasts events.
  """

  alias Quoracle.Actions.Router.Security
  alias Quoracle.PubSub.AgentEvents

  @doc """
  Handle Shell command completion.

  Takes command state and exit code, builds result, notifies Core via
  handle_action_result, and broadcasts completion event.

  Per-action Router: Returns state unchanged (no multi-command tracking).
  """
  @spec handle_completion(map() | nil, String.t(), integer(), map(), atom()) :: map()
  def handle_completion(nil, _command_id, _exit_code, state, _pubsub), do: state

  def handle_completion(command_state, _command_id, exit_code, state, pubsub) do
    # Calculate execution time
    execution_time_ms =
      DateTime.diff(DateTime.utc_now(), command_state.started_at, :millisecond)

    # Truncate command to 200 chars to save tokens (full command was in original action params)
    truncated_command =
      if byte_size(command_state.command) > 200 do
        String.slice(command_state.command, 0, 197) <> "..."
      else
        command_state.command
      end

    raw_result = %{
      action: "shell",
      command: truncated_command,
      stdout: command_state.stdout_buffer,
      stderr: command_state.stderr_buffer,
      exit_code: exit_code,
      execution_time_ms: execution_time_ms,
      status: :completed,
      sync: false
    }

    # Scrub secrets from output (secrets_used stored in command_state)
    secrets_used = Map.get(command_state, :secrets_used, [])
    {:ok, result} = Security.scrub_output({:ok, raw_result}, secrets_used)

    # Call Core.handle_action_result with action_id
    Quoracle.Agent.Core.handle_action_result(
      command_state.agent_pid,
      command_state.action_id,
      {:ok, result}
    )

    # Broadcast completion event via PubSub
    AgentEvents.broadcast_action_completed(
      command_state.agent_id,
      command_state.action_id,
      {:ok, result},
      pubsub
    )

    # Per-action Router: No multi-command tracking needed
    state
  end
end
