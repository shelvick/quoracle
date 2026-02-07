defmodule Quoracle.Actions.MCP do
  @moduledoc """
  MCP tool calling action with connection lifecycle management.

  Supports three modes:
  1. Connect: Spawn/connect to MCP server, list tools, return connection_id
  2. Call: Use existing connection to call a specific tool
  3. Terminate: Close a connection explicitly

  Like execute_shell with check_id pattern.
  """

  alias Quoracle.MCP.Client, as: MCPClient
  alias Quoracle.Utils.ResponseTruncator

  @default_timeout 30_000

  @type params :: map()
  @type agent_id :: String.t()
  @type opts :: keyword()

  @doc """
  Execute MCP action following 3-arity signature.

  ## Modes

  ### Connect (first call to a server)
  params: %{transport: :stdio, command: "npx ..."}
  params: %{transport: :http, url: "https://..."}

  Returns: {:ok, %{connection_id: "...", server_info: %{}, tools: [...]}}

  ### Call tool (subsequent calls)
  params: %{connection_id: "...", tool: "read_file", arguments: %{path: "..."}}

  Returns: {:ok, %{connection_id: "...", result: %{...}}}

  ### Terminate connection
  params: %{connection_id: "...", terminate: true}

  Returns: {:ok, %{connection_id: "...", terminated: true}}
  """
  @spec execute(params(), agent_id(), opts()) :: {:ok, map()} | {:error, atom()}

  # XOR validation: can't have both transport AND connection_id
  def execute(%{transport: _, connection_id: _}, _agent_id, _opts) do
    {:error, :xor_violation}
  end

  # Mode 1: Connect (stdio) - requires command
  def execute(%{transport: :stdio, command: _} = params, _agent_id, opts)
      when not is_map_key(params, :connection_id) do
    # Add default cwd if not provided
    params = Map.put_new(params, :cwd, File.cwd!())
    do_connect(params, opts)
  end

  # Mode 1: Connect (HTTP) - requires url
  def execute(%{transport: :http, url: _} = params, _agent_id, opts)
      when not is_map_key(params, :connection_id) do
    do_connect(params, opts)
  end

  # Mode 2: Call tool (connection_id + tool, no terminate)
  def execute(%{connection_id: conn_id, tool: tool_name} = params, _agent_id, opts)
      when not is_map_key(params, :terminate) do
    mcp_client = get_mcp_client(opts)
    arguments = Map.get(params, :arguments, %{})
    timeout = Map.get(params, :timeout, @default_timeout)

    case MCPClient.call_tool(mcp_client, conn_id, tool_name, arguments, timeout: timeout) do
      {:ok, result} ->
        # Truncate result to prevent OOM from massive MCP responses (screenshots, DOM)
        truncated_result = truncate_mcp_result(result.result)

        {:ok,
         %{
           connection_id: conn_id,
           result: truncated_result
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Mode 3: Terminate
  def execute(%{connection_id: conn_id, terminate: true}, _agent_id, opts) do
    mcp_client = get_mcp_client(opts)

    case MCPClient.terminate_connection(mcp_client, conn_id) do
      :ok ->
        {:ok, %{connection_id: conn_id, terminated: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Invalid params - catch all
  def execute(_params, _agent_id, _opts) do
    {:error, :invalid_params}
  end

  # Private helpers

  defp do_connect(params, opts) do
    mcp_client = get_mcp_client(opts)

    case MCPClient.connect(mcp_client, params) do
      {:ok, result} ->
        {:ok,
         %{
           connection_id: result.connection_id,
           tools: result.tools
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_mcp_client(opts) do
    Keyword.fetch!(opts, :mcp_client)
  end

  # Truncate MCP result - handles strings directly, maps recursively
  defp truncate_mcp_result(result) when is_binary(result) do
    ResponseTruncator.truncate_if_large(result)
  end

  defp truncate_mcp_result(result) when is_map(result) do
    ResponseTruncator.truncate_map_fields(result)
  end

  defp truncate_mcp_result(result) when is_list(result) do
    Enum.map(result, &truncate_mcp_result/1)
  end

  defp truncate_mcp_result(result), do: result
end
