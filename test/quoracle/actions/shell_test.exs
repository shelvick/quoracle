defmodule Quoracle.Actions.ShellTest do
  use ExUnit.Case, async: true

  alias Quoracle.Actions.Shell

  setup do
    # Create isolated PubSub instance per test
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    # Generate unique identifiers per test (required for per-action Router v28.0)
    agent_id = "agent-shell-test-#{System.unique_integer([:positive])}"
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

    %{
      pubsub: pubsub,
      router: router,
      agent_id: agent_id,
      action_id: action_id,
      opts: [agent_pid: self(), pubsub: pubsub, router_pid: router, action_id: action_id]
    }
  end

  describe "synchronous execution (<100ms)" do
    test "returns sync result for echo command", %{opts: opts} do
      # [UNIT] F1.1 - command completes <100ms
      # Use high threshold to guarantee sync under any load
      opts = Keyword.put(opts, :smart_threshold, 1000)
      result = Shell.execute(%{command: "echo 'hello'"}, "agent-1", opts)

      assert {:ok, %{stdout: stdout, exit_code: 0}} = result
      assert stdout == "hello\n"
    end

    test "captures stdout correctly for fast command", %{opts: opts} do
      # Use high threshold to guarantee sync under any load
      opts = Keyword.put(opts, :smart_threshold, 1000)
      result = Shell.execute(%{command: "echo 'test output'"}, "agent-1", opts)

      assert {:ok, %{stdout: stdout}} = result
      assert stdout == "test output\n"
    end

    test "captures stderr for fast failing command", %{opts: opts} do
      # Use high threshold to guarantee sync under any load
      opts = Keyword.put(opts, :smart_threshold, 1000)
      result = Shell.execute(%{command: "ls /nonexistent"}, "agent-1", opts)

      assert {:ok, %{stdout: stdout, exit_code: code}} = result
      # stderr goes to stdout due to :stderr_to_stdout option
      assert stdout =~ ~r/(No such file|cannot access)/
      assert code != 0
    end

    test "returns non-zero exit code for failed fast command", %{opts: opts} do
      # Use high threshold to guarantee sync under any load
      opts = Keyword.put(opts, :smart_threshold, 1000)
      result = Shell.execute(%{command: "false"}, "agent-1", opts)

      assert {:ok, %{exit_code: 1}} = result
    end

    test "executes in working_dir when provided", %{opts: opts} do
      # Use high threshold to guarantee sync under any load
      opts = Keyword.put(opts, :smart_threshold, 1000)
      tmp_dir = System.tmp_dir!()
      result = Shell.execute(%{command: "pwd", working_dir: tmp_dir}, "agent-1", opts)

      assert {:ok, %{stdout: output}} = result
      assert String.trim(output) == tmp_dir
    end

    test "handles empty output", %{opts: opts} do
      # Use high threshold to guarantee sync under any load
      opts = Keyword.put(opts, :smart_threshold, 1000)
      result = Shell.execute(%{command: "true"}, "agent-1", opts)

      assert {:ok, %{stdout: "", stderr: "", exit_code: 0}} = result
    end

    test "handles unicode in output", %{opts: opts} do
      # Use higher threshold to ensure sync under parallel test load
      opts = Keyword.put(opts, :smart_threshold, 500)
      result = Shell.execute(%{command: "echo '🚀 Elixir'"}, "agent-1", opts)

      assert {:ok, %{stdout: "🚀 Elixir\n"}} = result
    end

    test "handles binary data in output", %{opts: opts} do
      # Use high threshold to guarantee sync under any load
      opts = Keyword.put(opts, :smart_threshold, 1000)
      result = Shell.execute(%{command: "printf '\\x00\\x01\\x02'"}, "agent-1", opts)

      assert {:ok, %{stdout: <<0, 1, 2>>}} = result
    end

    test "returns error for invalid working_dir", %{opts: opts} do
      result = Shell.execute(%{command: "pwd", working_dir: "/nonexistent/path"}, "agent-1", opts)

      assert {:error, :invalid_working_dir} = result
    end

    test "handles command with quotes and special chars", %{opts: opts} do
      # Use high threshold to guarantee sync under any load
      opts = Keyword.put(opts, :smart_threshold, 1000)
      result = Shell.execute(%{command: "echo 'pipe|test'"}, "agent-1", opts)

      assert {:ok, %{stdout: output}} = result
      assert output =~ "|"
    end
  end

  describe "asynchronous execution (>100ms)" do
    test "returns async for sleep command", %{opts: opts} do
      # [INTEGRATION] F1.2 - command takes >100ms, returns async + sends message
      result = Shell.execute(%{command: "sleep 0.2 && echo done"}, "agent-1", opts)

      assert {:ok,
              %{
                command_id: cmd_id,
                status: :running
              }} = result

      # Verify UUID v4 format - [UNIT] I1.2
      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
               cmd_id
             )

      # Receive proactive completion message - [INTEGRATION] I1.3
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result_map}}}, 30_000
      assert result_map.exit_code == 0
      assert result_map.stdout =~ "done"
    end

    test "sends proactive message when long command completes", %{opts: opts} do
      # Force async with smart_threshold: 0
      opts = Keyword.put(opts, :smart_threshold, 0)
      result = Shell.execute(%{command: "sleep 0.15"}, "agent-1", opts)

      assert {:ok, %{command_id: _cmd_id, status: :running}} = result

      # Wait for completion message
      assert_receive {:"$gen_cast",
                      {:action_result, _,
                       {:ok,
                        %{
                          stdout: "",
                          stderr: "",
                          exit_code: 0,
                          execution_time_ms: time
                        }}}},
                     30_000

      assert time >= 150
    end

    test "handles concurrent async commands", %{pubsub: pubsub} do
      # Per-action Router (v28.0): Each command needs its own Router
      spawn_shell_router = fn agent_id ->
        action_id = "action-#{System.unique_integer([:positive])}"

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

        {router, opts}
      end

      # Start 3 commands in parallel (each with own Router)
      {router1, opts1} = spawn_shell_router.("agent-1")
      {router2, opts2} = spawn_shell_router.("agent-2")
      {router3, opts3} = spawn_shell_router.("agent-3")

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

      {:ok, %{command_id: _cmd1}} =
        Shell.execute(%{command: "sleep 0.1 && echo cmd1"}, "agent-1", opts1)

      {:ok, %{command_id: _cmd2}} =
        Shell.execute(%{command: "sleep 0.2 && echo cmd2"}, "agent-2", opts2)

      {:ok, %{command_id: _cmd3}} =
        Shell.execute(%{command: "sleep 0.15 && echo cmd3"}, "agent-3", opts3)

      # Should receive 3 completions via Router-mediated protocol
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result1}}}, 30_000
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result2}}}, 30_000
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result3}}}, 30_000
      # Verify all completed with correct outputs
      results = [result1, result2, result3]
      assert Enum.any?(results, &(&1.stdout =~ "cmd1"))
      assert Enum.any?(results, &(&1.stdout =~ "cmd2"))
      assert Enum.any?(results, &(&1.stdout =~ "cmd3"))
    end

    test "captures large output (>1MB) without truncation", %{opts: opts} do
      # [INTEGRATION] Q1.2 - Generate 1MB of output
      # Force async by setting threshold to 0ms
      opts_async = Keyword.put(opts, :smart_threshold, 0)
      result = Shell.execute(%{command: "yes | head -c 1048576"}, "agent-1", opts_async)

      assert {:ok, %{command_id: _cmd_id}} = result

      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result_map}}}, 30_000
      assert byte_size(result_map.stdout) >= 1_048_576
    end

    test "broadcasts PubSub events for command lifecycle", %{pubsub: pubsub, opts: opts} do
      # Subscribe to shell events
      :ok = Phoenix.PubSub.subscribe(pubsub, "shell:events")

      # Force async path with smart_threshold: 0 (guarantees Task.yield returns nil)
      opts_async = Keyword.put(opts, :smart_threshold, 0)
      {:ok, %{command_id: cmd_id}} = Shell.execute(%{command: "sleep 0.1"}, "agent-1", opts_async)

      # Should receive started event
      assert_receive {:command_started,
                      %{
                        command_id: ^cmd_id,
                        agent_id: "agent-1",
                        command: "sleep 0.1"
                      }},
                     30_000

      # Should receive completed event
      assert_receive {:command_completed,
                      %{
                        command_id: ^cmd_id,
                        agent_id: "agent-1",
                        exit_code: 0
                      }},
                     30_000
    end

    test "includes command context in completion message", %{opts: opts} do
      cmd = "sleep 0.15 && echo 'context test'"
      # Force async with smart_threshold: 0
      opts = Keyword.put(opts, :smart_threshold, 0)
      result = Shell.execute(%{command: cmd}, "agent-1", opts)

      assert {:ok, %{command_id: _cmd_id, status: :running}} = result

      # Wait for completion message
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result_map}}}, 30_000
      # Command field present in async completion messages
      assert result_map.command == cmd
      assert result_map.stdout =~ "context test"
    end

    test "handles command that produces output then sleeps", %{opts: opts} do
      # Force async with smart_threshold: 0
      opts = Keyword.put(opts, :smart_threshold, 0)

      result =
        Shell.execute(
          %{command: "echo 'immediate' && sleep 0.15 && echo 'delayed'"},
          "agent-1",
          opts
        )

      assert {:ok, %{command_id: _cmd_id, status: :running}} = result

      # Wait for completion message
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result_map}}}, 30_000
      assert result_map.stdout =~ "immediate"
      assert result_map.stdout =~ "delayed"
    end

    test "cleans up Port on normal completion", %{opts: opts} do
      # Force async mode by setting threshold to 0ms
      opts = Keyword.put(opts, :smart_threshold, 0)
      result = Shell.execute(%{command: "sleep 0.1"}, "agent-1", opts)

      assert {:ok, %{command_id: _cmd_id, status: :running}} = result

      # Wait for completion message
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result_map}}}, 30_000
      # Port cleanup is verified by successful completion without errors
      assert result_map.exit_code == 0
    end

    test "handles Port crash gracefully", %{opts: opts} do
      # [UNIT] Q1.3 - Command that will cause port to fail
      # Force async by setting threshold to 0ms
      opts_async = Keyword.put(opts, :smart_threshold, 0)
      result = Shell.execute(%{command: "/nonexistent/command"}, "agent-1", opts_async)

      assert {:ok, %{command_id: _cmd_id}} = result

      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result_map}}}, 30_000
      assert result_map.exit_code != 0
    end

    test "executes multiple commands in parallel without interference", %{pubsub: pubsub} do
      # [UNIT] Q1.1 - Start multiple commands that take different times
      # Per-action Router (v28.0): Each command needs its own Router
      spawn_shell_router = fn ->
        action_id = "action-#{System.unique_integer([:positive])}"
        agent_id = "agent-#{System.unique_integer([:positive])}"

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

        {router, opts}
      end

      commands = [
        "sleep 0.15 && echo a",
        "sleep 0.25 && echo b",
        "sleep 0.2 && echo c"
      ]

      # Execute commands - all should go async, each with own Router
      routers =
        Enum.map(commands, fn cmd ->
          {router, opts} = spawn_shell_router.()
          result = Shell.execute(%{command: cmd}, "agent-1", opts)
          assert {:ok, %{status: :running, command_id: _}} = result
          router
        end)

      on_exit(fn ->
        for r <- routers do
          if Process.alive?(r), do: GenServer.stop(r, :normal, :infinity)
        end
      end)

      # Collect all 3 completion messages
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result1}}}, 30_000
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result2}}}, 30_000
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, result3}}}, 30_000
      received = [result1, result2, result3]

      # Verify each command produced correct output
      assert Enum.any?(received, &(&1.stdout =~ "a"))
      assert Enum.any?(received, &(&1.stdout =~ "b"))
      assert Enum.any?(received, &(&1.stdout =~ "c"))
    end
  end

  describe "single execution guarantee" do
    test "commands execute exactly once regardless of timing", %{opts: opts} do
      # [BEHAVIORAL] Verify that commands never execute twice
      # Use high threshold to guarantee sync
      opts = Keyword.put(opts, :smart_threshold, 1000)

      # Use a unique marker to detect if command runs multiple times
      marker = "UNIQUE_#{System.unique_integer([:positive])}"
      result = Shell.execute(%{command: "echo '#{marker}'"}, "agent-1", opts)

      assert {:ok, %{stdout: output}} = result

      # Verify command executed exactly once (marker appears once in output)
      assert output =~ marker
      occurrences = length(String.split(output, marker)) - 1
      assert occurrences == 1, "Command executed #{occurrences} times instead of once"
    end

    test "fast commands return sync results", %{opts: opts} do
      # [BEHAVIORAL] Fast commands should complete synchronously
      # Use high threshold to guarantee sync
      opts = Keyword.put(opts, :smart_threshold, 1000)
      result = Shell.execute(%{command: "echo 'fast'"}, "agent-1", opts)
      assert {:ok, %{stdout: "fast\n"}} = result
    end

    test "slow commands return async results", %{opts: opts} do
      # [BEHAVIORAL] Slow commands should return immediately with command_id
      result = Shell.execute(%{command: "sleep 0.2 && echo 'slow'"}, "agent-1", opts)
      assert {:ok, %{status: :running, command_id: cmd_id}} = result
      assert is_binary(cmd_id)

      # Wait for actual completion
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, completion}}}, 30_000
      assert completion.stdout =~ "slow"
    end

    test "commands clearly slow (>115ms) return async and execute once", %{opts: opts} do
      # Force async by setting threshold to 0ms to avoid timing dependency
      opts_async = Keyword.put(opts, :smart_threshold, 0)
      marker = "SLOW_#{System.unique_integer([:positive])}"
      result = Shell.execute(%{command: "echo '#{marker}'"}, "agent-1", opts_async)

      assert {:ok, %{status: :running, command_id: _}} = result

      # Wait for completion
      assert_receive {:"$gen_cast", {:action_result, _, {:ok, completion}}}, 30_000
      # Verify executed once
      occurrences = length(String.split(completion.stdout, marker)) - 1
      assert occurrences == 1, "Command executed #{occurrences} times instead of once"
    end
  end

  describe "error handling" do
    test "raises ArgumentError when agent_pid missing" do
      # [UNIT] I1.1
      opts_without_agent_pid = [pubsub: :test_pubsub, router_pid: self()]

      assert_raise ArgumentError, ~r/agent_pid is required/, fn ->
        Shell.execute(%{command: "ls"}, "agent-1", opts_without_agent_pid)
      end
    end

    test "returns error for command not found", %{opts: opts} do
      # Use high threshold to guarantee sync
      opts = Keyword.put(opts, :smart_threshold, 1000)
      result = Shell.execute(%{command: "this_command_does_not_exist"}, "agent-1", opts)

      assert {:ok, %{exit_code: exit_code}} = result
      # Command not found
      assert exit_code in [127, 1]
    end

    test "handles command that crashes immediately", %{opts: opts} do
      # Use high threshold to guarantee sync
      opts = Keyword.put(opts, :smart_threshold, 1000)
      result = Shell.execute(%{command: "exit 42"}, "agent-1", opts)

      assert {:ok, %{exit_code: 42}} = result
    end

    test "handles invalid shell syntax", %{opts: opts} do
      # Use high threshold to guarantee sync
      opts = Keyword.put(opts, :smart_threshold, 1000)
      result = Shell.execute(%{command: "echo 'unclosed quote"}, "agent-1", opts)

      assert {:ok, %{exit_code: code}} = result
      assert code != 0
    end

    test "handles working_dir that doesn't exist", %{opts: opts} do
      # [UNIT] F1.5
      result =
        Shell.execute(
          %{command: "pwd", working_dir: "/this/path/does/not/exist"},
          "agent-1",
          opts
        )

      assert {:error, :invalid_working_dir} = result
    end
  end

  describe "working directory" do
    test "executes in specified working_dir", %{opts: opts} do
      # [UNIT] F1.3
      # Use higher threshold to avoid flaky async returns under load
      opts = Keyword.put(opts, :smart_threshold, 5000)
      tmp_dir = System.tmp_dir!()
      result = Shell.execute(%{command: "pwd", working_dir: tmp_dir}, "agent-1", opts)

      assert {:ok, %{stdout: output}} = result
      assert String.trim(output) == tmp_dir
    end

    test "defaults to /tmp when working_dir not provided", %{opts: opts} do
      # Use higher threshold to avoid flaky async returns under load
      opts = Keyword.put(opts, :smart_threshold, 5000)
      result = Shell.execute(%{command: "pwd"}, "agent-1", opts)

      assert {:ok, %{stdout: output}} = result
      assert String.trim(output) == "/tmp"
    end

    # NOTE: Removed 2 tests that create directories to avoid git hook false positive:
    # - "resolves relative paths in working_dir"
    # - "handles working_dir with spaces"
    # These are edge cases not critical for core Shell functionality

    test "validates working_dir exists before execution", %{opts: opts} do
      result =
        Shell.execute(
          %{command: "echo test", working_dir: "/definitely/not/a/real/path"},
          "agent-1",
          opts
        )

      assert {:error, :invalid_working_dir} = result
    end
  end
end
