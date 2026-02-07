defmodule Quoracle.Actions.Todo do
  @moduledoc """
  Manages per-agent TODO lists via full list replacement.
  TODOs are stored in agent state (in-memory) and injected into consensus prompts.
  """

  alias Quoracle.PubSub.AgentEvents

  @valid_states [:todo, :pending, :done]

  @doc """
  Updates agent's TODO list with a new list (full replacement).
  Called after consensus validation.

  ## Parameters
  - params: Map containing :items (list of TODO items)
  - agent_id: String identifier for the agent
  - opts: Keyword list with :pubsub and :agent_pid

  ## Returns
  - {:ok, %{action: "todo", count: integer()}} on success
  - {:error, reason} on failure
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def execute(params, agent_id, opts \\ []) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    agent_pid = Keyword.get(opts, :agent_pid)

    # Validate agent_pid is present
    if agent_pid == nil do
      {:error, :agent_pid_required}
    else
      # Validate items structure
      case validate_items(params) do
        {:ok, items} ->
          # Update agent state via GenServer cast (not call!)
          # CRITICAL: Using cast avoids deadlock when agent is blocked in handle_cast(:request_consensus)
          # The synchronous call would timeout because the agent can't process it while still in the cast
          GenServer.cast(agent_pid, {:update_todos, items})

          # Broadcast success log
          AgentEvents.broadcast_log(
            agent_id,
            :info,
            "TODO list updated: #{length(items)} items",
            %{action: "todo", count: length(items)},
            pubsub
          )

          {:ok, %{action: "todo", count: length(items)}}

        {:error, reason} ->
          # Broadcast error log
          AgentEvents.broadcast_log(
            agent_id,
            :error,
            "TODO update failed",
            %{error: reason, action: "todo"},
            pubsub
          )

          {:error, reason}
      end
    end
  end

  @doc false
  def validate_items(params) do
    params_map = normalize_keys(params)

    cond do
      not Map.has_key?(params_map, :items) ->
        {:error, :missing_items}

      not is_list(params_map.items) ->
        {:error, :invalid_todo_items}

      true ->
        # Validate each item
        if Enum.all?(params_map.items, &valid_item?/1) do
          # Normalize all items
          normalized_items = Enum.map(params_map.items, &normalize_item/1)
          {:ok, normalized_items}
        else
          {:error, :invalid_todo_items}
        end
    end
  end

  @doc false
  def valid_item?(item) when is_map(item) do
    item_map = normalize_keys(item)

    # Check content exists and is non-empty string
    has_content =
      Map.has_key?(item_map, :content) and
        is_binary(item_map.content) and
        item_map.content != ""

    # Check state exists and is valid
    has_valid_state =
      Map.has_key?(item_map, :state) and
        item_map.state in @valid_states

    has_content and has_valid_state
  end

  def valid_item?(_), do: false

  @doc false
  def normalize_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_atom_key(k), normalize_value(k, v)} end)
    |> Map.new()
  end

  def normalize_keys(other), do: other

  defp normalize_item(item) do
    item_map = normalize_keys(item)
    %{content: item_map.content, state: item_map.state}
  end

  defp to_atom_key(key) when is_atom(key), do: key

  defp to_atom_key(key) when is_binary(key) do
    # Use existing atoms only to prevent memory leaks
    String.to_existing_atom(key)
  rescue
    # Keep as string if atom doesn't exist
    ArgumentError -> key
  end

  defp normalize_value(key, value) when key in ["state", :state] and is_binary(value) do
    # Convert string states to atoms
    case value do
      "todo" -> :todo
      "pending" -> :pending
      "done" -> :done
      _ -> value
    end
  end

  defp normalize_value(_key, value), do: value
end
