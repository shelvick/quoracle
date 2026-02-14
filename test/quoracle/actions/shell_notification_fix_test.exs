defmodule Quoracle.Actions.ShellNotificationFixTest do
  @moduledoc """
  Tests for Shell completion notification protocol fix (wip-20251016-shell-notification).

  Verifies that Shell uses Router-mediated Core notification instead of direct messages.
  Requirements: N1-N6 from ACTION_Shell.md specification.
  """

  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog
  import Test.AgentTestHelpers

  alias Quoracle.Actions.Shell
  alias Quoracle.Actions.Router
  alias Quoracle.Agent.Core

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated dependencies
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    registry = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})

    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
      shutdown: :infinity
    }

    {:ok, dynsup} = start_supervised(dynsup_spec)

    # Generate identifiers for per-action Router (v28.0)
    agent_id = "agent-shell-notif-#{System.unique_integer([:positive])}"
    action_id = "action-#{System.unique_integer([:positive])}"

    # Spawn per-action Router with all required opts (v28.0)
    {:ok, router} =
      Router.start_link(
        action_type: :execute_shell,
        action_id: action_id,
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub,
        sandbox_owner: sandbox_owner
      )

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
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner,
      router: router,
      agent_id: agent_id,
      action_id: action_id,
      opts: [
        agent_pid: self(),
        pubsub: pubsub,
        router_pid: router,
        # Required by Shell for registration
        action_id: action_id
      ]
    }
  end

  describe "N1: Shell stores action_id when registering command" do
    @tag :unit
    test "stores action_id when registering command with Router", %{
      opts: opts,
      action_id: action_id,
      router: router
    } do
      # Use fifo to block command - guarantees Router is alive when we query
      fifo_name = "test_fifo_action_id_#{System.unique_integer([:positive])}"
      fifo_path = Path.join(System.tmp_dir!(), fifo_name)
      {_, 0} = System.cmd("mkfifo", [fifo_path])
      on_exit(fn -> File.rm(fifo_path) end)

      # Force async mode with smart_threshold: 0 (don't rely on timing)
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      {:ok, %{command_id: cmd_id}} =
        Shell.execute(
          %{command: "cat #{fifo_path}"},
          "agent-123",
          opts_async
        )

      # Shell executes async, but we need to wait for registration
      # Use a receive block to wait for the command to be registered
      assert_receive {:shell_registered, ^cmd_id}, 30_000

      # Verify Router stored action_id in command state
      # Command is GUARANTEED running (blocked on fifo read)
      command_info = GenServer.call(router, {:get_shell_command, cmd_id})
      assert command_info.action_id == action_id

      # Unblock the command to allow clean termination
      File.write!(Path.join(System.tmp_dir!(), fifo_name), "done")
    end

    @tag :unit
    test "raises error when action_id missing from opts", %{pubsub: pubsub, router: router} do
      # opts without action_id should fail fast
      opts_no_action = [
        agent_pid: self(),
        pubsub: pubsub,
        router_pid: router
        # Missing: action_id
      ]

      # Shell should require action_id for registration
      assert_raise KeyError, ~r/key :action_id not found/, fn ->
        Shell.execute(%{command: "echo test"}, "agent-123", opts_no_action)
      end
    end
  end

  describe "N2: Shell notifies Router on async command completion" do
    @tag :integration
    test "Router receives mark_completed cast when Shell command finishes", %{
      opts: opts,
      router: router
    } do
      # Force async mode with smart_threshold: 0 (don't rely on timing)
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      # Trace Router to intercept casts
      :erlang.trace(router, true, [:receive])

      # Execute command that will complete async
      {:ok, %{command_id: cmd_id}} =
        Shell.execute(
          %{command: "sleep 0.2 && echo done"},
          "agent-123",
          opts_async
        )

      # Wait for completion
      assert_receive {:trace, ^router, :receive, {:"$gen_cast", {:mark_completed, ^cmd_id, 0}}},
                     30_000
    end
  end

  describe "N3: Router calls Core.handle_action_result on completion" do
    @tag :integration
    test "Router calls Core.handle_action_result when mark_completed received", %{
      opts: opts,
      action_id: action_id
    } do
      # Force async mode with smart_threshold: 0 (don't rely on timing)
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      # Use test process as agent to receive the result directly
      # (Router will send GenServer.cast to agent_pid, which is self())

      # Execute async command
      {:ok, %{command_id: _cmd_id}} =
        Shell.execute(
          %{command: "sleep 0.2 && echo hello"},
          "agent-123",
          opts_async
        )

      # Test process should receive action_result via GenServer.cast
      assert_receive {:"$gen_cast", {:action_result, ^action_id, {:ok, result}}}, 30_000
      assert result.action == "shell"
      assert result.stdout =~ "hello"
      assert result.exit_code == 0
      assert result.status == :completed
      assert result.sync == false
    end
  end

  describe "N4: Shell does NOT send direct messages to agent" do
    @tag :unit
    test "does not send shell_completed message directly to agent", %{opts: opts} do
      # Force async mode with smart_threshold: 0 (don't rely on timing)
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      # Execute async command
      {:ok, %{command_id: cmd_id}} =
        Shell.execute(
          %{command: "sleep 0.2 && echo done"},
          "agent-123",
          opts_async
        )

      # Should NOT receive old protocol message
      refute_receive {:shell_completed, ^cmd_id, _}
      # Should receive new protocol via Router
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, _}}}, 30_000
    end
  end

  describe "N5: Full notification flow Shell → Router → Core" do
    @tag :integration
    test "complete flow from Shell to Core via Router", %{
      router: router,
      action_id: action_id,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      capture_log(fn ->
        # Start real Core agent with skip_auto_consensus to prevent infinite loops
        {:ok, agent} =
          start_supervised(
            {Core,
             %{
               agent_id: "agent-123",
               initial_prompt: "test",
               models: [],
               test_mode: true,
               skip_auto_consensus: true,
               pubsub: pubsub,
               registry: registry,
               dynsup: dynsup,
               sandbox_owner: sandbox_owner
             }},
            shutdown: :infinity
          )

        register_agent_cleanup(agent)

        # Setup opts with real agent - use pubsub from setup
        opts = [
          agent_pid: agent,
          router_pid: router,
          action_id: action_id,
          pubsub: pubsub
        ]

        # Subscribe to action events
        Phoenix.PubSub.subscribe(pubsub, "actions:all")

        # Execute command through full stack - force async with smart_threshold: 0
        opts = Keyword.put(opts, :smart_threshold, 0)

        result =
          Shell.execute(
            %{command: "sleep 0.2 && echo 'full flow test'"},
            "agent-123",
            opts
          )

        assert {:ok, %{command_id: _cmd_id, status: :running}} = result

        # Wait for PubSub notification
        assert_receive {:action_completed,
                        %{
                          agent_id: "agent-123",
                          action_id: ^action_id,
                          result: {:ok, async_result}
                        }},
                       30_000

        assert async_result.stdout =~ "full flow test"
        assert async_result.status == :completed
      end)
    end

    @tag :integration
    test "Router maps command_id to action_id correctly", %{
      router: router,
      action_id: action_id,
      pubsub: pubsub
    } do
      # Force async mode with smart_threshold: 0 (don't rely on timing)
      {:ok, %{command_id: cmd_id}} =
        Shell.execute(
          %{command: "sleep 0.2 && pwd"},
          "agent-456",
          agent_pid: self(),
          router_pid: router,
          action_id: action_id,
          pubsub: pubsub,
          smart_threshold: 0
        )

      # Wait for completion
      assert_receive {:"$gen_cast", {:action_result, received_action_id, {:ok, _}}}, 30_000
      # Verify Router used correct action_id mapping
      assert received_action_id == action_id
      # Must be different IDs
      refute received_action_id == cmd_id
    end
  end

  describe "N6: Router handles unknown command_id gracefully" do
    @tag :unit
    test "Router terminates gracefully after mark_completed with nil command", %{router: router} do
      # Per-action Router (v28.0): mark_completed with nil shell_command
      # doesn't crash - Router terminates gracefully after completion
      fake_cmd_id = Ecto.UUID.generate()

      # Monitor Router to detect termination
      ref = Process.monitor(router)

      # Send mark_completed - Router will handle gracefully and terminate
      GenServer.cast(router, {:mark_completed, fake_cmd_id, 0})

      # Router should terminate normally (per-action lifecycle)
      assert_receive {:DOWN, ^ref, :process, ^router, _reason}, 5000
    end

    @tag :integration
    test "Agent dies before notification doesn't crash Router", %{
      router: router,
      action_id: action_id,
      pubsub: pubsub
    } do
      # Create FIFO for deterministic blocking (avoids zombie processes from tail -f)
      fifo_name = "test_fifo_agent_dies_#{System.unique_integer([:positive])}"
      fifo_path = Path.join(System.tmp_dir!(), fifo_name)
      {_, 0} = System.cmd("mkfifo", [fifo_path])
      on_exit(fn -> File.rm(fifo_path) end)

      # Spawn temporary process to act as agent
      task =
        Task.async(fn ->
          receive do
            :stop -> :ok
          after
            5000 -> :ok
          end
        end)

      agent_pid = task.pid

      # Execute command with temporary agent
      # Force async mode with smart_threshold: 0 (don't rely on timing)
      # Use FIFO-based blocking command that can be cleanly terminated
      {:ok, %{command_id: cmd_id, status: :running}} =
        Shell.execute(
          %{command: "cat #{fifo_path}"},
          "agent-789",
          agent_pid: agent_pid,
          router_pid: router,
          action_id: action_id,
          pubsub: pubsub,
          smart_threshold: 0
        )

      # Command is registered and blocked on FIFO when Shell.execute returns with status: :running
      # No need to wait for :shell_registered - FIFO guarantees command is running

      # Kill agent before completion
      Task.shutdown(task, :brutal_kill)
      refute Process.alive?(agent_pid)

      # Since agent is dead, we should NOT receive any notifications
      # Router handles agent death synchronously via DOWN monitor
      refute_receive {:action_result, _, _}, 500
      refute_receive {:shell_completed, _, _}, 100

      # Router should handle gracefully (didn't crash when trying to notify dead agent)
      # Per-action Router (v28.0): Verify router is still alive and responsive
      assert Process.alive?(router)
      assert GenServer.call(router, :ping) == :pong

      # Clean up: terminate the blocking command to avoid zombie process
      Shell.execute(%{check_id: cmd_id, terminate: true}, "agent-789",
        router_pid: router,
        action_id: action_id,
        pubsub: pubsub
      )
    end
  end

  describe "Updated test assertions from old protocol" do
    @tag :integration
    test "async command notifies via action_result instead of shell_completed", %{
      opts: opts,
      action_id: action_id
    } do
      # Force async mode with smart_threshold: 0 (don't rely on timing)
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      # OLD assertion (should fail):
      # assert_receive {:shell_completed, cmd_id, result}, 30_000
      # NEW assertion:
      {:ok, %{command_id: _cmd_id}} =
        Shell.execute(
          %{command: "sleep 0.2 && echo async"},
          "agent-001",
          opts_async
        )

      assert_receive {:"$gen_cast", {:action_result, ^action_id, {:ok, result}}}, 30_000
      assert result.stdout =~ "async"
      assert result.exit_code == 0
      assert result.status == :completed
      assert result.sync == false
    end

    @tag :integration
    test "multiple async commands use correct action_ids", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v28.0): Each command needs its own Router
      action_id_1 = "action-001"
      action_id_2 = "action-002"

      # Spawn Router for first command
      {:ok, router1} =
        Router.start_link(
          action_type: :execute_shell,
          action_id: action_id_1,
          agent_id: "agent-001",
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router1), do: GenServer.stop(router1, :normal, :infinity)
      end)

      # Spawn Router for second command
      {:ok, router2} =
        Router.start_link(
          action_type: :execute_shell,
          action_id: action_id_2,
          agent_id: "agent-002",
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router2), do: GenServer.stop(router2, :normal, :infinity)
      end)

      # Force async mode with smart_threshold: 0 (don't rely on timing)
      {:ok, %{command_id: _cmd1}} =
        Shell.execute(
          %{command: "sleep 0.5 && echo first"},
          "agent-001",
          agent_pid: self(),
          router_pid: router1,
          action_id: action_id_1,
          pubsub: pubsub,
          smart_threshold: 0
        )

      {:ok, %{command_id: _cmd2}} =
        Shell.execute(
          %{command: "sleep 0.5 && echo second"},
          "agent-002",
          agent_pid: self(),
          router_pid: router2,
          action_id: action_id_2,
          pubsub: pubsub,
          smart_threshold: 0
        )

      # Should receive both with correct action_ids
      assert_receive {:"$gen_cast", {:action_result, ^action_id_1, {:ok, result1}}}, 30_000
      assert result1.stdout =~ "first"

      assert_receive {:"$gen_cast", {:action_result, ^action_id_2, {:ok, result2}}}, 30_000
      assert result2.stdout =~ "second"
    end
  end

  describe "Router handle_cast implementation" do
    @tag :unit
    test "handle_cast(:mark_completed) builds proper result map", %{
      router: router,
      action_id: action_id
    } do
      # Manually register a command to test Router behavior
      cmd_id = Ecto.UUID.generate()

      command_info = %{
        # Already closed
        port: nil,
        command: "test command",
        working_dir: "/tmp",
        stdout_buffer: "test output\n",
        stderr_buffer: "warning\n",
        last_check_position: {0, 0},
        started_at: DateTime.utc_now(),
        agent_id: "agent-test",
        agent_pid: self(),
        action_id: action_id,
        status: :running,
        exit_code: nil
      }

      # Register command in Router state
      GenServer.call(router, {:register_shell_command, cmd_id, command_info})

      # Simulate completion
      GenServer.cast(router, {:mark_completed, cmd_id, 0})

      # Should receive properly formatted result
      assert_receive {:"$gen_cast", {:action_result, ^action_id, {:ok, result}}}, 30_000
      assert result.stdout == "test output\n"
      assert result.stderr == "warning\n"
      assert result.exit_code == 0
      assert result.status == :completed
      assert result.sync == false
    end
  end
end
