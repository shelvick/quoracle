defmodule Quoracle.Actions.SendMessage do
  @moduledoc """
  Action module for sending messages to users and other agents.

  Messages to `:parent` when no parent exists are routed to the user.
  Uses direct Erlang messaging for agent-to-agent communication and
  PubSub broadcasting for user messages.

  This module now requires explicit agent_id and task_id parameters,
  eliminating the need for querying the sender process.
  """

  require Logger

  @doc """
  Send a message to the specified target (standard 3-arity signature).

  ## Parameters
  - params: Map with :to and :content keys (required)
  - agent_id: The sending agent's ID
  - opts: Keyword list with :action_id (required), :task_id (optional), :registry, :pubsub

  ## Returns
  - {:ok, result_map} on success
  - {:error, reason} on failure
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def execute(params, agent_id, opts) when is_binary(agent_id) and is_list(opts) do
    action_id = Keyword.fetch!(opts, :action_id)
    task_id = Keyword.get(opts, :task_id, agent_id)
    execute(params, action_id, agent_id, task_id, opts)
  end

  @doc """
  Send a message to the specified target with explicit metadata (5-arity signature).

  ## Parameters
  - params: Map with :to and :content keys (required)
  - action_id: Unique action identifier for tracking
  - agent_id: The sending agent's ID
  - task_id: The task context ID (used for PubSub topics)
  - opts: Keyword list with :registry and :pubsub for dependency injection

  ## Returns
  - {:ok, result_map} on success
  - {:error, reason} on failure
  """
  @spec execute(map(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def execute(params, _action_id, agent_id, task_id, opts) when is_list(opts) do
    # Normalize parameters to atom keys
    params = normalize_keys(params)

    # Extract dependency injection options
    pubsub = Keyword.get(opts, :pubsub)
    registry = Keyword.get(opts, :registry)

    # Validate required parameters
    with {:validate_to, to} when not is_nil(to) <- {:validate_to, Map.get(params, :to)},
         {:validate_content, content} when not is_nil(content) <-
           {:validate_content, Map.get(params, :content)} do
      # Normalize string targets to atoms
      to = normalize_target(to)

      case resolve_targets(to, agent_id, registry) do
        {:ok, targets} ->
          send_messages(targets, content, agent_id, task_id, pubsub)
          Logger.info("Message sent from #{agent_id} to #{inspect(to)}")

          # Extract agent IDs from targets for return value
          # Transform {:agent, pid, id} -> id, {:user, nil} -> "user"
          sent_to_ids =
            Enum.map(targets, fn
              {:agent, _pid, id} -> id
              {:user, nil} -> "user"
            end)

          {:ok, %{action: "send_message", sent_to: sent_to_ids}}

        {:error, reason} ->
          Logger.error("Failed to send message: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:validate_to, nil} -> {:error, :missing_to}
      {:validate_content, nil} -> {:error, :missing_content}
    end
  end

  # Parameter normalization helpers (pattern from Orient)
  defp normalize_keys(params) when is_map(params) do
    params
    |> Enum.map(fn {k, v} -> {to_atom_key(k), v} end)
    |> Enum.into(%{})
  end

  defp to_atom_key(key) when is_atom(key), do: key

  defp to_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    # Keep as string if atom doesn't exist
    ArgumentError -> key
  end

  defp normalize_target(target) when is_binary(target) do
    # Strip brackets - LLMs sometimes send [parent] instead of parent
    target = String.trim(target, "[]")

    case target do
      "parent" -> :parent
      "children" -> :children
      "announcement" -> :announcement
      other -> other
    end
  end

  defp normalize_target(target), do: target

  # Target resolution functions
  defp resolve_targets(:parent, agent_id, registry) do
    resolve_parent(agent_id, registry)
  end

  defp resolve_targets(:children, agent_id, registry) do
    resolve_children(agent_id, registry)
  end

  defp resolve_targets(:announcement, agent_id, registry) do
    resolve_all_descendants(agent_id, registry)
  end

  defp resolve_targets(to, _agent_id, nil) when is_list(to) do
    # No registry provided - all agents are not found
    Enum.each(to, fn id ->
      Logger.error("Target agent not found: #{id}")
    end)

    {:ok, []}
  end

  defp resolve_targets(to, _agent_id, registry) when is_list(to) do
    # Direct list of agent IDs - resolve each to PID
    targets =
      Enum.map(to, fn id ->
        case Registry.lookup(registry, {:agent, id}) do
          [{pid, _}] -> {:agent, pid, id}
          [] -> {:not_found, id}
        end
      end)

    # Filter out not found, but log errors
    valid_targets =
      Enum.filter(targets, fn
        {:agent, _, _} ->
          true

        {:not_found, id} ->
          Logger.error("Target agent not found: #{id}")
          false
      end)

    {:ok, valid_targets}
  end

  defp resolve_targets(to, _agent_id, _registry) do
    Logger.error(
      "Invalid send_message target: #{inspect(to)}. " <>
        "Valid targets: 'parent', 'children', 'announcement', or a list of agent IDs"
    )

    {:error, :invalid_target}
  end

  defp resolve_parent(_agent_id, nil) do
    # No registry provided - assume root agent, send to user
    {:ok, [{:user, nil}]}
  end

  defp resolve_parent(agent_id, registry) do
    # Look up agent's composite value to get parent info
    case Registry.lookup(registry, {:agent, agent_id}) do
      [{_pid, composite}] when is_map(composite) ->
        parent_pid = Map.get(composite, :parent_pid)
        parent_id = Map.get(composite, :parent_id)

        # Has parent - look up parent to verify it exists
        if parent_id do
          case Registry.lookup(registry, {:agent, parent_id}) do
            [{^parent_pid, _}] -> {:ok, [{:agent, parent_pid, parent_id}]}
            _ -> {:error, :parent_not_found}
          end
        else
          # No parent - this is root agent, send to user
          {:ok, [{:user, nil}]}
        end

      _ ->
        # Agent not found in registry - cannot determine parentage
        # This prevents terminated children's messages from leaking to user mailbox
        Logger.warning("resolve_parent: agent #{agent_id} not found in registry")
        {:error, :sender_not_found}
    end
  end

  defp resolve_children(_agent_id, nil) do
    # No registry provided - no children can be found
    {:ok, []}
  end

  defp resolve_children(agent_id, registry) do
    # Find all agents that list this agent as parent via composite values
    # Select pattern: match {:agent, child_id} keys where composite.parent_id == agent_id
    children =
      Registry.select(registry, [
        {
          # Match {{:agent, agent_id}, pid, composite_value}
          {{:agent, :"$1"}, :"$2", :"$3"},
          # No guards - we'll filter in Elixir
          [],
          # Return {key, pid, composite}
          [{{:"$1", :"$2", :"$3"}}]
        }
      ])
      |> Enum.filter(fn {_child_id, _pid, composite} ->
        # Filter for agents whose parent_id matches
        is_map(composite) && Map.get(composite, :parent_id) == agent_id
      end)
      |> Enum.map(fn {child_id, pid, _composite} ->
        # We already have the pid from Registry.select
        {:agent, pid, child_id}
      end)

    {:ok, children}
  end

  # Maximum depth for announcement traversal
  @max_announcement_depth 100

  defp resolve_all_descendants(_agent_id, nil), do: {:ok, []}

  defp resolve_all_descendants(agent_id, registry) do
    # Get sender's PID to exclude from results
    sender_pid =
      case Registry.lookup(registry, {:agent, agent_id}) do
        [{pid, _}] -> pid
        [] -> nil
      end

    # Initialize visited set with sender
    initial_visited = if sender_pid, do: MapSet.new([sender_pid]), else: MapSet.new()

    # Get direct children as starting queue
    {:ok, direct_children} = resolve_children(agent_id, registry)

    # BFS traversal
    all_descendants = bfs_descendants(direct_children, registry, initial_visited, 1)
    {:ok, all_descendants}
  end

  defp bfs_descendants(_queue, _registry, _visited, depth) when depth > @max_announcement_depth do
    Logger.warning("Announcement depth limit (#{@max_announcement_depth}) reached")
    []
  end

  defp bfs_descendants([], _registry, _visited, _depth), do: []

  defp bfs_descendants(current_level, registry, visited, depth) do
    # Filter out already-visited PIDs (cycle detection)
    {new_targets, new_visited} =
      Enum.reduce(current_level, {[], visited}, fn {:agent, pid, _id} = target, {acc, vis} ->
        if MapSet.member?(vis, pid) do
          {acc, vis}
        else
          {[target | acc], MapSet.put(vis, pid)}
        end
      end)

    # Get children of all new targets for next level
    next_level =
      Enum.flat_map(new_targets, fn {:agent, _pid, child_id} ->
        {:ok, grandchildren} = resolve_children(child_id, registry)
        grandchildren
      end)

    # Recurse and combine
    new_targets ++ bfs_descendants(next_level, registry, new_visited, depth + 1)
  end

  # Message sending functions
  defp send_messages(targets, content, agent_id, task_id, pubsub) do
    timestamp = DateTime.utc_now()

    Enum.each(targets, fn
      {:user, _} ->
        # Broadcast to task-specific topic for UI_Mailbox
        topic = "tasks:#{task_id}:messages"

        message = %{
          id: System.unique_integer([:positive]),
          from: :agent,
          sender_id: agent_id,
          content: content,
          timestamp: timestamp,
          status: :sent,
          task_id: task_id
        }

        # Only broadcast if pubsub is provided
        if pubsub do
          Phoenix.PubSub.broadcast(pubsub, topic, {:agent_message, message})
        end

      {:agent, target_pid, target_id} ->
        # Direct Erlang message to agent process
        send(target_pid, {:agent_message, agent_id, content})

        # Also broadcast to PubSub for EventHistory persistence
        if pubsub do
          message = %{
            id: System.unique_integer([:positive]),
            from: :agent,
            sender_id: agent_id,
            recipient_id: target_id,
            content: content,
            timestamp: timestamp,
            status: :sent,
            task_id: task_id
          }

          topic = "tasks:#{task_id}:messages"
          Phoenix.PubSub.broadcast(pubsub, topic, {:agent_message, message})
        end

        # Log the inter-agent communication
        Logger.debug(
          "Message from #{agent_id} to #{target_id}: #{String.slice(content, 0, 50)}..."
        )
    end)
  end
end
