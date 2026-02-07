defmodule Quoracle.Agent.TreeTerminator do
  @moduledoc """
  Recursively terminates an agent tree in bottom-up order.
  Called from dismiss_child action's background task.

  ## Algorithm
  1. BFS traversal to collect all descendants
  2. Set dismissing flag on each agent during traversal (race prevention)
  3. Reverse the collection order (bottom-up: leaves first)
  4. Terminate each agent, delete DB records, broadcast events
  5. Continue on partial failures (log and proceed)
  """

  require Logger

  import Ecto.Query

  alias Quoracle.Agent.{Core, DynSup, RegistryQueries}
  alias Quoracle.Agents.Agent, as: AgentSchema
  alias Quoracle.Logs.Log
  alias Quoracle.Messages.Message
  alias Quoracle.Repo

  @doc """
  Terminates an agent tree starting from the given root agent.

  Collects all descendants via BFS, then terminates in bottom-up order
  (leaves first) to prevent orphan scenarios.

  ## Parameters
  - `root_agent_id` - The agent_id of the root agent to terminate
  - `dismissed_by` - The agent_id of the parent requesting dismissal
  - `reason` - Human-readable reason for dismissal
  - `deps` - Map with :registry, :dynsup, :pubsub, :sandbox_owner

  ## Returns
  - `:ok` always (partial failures are logged but don't stop termination)
  """
  @spec terminate_tree(String.t(), String.t(), String.t(), map()) :: :ok
  def terminate_tree(root_agent_id, dismissed_by, reason, deps) do
    Logger.info("TreeTerminator: Starting termination of #{root_agent_id}, reason: #{reason}")

    # 1. Collect all descendants (BFS traversal)
    descendants = collect_descendants(root_agent_id, deps.registry)

    # 2. Build termination order (reverse BFS = bottom-up, leaves first)
    termination_order = Enum.reverse([root_agent_id | descendants])

    # 3. Terminate each agent in order
    results =
      Enum.map(termination_order, fn agent_id ->
        terminate_single_agent(agent_id, dismissed_by, reason, deps)
      end)

    # 4. Log summary
    {successes, failures} = Enum.split_with(results, &match?({:ok, _}, &1))

    Logger.info(
      "TreeTerminator: Completed. #{length(successes)} terminated, #{length(failures)} failed"
    )

    :ok
  end

  # Collect all descendants of an agent using BFS traversal
  @spec collect_descendants(String.t(), atom()) :: [String.t()]
  defp collect_descendants(root_id, registry) do
    collect_descendants_bfs([root_id], [], registry)
  end

  defp collect_descendants_bfs([], collected, _registry), do: collected

  defp collect_descendants_bfs([current_agent_id | rest], collected, registry) do
    # Set dismissing flag BEFORE collecting children (race prevention)
    set_agent_dismissing(current_agent_id, registry)

    # Get PID for this agent to find its children
    children_agent_ids =
      case get_agent_pid(current_agent_id, registry) do
        {:ok, current_pid} ->
          # Get direct children of current agent
          children = RegistryQueries.find_children_by_parent(current_pid, registry)
          Enum.map(children, fn {_child_pid, composite} -> composite.agent_id end)

        :error ->
          # Agent already gone, no children to collect
          []
      end

    # Add children to queue and collected list
    collect_descendants_bfs(rest ++ children_agent_ids, collected ++ children_agent_ids, registry)
  end

  # Set the dismissing flag on an agent (prevents new spawns during termination)
  # Handles race condition where process dies between lookup and call
  defp set_agent_dismissing(agent_id, registry) do
    case get_agent_pid(agent_id, registry) do
      {:ok, pid} ->
        try do
          Core.set_dismissing(pid, true)
        catch
          :exit, _ ->
            # Process died between lookup and call - that's fine
            :ok
        end

      :error ->
        # Agent already gone
        :ok
    end
  end

  # Get agent PID from agent_id using Registry lookup
  @spec get_agent_pid(String.t(), atom()) :: {:ok, pid()} | :error
  defp get_agent_pid(agent_id, registry) do
    case Registry.lookup(registry, {:agent, agent_id}) do
      [{pid, _composite}] -> {:ok, pid}
      [] -> :error
    end
  end

  # Terminate a single agent: broadcast events, stop process, delete DB records
  @spec terminate_single_agent(String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, String.t(), term()}
  defp terminate_single_agent(agent_id, dismissed_by, reason, deps) do
    Logger.debug("TreeTerminator: Terminating #{agent_id}")

    # 1. Broadcast agent_dismissed event (before termination)
    broadcast_dismissed(agent_id, dismissed_by, reason, deps.pubsub)

    # 2. Terminate the GenServer (triggers Core.terminate/2 for cleanup)
    case terminate_process(agent_id, deps.registry) do
      :ok ->
        # 3. Delete DB records
        delete_agent_records(agent_id)

        # 4. Broadcast agent_terminated event (after cleanup)
        broadcast_terminated(agent_id, reason, deps.pubsub)

        {:ok, agent_id}

      {:error, term_reason} ->
        Logger.warning("TreeTerminator: Failed to terminate #{agent_id}: #{inspect(term_reason)}")
        {:error, agent_id, term_reason}
    end
  end

  # Terminate the GenServer process
  @spec terminate_process(String.t(), atom()) :: :ok | {:error, term()}
  defp terminate_process(agent_id, registry) do
    case get_agent_pid(agent_id, registry) do
      {:ok, pid} ->
        # Use DynSup.terminate_agent for graceful shutdown
        # This triggers Core.terminate/2 → Router cleanup, ACE persistence
        DynSup.terminate_agent(pid)

      :error ->
        # Agent already gone - that's fine (idempotent)
        :ok
    end
  end

  # Delete all database records for an agent
  # Wrapped in try/catch to handle test sandbox cleanup race (sandbox owner exits before Task completes)
  @spec delete_agent_records(String.t()) :: :ok
  defp delete_agent_records(agent_id) do
    try do
      # Delete in order respecting foreign keys
      # 1. Delete messages (both sent and received)
      Repo.delete_all(
        from(m in Message, where: m.from_agent_id == ^agent_id or m.to_agent_id == ^agent_id)
      )

      # 2. Delete logs
      Repo.delete_all(from(l in Log, where: l.agent_id == ^agent_id))

      # 3. Delete agent record
      Repo.delete_all(from(a in AgentSchema, where: a.agent_id == ^agent_id))

      :ok
    catch
      # Handle sandbox owner exit race condition in tests
      # This happens when test exits before TreeTerminator Task completes
      # Catch all exit patterns - cleanup is best-effort, agent is already terminated
      :exit, _ -> :ok
    end
  end

  # Broadcast agent_dismissed event (handles cleanup race gracefully)
  defp broadcast_dismissed(agent_id, dismissed_by, reason, pubsub) when not is_nil(pubsub) do
    try do
      Phoenix.PubSub.broadcast(
        pubsub,
        "agents:#{agent_id}",
        {:agent_dismissed,
         %{
           agent_id: agent_id,
           dismissed_by: dismissed_by,
           reason: reason,
           timestamp: DateTime.utc_now()
         }}
      )
    rescue
      # PubSub may be cleaned up during test teardown
      ArgumentError -> :ok
    end
  end

  defp broadcast_dismissed(_agent_id, _dismissed_by, _reason, nil), do: :ok

  # Broadcast agent_terminated event (handles cleanup race gracefully)
  defp broadcast_terminated(agent_id, reason, pubsub) when not is_nil(pubsub) do
    try do
      Phoenix.PubSub.broadcast(
        pubsub,
        "agents:#{agent_id}",
        {:agent_terminated,
         %{
           agent_id: agent_id,
           reason: reason,
           timestamp: DateTime.utc_now()
         }}
      )
    rescue
      # PubSub may be cleaned up during test teardown
      ArgumentError -> :ok
    end
  end

  defp broadcast_terminated(_agent_id, _reason, nil), do: :ok
end
