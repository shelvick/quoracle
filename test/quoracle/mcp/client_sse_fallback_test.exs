defmodule Quoracle.MCP.ClientSSEFallbackTest do
  @moduledoc """
  Integration test for MCP HTTP transport auto-negotiation.

  Tests that the client correctly falls back from streamable-http to SSE
  when connecting to servers using MCP protocol version 2024-11-05.

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
        agent_id: "test-sse-fallback-#{System.unique_integer([:positive])}",
        agent_pid: agent_pid,
        anubis_module: AnubisWrapper
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

  describe "SSE fallback integration" do
    @tag timeout: 30_000
    test "connects to MCP server using SSE fallback", context do
      # Skip if MCP server not available (integration test)
      if Map.get(context, :server_available) == false do
        :ok
      else
        client = context.client

        # This should:
        # 1. Try streamable-http first (fails with incompatible_transport)
        # 2. Fall back to SSE (succeeds)
        result = Client.connect(client, %{transport: :http, url: @mcp_url})

        case result do
          {:ok, connection} ->
            assert is_binary(connection.connection_id)
            assert is_list(connection.tools)
            # MCP server should expose tools
            assert connection.tools != []

            # Cleanup
            Client.terminate_connection(client, connection.connection_id)

          {:error, reason} ->
            flunk("Expected SSE fallback to succeed, got error: #{inspect(reason)}")
        end
      end
    end
  end
end
