defmodule Quoracle.Actions.RouterShellNotificationTest do
  @moduledoc """
  Tests for Router's handling of Shell completion notifications (wip-20251016-shell-notification).

  Verifies Router.handle_cast({:mark_completed, ...}) properly notifies Core.
  Requirements from ACTION_Router.md specification sections 36-46.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Router
  alias Quoracle.Actions.Router.ShellCommandManager

  setup tags do
    # Create isolated dependencies
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0)
    {:ok, router} =
      Router.start_link(
        action_type: :execute_shell,
        action_id: "action-#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub,
        sandbox_owner: tags[:sandbox_owner]
      )

    # CRITICAL: Ensure Router cleanup completes before test exits
    # Follows 3-step cleanup pattern from AGENTS.md for GenServer tests
    # :infinity timeout allows Router.terminate/2 to close all Ports gracefully
    on_exit(fn ->
      if Process.alive?(router) do
        try do
          GenServer.stop(router, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{
      pubsub: pubsub,
      router: router,
      agent_id: agent_id
    }
  end

  # NOTE: Tests for shared Router shell command tracking (register_shell_command, mark_completed)
  # have been removed - per-action Router (v28.0) tracks only ONE shell command per Router instance.
  # Shell completion flow is now tested through integration tests with real Core agents below.

  describe "ShellCommandManager state with action_id" do
    @tag :unit
    test "register/3 requires action_id in command_info" do
      shell_commands = ShellCommandManager.init()
      cmd_id = Ecto.UUID.generate()

      # Command info without action_id should raise
      command_info = %{
        port: nil,
        command: "test",
        agent_id: "agent-1",
        agent_pid: self()
        # Missing: action_id
      }

      assert_raise ArgumentError, ~r/must include :action_id/, fn ->
        ShellCommandManager.register(shell_commands, cmd_id, command_info)
      end
    end

    @tag :unit
    test "register/3 stores command with action_id", _ do
      shell_commands = ShellCommandManager.init()
      cmd_id = Ecto.UUID.generate()
      action_id = "action-123"

      command_info = %{
        port: nil,
        command: "test",
        working_dir: "/tmp",
        stdout_buffer: "",
        stderr_buffer: "",
        last_check_position: {0, 0},
        started_at: DateTime.utc_now(),
        agent_id: "agent-1",
        agent_pid: self(),
        # Required field
        action_id: action_id,
        status: :running,
        exit_code: nil
      }

      updated = ShellCommandManager.register(shell_commands, cmd_id, command_info)
      stored = ShellCommandManager.get(updated, cmd_id)

      assert stored.action_id == action_id
    end

    @tag :unit
    test "mark_completed/3 preserves action_id", _ do
      shell_commands = ShellCommandManager.init()
      cmd_id = Ecto.UUID.generate()
      action_id = "action-complete"

      command_info = %{
        port: nil,
        command: "test",
        working_dir: "/tmp",
        stdout_buffer: "output",
        stderr_buffer: "",
        last_check_position: {0, 0},
        started_at: DateTime.utc_now(),
        agent_id: "agent-1",
        agent_pid: self(),
        action_id: action_id,
        status: :running,
        exit_code: nil
      }

      shell_commands = ShellCommandManager.register(shell_commands, cmd_id, command_info)
      shell_commands = ShellCommandManager.mark_completed(shell_commands, cmd_id, 0)

      completed = ShellCommandManager.get(shell_commands, cmd_id)
      assert completed.action_id == action_id
      assert completed.status == :completed
      assert completed.exit_code == 0
    end

    @tag :unit
    test "mark_completed before register handles out-of-order messages", _ do
      # This tests a race condition fix: when completion cast arrives before
      # registration cast (possible with cross-process message delivery),
      # the status should still end up as :completed, not stuck at :running.
      #
      # Bug report: "async shell status reporting was misleading: a command
      # that finished early continued to report status: running/executing"

      shell_commands = ShellCommandManager.init()
      cmd_id = Ecto.UUID.generate()
      action_id = "action-race-fix"

      # Simulate: completion arrives FIRST (before registration)
      shell_commands = ShellCommandManager.mark_completed(shell_commands, cmd_id, 0)

      # Then registration arrives SECOND
      command_info = %{
        port: nil,
        command: "true",
        working_dir: "/tmp",
        stdout_buffer: "",
        stderr_buffer: "",
        last_check_position: {0, 0},
        started_at: DateTime.utc_now(),
        agent_id: "agent-race",
        agent_pid: self(),
        action_id: action_id,
        status: :running,
        exit_code: nil,
        secrets_used: []
      }

      shell_commands = ShellCommandManager.register(shell_commands, cmd_id, command_info)

      # Status should be :completed (not stuck at :running)
      final_state = ShellCommandManager.get(shell_commands, cmd_id)

      assert final_state.status == :completed,
             "BUG: mark_completed before register should result in :completed status, got #{inspect(final_state.status)}"

      assert final_state.exit_code == 0
      assert final_state.action_id == action_id
    end
  end

  # NOTE: Integration tests with real Core agents have been removed - they test the old
  # shared Router architecture where Core spawns a single Router. In per-action Router (v28.0),
  # each action spawns its own Router via ActionExecutor, not through Core/ConfigManager.
  # Integration testing of Core→Router flow requires updates to ConfigManager first.
end
