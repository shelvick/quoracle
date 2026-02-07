defmodule Quoracle.Actions.Router.ShellCommandManager do
  @moduledoc """
  Manages shell command state for Router.

  Handles registration, output buffering, status tracking, and termination
  for async shell command execution.
  """

  # Type definitions for shell command state management
  @typedoc """
  State structure for tracking shell command execution.

  - port: Erlang port for the running command (nil during registration)
  - command: Shell command string being executed
  - working_dir: Working directory for command execution
  - stdout_buffer: Accumulated stdout output
  - stderr_buffer: Accumulated stderr output (currently unused)
  - last_check_position: Byte positions for incremental output delivery {stdout_pos, stderr_pos}
  - started_at: DateTime when command started
  - agent_id: ID of agent that initiated the command
  - agent_pid: PID of agent for proactive completion messages
  - action_id: Router's action ID for Core notification (REQUIRED)
  - status: Current execution status
  - exit_code: Process exit code (nil while running)
  """
  @type shell_command_state :: %{
          port: port() | nil,
          command: String.t(),
          working_dir: String.t(),
          stdout_buffer: binary(),
          stderr_buffer: binary(),
          last_check_position: {non_neg_integer(), non_neg_integer()},
          started_at: DateTime.t(),
          agent_id: String.t(),
          agent_pid: pid(),
          action_id: String.t(),
          status: :running | :completed,
          exit_code: integer() | nil
        }

  @doc """
  Initialize shell command state for per-action Router.

  Per-action Router (v2.0): Returns nil (no command initially).
  Each Router handles at most one shell command.
  """
  @spec init() :: nil
  def init do
    nil
  end

  @doc """
  Register or update a shell command.

  Requires action_id in command_state for Router-mediated Core notification.

  Handles out-of-order message delivery: if mark_completed arrived before
  registration (possible with cross-process casts), applies the pending
  completion immediately.
  """
  @spec register(map() | nil, String.t(), shell_command_state()) :: map()
  def register(shell_commands, command_id, command_state) do
    unless Map.has_key?(command_state, :action_id) do
      raise ArgumentError, "command_state must include :action_id for Core notification"
    end

    # Per-action Router (v2.0): Handle nil from init/0
    shell_commands = shell_commands || %{}

    case Map.get(shell_commands, command_id) do
      %{pending_completion: exit_code} ->
        # Completion arrived before registration - apply immediately
        Map.put(shell_commands, command_id, %{
          command_state
          | status: :completed,
            exit_code: exit_code
        })

      _ ->
        Map.put(shell_commands, command_id, command_state)
    end
  end

  @doc """
  Get shell command state by ID.
  """
  @spec get(map() | nil, String.t()) :: shell_command_state() | nil
  def get(shell_commands, command_id) do
    # Per-action Router (v2.0): Handle nil from init/0
    shell_commands = shell_commands || %{}
    Map.get(shell_commands, command_id)
  end

  @doc """
  Append output data to command buffer.
  """
  @spec append_output(map() | nil, String.t(), :stdout, binary()) :: map()
  def append_output(shell_commands, command_id, :stdout, data) do
    # Per-action Router (v2.0): Handle nil from init/0
    shell_commands = shell_commands || %{}

    case Map.get(shell_commands, command_id) do
      nil ->
        shell_commands

      command_state ->
        updated_command = %{command_state | stdout_buffer: command_state.stdout_buffer <> data}
        Map.put(shell_commands, command_id, updated_command)
    end
  end

  @doc """
  Update last check position for incremental output delivery.
  """
  @spec update_check_position(map() | nil, String.t(), {non_neg_integer(), non_neg_integer()}) ::
          map()
  def update_check_position(shell_commands, command_id, new_position) do
    # Per-action Router (v2.0): Handle nil from init/0
    shell_commands = shell_commands || %{}

    case Map.get(shell_commands, command_id) do
      nil ->
        shell_commands

      command_state ->
        updated_command = %{command_state | last_check_position: new_position}
        Map.put(shell_commands, command_id, updated_command)
    end
  end

  @doc """
  Mark command as completed with exit code.

  Handles out-of-order message delivery: if registration hasn't arrived yet
  (possible with cross-process casts), stores a pending completion marker
  that register/3 will apply when the registration arrives.
  """
  @spec mark_completed(map() | nil, String.t(), integer()) :: map()
  def mark_completed(shell_commands, command_id, exit_code) do
    # Per-action Router (v2.0): Handle nil from init/0
    shell_commands = shell_commands || %{}

    case Map.get(shell_commands, command_id) do
      nil ->
        # Registration hasn't arrived yet - store pending completion
        Map.put(shell_commands, command_id, %{pending_completion: exit_code})

      %{pending_completion: _} ->
        # Already pending, update with latest exit code
        Map.put(shell_commands, command_id, %{pending_completion: exit_code})

      command_state ->
        updated_command = %{command_state | status: :completed, exit_code: exit_code}
        Map.put(shell_commands, command_id, updated_command)
    end
  end

  @doc """
  Mark command as terminated and clean up resources.
  Closes port if still alive before deleting state.
  """
  @spec mark_terminated(map() | nil, String.t()) :: map()
  def mark_terminated(shell_commands, command_id) do
    # Per-action Router (v2.0): Handle nil from init/0
    shell_commands = shell_commands || %{}

    # Close port if still alive before deleting state
    case Map.get(shell_commands, command_id) do
      %{port: port} when is_port(port) ->
        catch_port_close(port)

      _ ->
        :ok
    end

    Map.delete(shell_commands, command_id)
  end

  # Safely close port (handles already-closed ports)
  defp catch_port_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
