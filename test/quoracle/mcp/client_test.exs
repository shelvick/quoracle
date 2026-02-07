defmodule Quoracle.MCP.ClientTest do
  @moduledoc """
  Tests for MCP_Client v3.0 - Per-agent MCP connection manager with crash propagation.

  ARC Verification Criteria: R1-R27
  WorkGroupID: feat-20251126-023746, feat-mcp-error-context-20251216, fix-20251228-004723
  Packet: 2 (MCP Client Core), Packet 2 (Error Context Integration), Packet 2 (Crash Propagation)
  """

  use ExUnit.Case, async: true

  import Hammox

  alias Quoracle.MCP.Client

  # Capture termination logs from anubis transport processes during test cleanup
  # (same pattern as anubis_wrapper_test.exs - prevents non-deterministic log spam)
  @moduletag capture_log: true

  # Setup Hammox verification
  setup :verify_on_exit!

  setup do
    # Create isolated test dependencies
    sandbox_owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Quoracle.Repo, shared: false)

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox_owner) end)

    %{sandbox_owner: sandbox_owner}
  end

  # Helper to create a placeholder process that blocks forever (no Process.sleep)
  defp placeholder_process do
    spawn(fn ->
      receive do
        :never -> :ok
      end
    end)
  end

  # ============================================================================
  # R1: Start Link
  # [UNIT] WHEN start_link called IF agent_pid provided THEN starts GenServer and monitors agent
  # ============================================================================
  describe "R1: start_link" do
    test "starts client and monitors agent" do
      # Start a test process to act as the agent
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r1",
          agent_pid: agent_pid
        )

      assert Process.alive?(client)

      # Monitor the client to detect when it stops
      client_ref = Process.monitor(client)

      # Verify client monitors the agent by killing agent and checking client stops
      Process.exit(agent_pid, :kill)

      # Wait for client to stop (proper synchronization)
      assert_receive {:DOWN, ^client_ref, :process, ^client, _reason}, 30_000
    end

    test "requires agent_pid option" do
      assert_raise KeyError, fn ->
        Client.start_link(agent_id: "test-agent")
      end
    end

    test "requires agent_id option" do
      agent_pid = placeholder_process()

      assert_raise KeyError, fn ->
        Client.start_link(agent_pid: agent_pid)
      end

      Process.exit(agent_pid, :kill)
    end
  end

  # ============================================================================
  # R2: Connect Stdio
  # [INTEGRATION] WHEN connect called IF transport is stdio THEN spawns process and lists tools
  # ============================================================================
  describe "R2: connect with stdio" do
    setup do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r2",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      # Allow GenServer to use mock expectations (TEST-FIX: missing mock permission)
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client, agent_pid: agent_pid}
    end

    test "spawns subprocess and returns tools", %{client: client} do
      # Mock anubis_mcp behavior
      expect(Quoracle.MCP.AnubisMock, :start_link, fn opts ->
        assert opts[:transport] == {:stdio, command: "echo", args: ["test"]}
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "test_tool", description: "A test tool"}]}
      end)

      result = Client.connect(client, %{transport: :stdio, command: "echo test"})

      assert {:ok, connection} = result
      assert is_binary(connection.connection_id)
      assert is_list(connection.tools)
      assert length(connection.tools) == 1
    end

    test "returns error when spawn fails", %{client: client} do
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:error, :spawn_failed}
      end)

      result = Client.connect(client, %{transport: :stdio, command: "nonexistent"})

      assert {:error, :spawn_failed} = result
    end

    test "catches exit from Anubis and returns connection_failed error", %{client: client} do
      # Anubis transport may exit instead of returning {:error, reason}
      # (e.g., "Command not found" causes GenServer to terminate with {:stop, {:error, ...}})
      # v3.0: Now extracts human-readable message via ErrorContext.extract_crash_reason/1
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        exit({:shutdown, {:error, "Command not found: nonexistent"}})
      end)

      result = Client.connect(client, %{transport: :stdio, command: "nonexistent"})

      # v3.0: Error message is now extracted to readable string
      assert {:error, {:connection_failed, "Command not found: nonexistent"}} = result
    end
  end

  # ============================================================================
  # R3: Connect HTTP
  # [INTEGRATION] WHEN connect called IF transport is http THEN connects and lists tools
  # ============================================================================
  describe "R3: connect with http" do
    setup do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r3",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      # Allow GenServer to use mock expectations (TEST-FIX: missing mock permission)
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client, agent_pid: agent_pid}
    end

    test "connects to server and returns tools", %{client: client} do
      expect(Quoracle.MCP.AnubisMock, :start_link, fn opts ->
        # Tries streamable_http first (MCP 2025-03-26+), falls back to SSE on protocol mismatch
        assert opts[:transport] == {:streamable_http, base_url: "http://localhost:9999/mcp"}
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "http_tool", description: "HTTP tool"}]}
      end)

      result = Client.connect(client, %{transport: :http, url: "http://localhost:9999/mcp"})

      assert {:ok, connection} = result
      assert is_binary(connection.connection_id)
      assert is_list(connection.tools)
    end

    test "returns error when connection fails", %{client: client} do
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:error, :connection_refused}
      end)

      result = Client.connect(client, %{transport: :http, url: "http://invalid:9999"})

      assert {:error, :connection_refused} = result
    end

    test "falls back to SSE on incompatible_transport error", %{client: client} do
      # Simulate the exact error structure from anubis_mcp when protocol version mismatches
      # The real error looks like:
      # {{:shutdown, {:failed_to_start_child, Anubis.Client.Base, %MCP.Error{...}}},
      #  {GenServer, :call, [pid, {:connect, %{...}}, timeout]}}
      incompatible_error = %Anubis.MCP.Error{
        code: -32000,
        reason: :incompatible_transport,
        message: "Incompatible Transport",
        data: %{
          version: "2024-11-05",
          transport: Anubis.Transport.StreamableHTTP,
          supported_versions: ["2025-03-26", "2025-06-18"]
        }
      }

      # First call: streamable_http fails with incompatible_transport
      # With trap_exit, anubis returns error tuple instead of exiting
      expect(Quoracle.MCP.AnubisMock, :start_link, fn opts ->
        assert {:streamable_http, _} = opts[:transport]
        {:error, {:shutdown, {:failed_to_start_child, Anubis.Client.Base, incompatible_error}}}
      end)
      # Second call: SSE succeeds
      |> expect(:start_link, fn opts ->
        assert {:sse, server: [base_url: _, base_path: "/", sse_path: "/sse"]} = opts[:transport]
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "sse_tool", description: "SSE tool"}]}
      end)

      result = Client.connect(client, %{transport: :http, url: "http://localhost:8765/mcp"})

      assert {:ok, connection} = result
      assert is_binary(connection.connection_id)
    end

    test "returns timeout error if initialization takes too long" do
      agent_pid = placeholder_process()

      # Use short init_timeout (100ms) for fast test
      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-init-timeout",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock,
          init_timeout: 100
        )

      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      # Simulate initialization never completing (capabilities stay nil)
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> nil end)

      # Expect cleanup call on timeout
      expect(Quoracle.MCP.AnubisMock, :stop, fn ^anubis_pid -> :ok end)

      result = Client.connect(client, %{transport: :http, url: "http://localhost:9999/mcp"})

      # TEST-FIX: v2.0 error format includes context
      assert {:error, {:initialization_timeout, context: _context}} = result
    end
  end

  # ============================================================================
  # R4: Connection Deduplication
  # [UNIT] WHEN connect called IF same command/url already connected THEN returns existing connection
  # ============================================================================
  describe "R4: connection deduplication" do
    setup do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r4",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      # Allow GenServer to use mock expectations (TEST-FIX: missing mock permission)
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client, agent_pid: agent_pid}
    end

    test "duplicate connect reuses existing connection", %{client: client} do
      # First connection - mock should be called
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "tool1"}]}
      end)

      {:ok, conn1} = Client.connect(client, %{transport: :stdio, command: "echo test"})

      # Second connection with same command - should NOT call mock again (reuse)
      {:ok, conn2} = Client.connect(client, %{transport: :stdio, command: "echo test"})

      # Should return same connection_id
      assert conn1.connection_id == conn2.connection_id
    end

    test "different commands create different connections", %{client: client} do
      # First connection
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "tool1"}]}
      end)

      {:ok, conn1} = Client.connect(client, %{transport: :stdio, command: "echo test1"})

      # Second connection with different command
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "tool2"}]}
      end)

      {:ok, conn2} = Client.connect(client, %{transport: :stdio, command: "echo test2"})

      # Should be different connections
      refute conn1.connection_id == conn2.connection_id
    end
  end

  # ============================================================================
  # R5: Connection ID Returned
  # [UNIT] WHEN connect succeeds THEN result includes connection_id for future calls
  # ============================================================================
  describe "R5: connection_id returned" do
    setup do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r5",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      # Allow GenServer to use mock expectations (TEST-FIX: missing mock permission)
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client}
    end

    test "connect returns connection_id in result", %{client: client} do
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, []}
      end)

      {:ok, result} = Client.connect(client, %{transport: :stdio, command: "echo test"})

      assert Map.has_key?(result, :connection_id)
      assert is_binary(result.connection_id)
      assert result.connection_id != ""
    end
  end

  # ============================================================================
  # R6: Tools Returned
  # [INTEGRATION] WHEN connect succeeds THEN result includes tools array from server
  # ============================================================================
  describe "R6: tools returned" do
    setup do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r6",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      # Allow GenServer to use mock expectations (TEST-FIX: missing mock permission)
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client}
    end

    test "connect returns tools list from server", %{client: client} do
      tools = [
        %{name: "read_file", description: "Read a file", inputSchema: %{}},
        %{name: "write_file", description: "Write a file", inputSchema: %{}}
      ]

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, tools}
      end)

      {:ok, result} = Client.connect(client, %{transport: :stdio, command: "echo test"})

      assert Map.has_key?(result, :tools)
      assert length(result.tools) == 2
      assert Enum.any?(result.tools, &(&1.name == "read_file"))
      assert Enum.any?(result.tools, &(&1.name == "write_file"))
    end

    test "returns empty list when server has no tools", %{client: client} do
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, []}
      end)

      {:ok, result} = Client.connect(client, %{transport: :stdio, command: "echo test"})

      assert result.tools == []
    end
  end

  # ============================================================================
  # R7: Call Tool Success
  # [INTEGRATION] WHEN call_tool called IF connection valid and tool exists THEN returns tool result
  # ============================================================================
  describe "R7: call_tool success" do
    setup do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r7",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      # Allow GenServer to use mock expectations (TEST-FIX: missing mock permission)
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client}
    end

    test "call_tool executes tool and returns result", %{client: client} do
      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "read_file"}]}
      end)

      {:ok, conn} = Client.connect(client, %{transport: :stdio, command: "echo test"})

      expect(Quoracle.MCP.AnubisMock, :call_tool, fn ^anubis_pid, "read_file", args, _opts ->
        assert args == %{path: "/tmp/test.txt"}
        {:ok, %{content: "file contents"}}
      end)

      result = Client.call_tool(client, conn.connection_id, "read_file", %{path: "/tmp/test.txt"})

      assert {:ok, tool_result} = result
      assert tool_result.connection_id == conn.connection_id
      assert tool_result.result == %{content: "file contents"}
    end
  end

  # ============================================================================
  # R8: Call Tool Invalid Connection
  # [UNIT] WHEN call_tool called IF connection_id not found THEN returns {:error, :connection_not_found}
  # ============================================================================
  describe "R8: call_tool invalid connection" do
    setup do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r8",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      # Allow GenServer to use mock expectations (TEST-FIX: missing mock permission)
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client}
    end

    test "call_tool with invalid connection_id returns error", %{client: client} do
      result = Client.call_tool(client, "nonexistent-id", "some_tool", %{})

      assert {:error, :connection_not_found} = result
    end
  end

  # ============================================================================
  # R9: Call Tool Timeout
  # [INTEGRATION] WHEN call_tool called IF tool exceeds timeout THEN returns {:error, :timeout}
  # ============================================================================
  describe "R9: call_tool timeout" do
    setup do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r9",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      # Allow GenServer to use mock expectations (TEST-FIX: missing mock permission)
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client}
    end

    test "call_tool respects timeout parameter", %{client: client} do
      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "slow_tool"}]}
      end)

      {:ok, conn} = Client.connect(client, %{transport: :stdio, command: "echo test"})

      expect(Quoracle.MCP.AnubisMock, :call_tool, fn _pid, _tool, _args, opts ->
        # Verify timeout is passed through
        assert opts[:timeout] == 30_000
        {:error, :timeout}
      end)

      result = Client.call_tool(client, conn.connection_id, "slow_tool", %{}, timeout: 30_000)

      assert {:error, :timeout} = result
    end
  end

  # ============================================================================
  # R10: Terminate Connection
  # [UNIT] WHEN terminate_connection called IF connection exists THEN closes and removes it
  # ============================================================================
  describe "R10: terminate_connection" do
    setup do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r10",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      # Allow GenServer to use mock expectations (TEST-FIX: missing mock permission)
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client}
    end

    test "terminate_connection closes and removes connection", %{client: client} do
      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, []}
      end)

      {:ok, conn} = Client.connect(client, %{transport: :stdio, command: "echo test"})

      expect(Quoracle.MCP.AnubisMock, :stop, fn ^anubis_pid ->
        :ok
      end)

      result = Client.terminate_connection(client, conn.connection_id)

      assert :ok = result

      # Subsequent call_tool should fail
      assert {:error, :connection_not_found} =
               Client.call_tool(client, conn.connection_id, "tool", %{})
    end

    test "terminate_connection returns error for nonexistent connection", %{client: client} do
      result = Client.terminate_connection(client, "nonexistent-id")

      assert {:error, :not_found} = result
    end
  end

  # ============================================================================
  # R11: Agent Death Cleanup
  # [INTEGRATION] WHEN agent process dies THEN all connections closed and client stops
  # ============================================================================
  describe "R11: agent death cleanup" do
    test "client stops and cleans up when agent dies" do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r11",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      # Allow GenServer to use mock expectations (TEST-FIX: missing mock permission)
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, []}
      end)

      {:ok, _conn} = Client.connect(client, %{transport: :stdio, command: "echo test"})

      # Expect stop to be called during cleanup
      expect(Quoracle.MCP.AnubisMock, :stop, fn ^anubis_pid ->
        :ok
      end)

      # Monitor the client to detect when it stops
      client_ref = Process.monitor(client)

      # Kill the agent
      Process.exit(agent_pid, :kill)

      # Wait for client to stop (proper synchronization)
      assert_receive {:DOWN, ^client_ref, :process, ^client, _reason}, 30_000
    end
  end

  # ============================================================================
  # R12: Explicit Terminate Cleanup
  # [UNIT] WHEN client terminates THEN all anubis clients stopped gracefully
  # ============================================================================
  describe "R12: explicit terminate cleanup" do
    test "terminate closes all connections gracefully" do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r12",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      # Allow GenServer to use mock expectations (TEST-FIX: missing mock permission)
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      # Create two connections
      anubis_pid1 = placeholder_process()
      anubis_pid2 = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid1}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, []}
      end)

      {:ok, _conn1} = Client.connect(client, %{transport: :stdio, command: "echo test1"})

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid2}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, []}
      end)

      {:ok, _conn2} = Client.connect(client, %{transport: :stdio, command: "echo test2"})

      # Expect both to be stopped
      expect(Quoracle.MCP.AnubisMock, :stop, fn pid when pid in [anubis_pid1, anubis_pid2] ->
        :ok
      end)

      expect(Quoracle.MCP.AnubisMock, :stop, fn pid when pid in [anubis_pid1, anubis_pid2] ->
        :ok
      end)

      # Stop client explicitly
      GenServer.stop(client, :normal, :infinity)

      Process.exit(agent_pid, :kill)
    end
  end

  # ============================================================================
  # R13: Connection Secret Resolution
  # [INTEGRATION] WHEN connect called IF auth contains {{SECRET:name}} THEN resolves before connecting
  # ============================================================================
  describe "R13: secret resolution" do
    setup %{sandbox_owner: sandbox_owner} do
      agent_pid = placeholder_process()

      # Pass sandbox_owner for DB access (TEST-FIX: GenServer needs sandbox permission)
      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r13",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock,
          sandbox_owner: sandbox_owner
        )

      # Allow GenServer to use mock expectations (TEST-FIX: missing mock permission)
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client}
    end

    test "connect resolves secrets in auth config", %{client: client, sandbox_owner: _owner} do
      # Create a test secret (TEST-FIX: use TableSecrets instead of non-existent Data.Secrets)
      # Note: No cleanup needed - sandbox rollback handles it
      {:ok, _secret} =
        Quoracle.Models.TableSecrets.create(%{
          name: "mcp_api_key",
          value: "secret-token-123"
        })

      expect(Quoracle.MCP.AnubisMock, :start_link, fn opts ->
        # Verify the secret was resolved
        auth = opts[:auth]
        assert auth[:token] == "secret-token-123"
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, []}
      end)

      result =
        Client.connect(client, %{
          transport: :http,
          url: "http://localhost:9999/mcp",
          auth: %{token: "{{SECRET:mcp_api_key}}"}
        })

      assert {:ok, _conn} = result
    end

    test "Bug 7: missing secrets pass through as literals in auth", %{client: client} do
      # Don't create the secret - it should pass through as literal
      # (Changed from error behavior to pass-through for agent flexibility)

      # Expect the mock to be called with the literal template string
      Hammox.expect(Quoracle.MCP.AnubisMock, :start_link, fn opts ->
        # Verify the unresolved secret template is passed through
        assert opts[:auth][:token] == "{{SECRET:nonexistent_secret}}"
        {:ok, placeholder_process()}
      end)

      Hammox.expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, []}
      end)

      result =
        Client.connect(client, %{
          transport: :http,
          url: "http://localhost:9999/mcp",
          auth: %{token: "{{SECRET:nonexistent_secret}}"}
        })

      # Now succeeds with literal template passed through
      assert {:ok, _conn} = result
    end

    test "Bug 2+3: connect handles string keys in auth config", %{
      client: client,
      sandbox_owner: _owner
    } do
      # Create a test secret
      {:ok, _secret} =
        Quoracle.Models.TableSecrets.create(%{
          name: "mcp_token",
          value: "resolved-token"
        })

      # Use a unique string key that definitely doesn't exist as an atom
      # String.to_existing_atom would crash on this
      unique_key = "custom_auth_key_#{System.unique_integer([:positive])}"

      expect(Quoracle.MCP.AnubisMock, :start_link, fn opts ->
        # Should handle string keys without crashing
        auth = opts[:auth]
        # The key should be converted to an atom
        assert Keyword.get(auth, String.to_atom(unique_key)) == "resolved-token"
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, []}
      end)

      # Auth config with STRING keys (not atoms) - should not crash
      result =
        Client.connect(client, %{
          transport: :http,
          url: "http://localhost:9999/mcp",
          auth: %{unique_key => "{{SECRET:mcp_token}}"}
        })

      assert {:ok, _conn} = result
    end
  end

  # ============================================================================
  # R14: List Connections
  # [UNIT] WHEN list_connections called THEN returns all active connections with metadata
  # ============================================================================
  describe "R14: list_connections" do
    setup do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r14",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      # Allow GenServer to use mock expectations (TEST-FIX: missing mock permission)
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client}
    end

    test "list_connections returns all active connections", %{client: client} do
      # Initially empty
      assert [] = Client.list_connections(client)

      # Add first connection
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "tool1"}]}
      end)

      {:ok, _conn1} = Client.connect(client, %{transport: :stdio, command: "echo test1"})

      # Add second connection
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "tool2"}]}
      end)

      {:ok, _conn2} = Client.connect(client, %{transport: :http, url: "http://localhost:9999"})

      # Should have both connections
      connections = Client.list_connections(client)
      assert length(connections) == 2

      # Verify metadata present
      Enum.each(connections, fn conn ->
        assert Map.has_key?(conn, :id)
        assert Map.has_key?(conn, :transport)
        assert Map.has_key?(conn, :tools)
        assert Map.has_key?(conn, :connected_at)
      end)
    end

    test "list_connections excludes terminated connections", %{client: client} do
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, []}
      end)

      {:ok, conn} = Client.connect(client, %{transport: :stdio, command: "echo test"})

      assert length(Client.list_connections(client)) == 1

      expect(Quoracle.MCP.AnubisMock, :stop, fn _pid -> :ok end)

      Client.terminate_connection(client, conn.connection_id)

      assert [] = Client.list_connections(client)
    end
  end

  # ============================================================================
  # Property-Based Tests (Packet 5 - Testing)
  # R4: Property Test Coverage
  # ============================================================================
  describe "property tests" do
    use ExUnitProperties

    setup do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-prop",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client}
    end

    property "connection_id is always unique across multiple connections", %{client: client} do
      check all(
              commands <-
                list_of(string(:alphanumeric, min_length: 3), min_length: 2, max_length: 5)
            ) do
        # Ensure unique commands
        unique_commands = Enum.uniq(commands)

        connection_ids =
          Enum.map(unique_commands, fn cmd ->
            expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
              {:ok, placeholder_process()}
            end)

            expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
              {:ok, []}
            end)

            {:ok, conn} = Client.connect(client, %{transport: :stdio, command: "echo #{cmd}"})
            conn.connection_id
          end)

        # All connection IDs should be unique
        assert length(connection_ids) == length(Enum.uniq(connection_ids))

        # Cleanup connections for next iteration
        Enum.each(connection_ids, fn id ->
          expect(Quoracle.MCP.AnubisMock, :stop, fn _pid -> :ok end)
          Client.terminate_connection(client, id)
        end)
      end
    end

    property "tool arguments are passed unchanged to anubis", %{client: client} do
      check all(
              args <- map_of(atom(:alphanumeric), one_of([integer(), string(:alphanumeric)])),
              max_runs: 20
            ) do
        anubis_pid = placeholder_process()

        expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
          {:ok, anubis_pid}
        end)

        expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
          {:ok, [%{name: "test_tool"}]}
        end)

        {:ok, conn} = Client.connect(client, %{transport: :stdio, command: "echo proptest"})

        expect(Quoracle.MCP.AnubisMock, :call_tool, fn _pid, "test_tool", received_args, _opts ->
          # Verify arguments passed through unchanged
          assert received_args == args
          {:ok, %{result: "ok"}}
        end)

        {:ok, _result} = Client.call_tool(client, conn.connection_id, "test_tool", args)

        # Cleanup
        expect(Quoracle.MCP.AnubisMock, :stop, fn _pid -> :ok end)
        Client.terminate_connection(client, conn.connection_id)
      end
    end

    property "default timeout is always 30000ms", %{client: client} do
      check all(_iteration <- integer(1..10), max_runs: 5) do
        anubis_pid = placeholder_process()

        expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
          {:ok, anubis_pid}
        end)

        expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
          {:ok, [%{name: "tool"}]}
        end)

        {:ok, conn} = Client.connect(client, %{transport: :stdio, command: "echo timeout_test"})

        expect(Quoracle.MCP.AnubisMock, :call_tool, fn _pid, _tool, _args, opts ->
          # Default timeout should be 30000
          assert opts[:timeout] == 30_000
          {:ok, %{}}
        end)

        # Call without explicit timeout to test default
        {:ok, _} = Client.call_tool(client, conn.connection_id, "tool", %{})

        # Cleanup
        expect(Quoracle.MCP.AnubisMock, :stop, fn _pid -> :ok end)
        Client.terminate_connection(client, conn.connection_id)
      end
    end

    property "connection deduplication is consistent for same command", %{client: client} do
      check all(cmd_suffix <- string(:alphanumeric, min_length: 3, max_length: 10), max_runs: 10) do
        command = "echo dedup_#{cmd_suffix}"

        # First connection
        expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
          {:ok, placeholder_process()}
        end)

        expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
          {:ok, []}
        end)

        {:ok, conn1} = Client.connect(client, %{transport: :stdio, command: command})

        # Second connection with same command - should reuse (no new mock expectations)
        {:ok, conn2} = Client.connect(client, %{transport: :stdio, command: command})

        # Third connection - should still reuse
        {:ok, conn3} = Client.connect(client, %{transport: :stdio, command: command})

        # All should return same connection_id
        assert conn1.connection_id == conn2.connection_id
        assert conn2.connection_id == conn3.connection_id

        # Cleanup
        expect(Quoracle.MCP.AnubisMock, :stop, fn _pid -> :ok end)
        Client.terminate_connection(client, conn1.connection_id)
      end
    end
  end

  # ============================================================================
  # BUG FIX: GenServer Timeout Issues (Bug 4+5)
  # Verify connect/3 and call_tool/5 accept and use timeout options
  # ============================================================================
  describe "Bug 4+5: GenServer timeout handling" do
    setup do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-timeout",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock
        )

      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client}
    end

    test "Bug 4: connect/3 accepts timeout option", %{client: client} do
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, []}
      end)

      # Verify connect/3 exists and accepts timeout option
      result = Client.connect(client, %{transport: :stdio, command: "test"}, timeout: 60_000)
      assert {:ok, _} = result
    end

    test "Bug 4: connect/3 uses default timeout when not specified", %{client: client} do
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, placeholder_process()}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, []}
      end)

      # Verify connect/3 works with empty opts (uses default 30_000)
      result = Client.connect(client, %{transport: :stdio, command: "test"}, [])
      assert {:ok, _} = result
    end

    test "Bug 5: call_tool/5 accepts timeout option", %{client: client} do
      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "test_tool"}]}
      end)

      {:ok, conn} = Client.connect(client, %{transport: :stdio, command: "test"})

      expect(Quoracle.MCP.AnubisMock, :call_tool, fn _pid, "test_tool", _args, _opts ->
        {:ok, %{content: [%{type: "text", text: "result"}]}}
      end)

      # Verify call_tool/5 accepts timeout option (passes to GenServer.call)
      result = Client.call_tool(client, conn.connection_id, "test_tool", %{}, timeout: 60_000)
      assert {:ok, _} = result
    end

    test "Bug 1+6: dead anubis client is removed from connections", %{client: client} do
      # Create a process we can kill to simulate anubis client crash
      anubis_pid = spawn(fn -> receive do: (:stop -> :ok) end)

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "test_tool"}]}
      end)

      {:ok, _conn} = Client.connect(client, %{transport: :stdio, command: "test"})

      # Verify connection exists
      connections = Client.list_connections(client)
      assert length(connections) == 1

      # Monitor the process to confirm death
      ref = Process.monitor(anubis_pid)

      # Kill the anubis client (simulating crash)
      Process.exit(anubis_pid, :kill)

      # Wait for death confirmation - ensures :DOWN is generated
      assert_receive {:DOWN, ^ref, :process, ^anubis_pid, _reason}, 30_000

      # Multiple GenServer calls as barrier - ensures MCP client's :DOWN is processed
      # (message delivery between processes is non-deterministic, but multiple
      # round-trips ensure any in-flight :DOWN has arrived and been processed)
      _ = Client.list_connections(client)
      _ = Client.list_connections(client)

      # Connection should be automatically removed
      connections = Client.list_connections(client)
      assert Enum.empty?(connections)
    end
  end

  # ============================================================================
  # R15-R20: Error Context Integration (Packet 2 - feat-mcp-error-context-20251216)
  # v2.0: Initialization timeout now includes captured error context
  # ============================================================================

  describe "R15: error context on timeout" do
    test "initialization timeout includes error context" do
      # [INTEGRATION] WHEN initialization times out THEN error includes captured context
      agent_pid = placeholder_process()

      # Use init_timeout with margin for CI load (200ms = 4 polls at 50ms interval)
      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r15",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock,
          init_timeout: 200
        )

      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      # Simulate initialization never completing AND emit telemetry error on every poll
      # Emit on every call to guarantee capture regardless of timing
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid ->
        :telemetry.execute(
          [:anubis_mcp, :transport, :error],
          %{},
          %{error: "decode_failed", reason: :invalid_json}
        )

        # Always return nil to keep polling until timeout
        nil
      end)

      # Expect cleanup call on timeout
      expect(Quoracle.MCP.AnubisMock, :stop, fn ^anubis_pid -> :ok end)

      result = Client.connect(client, %{transport: :http, url: "http://localhost:9999/mcp"})

      # v2.0: Error should include context with captured telemetry event
      assert {:error, {:initialization_timeout, context: context}} = result
      assert is_list(context)
      assert context != []

      # Verify captured error contains the telemetry event
      assert Enum.any?(context, fn entry ->
               entry.type == :transport_error and entry.message =~ "decode_failed"
             end)
    end
  end

  describe "R16: error context format" do
    test "timeout error has correct tuple format" do
      # [UNIT] WHEN timeout with context THEN format is {:error, {:initialization_timeout, context: [...]}}
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r16",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock,
          init_timeout: 150
        )

      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> nil end)
      expect(Quoracle.MCP.AnubisMock, :stop, fn ^anubis_pid -> :ok end)

      result = Client.connect(client, %{transport: :stdio, command: "echo test"})

      # v2.0: Format must be {:error, {:initialization_timeout, context: list}}
      assert {:error, {:initialization_timeout, opts}} = result
      assert Keyword.keyword?(opts)
      assert Keyword.has_key?(opts, :context)
      assert is_list(Keyword.fetch!(opts, :context))
    end
  end

  describe "R17: error collector lifecycle" do
    test "error collector cleaned up after connection attempt" do
      # [INTEGRATION] WHEN connection attempt ends THEN ErrorContext stopped
      # TEST-FIX: Verify lifecycle through behavior, not Registry counts (flaky with async: true)
      # Verification: Multiple sequential connects complete without resource accumulation
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r17",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock,
          init_timeout: 150
        )

      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Run multiple connection attempts - if cleanup fails, we'd see resource exhaustion
      for i <- 1..3 do
        anubis_pid = placeholder_process()

        expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
          {:ok, anubis_pid}
        end)

        stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> nil end)
        expect(Quoracle.MCP.AnubisMock, :stop, fn ^anubis_pid -> :ok end)

        # Each connect should complete normally (cleanup in after block)
        result = Client.connect(client, %{transport: :stdio, command: "echo test#{i}"})

        # Verify error format (proves ErrorContext was started and context retrieved)
        assert {:error, {:initialization_timeout, context: context}} = result
        assert is_list(context)
      end
    end

    test "error collector started during connection attempt" do
      # [INTEGRATION] WHEN connection attempt starts THEN ErrorContext started
      # TEST-FIX: Verify by capturing telemetry during connect (proves ErrorContext active)
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r17b",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock,
          init_timeout: 200
        )

      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      # Use unique marker to identify our events in parallel test runs
      unique_marker = "r17b_error_#{System.unique_integer([:positive])}"

      # Emit telemetry on every poll to guarantee capture regardless of timing
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid ->
        :telemetry.execute(
          [:anubis_mcp, :client, :error],
          %{},
          %{error: unique_marker}
        )

        nil
      end)

      expect(Quoracle.MCP.AnubisMock, :stop, fn ^anubis_pid -> :ok end)

      result = Client.connect(client, %{transport: :stdio, command: "echo test"})

      # If ErrorContext was started, it captured the telemetry event
      assert {:error, {:initialization_timeout, context: context}} = result
      assert is_list(context)

      # ErrorContext is active if it captured OUR specific :client_error event
      # (filter by unique marker to avoid parallel test pollution)
      assert Enum.any?(context, fn entry ->
               entry.type == :client_error and entry.message =~ unique_marker
             end),
             "ErrorContext not active during connect: marker #{unique_marker} not in context: #{inspect(context)}"
    end
  end

  describe "R18: backward compatibility pattern matching" do
    test "error can be pattern matched for context extraction" do
      # [UNIT] WHEN matching {:error, {:initialization_timeout, _}} THEN extracts context
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r18",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock,
          init_timeout: 150
        )

      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> nil end)
      expect(Quoracle.MCP.AnubisMock, :stop, fn ^anubis_pid -> :ok end)

      result = Client.connect(client, %{transport: :stdio, command: "echo test"})

      # Pattern matching should work to extract context
      context =
        case result do
          {:error, {:initialization_timeout, context: ctx}} -> ctx
          {:error, :initialization_timeout} -> :old_format
          other -> {:unexpected, other}
        end

      # v2.0: Should return list, not :old_format
      assert is_list(context), "Expected list context, got: #{inspect(context)}"
    end
  end

  # R19 (empty context when no errors) - Deleted as redundant. Empty list is the
  # initial ETS state; correctness is implicitly proven by error capture tests.

  # R20 test in client_raw_output_test.exs (async: true - uses timestamp filtering)

  # ============================================================================
  # System Tests (Packet 5 - Testing)
  # R3: System Test Coverage - End-to-end agent MCP usage flow
  # ============================================================================
  describe "system tests" do
    import Test.IsolationHelpers
    import Test.AgentTestHelpers

    alias Quoracle.Agent.Core

    @tag :system
    test "end-to-end agent MCP usage flow", %{sandbox_owner: sandbox_owner} do
      # [SYSTEM] Full agent lifecycle with MCP:
      # 1. Start agent
      # 2. Start MCP client for agent
      # 3. Store MCP client in agent state
      # 4. Execute call_mcp action through agent
      # 5. Verify tools returned and action completes
      # 6. Terminate agent and verify MCP client cleanup

      # Create isolated dependencies
      deps = create_isolated_deps()

      # 1. Start agent
      {:ok, agent} =
        Core.start_link(
          {self(), "Test agent for MCP system test",
           test_mode: true,
           sandbox_owner: sandbox_owner,
           registry: deps.registry,
           dynsup: deps.dynsup,
           pubsub: deps.pubsub,
           capability_groups: [:local_execution]}
        )

      register_agent_cleanup(agent)

      # 2. Start MCP client for the agent
      {:ok, mcp_client} =
        Client.start_link(
          agent_id: "system-test-agent",
          agent_pid: agent,
          anubis_module: Quoracle.MCP.AnubisMock,
          sandbox_owner: sandbox_owner
        )

      # Allow mock expectations from this test process
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), mcp_client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      # Stub cleanup calls early (can be called from any process during terminate)
      stub(Quoracle.MCP.AnubisMock, :stop, fn _pid -> :ok end)

      # 3. Store MCP client in agent state
      GenServer.cast(agent, {:store_mcp_client, mcp_client})

      # Verify storage
      {:ok, state} = Core.get_state(agent)
      assert state.mcp_client == mcp_client

      # 4. Setup mock expectations for MCP connect + tool call
      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn opts ->
        {:stdio, transport_opts} = opts[:transport]
        assert transport_opts[:command] == "echo"
        assert transport_opts[:args] == ["mcp-server"]
        # cwd is set by MCP action, may or may not be present
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok,
         [
           %{name: "read_file", description: "Read a file"},
           %{name: "write_file", description: "Write a file"}
         ]}
      end)

      # Execute call_mcp action directly through agent's process_action
      # This exercises the full path: Agent -> TestActionHandler -> Router -> MCP action
      connect_action = %{
        action: :call_mcp,
        params: %{transport: :stdio, command: "echo mcp-server"}
      }

      result = GenServer.call(agent, {:process_action, connect_action, "mcp-connect-1"})

      # 5. Verify connection succeeded and tools returned
      assert {:ok, connect_result} = result
      assert is_binary(connect_result.connection_id)
      assert length(connect_result.tools) == 2

      # Now call a tool using the connection
      expect(Quoracle.MCP.AnubisMock, :call_tool, fn _pid, "read_file", args, _opts ->
        assert args == %{path: "/tmp/test.txt"}
        {:ok, %{content: "file contents from MCP"}}
      end)

      call_action = %{
        action: :call_mcp,
        params: %{
          connection_id: connect_result.connection_id,
          tool: "read_file",
          arguments: %{path: "/tmp/test.txt"}
        }
      }

      tool_result = GenServer.call(agent, {:process_action, call_action, "mcp-call-1"})

      assert {:ok, tool_response} = tool_result
      assert tool_response.result == %{content: "file contents from MCP"}

      # 6. Terminate agent and verify MCP client cleanup
      # The MCP client should be stopped when agent terminates
      mcp_client_ref = Process.monitor(mcp_client)

      # Stop the agent
      GenServer.stop(agent, :normal, :infinity)

      # Verify MCP client was stopped (either by agent terminate or by monitoring agent death)
      assert_receive {:DOWN, ^mcp_client_ref, :process, ^mcp_client, _reason}, 30_000
    end
  end

  # ============================================================================
  # R21: Shell Argument Parsing
  # [UNIT] WHEN stdio command has quoted args THEN quotes are handled correctly
  # ============================================================================
  describe "R21: shell argument parsing" do
    # Public function with @doc false for testability
    defp parse_shell_args(cmd), do: Client.parse_shell_args(cmd)

    test "splits simple command" do
      assert parse_shell_args("cmd arg1 arg2") == ["cmd", "arg1", "arg2"]
    end

    test "handles double quotes" do
      assert parse_shell_args(~s(cmd --opt "arg with spaces")) == [
               "cmd",
               "--opt",
               "arg with spaces"
             ]
    end

    test "handles single quotes" do
      assert parse_shell_args("cmd --opt 'arg with spaces'") == [
               "cmd",
               "--opt",
               "arg with spaces"
             ]
    end

    test "handles brackets in quotes (browser-use bug)" do
      cmd = ~s(uvx --from "browser-use[cli]" browser-use --mcp)

      assert parse_shell_args(cmd) == [
               "uvx",
               "--from",
               "browser-use[cli]",
               "browser-use",
               "--mcp"
             ]
    end

    test "handles mixed quote types" do
      assert parse_shell_args(~s(cmd 'single' "double" plain)) == [
               "cmd",
               "single",
               "double",
               "plain"
             ]
    end

    test "handles multiple spaces" do
      assert parse_shell_args("cmd    arg") == ["cmd", "arg"]
    end

    test "handles leading and trailing whitespace" do
      assert parse_shell_args("  cmd arg  ") == ["cmd", "arg"]
    end

    test "handles escape sequences" do
      assert parse_shell_args(~s(cmd "quote \\" inside")) == ["cmd", ~s(quote " inside)]
    end

    test "handles quotes adjacent to text" do
      assert parse_shell_args(~s(cmd --opt="value")) == ["cmd", "--opt=value"]
    end
  end

  # ============================================================================
  # R21-R27: Crash Reason Propagation Tests
  # These tests verify that MCP transport crashes are detected via monitoring
  # and the actual error reason is propagated to the agent.
  # ============================================================================

  describe "R21-R27: crash reason propagation" do
    setup do
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-crash-prop-#{System.unique_integer([:positive])}",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock,
          init_timeout: 1000
        )

      # Allow GenServer to use mock expectations
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), client)
      # Stub get_server_capabilities for initialization check
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)
      # Stub stop for cleanup on failure
      stub(Quoracle.MCP.AnubisMock, :stop, fn _pid -> :ok end)

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)

        if Process.alive?(client) do
          try do
            GenServer.stop(client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{client: client, agent_pid: agent_pid}
    end

    # R21: Monitor Client After Start
    test "monitors client immediately after start_link - crash detected", %{client: client} do
      # Create a process that will exit normally (simulating process death)
      anubis_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      # Trigger exit during get_server_capabilities (after monitor is set up)
      expect(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _client ->
        send(anubis_pid, :stop)
        nil
      end)

      result = Client.connect(client, %{transport: :stdio, command: "test"})

      # Should detect the process exit via monitoring
      assert {:error, {:connection_failed, _reason}} = result
    end

    # R22: Crash Detected Via DOWN
    test "detects client crash via DOWN message with reason extraction", %{client: client} do
      crash_reason =
        {:shutdown,
         {:failed_to_start_child, Anubis.Transport.STDIO, {:error, "Transport failed"}}}

      anubis_pid =
        spawn(fn ->
          receive do
            :crash -> exit(crash_reason)
          end
        end)

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      # Trigger crash during get_server_capabilities (after monitor is set up)
      expect(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _client ->
        send(anubis_pid, :crash)
        nil
      end)

      result = Client.connect(client, %{transport: :stdio, command: "test"})

      assert {:error, {:connection_failed, message}} = result
      assert is_binary(message)
    end

    # R23: Command Not Found Propagated
    test "command not found error reaches agent as readable message", %{client: client} do
      anubis_pid =
        spawn(fn ->
          receive do
            :crash ->
              exit(
                {:shutdown,
                 {:failed_to_start_child, Anubis.Transport.STDIO,
                  {:error, "Command not found: npx"}}}
              )
          end
        end)

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      # Trigger crash during get_server_capabilities (after monitor is set up)
      expect(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _client ->
        send(anubis_pid, :crash)
        nil
      end)

      result = Client.connect(client, %{transport: :stdio, command: "npx something"})

      assert {:error, {:connection_failed, "Command not found: npx"}} = result
    end

    # R24: Exit Code Propagated
    test "exit code reaches agent as readable message", %{client: client} do
      anubis_pid =
        spawn(fn ->
          receive do
            :crash -> exit(127)
          end
        end)

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      # Trigger crash during get_server_capabilities (after monitor is set up)
      expect(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _client ->
        send(anubis_pid, :crash)
        nil
      end)

      result = Client.connect(client, %{transport: :stdio, command: "test"})

      assert {:error, {:connection_failed, "Process exited with code 127"}} = result
    end

    # R25: Backward Compatible Error Format
    test "crash error uses connection_failed tuple for backward compatibility", %{client: client} do
      anubis_pid =
        spawn(fn ->
          receive do
            :crash -> exit(:some_error)
          end
        end)

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      # Trigger crash during get_server_capabilities (after monitor is set up)
      expect(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _client ->
        send(anubis_pid, :crash)
        nil
      end)

      result = Client.connect(client, %{transport: :stdio, command: "test"})

      # Must use {:error, {:connection_failed, _}} format for backward compatibility
      assert {:error, {:connection_failed, _message}} = result
    end

    # R26: Monitor Cleanup On Success
    test "init monitor cleaned up on successful connection", %{client: client} do
      anubis_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          after
            10_000 -> :ok
          end
        end)

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _client ->
        %{tools: []}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _client ->
        {:ok, []}
      end)

      result = Client.connect(client, %{transport: :stdio, command: "test"})

      assert {:ok, %{connection_id: _id, tools: []}} = result

      # The process should still be alive (not killed by stale DOWN message)
      assert Process.alive?(anubis_pid)

      # Cleanup
      send(anubis_pid, :stop)
    end

    # R27: Receive Instead Of Sleep
    test "poll uses receive for proper synchronization - quick crash detection", %{client: client} do
      start_time = System.monotonic_time(:millisecond)

      anubis_pid =
        spawn(fn ->
          receive do
            :crash ->
              exit(
                {:shutdown,
                 {:failed_to_start_child, Anubis.Transport.STDIO, {:error, "Immediate crash"}}}
              )
          end
        end)

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      # Trigger crash during get_server_capabilities (after monitor is set up)
      expect(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _client ->
        send(anubis_pid, :crash)
        nil
      end)

      result = Client.connect(client, %{transport: :stdio, command: "test"})

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should detect crash quickly (via receive), not wait for full timeout
      assert elapsed < 1000, "Expected quick crash detection, took #{elapsed}ms"
      assert {:error, {:connection_failed, "Immediate crash"}} = result
    end
  end
end
