defmodule Quoracle.Actions.Shell.StatusCheck do
  @moduledoc """
  Handles status checking for async shell commands.
  """

  @doc """
  Execute status check for a running command by querying Router.

  Returns incremental output since last check.
  Use this when called externally (not from Router's handle_call).
  """
  @spec execute(String.t(), pid()) :: {:ok, map()} | {:error, atom()}
  def execute(command_id, router_pid) do
    # Query Router for state (for external callers)
    try do
      case GenServer.call(router_pid, {:get_shell_command, command_id}) do
        nil -> {:error, :command_not_found}
        state -> process_command_state(command_id, router_pid, state)
      end
    catch
      :exit, {:noproc, _} -> {:error, :command_not_found}
      :exit, {:normal, _} -> {:error, :command_not_found}
    end
  end

  @doc """
  Execute status check with pre-fetched state (avoids Router callback).

  Use this when called from Router's handle_call to avoid deadlock.
  The state may be nil if no command is registered.
  """
  @spec execute_with_state(String.t(), pid(), map() | nil) :: {:ok, map()} | {:error, atom()}
  def execute_with_state(command_id, router_pid, shell_command_state) do
    # Use passed state directly - NO Router callback (avoids deadlock)
    process_command_state(command_id, router_pid, shell_command_state)
  end

  # Process the command state (shared logic)
  defp process_command_state(_command_id, _router_pid, nil) do
    {:error, :command_not_found}
  end

  defp process_command_state(command_id, _router_pid, %{status: :completed}) do
    {:ok, %{status: :completed, command_id: command_id}}
  end

  defp process_command_state(command_id, router_pid, %{status: :running} = state) do
    {last_stdout_pos, last_stderr_pos} = state.last_check_position

    new_stdout = binary_part_safe(state.stdout_buffer, last_stdout_pos)
    new_stderr = binary_part_safe(state.stderr_buffer, last_stderr_pos)

    new_position = {
      byte_size(state.stdout_buffer),
      byte_size(state.stderr_buffer)
    }

    # Use cast to avoid deadlock when called from within Router.execute
    GenServer.cast(router_pid, {:update_check_position, command_id, new_position})

    {:ok,
     %{
       status: :running,
       new_stdout: new_stdout,
       new_stderr: new_stderr,
       bytes_stdout: byte_size(state.stdout_buffer),
       bytes_stderr: byte_size(state.stderr_buffer),
       last_output_at: state[:last_output_at] || state.started_at
     }}
  end

  @doc """
  Safely extract a portion of a binary, handling edge cases.
  """
  @spec binary_part_safe(binary(), non_neg_integer()) :: binary()
  def binary_part_safe(buffer, offset) do
    size = byte_size(buffer)

    if offset >= size do
      ""
    else
      binary_part(buffer, offset, size - offset)
    end
  end
end
