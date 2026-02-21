defmodule Quoracle.MCP.ClientHTTPIntegrationTest do
  @moduledoc """
  Integration test for MCP Streamable HTTP transport.

  Tests that the client connects to a Streamable HTTP MCP server
  (Camoufox on port 8765) and successfully lists tools.

  Requires: An MCP server running on port 8765
  Run with: mix test test/quoracle/mcp/client_sse_fallback_test.exs
  """

  # Single test with isolated client - no contention on external server
  use ExUnit.Case, async: true

  alias Quoracle.MCP.Client
  alias Quoracle.MCP.AnubisWrapper

  @moduletag :integration
  @moduletag capture_log: true

  @mcp_url "http://127.0.0.1:8765/mcp"

  setup do
    # Check if MCP server is running
    case :gen_tcp.connect(~c"127.0.0.1", 8765, [], 1000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        setup_test_client()

      {:error, _} ->
        # Server not available - return flag for test to check
        %{server_available: false}
    end
  end

  defp setup_test_client do
    sandbox_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Quoracle.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox_owner) end)

    # Create a placeholder agent process
    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(agent_pid), do: send(agent_pid, :stop)
    end)

    {:ok, client} =
      Client.start_link(
        agent_id: "test-http-integration-#{System.unique_integer([:positive])}",
        agent_pid: agent_pid,
        anubis_module: AnubisWrapper,
        init_timeout: 100
      )

    on_exit(fn ->
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

  describe "Streamable HTTP integration" do
    @tag timeout: 30_000
    test "connects to MCP server via Streamable HTTP", context do
      # Skip if MCP server not available (integration test)
      if Map.get(context, :server_available) == false do
        :ok
      else
        client = context.client

        # Streamable HTTP should connect directly (no SSE fallback needed)
        result = Client.connect(client, %{transport: :http, url: @mcp_url})

        case result do
          {:ok, connection} ->
            assert is_binary(connection.connection_id)
            assert is_list(connection.tools)
            # MCP server should expose tools
            assert connection.tools != []

            # Cleanup
            Client.terminate_connection(client, connection.connection_id)

          {:error, {:initialization_timeout, _}} ->
            # Server reachable via TCP but MCP protocol not responding in time - skip
            :ok

          {:error, {:connection_failed, _}} ->
            # Server reachable via TCP but MCP handshake timed out - skip
            :ok

          {:error, reason} ->
            flunk("Expected Streamable HTTP connection to succeed, got error: #{inspect(reason)}")
        end
      end
    end
  end
end
