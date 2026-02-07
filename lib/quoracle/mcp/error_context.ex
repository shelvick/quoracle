defmodule Quoracle.MCP.ErrorContext do
  @moduledoc """
  Per-connection error context collector for MCP initialization.

  Captures telemetry events and Logger output during connection attempts,
  providing actionable error context when initialization fails.

  ## Usage

      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      # ... connection attempt with potential errors ...

      context = ErrorContext.get_context(collector)
      # => [%{type: :transport_error, message: "exit_status: 1", ...}, ...]

      ErrorContext.stop(collector)

  ## Design

  Each connection attempt gets its own ErrorContext collector with unique
  handler IDs. This ensures test isolation (async: true compatible) and
  prevents stale error accumulation across connection attempts.

  Error context is captured from two sources:
  1. Telemetry events: Structured errors like decode_failed, exit_status
  2. Logger output: Raw stdio messages like "CLI addon not installed..."

  ## Logger Handler Strategy

  We use a single persistent :logger handler registered at application startup
  (or lazily on first use). The handler routes messages to active collectors
  via a Registry lookup. This avoids race conditions that occur when adding/
  removing handlers during async tests.
  """

  use GenServer
  require Logger

  @max_errors 20
  @max_message_length 200
  @handler_id :mcp_error_context_logger_handler
  @registry_name Quoracle.MCP.ErrorContext.Registry

  # Expose constants for LoggerHandler (avoids duplication)
  @doc false
  @spec max_errors() :: pos_integer()
  def max_errors, do: @max_errors

  @doc false
  @spec max_message_length() :: pos_integer()
  def max_message_length, do: @max_message_length

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start error context collector for a connection attempt.

  ## Options
    - `:connection_ref` - Required. Unique reference for this connection attempt.

  ## Examples

      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    connection_ref = Keyword.fetch!(opts, :connection_ref)
    GenServer.start_link(__MODULE__, connection_ref)
  end

  @doc """
  Get captured error context.

  Returns list of error maps with :type, :message, :timestamp, :source keys,
  sorted by timestamp (oldest first).

  ## Examples

      context = ErrorContext.get_context(collector)
      # => [%{type: :transport_error, message: "exit_status: 1", timestamp: 123, source: :telemetry}]
  """
  @spec get_context(pid()) :: [map()]
  def get_context(collector) do
    GenServer.call(collector, :get_context)
  end

  @doc """
  Stop collector and detach all handlers.

  ## Examples

      :ok = ErrorContext.stop(collector)
  """
  @spec stop(pid()) :: :ok
  def stop(collector) do
    GenServer.stop(collector, :normal)
  end

  @doc """
  Extract human-readable error message from nested supervisor failure tuples.

  Handles common patterns from OTP supervisor failures:
  - `{:shutdown, {:failed_to_start_child, _, {:error, msg}}}` → msg
  - `{:shutdown, {:failed_to_start_child, _, reason}}` → recursive extract
  - `{:noproc, _}` → "Process not found"
  - integer (exit code) → "Process exited with code N"
  - `:normal` / `:shutdown` → nil (not an error)
  - other → inspect(reason)

  ## Examples

      iex> extract_crash_reason({:shutdown, {:failed_to_start_child, Mod, {:error, "Command not found: npx"}}})
      "Command not found: npx"

      iex> extract_crash_reason(1)
      "Process exited with code 1"

      iex> extract_crash_reason(:normal)
      nil
  """
  @spec extract_crash_reason(term()) :: String.t() | nil

  # Normal/expected exits - not errors
  def extract_crash_reason(:normal), do: nil
  def extract_crash_reason(:shutdown), do: nil
  def extract_crash_reason({:shutdown, :normal}), do: nil

  # Supervisor failed_to_start_child with {:error, message}
  def extract_crash_reason({:shutdown, {:failed_to_start_child, _module, {:error, msg}}})
      when is_binary(msg),
      do: msg

  # Supervisor failed_to_start_child with other reason - recurse
  def extract_crash_reason({:shutdown, {:failed_to_start_child, _module, reason}}),
    do: extract_crash_reason(reason)

  # Generic {:error, msg} tuple
  def extract_crash_reason({:error, msg}) when is_binary(msg), do: msg

  # Generic shutdown with reason - recurse
  def extract_crash_reason({:shutdown, reason}), do: extract_crash_reason(reason)

  # Process not found (already dead when we tried to call)
  def extract_crash_reason({:noproc, _}), do: "Process not found"
  def extract_crash_reason(:noproc), do: "Process not found"

  # Port exit codes
  def extract_crash_reason(code) when is_integer(code),
    do: "Process exited with code #{code}"

  # Anubis MCP error struct
  def extract_crash_reason(%{__struct__: Anubis.MCP.Error, reason: reason}),
    do: "MCP error: #{inspect(reason)}"

  # Fallback - inspect the reason
  def extract_crash_reason(reason), do: inspect(reason)

  @doc false
  @spec ensure_handler_registered() :: :ok
  def ensure_handler_registered do
    # Check if handler already registered
    # Registry is started by the application supervision tree
    case :logger.get_handler_config(@handler_id) do
      {:ok, _} ->
        :ok

      {:error, {:not_found, _}} ->
        # Register the global handler (once, never removed)
        :logger.add_handler(
          @handler_id,
          Quoracle.MCP.ErrorContext.LoggerHandler,
          %{
            config: %{registry: @registry_name},
            level: :all
          }
        )

        :ok
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(connection_ref) do
    # Ensure the global Logger handler is registered
    ensure_handler_registered()

    # Generate unique telemetry handler ID for this connection
    telemetry_handler_id = "mcp_error_#{inspect(connection_ref)}"

    # Record start time to filter out events from concurrent tests
    # Use microsecond precision to prevent cross-test contamination in parallel tests
    start_time = System.monotonic_time(:microsecond)

    # Create ETS table for error storage (process-owned, auto-deleted on exit)
    table = :ets.new(:mcp_errors, [:set, :public])

    # Attach telemetry handlers (pass start_time for filtering)
    :telemetry.attach_many(
      telemetry_handler_id,
      [
        [:anubis_mcp, :transport, :error],
        [:anubis_mcp, :client, :error]
      ],
      &__MODULE__.handle_telemetry_event/4,
      %{table: table, collector: self(), start_time: start_time}
    )

    # Register this collector in the registry so the global Logger handler
    # can find it and route messages to our ETS table
    {:ok, _} = Registry.register(@registry_name, :collector, {table, start_time})

    {:ok,
     %{
       connection_ref: connection_ref,
       telemetry_handler_id: telemetry_handler_id,
       table: table,
       start_time: start_time
     }}
  end

  @impl true
  def handle_call(:get_context, _from, state) do
    # Retrieve all errors from ETS, sorted by insertion order (index)
    errors =
      :ets.tab2list(state.table)
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_, error} -> error end)

    {:reply, errors, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Detach telemetry handler
    :telemetry.detach(state.telemetry_handler_id)

    # Registry entry is automatically removed when this process terminates
    # The global Logger handler stays registered (intentionally - no race conditions)
    # ETS table is automatically deleted when this process terminates
    :ok
  end

  # ============================================================================
  # Telemetry Event Handler
  # ============================================================================

  @doc false
  @spec handle_telemetry_event([atom()], map(), map(), map()) :: :ok
  def handle_telemetry_event(event, _measurements, metadata, %{
        table: table,
        collector: collector,
        start_time: start_time
      }) do
    timestamp = System.monotonic_time(:microsecond)

    # Filter by target_collector if specified (test isolation)
    # If event has target_collector, only accept if it matches this collector
    target_matches =
      case Map.get(metadata, :target_collector) do
        nil -> true
        ^collector -> true
        _other -> false
      end

    # Filter out events from before this collector started (cross-test contamination)
    # Also filter out normal shutdowns - these aren't errors, just clean process exits
    if target_matches and timestamp >= start_time and not normal_shutdown?(metadata) do
      error_entry = %{
        type: format_event_type(event),
        message: format_metadata(metadata),
        timestamp: timestamp,
        source: :telemetry
      }

      # Store in ETS (counter as key for ordering)
      count = :ets.info(table, :size)

      if count < @max_errors do
        :ets.insert(table, {count, error_entry})
      end
    end

    :ok
  end

  defp format_event_type([:anubis_mcp, :transport, :error]), do: :transport_error
  defp format_event_type([:anubis_mcp, :client, :error]), do: :client_error
  defp format_event_type(event), do: List.last(event)

  defp format_metadata(%{error: error, reason: reason}) do
    message = "#{error}: #{inspect(reason)}"
    String.slice(message, 0, @max_message_length)
  end

  defp format_metadata(%{error: error}) do
    message = "#{error}"
    String.slice(message, 0, @max_message_length)
  end

  defp format_metadata(meta) do
    message = inspect(meta)
    String.slice(message, 0, @max_message_length)
  end

  # Filter out normal/expected shutdowns - these aren't errors, just clean process exits
  # These leak across parallel tests when MCP connections close normally
  defp normal_shutdown?(%{reason: :normal}), do: true
  defp normal_shutdown?(%{reason: :shutdown}), do: true
  defp normal_shutdown?(%{reason: {:shutdown, _}}), do: true
  defp normal_shutdown?(_), do: false
end

defmodule Quoracle.MCP.ErrorContext.LoggerHandler do
  @moduledoc false
  @behaviour :logger_handler

  # Use parent module's constants to avoid duplication
  @max_errors Quoracle.MCP.ErrorContext.max_errors()
  @max_message_length Quoracle.MCP.ErrorContext.max_message_length()

  @impl true
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(log_event, handler_config) do
    # Wrap everything in try/catch to prevent handler from crashing
    # and corrupting the :logger system
    try do
      do_log(log_event, handler_config)
    catch
      _, _ -> :ok
    end
  end

  defp do_log(%{msg: msg, meta: meta}, %{config: %{registry: registry}}) do
    message = format_log_message(msg)

    if message && mcp_message?(message, meta) do
      timestamp = System.monotonic_time(:microsecond)

      error_entry = %{
        type: :raw_output,
        message: String.slice(message, 0, @max_message_length),
        timestamp: timestamp,
        source: :logger
      }

      # Route to all active collectors via registry (filter by start_time)
      Registry.dispatch(registry, :collector, fn entries ->
        for {_pid, {table, start_time}} <- entries do
          # Filter out events from before this collector started
          if timestamp >= start_time do
            case :ets.info(table, :size) do
              :undefined -> :ok
              count when count < @max_errors -> :ets.insert(table, {count, error_entry})
              _ -> :ok
            end
          end
        end
      end)
    end

    :ok
  end

  # Fallback for events without expected structure
  defp do_log(_log_event, _config), do: :ok

  # Check if message is from MCP (by domain or message prefix)
  # anubis_mcp doesn't set domain metadata, so we check message content
  defp mcp_message?(message, meta) do
    domain = Map.get(meta, :domain, [])

    has_mcp_domain =
      match?([:elixir, :anubis_mcp | _], domain) or
        match?([:anubis_mcp | _], domain)

    has_mcp_prefix =
      String.starts_with?(message, "MCP ") or
        String.starts_with?(message, "[MCP ")

    has_mcp_domain or has_mcp_prefix
  end

  defp format_log_message({:string, msg}), do: IO.iodata_to_binary(msg)
  defp format_log_message({:report, report}), do: inspect(report)
  defp format_log_message(msg) when is_binary(msg), do: msg
  defp format_log_message(msg) when is_list(msg), do: IO.iodata_to_binary(msg)
  defp format_log_message(_), do: nil
end
