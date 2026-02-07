defmodule Quoracle.Actions.Router.MCPHelpers do
  @moduledoc """
  MCP client initialization helpers for Router.
  Extracted to keep Router under 500 lines.
  """

  @doc """
  Gets or initializes MCP client for an agent.

  If mcp_client already exists in opts, returns it.
  Otherwise, starts a new MCP.Client and stores it in agent state.
  """
  @spec get_or_init_mcp_client(keyword()) :: pid() | nil
  def get_or_init_mcp_client(opts) do
    mcp_client = Keyword.get(opts, :mcp_client)
    agent_pid = Keyword.get(opts, :agent_pid)

    # DEBUG: Track MCP client creation
    require Logger

    Logger.warning(
      "MCPHelpers: mcp_client=#{inspect(mcp_client)}, agent_pid=#{inspect(agent_pid)}, creating_new=#{is_nil(mcp_client) and is_pid(agent_pid)}"
    )

    if is_nil(mcp_client) and is_pid(agent_pid) do
      agent_id = Keyword.get(opts, :agent_id) || GenServer.call(agent_pid, :get_agent_id)

      mcp_opts =
        [agent_id: agent_id, agent_pid: agent_pid]
        |> maybe_add_opt(:sandbox_owner, Keyword.get(opts, :sandbox_owner))
        |> maybe_add_opt(:anubis_module, Keyword.get(opts, :anubis_module))

      {:ok, client_pid} = Quoracle.MCP.Client.start_link(mcp_opts)
      GenServer.cast(agent_pid, {:store_mcp_client, client_pid})
      client_pid
    else
      mcp_client
    end
  end

  @doc """
  Lazy initialization for MCP client in opts.

  Only initializes for :call_mcp action type.
  """
  @spec maybe_lazy_init_mcp_client(atom(), keyword()) :: keyword()
  def maybe_lazy_init_mcp_client(:call_mcp, opts) do
    case get_or_init_mcp_client(opts) do
      nil -> opts
      client_pid -> Keyword.put(opts, :mcp_client, client_pid)
    end
  end

  def maybe_lazy_init_mcp_client(_action_type, opts), do: opts

  @spec maybe_add_opt(keyword(), atom(), any()) :: keyword()
  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
