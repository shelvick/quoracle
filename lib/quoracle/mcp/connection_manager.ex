defmodule Quoracle.MCP.ConnectionManager do
  @moduledoc """
  Handles MCP connection establishment and lifecycle management.
  Extracted from MCP.Client to reduce module size.
  """

  require Logger

  alias Quoracle.MCP.ErrorContext
  alias Quoracle.Security.SecretResolver

  # Client info for MCP protocol handshake - unique per connection to avoid ETS table collisions
  # (anubis_mcp uses client_info["name"] as part of named ETS table for tool validator caching)
  defp unique_client_info do
    %{"name" => "Quoracle_#{System.unique_integer([:positive])}", "version" => "1.0.0"}
  end

  # MCP initialization polling settings
  @init_poll_interval_ms 50

  @doc """
  Establish a new MCP connection via stdio transport.
  """
  @spec establish_stdio(map(), map()) :: {:ok, map()} | {:error, term()}
  def establish_stdio(params, state) do
    command = Map.fetch!(params, :command)
    cwd = Map.get(params, :cwd)
    [executable | args] = parse_shell_args(command)

    transport_opts = [command: executable, args: args]
    transport_opts = if cwd, do: Keyword.put(transport_opts, :cwd, cwd), else: transport_opts

    anubis_opts = [
      transport: {:stdio, transport_opts},
      client_info: unique_client_info(),
      capabilities: %{}
    ]

    start_and_list_tools(:stdio, command, anubis_opts, state)
  end

  @doc """
  Establish a new MCP connection via HTTP transport.
  Tries streamable-http first, falls back to SSE on protocol mismatch.
  """
  @spec establish_http(map(), map()) :: {:ok, map()} | {:error, term()}
  def establish_http(params, state) do
    url = Map.fetch!(params, :url)
    {:ok, resolved_auth} = resolve_auth_secrets(Map.get(params, :auth))

    # Try streamable-http first (MCP 2025-03-26+), fall back to SSE (2024-11-05) on protocol mismatch
    streamable_opts = build_http_anubis_opts(:streamable_http, url, resolved_auth)

    case start_and_list_tools(:http, url, streamable_opts, state) do
      {:ok, connection} ->
        {:ok, connection}

      {:error,
       {:shutdown,
        {:failed_to_start_child, _, %Anubis.MCP.Error{reason: :incompatible_transport}}}} ->
        # Protocol version mismatch - server uses 2024-11-05, retry with SSE
        Logger.debug("MCP server uses legacy protocol, falling back to SSE transport")
        sse_opts = build_http_anubis_opts(:sse, url, resolved_auth)
        start_and_list_tools(:http, url, sse_opts, state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate a unique connection ID.
  """
  @spec generate_connection_id() :: String.t()
  def generate_connection_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Stop a connection gracefully.
  """
  @spec stop_connection(map(), module()) :: :ok
  def stop_connection(connection, anubis_module) do
    try do
      anubis_module.stop(connection.anubis_client)
    catch
      :exit, _ -> :ok
    end
  end

  @doc """
  Parse shell command string into list of arguments, respecting quotes.
  Handles: double quotes, single quotes, escaped characters.
  Example: ~s(cmd --opt "arg with spaces") -> ["cmd", "--opt", "arg with spaces"]
  """
  @spec parse_shell_args(String.t()) :: [String.t()]
  def parse_shell_args(command) when is_binary(command) do
    command
    |> String.trim()
    |> do_parse_args([], "", nil)
    |> Enum.reverse()
  end

  # Private implementation

  defp build_http_anubis_opts(:streamable_http, url, resolved_auth) do
    opts = [
      transport: {:streamable_http, base_url: url},
      client_info: unique_client_info(),
      capabilities: %{}
    ]

    if resolved_auth, do: Keyword.put(opts, :auth, resolved_auth), else: opts
  end

  defp build_http_anubis_opts(:sse, url, resolved_auth) do
    # Parse URL to extract base_url (scheme://host:port)
    # Note: SSE endpoint is at root /sse, not under the streamable-http path
    uri = URI.parse(url)
    base_url = "#{uri.scheme}://#{uri.host}#{if uri.port, do: ":#{uri.port}", else: ""}"

    opts = [
      transport: {:sse, server: [base_url: base_url, base_path: "/", sse_path: "/sse"]},
      client_info: unique_client_info(),
      capabilities: %{}
    ]

    if resolved_auth, do: Keyword.put(opts, :auth, resolved_auth), else: opts
  end

  # Shared logic for starting anubis client and listing tools
  # v2.0: Now captures error context during connection attempts for actionable timeout diagnostics
  # v3.0: Monitor + DOWN message capture for crash reason propagation
  defp start_and_list_tools(transport, command_or_url, anubis_opts, state) do
    anubis_module = state.anubis_module

    # Start error context collector for this connection attempt
    connection_ref = make_ref()
    {:ok, error_collector} = ErrorContext.start_link(connection_ref: connection_ref)

    # Temporarily trap exits to catch failures from linked anubis process
    old_trap = Process.flag(:trap_exit, true)

    try do
      case anubis_module.start_link(anubis_opts) do
        {:ok, client_pid} ->
          # v3.0: Monitor immediately after start_link to catch crashes in handle_continue
          init_monitor = Process.monitor(client_pid)

          # Wait for MCP handshake to complete before calling list_tools
          # (anubis_mcp uses async initialization - start_link returns before handshake)
          case wait_for_initialization(
                 anubis_module,
                 client_pid,
                 state.init_timeout,
                 init_monitor
               ) do
            :ok ->
              # v3.0: Demonitor init monitor with :flush before creating connection monitor
              Process.demonitor(init_monitor, [:flush])

              case anubis_module.list_tools(client_pid) do
                {:ok, tools} ->
                  # Monitor the anubis client for crash detection (Bug 1+6 fix)
                  monitor_ref = Process.monitor(client_pid)

                  {:ok,
                   %{
                     id: generate_connection_id(),
                     transport: transport,
                     command_or_url: command_or_url,
                     anubis_client: client_pid,
                     monitor_ref: monitor_ref,
                     tools: tools,
                     connected_at: DateTime.utc_now(),
                     last_used_at: DateTime.utc_now()
                   }}

                {:error, reason} ->
                  anubis_module.stop(client_pid)
                  {:error, reason}
              end

            {:error, :initialization_timeout} ->
              # v2.0: Include captured error context in timeout error
              Process.demonitor(init_monitor, [:flush])
              context = ErrorContext.get_context(error_collector)
              anubis_module.stop(client_pid)
              {:error, {:initialization_timeout, context: context}}

            {:error, {:client_crashed, reason}} ->
              # v3.0: Client crashed during initialization - extract readable message
              Process.demonitor(init_monitor, [:flush])
              message = ErrorContext.extract_crash_reason(reason)
              {:error, {:connection_failed, message}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    catch
      # Anubis transport may exit instead of returning {:error, reason}
      _kind, reason ->
        message = ErrorContext.extract_crash_reason(reason)
        {:error, {:connection_failed, message}}
    after
      # Restore original trap_exit setting and clean up error collector
      Process.flag(:trap_exit, old_trap)
      ErrorContext.stop(error_collector)
    end
  end

  # Poll for MCP handshake completion (server_capabilities set)
  # v3.0: Now accepts monitor ref to detect crashes during initialization
  defp wait_for_initialization(anubis_module, client_pid, init_timeout, init_monitor) do
    deadline = System.monotonic_time(:millisecond) + init_timeout
    poll_for_capabilities(anubis_module, client_pid, deadline, init_monitor)
  end

  # Poll for MCP handshake completion
  # v3.0: Uses receive...after instead of Process.sleep for proper synchronization
  # This allows detecting crashes via DOWN messages during polling
  defp poll_for_capabilities(anubis_module, client_pid, deadline, init_monitor) do
    # First check if client already crashed (DOWN message in mailbox)
    case check_for_crash(init_monitor) do
      {:crashed, reason} ->
        {:error, {:client_crashed, reason}}

      :alive ->
        # Client still alive, check capabilities
        case anubis_module.get_server_capabilities(client_pid) do
          nil ->
            remaining = deadline - System.monotonic_time(:millisecond)

            if remaining > 0 do
              # Wait for either DOWN message or poll interval, whichever comes first
              wait_time = min(@init_poll_interval_ms, remaining)

              receive do
                {:DOWN, ^init_monitor, :process, _pid, reason} ->
                  {:error, {:client_crashed, reason}}
              after
                wait_time ->
                  poll_for_capabilities(anubis_module, client_pid, deadline, init_monitor)
              end
            else
              {:error, :initialization_timeout}
            end

          _capabilities ->
            :ok
        end
    end
  end

  # Check mailbox for DOWN message without blocking
  defp check_for_crash(init_monitor) do
    receive do
      {:DOWN, ^init_monitor, :process, _pid, reason} -> {:crashed, reason}
    after
      0 -> :alive
    end
  end

  defp resolve_auth_secrets(nil), do: {:ok, nil}

  defp resolve_auth_secrets(auth) when is_map(auth) do
    {:ok, resolved, _secrets_used} = SecretResolver.resolve_params(auth)
    {:ok, map_to_keyword(resolved)}
  end

  # Convert map with potentially string keys to keyword list with atom keys
  # Auth keys come from MCP server config (finite set), not user input
  defp map_to_keyword(map) do
    Enum.map(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      {key, v}
    end)
    |> Keyword.new()
  end

  # Shell argument parsing

  defp do_parse_args("", acc, "", nil), do: acc
  defp do_parse_args("", acc, current, nil), do: [current | acc]

  # Escape sequences
  defp do_parse_args(<<?\\, char, rest::binary>>, acc, current, in_quote) do
    do_parse_args(rest, acc, current <> <<char>>, in_quote)
  end

  # Quote handling
  defp do_parse_args(<<?", rest::binary>>, acc, current, nil),
    do: do_parse_args(rest, acc, current, ?")

  defp do_parse_args(<<?', rest::binary>>, acc, current, nil),
    do: do_parse_args(rest, acc, current, ?')

  defp do_parse_args(<<?", rest::binary>>, acc, current, ?"),
    do: do_parse_args(rest, acc, current, nil)

  defp do_parse_args(<<?', rest::binary>>, acc, current, ?'),
    do: do_parse_args(rest, acc, current, nil)

  # Whitespace outside quotes
  defp do_parse_args(<<char, rest::binary>>, acc, "", nil) when char in ~c[ \t\n],
    do: do_parse_args(rest, acc, "", nil)

  defp do_parse_args(<<char, rest::binary>>, acc, current, nil) when char in ~c[ \t\n],
    do: do_parse_args(rest, [current | acc], "", nil)

  # Regular characters
  defp do_parse_args(<<char, rest::binary>>, acc, current, in_quote),
    do: do_parse_args(rest, acc, current <> <<char>>, in_quote)
end
