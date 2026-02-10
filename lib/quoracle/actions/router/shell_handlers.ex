defmodule Quoracle.Actions.Router.ShellHandlers do
  @moduledoc """
  Handles shell-specific GenServer callbacks for Router.

  Per-action Router (v28.0): Each Router handles ONE shell command.
  State uses singular `shell_command` and `shell_task` fields.
  """

  alias Quoracle.Actions.Router.ShellCompletion

  @doc """
  Handle register_shell_task cast - tracks shell Task.async with monitoring.

  Per-action Router: Stores single task in shell_task field.
  """
  @spec handle_register_shell_task(String.t(), Task.t(), map()) :: {:noreply, map()}
  def handle_register_shell_task(_command_id, task, state) do
    # Track shell Task.async with monitoring to prevent DB connection leaks
    # CRITICAL: Monitor task process to track its actual lifetime
    task_monitor = Process.monitor(task.pid)
    {:noreply, %{state | shell_task: {task, task_monitor}}}
  end

  @doc """
  Handle update_shell_port cast - updates shell command with port and task_pid.

  Per-action Router: Updates single shell_command field.
  """
  @spec handle_update_shell_port(String.t(), port(), pid(), map()) :: {:noreply, map()}
  def handle_update_shell_port(_command_id, port, task_pid, state) do
    case state.shell_command do
      nil ->
        {:noreply, state}

      cmd_state ->
        updated = cmd_state |> Map.put(:port, port) |> Map.put(:task_pid, task_pid)
        {:noreply, %{state | shell_command: updated}}
    end
  end

  @doc """
  Handle register_shell_command call.

  Per-action Router: Stores command state in shell_command field.
  Requires action_id in command_state for Core notification.
  """
  @spec handle_register_call(String.t(), map(), map()) :: {:reply, :ok, map()}
  def handle_register_call(_command_id, command_state, state) do
    unless Map.has_key?(command_state, :action_id) do
      raise ArgumentError, "command_state must include :action_id for Core notification"
    end

    {:reply, :ok, %{state | shell_command: command_state}}
  end

  @doc """
  Handle get_shell_command call.

  Per-action Router: Returns shell_command field (ignores command_id).
  """
  @spec handle_get_call(String.t(), map()) :: {:reply, map() | nil, map()}
  def handle_get_call(_command_id, state) do
    {:reply, state.shell_command, state}
  end

  @doc """
  Handle register_shell_command cast.

  Sends shell_registered notification to agent after successful registration
  to ensure deterministic message ordering (registration happens before any async work).

  Per-action Router: Stores command state in shell_command field.
  """
  @spec handle_register_cast(String.t(), map(), map()) :: {:noreply, map()}
  def handle_register_cast(command_id, command_state, state) do
    unless Map.has_key?(command_state, :action_id) do
      raise ArgumentError, "command_state must include :action_id for Core notification"
    end

    # Send registration notification after successful registration
    # This ensures the message arrives before any async completion messages
    if command_state[:agent_pid] && Process.alive?(command_state.agent_pid) do
      send(command_state.agent_pid, {:shell_registered, command_id})
    end

    {:noreply, %{state | shell_command: command_state}}
  end

  @doc """
  Handle append_output cast.

  Per-action Router: Appends to shell_command's stdout_buffer.
  """
  @spec handle_append_output(String.t(), :stdout, binary(), map()) :: {:noreply, map()}
  def handle_append_output(_command_id, :stdout, data, state) do
    case state.shell_command do
      nil ->
        {:noreply, state}

      cmd_state ->
        updated = %{cmd_state | stdout_buffer: cmd_state.stdout_buffer <> data}
        {:noreply, %{state | shell_command: updated}}
    end
  end

  @doc """
  Handle update_check_position cast.

  Per-action Router: Updates shell_command's last_check_position.
  """
  @spec handle_update_check_position(String.t(), {non_neg_integer(), non_neg_integer()}, map()) ::
          {:noreply, map()}
  def handle_update_check_position(_command_id, new_position, state) do
    case state.shell_command do
      nil ->
        {:noreply, state}

      cmd_state ->
        updated = %{cmd_state | last_check_position: new_position}
        {:noreply, %{state | shell_command: updated}}
    end
  end

  @doc """
  Handle mark_completed cast.

  Per-action Router: Marks shell_command as completed and triggers completion flow.
  """
  @spec handle_mark_completed(String.t(), integer(), map(), atom()) :: {:noreply, map()}
  def handle_mark_completed(command_id, exit_code, state, pubsub) do
    command_state = state.shell_command

    # Update shell_command with completion status
    new_shell_command =
      if command_state do
        %{command_state | status: :completed, exit_code: exit_code}
      else
        nil
      end

    new_state = %{state | shell_command: new_shell_command}

    # Handle completion (notify Core, broadcast, etc.)
    new_state =
      ShellCompletion.handle_completion(command_state, command_id, exit_code, new_state, pubsub)

    # Clean up shell task (demonitor)
    new_state = cleanup_shell_task(new_state)

    {:noreply, new_state}
  end

  @doc """
  Handle mark_terminated cast.

  Per-action Router: Closes port if still alive and clears shell_command.
  """
  @spec handle_mark_terminated(String.t(), map()) :: {:noreply, map()}
  def handle_mark_terminated(_command_id, state) do
    # Close port if still alive
    case state.shell_command do
      %{port: port} when is_port(port) ->
        catch_port_close(port)

      _ ->
        :ok
    end

    # Clear shell_command and shell_task
    new_state = %{state | shell_command: nil}
    new_state = cleanup_shell_task(new_state)

    {:noreply, new_state}
  end

  # Demonitor and clear shell_task
  defp cleanup_shell_task(state) do
    case state.shell_task do
      {_task, monitor} ->
        Process.demonitor(monitor, [:flush])
        %{state | shell_task: nil}

      _ ->
        state
    end
  end

  # Safely close port (handles already-closed ports)
  defp catch_port_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Handle get_shell_status call.

  Per-action Router: Returns status of shell_command or error if none.
  """
  @spec handle_get_status(map()) :: {:reply, {:ok, map()} | {:error, atom()}, map()}
  def handle_get_status(state) do
    case state.shell_command do
      nil ->
        {:reply, {:error, :no_shell_command}, state}

      cmd ->
        status = %{
          status: cmd.status,
          command: cmd.command,
          started_at: cmd.started_at,
          exit_code: cmd.exit_code
        }

        {:reply, {:ok, status}, state}
    end
  end

  @doc """
  Handle terminate_shell call.

  Per-action Router: Terminates shell command and returns {:stop, :normal, result, state}.
  """
  @spec handle_terminate_shell(map()) ::
          {:reply, {:error, atom()}, map()} | {:stop, :normal, {:ok, map()}, map()}
  def handle_terminate_shell(state) do
    case state.shell_command do
      nil ->
        {:reply, {:error, :no_shell_command}, state}

      cmd ->
        # Close port if still alive
        if cmd.port && Port.info(cmd.port) do
          Port.close(cmd.port)
        end

        # Shutdown shell task if running
        case state.shell_task do
          {task, _monitor_ref} when is_struct(task, Task) ->
            Task.shutdown(task, :brutal_kill)

          _ ->
            :ok
        end

        {:stop, :normal, {:ok, %{terminated: true}}, state}
    end
  end

  @doc """
  Kill the OS process associated with a shell command.

  Uses SIGKILL to ensure immediate termination - cannot be caught.
  """
  @spec kill_os_process(map() | nil) :: :ok
  def kill_os_process(%{port: port}) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
        :ok

      _ ->
        :ok
    end
  end

  def kill_os_process(_), do: :ok
end
