defmodule Quoracle.Actions.MCPTest do
  @moduledoc """
  Tests for ACTION_MCP v2.0 - MCP Tool Calling Action.

  ARC Verification Criteria: R1-R14
  WorkGroupID: feat-20251126-023746
  Packet: 3 (Action Integration)
  """

  use ExUnit.Case, async: true

  # Capture all logs to prevent error log spam from connection_not_found tests
  @moduletag capture_log: true

  import Hammox

  alias Quoracle.Actions.MCP
  alias Quoracle.MCP.Client, as: MCPClient

  # Setup Hammox verification
  setup :verify_on_exit!

  setup do
    # Create isolated test dependencies
    sandbox_owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Quoracle.Repo, shared: false)

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox_owner) end)

    # Create a placeholder agent process
    agent_pid = spawn(fn -> receive do: (:never -> :ok) end)

    # Start MCP client with mock
    {:ok, mcp_client} =
      MCPClient.start_link(
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        agent_pid: agent_pid,
        anubis_module: Quoracle.MCP.AnubisMock,
        sandbox_owner: sandbox_owner
      )

    # Allow GenServer to use mock expectations
    Hammox.allow(Quoracle.MCP.AnubisMock, self(), mcp_client)
    # Stub get_server_capabilities to simulate initialized MCP client
    stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

    on_exit(fn ->
      if Process.alive?(mcp_client) do
        try do
          GenServer.stop(mcp_client, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end)

    %{
      sandbox_owner: sandbox_owner,
      agent_pid: agent_pid,
      mcp_client: mcp_client,
      agent_id: "test-agent-#{System.unique_integer([:positive])}",
      opts: [mcp_client: mcp_client, agent_pid: agent_pid]
    }
  end

  # Helper to create mock tools
  defp mock_tools do
    [
      %{
        name: "read_file",
        description: "Read contents of a file",
        inputSchema: %{
          type: "object",
          properties: %{path: %{type: "string"}},
          required: ["path"]
        }
      },
      %{
        name: "write_file",
        description: "Write contents to a file",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string"},
            content: %{type: "string"}
          },
          required: ["path", "content"]
        }
      }
    ]
  end

  # Helper to create mock tool result
  defp mock_tool_result do
    %{
      content: [
        %{type: "text", text: "File contents here"}
      ]
    }
  end

  # Helper to create a placeholder process that blocks forever
  defp placeholder_process do
    spawn(fn -> receive do: (:never -> :ok) end)
  end

  # ============================================================================
  # R1: Connect Stdio Returns Tools
  # [INTEGRATION] WHEN execute called IF transport=stdio and command valid THEN returns connection_id and tools list
  # ============================================================================
  describe "R1: connect with stdio returns tools" do
    test "returns connection_id and tools list", %{opts: opts, agent_id: agent_id} do
      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, mock_tools()}
      end)

      params = %{transport: :stdio, command: "npx @mcp/server"}

      result = MCP.execute(params, agent_id, opts)

      assert {:ok, %{connection_id: conn_id, tools: tools}} = result
      assert is_binary(conn_id)
      assert length(tools) == 2
      assert Enum.any?(tools, &(&1.name == "read_file"))
    end

    test "connect returns connection_id and tools", %{opts: opts, agent_id: agent_id} do
      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, mock_tools()}
      end)

      params = %{transport: :stdio, command: "npx @mcp/server"}

      result = MCP.execute(params, agent_id, opts)

      assert {:ok, %{connection_id: conn_id, tools: tools}} = result
      assert is_binary(conn_id)
      assert is_list(tools)
    end
  end

  # ============================================================================
  # R2: Connect HTTP Returns Tools
  # [INTEGRATION] WHEN execute called IF transport=http and url valid THEN returns connection_id and tools list
  # ============================================================================
  describe "R2: connect with http returns tools" do
    test "returns connection_id and tools list", %{opts: opts, agent_id: agent_id} do
      anubis_pid = placeholder_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, mock_tools()}
      end)

      params = %{transport: :http, url: "https://mcp.example.com/api"}

      result = MCP.execute(params, agent_id, opts)

      assert {:ok, %{connection_id: conn_id, tools: tools}} = result
      assert is_binary(conn_id)
      assert length(tools) == 2
    end
  end

  # ============================================================================
  # R3: Connect Deduplication
  # [INTEGRATION] WHEN execute called twice with same command/url THEN returns same connection_id
  # ============================================================================
  describe "R3: connect deduplication" do
    test "duplicate connect returns same connection_id", %{opts: opts, agent_id: agent_id} do
      anubis_pid = placeholder_process()

      # First connect
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, mock_tools()}
      end)

      params = %{transport: :stdio, command: "npx @mcp/server"}

      {:ok, %{connection_id: conn_id1}} = MCP.execute(params, agent_id, opts)

      # Second connect with same command - should reuse
      {:ok, %{connection_id: conn_id2}} = MCP.execute(params, agent_id, opts)

      assert conn_id1 == conn_id2
    end

    test "different commands get different connection_ids", %{opts: opts, agent_id: agent_id} do
      anubis_pid1 = placeholder_process()
      anubis_pid2 = placeholder_process()

      # First server
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid1}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid1 ->
        {:ok, mock_tools()}
      end)

      # Second server
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid2}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid2 ->
        {:ok, mock_tools()}
      end)

      {:ok, %{connection_id: conn_id1}} =
        MCP.execute(%{transport: :stdio, command: "server1"}, agent_id, opts)

      {:ok, %{connection_id: conn_id2}} =
        MCP.execute(%{transport: :stdio, command: "server2"}, agent_id, opts)

      assert conn_id1 != conn_id2
    end
  end

  # ============================================================================
  # R4: Call Tool Success
  # [INTEGRATION] WHEN execute called IF connection_id valid and tool exists THEN returns tool result
  # ============================================================================
  describe "R4: call tool success" do
    test "executes tool and returns result", %{opts: opts, agent_id: agent_id} do
      anubis_pid = placeholder_process()

      # Setup connection first
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, mock_tools()}
      end)

      {:ok, %{connection_id: conn_id}} =
        MCP.execute(%{transport: :stdio, command: "npx @mcp/server"}, agent_id, opts)

      # Now call tool
      expect(Quoracle.MCP.AnubisMock, :call_tool, fn ^anubis_pid,
                                                     "read_file",
                                                     %{path: "/test"},
                                                     _opts ->
        {:ok, mock_tool_result()}
      end)

      result =
        MCP.execute(
          %{connection_id: conn_id, tool: "read_file", arguments: %{path: "/test"}},
          agent_id,
          opts
        )

      assert {:ok, %{connection_id: ^conn_id, result: tool_result}} = result
      assert tool_result.content
    end
  end

  # ============================================================================
  # R5: Call Tool Not Found
  # [UNIT] WHEN execute called IF connection_id invalid THEN returns {:error, :connection_not_found}
  # ============================================================================
  describe "R5: call tool connection not found" do
    test "returns error for invalid connection_id", %{opts: opts, agent_id: agent_id} do
      params = %{
        connection_id: "nonexistent-connection-id",
        tool: "read_file",
        arguments: %{path: "/test"}
      }

      result = MCP.execute(params, agent_id, opts)

      assert {:error, :connection_not_found} = result
    end
  end

  # ============================================================================
  # R6: Call Tool With Arguments
  # [INTEGRATION] WHEN execute called IF arguments provided THEN passed to tool correctly
  # ============================================================================
  describe "R6: call tool with arguments" do
    test "passes arguments to tool correctly", %{opts: opts, agent_id: agent_id} do
      anubis_pid = placeholder_process()

      # Setup connection
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, mock_tools()}
      end)

      {:ok, %{connection_id: conn_id}} =
        MCP.execute(%{transport: :stdio, command: "npx @mcp/server"}, agent_id, opts)

      # Verify arguments are passed correctly
      test_args = %{path: "/custom/path", encoding: "utf-8"}

      expect(Quoracle.MCP.AnubisMock, :call_tool, fn ^anubis_pid, "read_file", args, _opts ->
        assert args == test_args
        {:ok, mock_tool_result()}
      end)

      result =
        MCP.execute(
          %{connection_id: conn_id, tool: "read_file", arguments: test_args},
          agent_id,
          opts
        )

      assert {:ok, %{result: _}} = result
    end

    test "empty arguments default to empty map", %{opts: opts, agent_id: agent_id} do
      anubis_pid = placeholder_process()

      # Setup connection
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, mock_tools()}
      end)

      {:ok, %{connection_id: conn_id}} =
        MCP.execute(%{transport: :stdio, command: "npx @mcp/server"}, agent_id, opts)

      # No arguments provided
      expect(Quoracle.MCP.AnubisMock, :call_tool, fn ^anubis_pid, "list_files", args, _opts ->
        assert args == %{}
        {:ok, mock_tool_result()}
      end)

      result = MCP.execute(%{connection_id: conn_id, tool: "list_files"}, agent_id, opts)

      assert {:ok, _} = result
    end
  end

  # ============================================================================
  # R7: Terminate Connection
  # [INTEGRATION] WHEN execute called IF terminate=true THEN closes connection and returns confirmation
  # ============================================================================
  describe "R7: terminate connection" do
    test "closes connection and returns confirmation", %{opts: opts, agent_id: agent_id} do
      anubis_pid = placeholder_process()

      # Setup connection
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, mock_tools()}
      end)

      {:ok, %{connection_id: conn_id}} =
        MCP.execute(%{transport: :stdio, command: "npx @mcp/server"}, agent_id, opts)

      # Terminate
      expect(Quoracle.MCP.AnubisMock, :stop, fn ^anubis_pid ->
        :ok
      end)

      result = MCP.execute(%{connection_id: conn_id, terminate: true}, agent_id, opts)

      assert {:ok, %{connection_id: ^conn_id, terminated: true}} = result
    end

    test "terminated connection cannot be used again", %{opts: opts, agent_id: agent_id} do
      anubis_pid = placeholder_process()

      # Setup and terminate connection
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, mock_tools()}
      end)

      {:ok, %{connection_id: conn_id}} =
        MCP.execute(%{transport: :stdio, command: "npx @mcp/server"}, agent_id, opts)

      expect(Quoracle.MCP.AnubisMock, :stop, fn ^anubis_pid ->
        :ok
      end)

      {:ok, %{terminated: true}} =
        MCP.execute(%{connection_id: conn_id, terminate: true}, agent_id, opts)

      # Try to use terminated connection
      result = MCP.execute(%{connection_id: conn_id, tool: "read_file"}, agent_id, opts)

      assert {:error, :connection_not_found} = result
    end
  end

  # ============================================================================
  # R8: Terminate Invalid Connection
  # [UNIT] WHEN execute called with terminate IF connection not found THEN returns error
  # ============================================================================
  describe "R8: terminate invalid connection" do
    test "returns error for nonexistent connection", %{opts: opts, agent_id: agent_id} do
      params = %{
        connection_id: "nonexistent-connection",
        terminate: true
      }

      result = MCP.execute(params, agent_id, opts)

      assert {:error, :not_found} = result
    end
  end

  # ============================================================================
  # R9: XOR Violation
  # [UNIT] WHEN execute called IF both transport AND connection_id present THEN returns {:error, :xor_violation}
  # ============================================================================
  describe "R9: XOR violation" do
    test "transport and connection_id together returns xor_violation", %{
      opts: opts,
      agent_id: agent_id
    } do
      params = %{
        transport: :stdio,
        command: "npx @mcp/server",
        connection_id: "some-connection"
      }

      result = MCP.execute(params, agent_id, opts)

      assert {:error, :xor_violation} = result
    end

    test "http transport with connection_id returns xor_violation", %{
      opts: opts,
      agent_id: agent_id
    } do
      params = %{
        transport: :http,
        url: "https://example.com",
        connection_id: "some-connection"
      }

      result = MCP.execute(params, agent_id, opts)

      assert {:error, :xor_violation} = result
    end
  end

  # ============================================================================
  # R10: Timeout Respected
  # [INTEGRATION] WHEN execute called IF timeout param provided THEN uses for tool call
  # ============================================================================
  describe "R10: timeout respected" do
    test "timeout parameter is passed to tool call", %{opts: opts, agent_id: agent_id} do
      anubis_pid = placeholder_process()

      # Setup connection
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, mock_tools()}
      end)

      {:ok, %{connection_id: conn_id}} =
        MCP.execute(%{transport: :stdio, command: "npx @mcp/server"}, agent_id, opts)

      # Call with custom timeout
      custom_timeout = 60_000

      expect(Quoracle.MCP.AnubisMock, :call_tool, fn ^anubis_pid, "read_file", _args, call_opts ->
        assert Keyword.get(call_opts, :timeout) == custom_timeout
        {:ok, mock_tool_result()}
      end)

      result =
        MCP.execute(
          %{connection_id: conn_id, tool: "read_file", timeout: custom_timeout},
          agent_id,
          opts
        )

      assert {:ok, _} = result
    end
  end

  # ============================================================================
  # R11: Default Timeout
  # [UNIT] WHEN execute called IF no timeout THEN uses 30 second default
  # ============================================================================
  describe "R11: default timeout" do
    test "default timeout is 30 seconds", %{opts: opts, agent_id: agent_id} do
      anubis_pid = placeholder_process()

      # Setup connection
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, mock_tools()}
      end)

      {:ok, %{connection_id: conn_id}} =
        MCP.execute(%{transport: :stdio, command: "npx @mcp/server"}, agent_id, opts)

      # Call without timeout - should use 30s default
      expect(Quoracle.MCP.AnubisMock, :call_tool, fn ^anubis_pid, "read_file", _args, call_opts ->
        assert Keyword.get(call_opts, :timeout) == 30_000
        {:ok, mock_tool_result()}
      end)

      result = MCP.execute(%{connection_id: conn_id, tool: "read_file"}, agent_id, opts)

      assert {:ok, _} = result
    end
  end

  # ============================================================================
  # R12: Invalid Params
  # [UNIT] WHEN execute called IF params don't match any mode THEN returns {:error, :invalid_params}
  # ============================================================================
  describe "R12: invalid params" do
    test "empty params returns error", %{opts: opts, agent_id: agent_id} do
      result = MCP.execute(%{}, agent_id, opts)

      assert {:error, :invalid_params} = result
    end

    test "missing required fields returns error", %{opts: opts, agent_id: agent_id} do
      # stdio without command
      result = MCP.execute(%{transport: :stdio}, agent_id, opts)
      assert {:error, :invalid_params} = result

      # http without url
      result = MCP.execute(%{transport: :http}, agent_id, opts)
      assert {:error, :invalid_params} = result

      # connection_id without tool or terminate
      result = MCP.execute(%{connection_id: "some-id"}, agent_id, opts)
      assert {:error, :invalid_params} = result
    end

    test "unknown transport returns error", %{opts: opts, agent_id: agent_id} do
      result = MCP.execute(%{transport: "websocket", url: "ws://example.com"}, agent_id, opts)

      assert {:error, :invalid_params} = result
    end
  end

  # ============================================================================
  # R13: 3-Arity Signature
  # [UNIT] WHEN execute called THEN accepts (params, agent_id, opts) signature
  # ============================================================================
  describe "R13: 3-arity signature" do
    test "follows standard 3-arity action signature", %{opts: opts, agent_id: agent_id} do
      # Call with 3 arguments - compiler verifies function exists,
      # test verifies it handles params correctly
      result = MCP.execute(%{}, agent_id, opts)
      assert {:error, :invalid_params} = result
    end
  end

  # ============================================================================
  # R14: Agent System Test
  # [SYSTEM] WHEN agent uses call_mcp via consensus THEN full flow works
  # ============================================================================
  describe "R14: agent system test" do
    @tag :system
    test "end-to-end MCP usage flow", %{opts: opts, agent_id: agent_id} do
      anubis_pid = placeholder_process()

      # Step 1: Connect to MCP server
      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, mock_tools()}
      end)

      {:ok, %{connection_id: conn_id, tools: tools}} =
        MCP.execute(%{transport: :stdio, command: "npx @mcp/server"}, agent_id, opts)

      assert is_binary(conn_id)
      assert length(tools) == 2

      # Step 2: Call a tool
      expect(Quoracle.MCP.AnubisMock, :call_tool, fn ^anubis_pid,
                                                     "read_file",
                                                     %{path: "/test.txt"},
                                                     _opts ->
        {:ok, %{content: [%{type: "text", text: "Hello from MCP!"}]}}
      end)

      {:ok, %{result: result}} =
        MCP.execute(
          %{connection_id: conn_id, tool: "read_file", arguments: %{path: "/test.txt"}},
          agent_id,
          opts
        )

      assert result.content
      assert hd(result.content).text == "Hello from MCP!"

      # Step 3: Terminate connection
      expect(Quoracle.MCP.AnubisMock, :stop, fn ^anubis_pid ->
        :ok
      end)

      {:ok, %{terminated: true}} =
        MCP.execute(%{connection_id: conn_id, terminate: true}, agent_id, opts)

      # Step 4: Verify cleanup - connection no longer available
      result = MCP.execute(%{connection_id: conn_id, tool: "read_file"}, agent_id, opts)
      assert {:error, :connection_not_found} = result
    end
  end
end
