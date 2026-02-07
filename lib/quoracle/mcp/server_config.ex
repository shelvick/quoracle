defmodule Quoracle.MCP.ServerConfig do
  @moduledoc """
  Configuration access for MCP servers.

  Servers are defined in config/config.exs and accessed at runtime.
  Supports both stdio (subprocess) and HTTP (remote) transports.
  """

  @type transport :: :stdio | :http

  @type server_config :: %{
          name: String.t(),
          transport: transport(),
          command: String.t() | nil,
          url: String.t() | nil,
          auth: map() | nil,
          timeout: pos_integer()
        }

  @doc """
  Get all configured MCP servers.
  """
  @spec list_servers() :: [server_config()]
  def list_servers do
    Application.get_env(:quoracle, :mcp_servers, [])
  end

  @doc """
  Get a specific server by name.
  """
  @spec get_server(String.t()) :: {:ok, server_config()} | {:error, :not_found}
  def get_server(name) do
    case Enum.find(list_servers(), &(&1.name == name)) do
      nil -> {:error, :not_found}
      config -> {:ok, config}
    end
  end

  @doc """
  Check if a server is configured.
  """
  @spec server_exists?(String.t()) :: boolean()
  def server_exists?(name) do
    Enum.any?(list_servers(), &(&1.name == name))
  end
end
