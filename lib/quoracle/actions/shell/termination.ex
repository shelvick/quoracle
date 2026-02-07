defmodule Quoracle.Actions.Shell.Termination do
  @moduledoc """
  Handles termination of running shell commands.
  """

  @doc """
  Execute termination for a running command.

  Sends SIGTERM with configurable grace period, falls back to SIGKILL if needed.

  Per-action Router (v28.0): When shell_command_state is provided in opts, uses it directly
  to avoid callback deadlock. When nil, queries Router via GenServer.call.
  """
  @spec execute(String.t(), pid(), keyword()) :: {:ok, map()} | {:error, atom()}
  def execute(command_id, router_pid, opts) do
    # CRITICAL: Check if key EXISTS, not if value is truthy.
    # Router passes shell_command_state: nil when state.shell_command is nil.
    # If we check truthiness, nil causes callback to Router = DEADLOCK (we're in handle_call).
    state_result =
      if Keyword.has_key?(opts, :shell_command_state) do
        # Called from Router's handle_call - use passed state, don't callback
        {:ok, Keyword.get(opts, :shell_command_state)}
      else
        # Per-action Router (v28.0): Router may have terminated after command completed.
        # Handle :noproc gracefully by returning :command_not_found.
        try do
          case GenServer.call(router_pid, {:get_shell_command, command_id}) do
            nil -> {:error, :command_not_found}
            state -> {:ok, state}
          end
        catch
          :exit, {:noproc, _} -> {:error, :command_not_found}
          :exit, {:normal, _} -> {:error, :command_not_found}
        end
      end

    case state_result do
      {:error, reason} ->
        {:error, reason}

      {:ok, nil} ->
        {:error, :command_not_found}

      {:ok, %{status: :completed}} ->
        {:error, :already_completed}

      {:ok, %{status: :running, port: nil} = state} ->
        # Port not yet set (race condition: command started but port update not processed)
        # Mark as terminated and return - the command task will handle its own cleanup
        GenServer.cast(router_pid, {:mark_terminated, command_id})

        {:ok,
         %{
           terminated: true,
           final_stdout: state.stdout_buffer,
           final_stderr: state.stderr_buffer,
           signal: :no_port
         }}

      {:ok, %{status: :running, port: port} = state} when is_port(port) ->
        # Get OS pid for sending signals
        os_pid =
          case :erlang.port_info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        signal =
          if os_pid do
            # Send SIGTERM to OS process
            System.cmd("kill", ["-TERM", to_string(os_pid)])

            # Immediately drain any error messages from the dying process
            # This catches "Broken pipe" errors written right after SIGTERM
            drain_port_messages(port)

            # Wait for graceful termination with configurable grace period
            grace_period_ms = Keyword.get(opts, :termination_grace_period_ms, 5000)
            wait_for_port_termination(port, os_pid, grace_period_ms)
          else
            # No OS pid available, just close port
            catch_port_close(port)
            :sigterm
          end

        GenServer.cast(router_pid, {:mark_terminated, command_id})

        {:ok,
         %{
           terminated: true,
           final_stdout: state.stdout_buffer,
           final_stderr: state.stderr_buffer,
           signal: signal
         }}

      {:ok, _invalid_state} ->
        # Invalid state structure (missing :status or unexpected format)
        {:error, :invalid_command_state}
    end
  end

  # Wait for port to terminate after SIGTERM, with fallback to SIGKILL
  # Accepts grace period in milliseconds
  defp wait_for_port_termination(port, os_pid, grace_period_ms) do
    check_interval_ms = 100
    max_checks = div(grace_period_ms, check_interval_ms)
    wait_for_port_termination_loop(port, os_pid, max_checks)
  end

  defp wait_for_port_termination_loop(port, os_pid, checks_remaining) when checks_remaining > 0 do
    # Give process time to respond to SIGTERM
    Process.sleep(100)
    # Drain pending messages during wait to prevent termination noise
    drain_port_messages(port)

    case Port.info(port) do
      nil ->
        :sigterm

      _ ->
        wait_for_port_termination_loop(port, os_pid, checks_remaining - 1)
    end
  end

  defp wait_for_port_termination_loop(port, os_pid, 0) do
    # Timeout - send SIGKILL (cannot be caught, instant termination)
    System.cmd("kill", ["-KILL", to_string(os_pid)])

    # CRITICAL: Wait for process to actually die before returning.
    # If we call Port.close before the process exits, the Task that owns
    # the port won't receive exit_status, causing it to hang forever in
    # collect_and_buffer_output. Router.terminate then hangs waiting for
    # the Task, blocking the GenServer.call response.
    wait_for_port_death(port, 10)
    :sigkill
  end

  # Wait for port to close naturally after SIGKILL (up to 1 second)
  defp wait_for_port_death(_port, 0), do: :ok

  defp wait_for_port_death(port, retries) do
    case Port.info(port) do
      nil ->
        :ok

      _ ->
        Process.sleep(100)
        wait_for_port_death(port, retries - 1)
    end
  end

  # Safely close port (handles already-closed ports)
  # Drains pending messages first to prevent termination noise in test output
  defp catch_port_close(port) do
    drain_port_messages(port)
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # Drain any pending messages from a dying port
  # This prevents "echo: write error: Broken pipe" noise when terminating shell commands
  defp drain_port_messages(port) do
    receive do
      {^port, _} -> drain_port_messages(port)
    after
      0 -> :ok
    end
  end
end
