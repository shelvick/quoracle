defmodule Quoracle.MCP.Client do
  @moduledoc """
  Per-agent MCP connection manager.

  Manages connections to MCP servers (stdio and HTTP), caches tool lists,
  deduplicates connections by command/url, and cleans up on agent termination.
  """

  use GenServer
  require Logger

  alias Quoracle.MCP.ConnectionManager

  @default_timeout 30_000

  # Default to our wrapper module (injectable for testing)
  # Note: AnubisWrapper uses Anubis.Client.Supervisor to properly start transport+client
  @default_anubis_module Quoracle.MCP.AnubisWrapper

  # MCP initialization polling settings (injectable via :init_timeout option)
  @init_timeout_ms 10_000

  # Client API

  @doc """
  Start MCP client for an agent.

  ## Options
    - `:agent_id` - Required. Unique identifier for the agent.
    - `:agent_pid` - Required. PID of the owning agent process.
    - `:anubis_module` - Optional. Module implementing anubis client (for testing).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    # Validate required options are present
    _agent_id = Keyword.fetch!(opts, :agent_id)
    _agent_pid = Keyword.fetch!(opts, :agent_pid)

    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Connect to MCP server, list tools, return connection info.

  ## Parameters
    - `client` - PID of the MCP client GenServer
    - `params` - Connection parameters:
      - `%{transport: :stdio, command: "cmd args"}` for stdio transport
      - `%{transport: :http, url: "http://..."}` for HTTP transport
      - Optional `:auth` map with authentication (supports {{SECRET:name}} templates)
    - `opts` - Options:
      - `:timeout` - GenServer call timeout in ms (default: 30000)
  """
  @spec connect(pid(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def connect(client, params, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(client, {:connect, params}, timeout)
  end

  @doc """
  Call a tool on an existing connection.

  ## Parameters
    - `client` - PID of the MCP client GenServer
    - `connection_id` - ID returned from connect/2
    - `tool_name` - Name of the tool to call
    - `arguments` - Tool arguments as a map
    - `opts` - Options:
      - `:timeout` - Timeout in ms for both GenServer call and tool execution (default: 30000)
  """
  @spec call_tool(pid(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def call_tool(client, connection_id, tool_name, arguments, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(client, {:call_tool, connection_id, tool_name, arguments, opts}, timeout)
  end

  @doc """
  Terminate a specific connection.
  """
  @spec terminate_connection(pid(), String.t()) :: :ok | {:error, :not_found}
  def terminate_connection(client, connection_id) do
    GenServer.call(client, {:terminate_connection, connection_id})
  end

  @doc """
  List all active connections.
  """
  @spec list_connections(pid()) :: [map()]
  def list_connections(client) do
    GenServer.call(client, :list_connections)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    agent_pid = Keyword.fetch!(opts, :agent_pid)
    agent_id = Keyword.fetch!(opts, :agent_id)
    anubis_module = Keyword.get(opts, :anubis_module, @default_anubis_module)
    sandbox_owner = Keyword.get(opts, :sandbox_owner)
    init_timeout = Keyword.get(opts, :init_timeout, @init_timeout_ms)

    # Monitor agent for cleanup
    Process.monitor(agent_pid)

    {:ok,
     %{
       agent_id: agent_id,
       agent_pid: agent_pid,
       anubis_module: anubis_module,
       sandbox_owner: sandbox_owner,
       init_timeout: init_timeout,
       connections: %{},
       # Deduplication: command/url -> connection_id
       connection_lookup: %{},
       # Monitor refs for anubis clients: monitor_ref -> connection_id
       anubis_monitors: %{}
     }, {:continue, :setup_sandbox}}
  end

  @impl true
  def handle_continue(:setup_sandbox, state) do
    # Allow DB access in test mode
    if state.sandbox_owner do
      Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, state.sandbox_owner, self())
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:connect, params}, _from, state) do
    transport = Map.fetch!(params, :transport)
    command_or_url = get_command_or_url(params)

    # DEBUG: Log connection state
    Logger.warning(
      "MCP.Client #{inspect(self())} connect: existing_connections=#{inspect(Map.keys(state.connections))}, lookup=#{inspect(state.connection_lookup)}"
    )

    # Check for existing connection (deduplication)
    case Map.get(state.connection_lookup, command_or_url) do
      nil ->
        # New connection
        case establish_connection(transport, params, state) do
          {:ok, connection} ->
            new_state = add_connection(state, connection, command_or_url)
            {:reply, {:ok, format_connection_result(connection)}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      existing_id ->
        # Reuse existing connection
        connection = Map.get(state.connections, existing_id)
        {:reply, {:ok, format_connection_result(connection)}, state}
    end
  end

  @impl true
  def handle_call({:call_tool, connection_id, tool_name, arguments, opts}, _from, state) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # DEBUG: Log connection lookup
    Logger.warning(
      "MCP.Client #{inspect(self())} call_tool: looking for #{connection_id} in #{inspect(Map.keys(state.connections))}"
    )

    case Map.get(state.connections, connection_id) do
      nil ->
        Logger.error(
          "MCP.Client #{inspect(self())} call_tool: CONNECTION NOT FOUND! connection_id=#{connection_id}, available=#{inspect(Map.keys(state.connections))}"
        )

        {:reply, {:error, :connection_not_found}, state}

      connection ->
        anubis_module = state.anubis_module

        case anubis_module.call_tool(
               connection.anubis_client,
               tool_name,
               arguments,
               timeout: timeout
             ) do
          {:ok, result} ->
            # Update last_used_at
            updated_connection = %{connection | last_used_at: DateTime.utc_now()}
            new_state = put_in(state.connections[connection_id], updated_connection)
            {:reply, {:ok, %{connection_id: connection_id, result: result}}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:terminate_connection, connection_id}, _from, state) do
    case Map.get(state.connections, connection_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      connection ->
        # Stop the anubis client
        stop_connection(connection, state.anubis_module)

        # Demonitor to prevent late :DOWN messages
        Process.demonitor(connection.monitor_ref, [:flush])

        # Remove from state (all three maps)
        new_state = %{
          state
          | connections: Map.delete(state.connections, connection_id),
            connection_lookup: remove_from_lookup(state.connection_lookup, connection_id),
            anubis_monitors: Map.delete(state.anubis_monitors, connection.monitor_ref)
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:list_connections, _from, state) do
    connections =
      state.connections
      |> Enum.map(fn {_id, conn} ->
        %{
          id: conn.id,
          transport: conn.transport,
          tools: conn.tools,
          connected_at: conn.connected_at
        }
      end)

    {:reply, connections, state}
  end

  # Clean up when agent dies
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{agent_pid: pid} = state) do
    cleanup_all_connections(state)
    # Clear connections so terminate/2 doesn't try to clean up again
    {:stop, :normal, %{state | connections: %{}}}
  end

  # Clean up when anubis client crashes (Bug 1+6 fix)
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.anubis_monitors, ref) do
      nil ->
        # Unknown monitor, ignore
        {:noreply, state}

      connection_id ->
        # Remove the dead connection
        connection = Map.get(state.connections, connection_id)

        new_state = %{
          state
          | connections: Map.delete(state.connections, connection_id),
            connection_lookup: remove_from_lookup(state.connection_lookup, connection_id),
            anubis_monitors: Map.delete(state.anubis_monitors, ref)
        }

        transport = connection && connection.transport

        Logger.warning(
          "MCP connection #{connection_id} (#{transport}) removed: anubis client crashed"
        )

        {:noreply, new_state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_all_connections(state)
    :ok
  end

  # Private Functions

  defp get_command_or_url(%{transport: :stdio, command: command}), do: command
  defp get_command_or_url(%{transport: :http, url: url}), do: url

  defp establish_connection(:stdio, params, state) do
    ConnectionManager.establish_stdio(params, state)
  end

  defp establish_connection(:http, params, state) do
    ConnectionManager.establish_http(params, state)
  end

  defp add_connection(state, connection, command_or_url) do
    %{
      state
      | connections: Map.put(state.connections, connection.id, connection),
        connection_lookup: Map.put(state.connection_lookup, command_or_url, connection.id),
        anubis_monitors: Map.put(state.anubis_monitors, connection.monitor_ref, connection.id)
    }
  end

  defp remove_from_lookup(lookup, connection_id) do
    lookup
    |> Enum.reject(fn {_k, v} -> v == connection_id end)
    |> Map.new()
  end

  defp format_connection_result(connection) do
    %{
      connection_id: connection.id,
      tools: connection.tools
    }
  end

  defp stop_connection(connection, anubis_module) do
    ConnectionManager.stop_connection(connection, anubis_module)
  end

  defp cleanup_all_connections(state) do
    Enum.each(state.connections, fn {_id, connection} ->
      stop_connection(connection, state.anubis_module)
    end)
  end

  @doc false
  # Delegate to ConnectionManager for backward compatibility
  @spec parse_shell_args(String.t()) :: [String.t()]
  def parse_shell_args(command), do: ConnectionManager.parse_shell_args(command)
end
