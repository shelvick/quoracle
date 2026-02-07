defmodule Quoracle.MCP.AnubisWrapper do
  @moduledoc """
  Wrapper around anubis_mcp library providing a simplified interface.

  The anubis_mcp library uses a Supervisor-based architecture that starts
  both transport and client processes. This wrapper provides the simpler
  interface expected by MCP.Client:
  - start_link/1 returns {:ok, client_ref}
  - list_tools/1 takes client_ref
  - call_tool/4 takes client_ref
  - stop/1 takes client_ref

  The client_ref is the registered name of the client process, which can
  be used with Anubis.Client.Base functions.
  """

  @behaviour Quoracle.MCP.AnubisBehaviour

  @default_protocol_version "2024-11-05"

  @impl true
  @spec start_link(keyword()) :: {:ok, atom()} | {:error, term()}
  def start_link(opts) do
    # Generate unique names for client and supervisor (must be different!)
    unique_id = System.unique_integer([:positive, :monotonic])
    client_name = :"anubis_client_#{unique_id}"
    supervisor_name = :"anubis_sup_#{unique_id}"

    # Extract transport from opts
    transport = Keyword.fetch!(opts, :transport)

    # Build Supervisor opts - name: is for supervisor, client_name: is for client
    supervisor_opts = [
      name: supervisor_name,
      client_name: client_name,
      transport: transport,
      client_info: Keyword.get(opts, :client_info, %{"name" => "Quoracle", "version" => "1.0.0"}),
      capabilities: Keyword.get(opts, :capabilities, %{}),
      protocol_version: Keyword.get(opts, :protocol_version, @default_protocol_version)
    ]

    case Anubis.Client.Supervisor.start_link(client_name, supervisor_opts) do
      {:ok, _supervisor_pid} ->
        # Return the client name - this is what callers use for subsequent operations
        {:ok, client_name}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec list_tools(atom()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(client_name) when is_atom(client_name) do
    case Anubis.Client.Base.list_tools(client_name) do
      {:ok, response} ->
        # anubis_mcp returns %Anubis.MCP.Response{} struct
        # Extract tools from response.result (which has string keys)
        tools = Map.get(response.result, "tools", [])
        {:ok, tools}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  @spec call_tool(atom(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call_tool(client_name, tool_name, arguments, opts \\ []) when is_atom(client_name) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    Anubis.Client.Base.call_tool(client_name, tool_name, arguments, timeout: timeout)
  end

  @impl true
  @spec get_server_capabilities(atom()) :: map() | nil
  def get_server_capabilities(client_name) when is_atom(client_name) do
    Anubis.Client.Base.get_server_capabilities(client_name)
  end

  @impl true
  @spec stop(atom()) :: :ok
  def stop(client_name) when is_atom(client_name) do
    # Derive supervisor name from client name pattern
    # client_name: :anubis_client_123 -> supervisor_name: :anubis_sup_123
    # Use to_existing_atom since we created this atom in start_link
    supervisor_name =
      client_name
      |> Atom.to_string()
      |> String.replace("anubis_client_", "anubis_sup_")
      |> String.to_existing_atom()

    case Process.whereis(supervisor_name) do
      nil ->
        :ok

      pid ->
        try do
          Supervisor.stop(pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end

        :ok
    end
  end
end
