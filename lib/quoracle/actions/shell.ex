defmodule Quoracle.Actions.Shell do
  @moduledoc """
  Shell command execution action with smart mode (sync <100ms, async >100ms).
  Supports output capture, working directory, and proactive completion messages.
  """

  require Logger

  alias Quoracle.Actions.Shell.{StatusCheck, Termination}
  alias Quoracle.Utils.ResponseTruncator

  @smart_mode_threshold_ms 100

  @doc """
  Execute a shell command with smart mode detection.

  ## Parameters
  - params: Map with :command (required), :working_dir (optional)
  - agent_id: String identifier for the agent
  - opts: Keyword list with :agent_pid (required), :pubsub, :router_pid

  ## Returns
  - Sync (<100ms): `{:ok, %{sync: true, stdout, stderr, exit_code, execution_time_ms}}`
  - Async (>100ms): `{:ok, %{command_id, async: true, status: :running, command, started_at}}`
  - Error: `{:error, :invalid_working_dir}`

  ## Raises
  - ArgumentError if agent_pid not in opts
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  # XOR validation: reject if both command and check_id are present
  def execute(%{command: _, check_id: _}, _agent_id, _opts) do
    {:error, :xor_violation}
  end

  def execute(%{command: command} = params, agent_id, opts) do
    # Validate required opts
    agent_pid =
      case Keyword.fetch(opts, :agent_pid) do
        {:ok, pid} -> pid
        :error -> raise ArgumentError, "agent_pid is required in opts"
      end

    pubsub = Keyword.get(opts, :pubsub)
    router_pid = Keyword.get(opts, :router_pid)

    # Validate working directory (default to /tmp to force intentional choice when it matters)
    working_dir = Map.get(params, :working_dir, "/tmp")

    case validate_working_dir(working_dir) do
      :ok ->
        execute_command(command, working_dir, agent_id, agent_pid, pubsub, router_pid, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(%{check_id: command_id} = params, _agent_id, opts) do
    router_pid = Keyword.fetch!(opts, :router_pid)
    terminate = Map.get(params, :terminate, false)

    if terminate do
      Termination.execute(command_id, router_pid, opts)
    else
      # Per-action Router (v28.0): Check if key EXISTS (not just truthy) to avoid deadlock.
      # Router passes shell_command_state: nil when state.shell_command is nil.
      # If we check truthiness, nil causes StatusCheck to callback to Router = DEADLOCK.
      if Keyword.has_key?(opts, :shell_command_state) do
        # Called from Router - use passed state directly, even if nil
        shell_command_state = Keyword.get(opts, :shell_command_state)
        StatusCheck.execute_with_state(command_id, router_pid, shell_command_state)
      else
        # Called externally - query Router for state
        StatusCheck.execute(command_id, router_pid)
      end
    end
  end

  # Validate working directory exists
  defp validate_working_dir(nil), do: :ok

  defp validate_working_dir(path) do
    if File.dir?(path) do
      :ok
    else
      {:error, :invalid_working_dir}
    end
  end

  # Execute command with smart mode detection
  # CRITICAL: Opens port ONCE, never kills and restarts (prevents duplicate execution)
  defp execute_command(command, working_dir, agent_id, agent_pid, pubsub, router_pid, opts) do
    command_id = generate_command_id()
    started_at = DateTime.utc_now()

    # Extract action_id from opts (required for Router-mediated Core notification)
    action_id = Keyword.fetch!(opts, :action_id)

    # Extract secrets_used for async completion scrubbing (empty list if not present)
    secrets_used = Keyword.get(opts, :secrets_used, [])

    # Shell's sync/async threshold:
    # - When called through Router (router_pid present): use smart_threshold from opts
    #   because Router/Execution layer adds overhead
    # - When called directly (tests): use fixed 100ms for fast response
    threshold =
      if router_pid do
        Keyword.get(opts, :smart_threshold, @smart_mode_threshold_ms)
      else
        @smart_mode_threshold_ms
      end

    # Register command in Router FIRST (before opening port)
    # This ensures async infrastructure is ready regardless of execution time
    # Per-action Router (v28.0): Use cast (async) - Shell is now called directly from
    # handle_call, so call would deadlock. Cast is processed after handle_call returns,
    # before check_id arrives.
    if router_pid && Process.alive?(router_pid) do
      GenServer.cast(router_pid, {
        :register_shell_command,
        command_id,
        %{
          port: nil,
          command: command,
          working_dir: working_dir,
          stdout_buffer: "",
          stderr_buffer: "",
          last_check_position: {0, 0},
          started_at: started_at,
          agent_id: agent_id,
          agent_pid: agent_pid,
          action_id: action_id,
          status: :running,
          exit_code: nil,
          secrets_used: secrets_used
        }
      })
    end

    # Open port ONCE with async-capable infrastructure
    # Port is opened inside task so port messages go to task process
    task =
      Task.async(fn ->
        port_opts = build_port_opts(command, working_dir)
        port = Port.open({:spawn_executable, "/bin/bash"}, port_opts)

        # Update Router with actual port reference
        update_router_with_port_and_task(router_pid, command_id, port, self())

        # Use async-capable collection (works for both sync and async paths)
        collect_and_buffer_output(
          port,
          command_id,
          router_pid,
          agent_id,
          agent_pid,
          pubsub,
          command
        )
      end)

    # Register task in Router for cleanup tracking
    if router_pid && Process.alive?(router_pid) do
      GenServer.cast(router_pid, {:register_shell_task, command_id, task})
    end

    # Wait for fast completion - task continues running either way
    case Task.yield(task, threshold) do
      {:ok, result} ->
        # Fast path - completed within threshold
        # Command already marked completed by collect_and_buffer_output
        # Return sync result for fast commands
        {:ok, Map.merge(result, %{action: "shell"})}

      nil ->
        # Slow path - command still running
        # Task continues with same port - NO killing, NO re-spawning
        broadcast_event(pubsub, :command_started, %{
          command_id: command_id,
          agent_id: agent_id,
          command: command
        })

        {:ok,
         %{
           action: "shell",
           command_id: command_id,
           status: :running,
           sync: false
         }}
    end
  end

  # Build port options for command execution
  # NOTE: We redirect stdin from /dev/null because :use_stdio connects both
  # stdin and stdout, but we only need stdout for output capture. Without this,
  # commands that check stdin (like Claude Code) will hang waiting for input
  # on the open pipe that Erlang never closes.
  defp build_port_opts(command, working_dir) do
    [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      {:cd, working_dir},
      {:env, build_env()},
      {:args, ["-c", "exec 0</dev/null; #{command}"]}
    ]
  end

  # Build minimal environment for command execution
  defp build_env do
    [
      {~c"PATH", String.to_charlist(System.get_env("PATH", "/usr/bin:/bin"))},
      {~c"HOME", String.to_charlist(System.get_env("HOME", "/tmp"))},
      {~c"USER", String.to_charlist(System.get_env("USER", "user"))}
    ]
  end

  # Update Router state with opened port and task PID
  # Uses cast to avoid blocking - port info is for status checks, not critical path
  defp update_router_with_port_and_task(router_pid, command_id, port, task_pid)
       when is_pid(router_pid) and is_port(port) do
    if Process.alive?(router_pid) do
      GenServer.cast(router_pid, {:update_shell_port, command_id, port, task_pid})
    end
  end

  defp update_router_with_port_and_task(_router_pid, _command_id, _port, _task_pid), do: :ok

  # Collect and buffer output (used for both sync and async paths)
  # Accumulates stdout locally AND buffers in Router, returns result map
  defp collect_and_buffer_output(
         port,
         command_id,
         router_pid,
         agent_id,
         agent_pid,
         pubsub,
         _command,
         stdout_acc \\ ""
       ) do
    receive do
      {^port, {:data, data}} ->
        # Append to buffer in Router state
        if router_pid do
          GenServer.cast(router_pid, {:append_output, command_id, :stdout, data})
        end

        # Broadcast output received for test synchronization (replaces Process.sleep)
        broadcast_event(pubsub, :output_received, %{
          command_id: command_id,
          bytes: byte_size(data)
        })

        # Accumulate locally for return value
        collect_and_buffer_output(
          port,
          command_id,
          router_pid,
          agent_id,
          agent_pid,
          pubsub,
          nil,
          stdout_acc <> data
        )

      {^port, {:exit_status, code}} ->
        # Command completed - mark in Router state (async, non-blocking)
        # Router will notify Core via handle_action_result
        if router_pid && Process.alive?(router_pid) do
          GenServer.cast(router_pid, {:mark_completed, command_id, code})
        end

        # Broadcast completion event (agent_id passed directly, no blocking call needed)
        if router_pid do
          broadcast_event(pubsub, :command_completed, %{
            command_id: command_id,
            agent_id: agent_id,
            exit_code: code
          })
        end

        # CRITICAL: Explicitly close Port before Task exits
        # Port auto-close is asynchronous and races with erl_child_setup cleanup
        # Explicit close prevents EPIPE (error 32) during test teardown
        #
        # NOTE: Fast-exiting commands (<100ms) may trigger non-deterministic
        # "erl_child_setup: failed with error 32 on line 282" messages (~9% of runs).
        # This is a known Erlang VM race condition where child exits before
        # erl_child_setup's acknowledgment protocol completes (commit 0d17cd6, April 2022).
        # Tests still pass - this is cosmetic log noise only.
        # References: Elixir #11988, erlang/otp erl_child_setup.c:282
        catch_port_close(port)

        # Return result map (used by sync path)
        # Truncate stdout to prevent OOM from massive output
        %{stdout: ResponseTruncator.truncate_if_large(stdout_acc), stderr: "", exit_code: code}
    end
  end

  # Safely close port (handles already-closed ports)
  defp catch_port_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # Generate UUID v4 for command ID
  defp generate_command_id do
    <<a1::48, _::4, a2::12, _::2, a3::62>> = :crypto.strong_rand_bytes(16)

    hex_string =
      <<a1::48, 4::4, a2::12, 2::2, a3::62>>
      |> Base.encode16(case: :lower)

    # Format as UUID: 8-4-4-4-12
    String.slice(hex_string, 0, 8) <>
      "-" <>
      String.slice(hex_string, 8, 4) <>
      "-" <>
      String.slice(hex_string, 12, 4) <>
      "-" <>
      String.slice(hex_string, 16, 4) <>
      "-" <>
      String.slice(hex_string, 20, 12)
  end

  # Broadcast PubSub event
  defp broadcast_event(nil, _event, _data), do: :ok

  defp broadcast_event(pubsub, event, data) do
    try do
      Phoenix.PubSub.broadcast(pubsub, "shell:events", {event, data})
    rescue
      # PubSub Registry terminated (test cleanup race)
      ArgumentError -> :ok
    end
  end
end
