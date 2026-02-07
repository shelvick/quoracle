defmodule Quoracle.MCPTestHelpers do
  @moduledoc """
  Test helpers for MCP action testing.

  Provides utilities for emitting telemetry events and Logger messages
  that simulate anubis_mcp behavior during testing.
  """

  require Logger

  @doc """
  Returns mock tool definitions for testing.
  """
  @spec mock_tools() :: [map()]
  def mock_tools do
    [
      %{
        name: "read_file",
        description: "Read contents of a file",
        inputSchema: %{
          type: "object",
          properties: %{path: %{type: "string"}},
          required: ["path"]
        }
      }
    ]
  end

  @doc """
  Returns a mock tool result for testing.
  """
  @spec mock_tool_result() :: map()
  def mock_tool_result do
    %{content: [%{type: "text", text: "File contents here"}]}
  end

  @doc """
  Emit telemetry transport error event as if from anubis_mcp.

  ## Examples

      # Simple error
      emit_transport_error(:exit_status)

      # Error with reason
      emit_transport_error(:exit_status, 1)
  """
  @spec emit_transport_error(atom(), term(), keyword()) :: :ok
  def emit_transport_error(error, reason \\ nil, opts \\ []) do
    metadata =
      if reason, do: %{error: error, reason: reason}, else: %{error: error}

    metadata =
      if collector = Keyword.get(opts, :collector),
        do: Map.put(metadata, :target_collector, collector),
        else: metadata

    :telemetry.execute([:anubis_mcp, :transport, :error], %{}, metadata)
  end

  @doc """
  Emit telemetry client error event as if from anubis_mcp.

  ## Examples

      emit_client_error(:decode_failed)
      emit_client_error(:decode_failed, collector: pid)
  """
  @spec emit_client_error(atom(), keyword()) :: :ok
  def emit_client_error(error, opts \\ []) do
    metadata = %{error: error}

    metadata =
      if collector = Keyword.get(opts, :collector),
        do: Map.put(metadata, :target_collector, collector),
        else: metadata

    :telemetry.execute([:anubis_mcp, :client, :error], %{}, metadata)
  end

  @doc """
  Log message with anubis_mcp domain for Logger handler testing.

  This simulates the raw stdio output that anubis_mcp logs when
  MCP servers emit non-JSON messages (like error messages).

  ## Examples

      log_anubis_message("CLI addon is not installed. Please install...")
  """
  @spec log_anubis_message(String.t()) :: :ok
  def log_anubis_message(message) do
    Logger.error(message, domain: [:anubis_mcp, :transport])
  end

  @doc """
  Log message with a non-anubis domain (should be filtered out).
  """
  @spec log_other_message(String.t()) :: :ok
  def log_other_message(message) do
    Logger.error(message, domain: [:other, :domain])
  end

  @doc """
  Log message exactly as anubis_mcp does - NO domain metadata.

  This simulates actual anubis_mcp behavior where Logging.log/3 calls
  Logger.debug/error/etc without setting a :domain key. Messages have
  format "MCP transport event: ..." or "MCP transport details: ...".

  Uses Logger.error to work in test env (Logger level: :error).
  """
  @spec log_anubis_message_realistic(String.t()) :: :ok
  def log_anubis_message_realistic(message) do
    # anubis_mcp does NOT set domain - just calls Logger directly
    # Using :error level to work in test env (level: :error config)
    Logger.error(message)
  end

  @doc """
  Generate a long message for truncation testing.
  """
  @spec long_message(pos_integer()) :: String.t()
  def long_message(length) do
    String.duplicate("x", length)
  end
end
