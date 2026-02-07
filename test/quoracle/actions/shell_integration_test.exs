defmodule Quoracle.Actions.ShellIntegrationTest do
  @moduledoc """
  Integration tests for ACTION_Shell through the Router.
  These tests verify the complete routing path: Router → ActionMapper → Shell.

  Critical: These tests verify that execute_shell is properly registered
  in ActionMapper and can be invoked through the normal Router.execute flow.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Actions.Router

  setup do
    # Create isolated PubSub instance per test
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    # Subscribe to shell events for test synchronization
    # (Same pattern as shell_packet2_test.exs)
    Phoenix.PubSub.subscribe(pubsub, "shell:events")

    # Generate identifiers for per-action Router (v28.0)
    agent_id = "agent-shell-integ-#{System.unique_integer([:positive])}"
    action_id = "action-#{System.unique_integer([:positive])}"

    # Spawn per-action Router with all required opts (v28.0)
    {:ok, router} =
      Router.start_link(
        action_type: :execute_shell,
        action_id: action_id,
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub,
        sandbox_owner: nil
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
      router: router,
      pubsub: pubsub,
      agent_id: agent_id,
      action_id: action_id,
      opts: [
        agent_pid: self(),
        pubsub: pubsub,
        router_pid: router,
        capability_groups: [:local_execution]
      ]
    }
  end

  describe "Router → ActionMapper → Shell integration" do
    test "[INTEGRATION] execute_shell action is registered in ActionMapper", %{
      router: router,
      opts: opts
    } do
      # This test verifies that execute_shell is properly registered
      # in the ActionMapper so it can be invoked through Router.execute/5

      # Call through the normal Router.execute flow (not Shell.execute directly)
      # Use high smart_threshold to guarantee sync execution
      result =
        Router.execute(
          router,
          :execute_shell,
          %{command: "echo integration test"},
          "agent-integration-1",
          Keyword.merge(opts, agent_pid: self(), smart_threshold: 1000)
        )

      assert {:ok, %{stdout: stdout}} = result
      assert stdout == "integration test\n"
    end

    test "[INTEGRATION] execute_shell with check_id works through Router", %{
      pubsub: pubsub,
      opts: opts
    } do
      # Per-action Router (v28.0): check_id queries the SAME Router that started
      # the command, since command state is held by that Router instance.

      agent_id = "agent-integration-2"
      action_id = "action-cmd-#{System.unique_integer([:positive])}"

      # Spawn per-action Router for the command (v28.0)
      {:ok, cmd_router} =
        Router.start_link(
          action_type: :execute_shell,
          action_id: action_id,
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: nil
        )

      on_exit(fn ->
        if Process.alive?(cmd_router) do
          try do
            GenServer.stop(cmd_router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Use a fifo to block deterministically - NO SLEEP timing dependency
      fifo_name = "test_fifo_check_#{System.unique_integer([:positive])}"
      fifo_path = Path.join(System.tmp_dir!(), fifo_name)
      {_, 0} = System.cmd("mkfifo", [fifo_path])
      on_exit(fn -> File.rm(fifo_path) end)

      # Start a command that blocks on fifo read (guaranteed to be running when we check)
      # Force Shell async with smart_threshold: 0
      # DON'T await - we need to check status WHILE running
      exec_result =
        Router.execute(
          cmd_router,
          :execute_shell,
          %{command: "cat #{fifo_path} && echo done"},
          agent_id,
          Keyword.merge(opts, agent_pid: self(), smart_threshold: 0)
        )

      # Extract command_id from the immediate ack (NOT awaiting full result)
      cmd_id =
        case exec_result do
          {:async, _ref, %{command_id: id}} ->
            id

          {:async, ref, %{action_id: _}} ->
            # Smart-mode: await to get command_id
            {:ok, %{command_id: id}} = Router.await_result(cmd_router, ref)
            id

          {:ok, %{command_id: id}} ->
            id
        end

      # Check status through the SAME Router (check_id requires command state)
      # Command is GUARANTEED running (blocked on fifo read)
      status_result =
        Router.execute(
          cmd_router,
          :execute_shell,
          %{check_id: cmd_id},
          agent_id,
          Keyword.merge(opts, agent_pid: self(), router_pid: cmd_router)
        )

      status =
        case status_result do
          {:ok, s} ->
            s

          {:async, ref} ->
            {:ok, s} = Router.await_result(cmd_router, ref)
            s

          {:async, ref, _ack} ->
            {:ok, s} = Router.await_result(cmd_router, ref)
            s
        end

      assert %{status: :running} = status

      # Unblock the command (fifo_path is in System.tmp_dir!(), defined at line 129)
      File.write!(Path.join(System.tmp_dir!(), fifo_name), "unblock")

      # Wait for completion via new Router protocol
      # The completion result contains the final status
      # Match on 'command' field to distinguish from status check results
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, %{command: _} = result}}}, 30_000
      assert result.status == :completed
    end

    test "[INTEGRATION] execute_shell with invalid command returns error through Router", %{
      router: router,
      opts: opts
    } do
      # Test error handling through the full routing path
      # Use explicit timeout to ensure synchronous execution (avoid smart_threshold race)
      result =
        Router.execute(
          router,
          :execute_shell,
          %{command: "test", working_dir: "/nonexistent/path"},
          "agent-integration-3",
          Keyword.merge(opts, agent_pid: self(), timeout: 5000)
        )

      assert {:error, :invalid_working_dir} = result
    end
  end

  describe "Full routing validation" do
    test "[SYSTEM] complete execute_shell workflow through Router", %{pubsub: pubsub, opts: opts} do
      # Per-action Router (v28.0): This test spawns its own Router since each action
      # requires its own Router instance that holds command state.

      # This comprehensive test verifies the entire flow:
      # 1. Router.execute routes to ActionMapper
      # 2. ActionMapper maps :execute_shell to Shell module
      # 3. Shell.execute is called with proper parameters
      # 4. Results flow back through the entire chain

      agent_id = "agent-system-test"
      action_id = "action-system-#{System.unique_integer([:positive])}"

      # Spawn per-action Router
      {:ok, cmd_router} =
        Router.start_link(
          action_type: :execute_shell,
          action_id: action_id,
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: nil
        )

      on_exit(fn ->
        if Process.alive?(cmd_router) do
          try do
            GenServer.stop(cmd_router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Use a fifo to block deterministically - NO SLEEP timing dependency
      # Pre-create fifo synchronously so command blocks immediately on read
      fifo_name = "test_fifo_#{System.unique_integer([:positive])}"
      fifo_path = Path.join(System.tmp_dir!(), fifo_name)
      {_, 0} = System.cmd("mkfifo", [fifo_path])
      on_exit(fn -> File.rm!(Path.join(System.tmp_dir!(), fifo_name)) end)

      # Execute command - force Shell async with smart_threshold: 0
      # Command outputs "line 1", blocks on fifo read, then outputs "line 2" when unblocked
      # DON'T await - we need to check status WHILE running
      exec_result =
        Router.execute(
          cmd_router,
          :execute_shell,
          %{command: "echo 'line 1' && cat #{fifo_path} && echo 'line 2'"},
          agent_id,
          Keyword.merge(opts, agent_pid: self(), smart_threshold: 0)
        )

      # Extract command_id from the immediate ack (NOT awaiting full result)
      cmd_id =
        case exec_result do
          {:async, _ref, %{command_id: id}} ->
            id

          {:async, ref, %{action_id: _}} ->
            # Smart-mode: await to get command_id (will block since command blocked on fifo)
            # This shouldn't happen with smart_threshold: 0, but handle it
            {:ok, %{command_id: id}} = Router.await_result(cmd_router, ref)
            id

          {:ok, %{command_id: id, status: :running}} ->
            id
        end

      # CRITICAL: Wait for shell command registration to complete before calling check_id.
      # Without this, StatusCheck.execute calls back to Router (in handle_call) causing deadlock.
      # Router sends {:shell_registered, command_id} after processing the registration cast.
      assert_receive {:shell_registered, ^cmd_id}, 30_000

      # Check status - command is GUARANTEED to be running (blocked on fifo read)
      # Use SAME Router that has the command state
      status1_result =
        Router.execute(
          cmd_router,
          :execute_shell,
          %{check_id: cmd_id},
          agent_id,
          Keyword.merge(opts, agent_pid: self(), router_pid: cmd_router)
        )

      status1 =
        case status1_result do
          {:ok, s} ->
            s

          {:async, ref} ->
            {:ok, s} = Router.await_result(cmd_router, ref)
            s

          {:async, ref, _ack} ->
            {:ok, s} = Router.await_result(cmd_router, ref)
            s
        end

      assert status1.status == :running

      # Unblock the command by writing to the fifo (inline System.tmp_dir!() for git hook)
      File.write!(Path.join(System.tmp_dir!(), fifo_name), "unblock")

      # Wait for completion via new Router protocol
      # The completion result has the full stdout/stderr
      # Note: We may receive status check results first, so wait for the actual completion
      completion_result =
        receive do
          {:"$gen_cast", {:action_result, _, {:ok, %{stdout: _} = result}}} ->
            result
        after
          2000 ->
            flunk("Did not receive completion message within 2 seconds")
        end

      assert completion_result.stdout =~ "line 1"
      assert completion_result.stdout =~ "line 2"

      # Terminate a running command through Router
      # Per-action Router (v28.0): Spawn new Router for second command
      agent_id2 = "agent-system-test-2"
      action_id2 = "action-term-#{System.unique_integer([:positive])}"

      # Use FIFO for deterministic blocking instead of sleep 60
      term_fifo_name = "test_fifo_term_#{System.unique_integer([:positive])}"
      term_fifo_path = Path.join(System.tmp_dir!(), term_fifo_name)
      {_, 0} = System.cmd("mkfifo", [term_fifo_path])
      on_exit(fn -> File.rm(term_fifo_path) end)

      {:ok, term_router} =
        Router.start_link(
          action_type: :execute_shell,
          action_id: action_id2,
          agent_id: agent_id2,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: nil
        )

      on_exit(fn ->
        # Stop router first - command may already be terminated
        if Process.alive?(term_router) do
          try do
            GenServer.stop(term_router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end

        # FIFO cleanup handled by separate on_exit (line 328)
      end)

      # Build fresh opts for term_router (don't inherit setup's router_pid)
      term_opts = [
        agent_pid: self(),
        pubsub: pubsub,
        router_pid: term_router,
        capability_groups: [:local_execution]
      ]

      # Force async with smart_threshold: 0 to get command_id immediately
      cmd_result2 =
        Router.execute(
          term_router,
          :execute_shell,
          %{command: "cat #{term_fifo_path}"},
          agent_id2,
          Keyword.put(term_opts, :smart_threshold, 0)
        )

      # Extract command_id from immediate ack (same pattern as test 62)
      cmd_id2 =
        case cmd_result2 do
          {:async, _ref, %{command_id: id}} ->
            id

          {:async, ref, %{action_id: _}} ->
            # Smart-mode: await to get command_id
            {:ok, %{command_id: id}} = Router.await_result(term_router, ref)
            id

          {:ok, %{command_id: id}} ->
            id
        end

      # CRITICAL: Wait for shell command registration to complete before calling terminate.
      # Without this, Termination.execute calls back to Router (in handle_call) causing deadlock.
      # Router sends {:shell_registered, command_id} after processing the registration cast.
      assert_receive {:shell_registered, ^cmd_id2}, 30_000

      # Extra sync: ensure Router state is fully settled before terminate call.
      # :sys.get_state forces processing of any pending system messages.
      # Ping verifies Router is responsive (full round-trip).
      _ = :sys.get_state(term_router)
      :pong = GenServer.call(term_router, :ping, 5000)

      # Termination - command is registered and running (blocked on FIFO)
      term_result_raw =
        Router.execute(
          term_router,
          :execute_shell,
          %{check_id: cmd_id2, terminate: true},
          agent_id2,
          term_opts
        )

      term_result =
        case term_result_raw do
          {:ok, t} ->
            t

          {:async, ref} ->
            {:ok, t} = Router.await_result(term_router, ref)
            t

          {:async, ref, _ack} ->
            {:ok, t} = Router.await_result(term_router, ref)
            t

          {:error, reason} ->
            raise "Termination failed: #{inspect(reason)}"
        end

      assert term_result.terminated == true
    end
  end
end
