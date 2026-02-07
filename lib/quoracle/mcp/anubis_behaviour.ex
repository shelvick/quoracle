defmodule Quoracle.MCP.AnubisBehaviour do
  @moduledoc """
  Behaviour defining the interface for anubis_mcp client operations.

  This behaviour abstracts the anubis_mcp library for testing purposes,
  allowing mocked implementations in tests while using the real library
  in production.
  """

  @typedoc "Transport configuration for MCP connection"
  @type transport ::
          {:stdio, keyword()}
          | {:streamable_http, keyword()}

  @typedoc "Client reference - either PID or registered name"
  @type client_ref :: pid() | atom()

  @typedoc "Tool definition returned by MCP server"
  @type tool :: map()

  @typedoc "Options for call_tool"
  @type call_opts :: [timeout: pos_integer()]

  @doc """
  Starts a new anubis_mcp client connection.

  ## Options
    - `:transport` - Transport configuration (stdio or streamable_http)
    - `:auth` - Optional authentication configuration

  Returns `{:ok, client_ref}` on success or `{:error, reason}` on failure.
  """
  @callback start_link(opts :: keyword()) :: {:ok, client_ref()} | {:error, term()}

  @doc """
  Lists tools available from the connected MCP server.

  Returns `{:ok, tools}` with list of tool definitions or `{:error, reason}`.
  """
  @callback list_tools(client :: client_ref()) :: {:ok, [tool()]} | {:error, term()}

  @doc """
  Calls a tool on the MCP server.

  ## Parameters
    - `client` - The anubis client reference (pid or registered name)
    - `tool_name` - Name of the tool to call
    - `arguments` - Tool arguments as a map
    - `opts` - Options including `:timeout`

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @callback call_tool(
              client :: client_ref(),
              tool_name :: String.t(),
              arguments :: map(),
              opts :: call_opts()
            ) :: {:ok, term()} | {:error, term()}

  @doc """
  Stops an anubis client connection.

  Returns `:ok` on success.
  """
  @callback stop(client :: client_ref()) :: :ok

  @doc """
  Gets the server capabilities after initialization.

  Returns `nil` if initialization hasn't completed yet, or the capabilities map.
  Used to check if the MCP handshake has finished.
  """
  @callback get_server_capabilities(client :: client_ref()) :: map() | nil
end
