defmodule Quoracle.MCP.ClientRawOutputTest do
  @moduledoc """
  Isolated test for R20: context includes raw server output.

  This test verifies that raw server output (like CLI addon messages) is
  captured in the error context. Requires serial execution because Logger
  handler registration is inherently global and has race condition with
  first poll in parallel tests.

  WorkGroupID: feat-mcp-error-context-20251216
  """

  # ErrorContext uses Registry + microsecond timestamps for test isolation
  use ExUnit.Case, async: true

  import Hammox

  alias Quoracle.MCP.Client

  @moduletag capture_log: true

  setup :verify_on_exit!

  # Create placeholder process for agent_pid/anubis_pid
  defp placeholder_process do
    spawn(fn ->
      receive do
        :never -> :ok
      end
    end)
  end

  describe "R20: context includes raw server output" do
    test "captures raw server output like CLI addon messages" do
      # [INTEGRATION] WHEN MCP server outputs non-JSON text THEN text captured in context
      agent_pid = placeholder_process()

      {:ok, client} =
        Client.start_link(
          agent_id: "test-agent-r20",
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

      # Simulate raw server output via Logger on first poll (deterministic, no timing)
      # anubis_mcp logs raw output with domain [:anubis_mcp, :transport]
      {:ok, logged_agent} = Agent.start_link(fn -> false end)

      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid ->
        # Log raw output on first capability check (during polling)
        unless Agent.get(logged_agent, & &1) do
          Agent.update(logged_agent, fn _ -> true end)

          require Logger

          # Use Logger.error because test.exs has level: :error
          Logger.error("CLI addon is not installed. Please install the CLI addon first.",
            domain: [:anubis_mcp, :transport]
          )
        end

        # Always return nil to keep polling until timeout
        nil
      end)

      on_exit(fn ->
        if Process.alive?(logged_agent) do
          try do
            Agent.stop(logged_agent)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      expect(Quoracle.MCP.AnubisMock, :stop, fn ^anubis_pid -> :ok end)

      result =
        Client.connect(client, %{transport: :stdio, command: "npx @modelcontextprotocol/server"})

      # v2.0: Raw output should be captured in context
      assert {:error, {:initialization_timeout, context: context}} = result
      assert is_list(context)

      # Find the raw output entry containing CLI addon message
      # Multiple raw_output entries may exist; find the specific one we logged
      raw_entry =
        Enum.find(context, fn entry ->
          entry.type == :raw_output and entry.message =~ "CLI addon"
        end)

      assert raw_entry != nil,
             "Expected raw_output entry with 'CLI addon' in context: #{inspect(context)}"
    end
  end
end
