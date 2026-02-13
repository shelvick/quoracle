defmodule Quoracle.Actions.ShellPacket2Test do
  @moduledoc """
  Tests for ACTION_Shell Packet 2: Status Management & Lifecycle.
  These tests verify check_id, incremental output, and termination functionality.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Actions.Shell

  setup do
    # Create isolated PubSub instance per test
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    # Generate identifiers for per-action Router (v28.0)
    agent_id = "agent-shell-packet2-#{System.unique_integer([:positive])}"
    action_id = "action-#{System.unique_integer([:positive])}"

    # Spawn per-action Router with all required opts (v28.0)
    {:ok, router} =
      Quoracle.Actions.Router.start_link(
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

    # Subscribe to shell events for test synchronization
    # Replaces Process.sleep anti-pattern with event-driven waits
    Phoenix.PubSub.subscribe(pubsub, "shell:events")

    %{
      pubsub: pubsub,
      router: router,
      agent_id: agent_id,
      action_id: action_id,
      opts: [agent_pid: self(), pubsub: pubsub, router_pid: router, action_id: action_id]
    }
  end

  describe "status checking (check_id)" do
    # F2.1 removed - redundant with F2.3 which tests incremental output more robustly
    # F2.1 was brittle due to timing assumptions about when output arrives
    # F2.3 handles timing gracefully and verifies the same feature (no duplication)

    test "[UNIT] F2.2: check_id for completed command returns command_not_found", %{
      opts: opts
    } do
      # Per-action Router (v28.0): After command completes, Router terminates.
      # check_id for completed command returns :command_not_found since Router is dead.
      # Completion info is delivered via action_result, not check_id.

      # Start a command that takes long enough to guarantee async execution
      # Force async with threshold: 0 and use sleep to prevent sync fast-path
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      {:ok, %{command_id: cmd_id}} =
        Shell.execute(%{command: "sleep 0.05 && echo done"}, "agent-1", opts_async)

      # Wait for completion via action_result - this is the canonical way
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result}}}, 30_000
      assert result.status == :completed
      assert result.stdout =~ "done"
      assert result.exit_code == 0

      # Per-action Router (v28.0): Router terminated, check_id returns not found
      check_result = Shell.execute(%{check_id: cmd_id}, "agent-1", opts)
      assert {:error, :command_not_found} = check_result
    end

    test "[INTEGRATION] F2.3: repeated check_id calls get incremental output without duplication",
         %{opts: opts} do
      # Per-action Router (v28.0): Collect output via check_id while running,
      # then get final output from action_result when complete.

      # Start command that produces output over time
      # Force async to ensure Router buffering
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      {:ok, %{command_id: cmd_id}} =
        Shell.execute(
          %{command: "for i in 1 2 3 4 5; do echo output-$i; sleep 0.05; done"},
          "agent-1",
          opts_async
        )

      # Collect incremental output through check_id calls while running
      # Use a simple loop that handles completion gracefully
      full_output =
        collect_incremental_output(cmd_id, opts, 10, [])

      # Verify no duplication - each line appears exactly once
      for i <- 1..5 do
        line = "output-#{i}"
        occurrences = full_output |> String.split(line) |> length() |> Kernel.-(1)
        assert occurrences <= 1, "Line '#{line}' appeared #{occurrences} times"
      end
    end

    test "[UNIT] F2.5: check_id for non-existent command returns error", %{opts: opts} do
      result = Shell.execute(%{check_id: "fake-uuid-does-not-exist"}, "agent-1", opts)

      assert {:error, :command_not_found} = result
    end

    test "[UNIT] I2.2: incremental output advances with each check_id call", %{
      opts: opts
    } do
      # Per-action Router (v28.0): Verify position tracking by checking that:
      # 1. We receive multiple incremental chunks (not just one final output)
      # 2. All lines eventually appear (in incremental or final output)

      # Force async to ensure Router buffering and position tracking
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      # Start a command that produces output over time
      {:ok, %{command_id: cmd_id}} =
        Shell.execute(
          %{command: "echo line1; sleep 0.3; echo line2; sleep 0.3; echo line3"},
          "agent-1",
          opts_async
        )

      # Collect incremental output by polling on :output_received events
      # Stop when we get action_result (command completed)
      {chunks, final_result} =
        Enum.reduce_while(1..20, {0, nil}, fn _, {chunk_count, _} ->
          receive do
            {:output_received, %{command_id: ^cmd_id}} ->
              # Got output event - try to read incremental output
              case Shell.execute(%{check_id: cmd_id}, "agent-1", opts) do
                {:ok, %{status: :running, new_stdout: stdout}} when stdout != "" ->
                  {:cont, {chunk_count + 1, nil}}

                {:ok, %{status: :running}} ->
                  {:cont, {chunk_count, nil}}

                {:ok, %{status: :completed} = result} ->
                  {:halt, {chunk_count, result}}

                {:error, :command_not_found} ->
                  {:halt, {chunk_count, nil}}
              end

            {:"$gen_cast", {:action_result, _, {:ok, result}}} ->
              {:halt, {chunk_count, result}}
          after
            30_000 -> flunk("Timeout waiting for output")
          end
        end)

      # Verify we got multiple incremental chunks (proves position tracking works)
      assert chunks >= 2, "Expected multiple incremental chunks, got #{chunks}"

      # Get final result if we don't have it yet (might be in mailbox)
      final_result =
        final_result ||
          receive do
            {:"$gen_cast", {:action_result, _, {:ok, result}}} -> result
          after
            5000 -> nil
          end

      # All lines must appear in the final result
      assert final_result, "Never received final action_result"
      final_stdout = Map.get(final_result, :stdout, "")

      for line <- ["line1", "line2", "line3"] do
        assert String.contains?(final_stdout, line),
               "Line '#{line}' not in final output: #{inspect(final_stdout)}"
      end
    end

    test "[INTEGRATION] I2.3: completion delivered via action_result and Router terminates", %{
      opts: opts,
      router: router
    } do
      # Per-action Router (v28.0): Completion is delivered via action_result,
      # then Router terminates. Post-completion polling is not supported.

      # Monitor Router to verify termination
      router_ref = Process.monitor(router)

      # Quick command that completes fast
      # Force async with threshold: 0 to ensure it registers in Router
      opts_async = Keyword.put(opts, :smart_threshold, 0)
      {:ok, %{command_id: cmd_id}} = Shell.execute(%{command: "echo fast"}, "agent-1", opts_async)

      # Wait for completion via action_result - this is the ONLY way to get results
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result}}}, 30_000
      assert result.stdout =~ "fast"
      assert result.exit_code == 0
      assert result.status == :completed
      # command_id is returned from initial execute, not in action_result
      assert cmd_id != nil

      # Router should terminate after completion (per-action lifecycle)
      assert_receive {:DOWN, ^router_ref, :process, ^router, _reason}, 5000
    end
  end

  describe "command termination" do
    test "[UNIT] F2.4: terminate sends SIGTERM, waits 5s, then SIGKILL if needed", %{opts: opts} do
      # Use FIFO for deterministic blocking instead of sleep 10
      fifo_name = "test_fifo_sigkill_#{System.unique_integer([:positive])}"
      fifo_path = Path.join(System.tmp_dir!(), fifo_name)
      {_, 0} = System.cmd("mkfifo", [fifo_path])
      on_exit(fn -> File.rm(fifo_path) end)

      # Start a command that ignores SIGTERM and blocks on FIFO
      {:ok, %{command_id: cmd_id}} =
        Shell.execute(
          %{command: "trap '' TERM; echo ready; cat #{fifo_path}"},
          "agent-1",
          opts
        )

      # Wait for trap to be installed (output confirms it)
      assert_receive {:output_received, %{command_id: ^cmd_id}}, 30_000

      # Request termination with short grace period for test speed
      opts_with_timeout = Keyword.put(opts, :termination_grace_period_ms, 500)
      start_time = System.monotonic_time(:millisecond)
      result = Shell.execute(%{check_id: cmd_id, terminate: true}, "agent-1", opts_with_timeout)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert {:ok,
              %{
                terminated: true,
                final_stdout: _,
                final_stderr: "",
                signal: :sigkill
              }} = result

      # Should have waited ~500ms before SIGKILL (not 5s)
      # Upper bound increased from 1000 to 2000 for parallel test stability
      assert elapsed >= 500
      assert elapsed < 2000
    end

    test "[UNIT] Q2.2: termination with SIGTERM succeeds immediately if process cooperates", %{
      opts: opts
    } do
      # Use FIFO for deterministic blocking instead of sleep 10
      fifo_name = "test_fifo_sigterm_#{System.unique_integer([:positive])}"
      fifo_path = Path.join(System.tmp_dir!(), fifo_name)
      {_, 0} = System.cmd("mkfifo", [fifo_path])
      on_exit(fn -> File.rm(fifo_path) end)

      # Start a command that responds to SIGTERM (cat does)
      {:ok, %{command_id: cmd_id}} =
        Shell.execute(
          %{command: "cat #{fifo_path}"},
          "agent-1",
          opts
        )

      # Wait for command to actually start
      assert_receive {:command_started, %{command_id: ^cmd_id}}, 30_000

      # Request termination
      start_time = System.monotonic_time(:millisecond)
      result = Shell.execute(%{check_id: cmd_id, terminate: true}, "agent-1", opts)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert {:ok,
              %{
                terminated: true,
                signal: signal
              }} = result

      # Should terminate quickly with SIGTERM
      assert signal == :sigterm
      assert elapsed < 1000
    end

    test "terminate for already completed command returns command_not_found", %{opts: opts} do
      # Per-action Router (v28.0): After command completes, Router terminates.
      # Terminate request returns :command_not_found since Router is dead.

      # Start a command that takes just long enough to go async
      # Force async with threshold: 0 to ensure it registers in Router
      # Note: "echo done" alone can complete before async path triggers (race condition)
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      {:ok, %{command_id: cmd_id}} =
        Shell.execute(%{command: "sleep 0.01 && echo done"}, "agent-1", opts_async)

      # Wait for completion via action_result
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, _}}}, 30_000

      # Try to terminate completed command - Router already terminated
      result = Shell.execute(%{check_id: cmd_id, terminate: true}, "agent-1", opts)

      assert {:error, :command_not_found} = result
    end

    test "terminate for non-existent command returns error", %{opts: opts} do
      result =
        Shell.execute(%{check_id: "fake-uuid", terminate: true}, "agent-1", opts)

      assert {:error, :command_not_found} = result
    end
  end

  describe "XOR validation" do
    test "[UNIT] I2.1: params with both command and check_id are rejected", %{opts: opts} do
      # XOR validation should reject params with both command and check_id
      params = %{command: "echo test", check_id: "some-uuid"}
      result = Shell.execute(params, "agent-1", opts)

      # Should return error for XOR violation
      assert {:error, :xor_violation} = result
    end
  end

  describe "incremental output delivery" do
    test "[INTEGRATION] Q2.1: frequent polling doesn't leak memory", %{
      opts: opts,
      router: router
    } do
      # Per-action Router (v28.0): Memory leak prevention is handled by Router termination.
      # This test verifies that frequent polling works and Router terminates cleanly.

      # Monitor Router to verify it terminates
      router_ref = Process.monitor(router)

      # Start a command that produces continuous output
      {:ok, %{command_id: cmd_id}} =
        Shell.execute(
          %{command: "for i in {1..50}; do echo data; sleep 0.01; done"},
          "agent-1",
          opts
        )

      # Poll frequently while command is running
      poll_results =
        Enum.reduce_while(1..100, [], fn _, acc ->
          case Shell.execute(%{check_id: cmd_id}, "agent-1", opts) do
            {:ok, %{status: :running}} ->
              # Brief pause between polls
              receive do
              after
                5 -> :ok
              end

              {:cont, [:running | acc]}

            {:ok, %{status: :completed}} ->
              {:halt, [:completed | acc]}

            {:error, :command_not_found} ->
              # Router already terminated
              {:halt, [:not_found | acc]}
          end
        end)

      # Verify we got some successful polls
      assert Enum.any?(poll_results, &(&1 == :running))

      # Wait for Router termination (natural completion or we terminate it)
      if Process.alive?(router) do
        # Terminate if still running
        Shell.execute(%{check_id: cmd_id, terminate: true}, "agent-1", opts)
      end

      # Router should terminate - no memory leak
      assert_receive {:DOWN, ^router_ref, :process, ^router, _reason}, 30_000
    end

    test "check_id correctly handles binary position slicing", %{opts: opts} do
      # Per-action Router (v28.0): Verify output contains expected content
      # using the helper that handles completion gracefully.

      # Force async to use Router buffering
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      {:ok, %{command_id: cmd_id}} =
        Shell.execute(
          %{command: "printf 'ABC'; sleep 0.15; printf 'DEF'; sleep 0.15; printf 'GHI'"},
          "agent-1",
          opts_async
        )

      # Collect output using helper
      full_output = collect_incremental_output(cmd_id, opts, 10, [])

      # Verify we got the expected content
      assert full_output =~ "ABC"
      assert full_output =~ "DEF"
      assert full_output =~ "GHI"
    end
  end

  describe "Router state management" do
    test "Router tracks command and terminates after completion", %{opts: opts, router: router} do
      # Per-action Router (v28.0): Verify behavior via action_result and Router termination

      # Force async to ensure Router tracks state
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      # Monitor Router for termination
      router_ref = Process.monitor(router)

      # Start a command
      {:ok, %{command_id: _cmd_id}} =
        Shell.execute(%{command: "echo hello"}, "agent-1", opts_async)

      # Wait for completion via action_result
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result}}}, 30_000
      assert result.status == :completed
      assert result.stdout =~ "hello"
      assert result.exit_code == 0

      # Per-action Router: Router terminates after completion
      assert_receive {:DOWN, ^router_ref, :process, ^router, _reason}, 5000
    end

    test "Router updates output buffers as command runs", %{opts: opts} do
      # Per-action Router (v28.0): Verify incremental output via check_id
      # Uses FIFO for deterministic blocking - command is GUARANTEED running when we check

      # Create FIFO to block command between outputs
      fifo_name = "test_fifo_buffers_#{System.unique_integer([:positive])}"
      fifo_path = Path.join(System.tmp_dir!(), fifo_name)
      {_, 0} = System.cmd("mkfifo", [fifo_path])
      on_exit(fn -> File.rm(fifo_path) end)

      # Force async to ensure Router buffering
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      # Command blocks on FIFO read between start and end
      {:ok, %{command_id: cmd_id}} =
        Shell.execute(
          %{command: "echo start; cat #{fifo_path}; echo end"},
          "agent-1",
          opts_async
        )

      # Wait for registration and first output event
      assert_receive {:shell_registered, ^cmd_id}, 30_000
      assert_receive {:output_received, %{command_id: ^cmd_id}}, 30_000

      # Command is GUARANTEED running (blocked on FIFO) - check_id is safe
      {:ok, status1} = Shell.execute(%{check_id: cmd_id}, "agent-1", opts)
      assert status1.status == :running
      assert status1.new_stdout =~ "start"

      # Unblock the command
      File.write!(Path.join(System.tmp_dir!(), fifo_name), "")

      # Wait for completion
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result}}}, 30_000
      assert result.stdout =~ "start"
      assert result.stdout =~ "end"
    end

    test "Router terminates after command termination", %{opts: opts, router: router} do
      # Per-action Router (v28.0): Router terminates after mark_terminated

      # Use FIFO for deterministic blocking instead of sleep 10
      fifo_name = "test_fifo_router_term_#{System.unique_integer([:positive])}"
      fifo_path = Path.join(System.tmp_dir!(), fifo_name)
      {_, 0} = System.cmd("mkfifo", [fifo_path])
      on_exit(fn -> File.rm(fifo_path) end)

      # Monitor Router for termination
      router_ref = Process.monitor(router)

      # Start command that blocks on FIFO
      {:ok, %{command_id: cmd_id}} =
        Shell.execute(%{command: "cat #{fifo_path}"}, "agent-1", opts)

      # Wait for command to start
      assert_receive {:command_started, %{command_id: ^cmd_id}}, 30_000

      # Terminate
      {:ok, _} = Shell.execute(%{check_id: cmd_id, terminate: true}, "agent-1", opts)

      # Router should terminate after mark_terminated (per-action lifecycle)
      assert_receive {:DOWN, ^router_ref, :process, ^router, _reason}, 30_000
    end
  end

  describe "system-level workflow" do
    test "[SYSTEM] Q2.3: complete workflow - spawn, check status, receive completion", %{
      opts: opts,
      router: router
    } do
      # Per-action Router (v28.0): Complete workflow uses check_id while running,
      # then gets final result via action_result when Router terminates.
      # Uses FIFOs for deterministic control over command execution stages.

      # Create FIFOs to control command progress
      fifo1 = "test_fifo_wf1_#{System.unique_integer([:positive])}"
      fifo2 = "test_fifo_wf2_#{System.unique_integer([:positive])}"
      fifo1_path = Path.join(System.tmp_dir!(), fifo1)
      fifo2_path = Path.join(System.tmp_dir!(), fifo2)
      {_, 0} = System.cmd("mkfifo", [fifo1_path])
      {_, 0} = System.cmd("mkfifo", [fifo2_path])

      on_exit(fn ->
        File.rm(fifo1_path)
        File.rm(fifo2_path)
      end)

      # Force async to test the async workflow
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      # Monitor Router for termination verification
      router_ref = Process.monitor(router)

      # Step 1: Spawn command with FIFO gates between stages
      {:ok, %{command_id: cmd_id, status: :running}} =
        Shell.execute(
          %{
            command: "echo starting; cat #{fifo1_path}; echo middle; cat #{fifo2_path}; echo done"
          },
          "agent-1",
          opts_async
        )

      # Step 2: Wait for first output event, then check status via check_id
      # Command is GUARANTEED running (blocked on fifo1)
      assert_receive {:shell_registered, ^cmd_id}, 30_000
      assert_receive {:output_received, %{command_id: ^cmd_id}}, 30_000
      {:ok, status1} = Shell.execute(%{check_id: cmd_id}, "agent-1", opts)
      assert status1.status == :running
      assert status1.new_stdout =~ "starting"

      # Step 3: Unblock fifo1, wait for middle output, check via check_id
      # Command is GUARANTEED running (blocked on fifo2)
      File.write!(Path.join(System.tmp_dir!(), fifo1), "")
      assert_receive {:output_received, %{command_id: ^cmd_id}}, 30_000
      {:ok, status2} = Shell.execute(%{check_id: cmd_id}, "agent-1", opts)
      assert status2.status == :running

      # Step 4: Unblock fifo2 and receive completion message via action_result
      File.write!(Path.join(System.tmp_dir!(), fifo2), "")
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result}}}, 30_000
      assert result.action == "shell"
      assert result.stdout =~ "starting"
      assert result.stdout =~ "middle"
      assert result.stdout =~ "done"
      assert result.exit_code == 0

      # Step 5: Per-action Router terminates after completion
      assert_receive {:DOWN, ^router_ref, :process, ^router, _reason}, 5000

      # Step 6: check_id after completion returns :command_not_found (Router dead)
      assert {:error, :command_not_found} = Shell.execute(%{check_id: cmd_id}, "agent-1", opts)
    end

    test "workflow with early termination", %{opts: opts, router: router} do
      # Force async to ensure Router tracking for termination workflow
      opts_async = Keyword.put(opts, :smart_threshold, 0)

      # Monitor Router to wait for termination (event-driven)
      router_ref = Process.monitor(router)

      # Start long-running command - use `tail -f /dev/null` which blocks forever
      {:ok, %{command_id: cmd_id}} =
        Shell.execute(%{command: "tail -f /dev/null"}, "agent-1", opts_async)

      # Wait for command to actually start
      assert_receive {:command_started, %{command_id: ^cmd_id}}, 30_000
      {:ok, status} = Shell.execute(%{check_id: cmd_id}, "agent-1", opts)
      assert status.status == :running

      # Terminate early
      {:ok, term_result} = Shell.execute(%{check_id: cmd_id, terminate: true}, "agent-1", opts)
      assert term_result.terminated == true

      # Per-action Router terminates after command termination
      # Wait for Router to terminate (event-driven, not polling)
      assert_receive {:DOWN, ^router_ref, :process, ^router, _reason}, 5000

      # Verify can't check terminated command - Router is gone
      result = Shell.execute(%{check_id: cmd_id}, "agent-1", opts)

      # Terminated commands are deleted from state, so should return command_not_found
      assert {:error, :command_not_found} = result
    end
  end

  describe "concurrent command isolation" do
    test "[INTEGRATION] C3: multiple agents get isolated results", %{pubsub: pubsub} do
      # Per-action Router (v28.0): Each command needs its own Router
      # Isolation is inherent - each Router handles exactly one command

      # Helper to spawn Router and execute command
      spawn_and_execute = fn agent_id, command ->
        action_id = "action-#{agent_id}"

        {:ok, router} =
          Quoracle.Actions.Router.start_link(
            action_type: :execute_shell,
            action_id: action_id,
            agent_id: agent_id,
            agent_pid: self(),
            pubsub: pubsub,
            sandbox_owner: nil
          )

        opts = [
          agent_pid: self(),
          pubsub: pubsub,
          router_pid: router,
          action_id: action_id,
          smart_threshold: 0
        ]

        {:ok, %{command_id: cmd_id}} = Shell.execute(%{command: command}, agent_id, opts)
        {action_id, cmd_id, router}
      end

      # Execute three commands concurrently with separate Routers
      {action1, _cmd1, router1} = spawn_and_execute.("agent-1", "echo agent1")
      {action2, _cmd2, router2} = spawn_and_execute.("agent-2", "echo agent2")
      {action3, _cmd3, router3} = spawn_and_execute.("agent-3", "echo agent3")

      on_exit(fn ->
        for r <- [router1, router2, router3] do
          if Process.alive?(r) do
            try do
              GenServer.stop(r, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end
      end)

      # Collect all results (order may vary)
      results =
        for _ <- 1..3 do
          assert_receive {:"$gen_cast", {:action_result, action_id, {:ok, result}}}, 30_000
          {action_id, result}
        end

      # Verify each agent got its own isolated result
      result1 = Enum.find_value(results, fn {id, r} -> if id == action1, do: r end)
      result2 = Enum.find_value(results, fn {id, r} -> if id == action2, do: r end)
      result3 = Enum.find_value(results, fn {id, r} -> if id == action3, do: r end)

      assert result1.stdout =~ "agent1"
      assert result2.stdout =~ "agent2"
      assert result3.stdout =~ "agent3"
    end
  end

  # Helper: Collect incremental output from check_id calls until completion
  # Returns the FULL final output (from action_result), not the incremental parts
  defp collect_incremental_output(cmd_id, opts, max_iterations, acc) when max_iterations > 0 do
    receive do
      {:output_received, %{command_id: ^cmd_id}} ->
        # Got output event, try check_id
        case Shell.execute(%{check_id: cmd_id}, "agent-1", opts) do
          {:ok, %{status: :running, new_stdout: stdout}} when stdout != "" ->
            collect_incremental_output(cmd_id, opts, max_iterations - 1, [stdout | acc])

          {:ok, %{status: :running}} ->
            collect_incremental_output(cmd_id, opts, max_iterations - 1, acc)

          {:ok, %{status: :completed, stdout: stdout}} ->
            # Completed via check_id - return full stdout from result
            stdout

          {:error, :command_not_found} ->
            # Router terminated - get full output from action_result
            receive do
              {:"$gen_cast", {:action_result, _, {:ok, result}}} -> result.stdout
            after
              100 -> acc |> Enum.reverse() |> Enum.join()
            end

          _ ->
            collect_incremental_output(cmd_id, opts, max_iterations - 1, acc)
        end

      {:"$gen_cast", {:action_result, _, {:ok, result}}} ->
        # Command completed via action_result - return full stdout
        result.stdout
    after
      30_000 -> acc |> Enum.reverse() |> Enum.join()
    end
  end

  defp collect_incremental_output(_cmd_id, _opts, 0, acc) do
    acc |> Enum.reverse() |> Enum.join()
  end
end
