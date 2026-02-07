defmodule Quoracle.Agent.RegistryQueries do
  @moduledoc """
  Registry query functions for agent discovery and relationship queries.

  Provides functions to find children, parents, and siblings using Registry
  composite values with proper dependency injection support for testing.
  """

  @doc """
  Find all children of a parent agent. Registry is required.
  """
  @spec find_children_by_parent(pid(), atom()) :: [{pid(), map()}]
  def find_children_by_parent(parent_pid, registry) do
    Registry.select(registry, [
      {{{:agent, :"$1"}, :"$2", :"$3"}, [{:==, {:map_get, :parent_pid, :"$3"}, parent_pid}],
       [{{:"$2", :"$3"}}]}
    ])
  end

  @doc """
  Get the parent PID of an agent from the Registry composite value.
  Registry is required.
  """
  @spec get_parent_from_registry(String.t(), atom()) :: pid() | nil
  def get_parent_from_registry(agent_id, registry) do
    case Registry.lookup(registry, {:agent, agent_id}) do
      [{_pid, composite}] when is_map(composite) ->
        Map.get(composite, :parent_pid)

      _ ->
        nil
    end
  end

  @doc """
  Find all sibling agents (agents with the same parent) of the given agent.
  Registry is required.
  """
  @spec find_siblings(pid(), atom()) :: [{pid(), map()}]
  def find_siblings(agent_pid, registry) do
    # First get the agent's parent
    agent_id = get_agent_id(agent_pid)
    parent_pid = get_parent_from_registry(agent_id, registry)

    if parent_pid do
      # Find all children of the parent, excluding self
      parent_pid
      |> find_children_by_parent(registry)
      |> Enum.reject(fn {pid, _} -> pid == agent_pid end)
    else
      []
    end
  end

  @doc """
  Get agent_id from a PID by looking up in Registry.
  Returns nil if PID not found or not registered.

  Used by persistence layer to extract parent agent_id from parent_pid.
  """
  @spec get_agent_id_from_pid(pid() | nil, atom()) :: String.t() | nil
  def get_agent_id_from_pid(nil, _registry), do: nil

  def get_agent_id_from_pid(pid, registry) do
    # Search Registry for any key where the PID matches
    case Registry.keys(registry, pid) do
      [{:agent, agent_id}] -> agent_id
      _ -> nil
    end
  end

  @doc """
  List all agents registered in the Registry.
  Returns list of tuples {agent_id, composite_value}.
  Used by LiveView to discover all existing agents at mount.
  """
  @spec list_all_agents(atom()) :: [{String.t(), map()}]
  def list_all_agents(registry) do
    Registry.select(registry, [
      {{{:agent, :"$1"}, :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}
    ])
  end

  @doc """
  List all agents for a specific task.
  Returns list of tuples {agent_id, composite_value}.
  Used by TaskRestorer to find all live agents for pause/restore operations.
  """
  @spec list_agents_for_task(binary(), atom()) :: [{String.t(), map()}]
  def list_agents_for_task(task_id, registry) do
    Registry.select(registry, [
      {{{:agent, :"$1"}, :"$2", :"$3"}, [{:==, {:map_get, :task_id, :"$3"}, task_id}],
       [{{:"$1", :"$3"}}]}
    ])
  end

  # Helper to get agent ID from PID
  defp get_agent_id(pid) do
    case GenServer.call(pid, :get_agent_id) do
      {:ok, agent_id} -> agent_id
      agent_id when is_binary(agent_id) -> agent_id
    end
  end
end
