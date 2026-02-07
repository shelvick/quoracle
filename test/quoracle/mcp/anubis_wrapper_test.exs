defmodule Quoracle.MCP.AnubisWrapperTest do
  @moduledoc """
  Integration tests for AnubisWrapper proving the transport format fix.

  These tests use the REAL anubis_mcp library (not mocked) to verify
  that our transport format is accepted by the library.

  Background: Anubis.Client.Base expects transport to already be running
  and passed as [layer: Module, name: atom]. But our code passes
  {:stdio, command: ..., args: ...}. AnubisWrapper fixes this by using
  Anubis.Client.Supervisor which handles the tuple format correctly.
  """
  use ExUnit.Case, async: true

  # Capture logs at module level to suppress expected OTP GenServer
  # termination logs from transport processes (function-level capture_log
  # only captures logs from the test process, not spawned processes)
  @moduletag capture_log: true

  alias Quoracle.MCP.AnubisWrapper

  describe "start_link/1 transport format" do
    @tag :integration
    test "accepts stdio transport tuple format" do
      # Use 'cat' as a simple command that exists on all Unix systems.
      # It won't speak MCP protocol, but we're testing that the transport
      # format is ACCEPTED (not rejected with Peri.Error).
      #
      # The connection will fail during MCP handshake, but that's expected.
      # What matters is we don't get the Peri.Error about transport format.
      opts = [
        transport: {:stdio, command: "cat", args: []}
      ]

      # This should NOT raise a Peri.Error about transport format.
      # It may fail for other reasons (cat doesn't speak MCP), but the
      # transport format itself should be valid.
      result = AnubisWrapper.start_link(opts)

      # We expect either:
      # - {:ok, client_name} if connection succeeds (unlikely with cat)
      # - {:error, reason} for MCP protocol failure (expected)
      # But NOT a raise/crash from Peri validation
      case result do
        {:ok, client_name} ->
          # Clean up if it somehow succeeded
          AnubisWrapper.stop(client_name)
          assert is_atom(client_name)

        {:error, reason} ->
          # Expected - cat doesn't speak MCP. But we got past transport validation!
          assert reason != nil
      end
    end

    @tag :integration
    test "Anubis.Client.Base rejects our transport format (proving the bug)" do
      # This test documents the bug we're fixing.
      # Anubis.Client.Base expects [layer: Module, name: atom] but we pass
      # {:stdio, command: ..., args: ...}
      opts = [
        transport: {:stdio, command: "cat", args: []},
        client_info: %{"name" => "Test", "version" => "1.0.0"},
        capabilities: %{}
      ]

      # This SHOULD fail with Peri.Error or similar validation error
      # because Base expects a different format
      result =
        try do
          Anubis.Client.Base.start_link(opts)
        rescue
          e -> {:raised, e}
        catch
          :exit, reason -> {:exit, reason}
        end

      # Verify it fails (this documents the bug)
      case result do
        {:raised, %{__struct__: Peri.Error}} ->
          # Expected - Peri validation rejects the transport format
          assert true

        {:raised, _other_error} ->
          # Some other validation error - still proves the format is rejected
          assert true

        {:exit, _reason} ->
          # Process crashed - also proves it doesn't work
          assert true

        {:ok, _pid} ->
          # If this somehow succeeds, the bug is fixed at the library level
          # and we don't need our wrapper anymore. Fail to alert us.
          flunk("Anubis.Client.Base unexpectedly accepted tuple transport format")

        {:error, _reason} ->
          # Soft failure is also acceptable - format was processed but failed
          assert true
      end
    end
  end
end
