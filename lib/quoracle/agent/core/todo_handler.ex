defmodule Quoracle.Agent.Core.TodoHandler do
  @moduledoc """
  Handles TODO-related GenServer callbacks for Agent.Core.
  Extracted to keep core.ex under 500-line limit.
  """

  alias Quoracle.PubSub.AgentEvents

  @doc """
  Handle update_todos GenServer cast - replace entire TODO list.
  Uses cast (not call) to avoid deadlock when called from action execution
  while agent is blocked in handle_cast(:request_consensus).
  """
  @spec handle_update_todos(list(map()), map()) :: {:noreply, map()}
  def handle_update_todos(items, state) when is_list(items) do
    new_state = %{state | todos: items}
    pubsub = state.pubsub
    AgentEvents.broadcast_todos_updated(state.agent_id, items, pubsub)
    {:noreply, new_state}
  end

  @doc """
  Handle get_todos GenServer call - retrieve current TODO list.
  """
  @spec handle_get_todos(map()) :: {:reply, list(map()), map()}
  def handle_get_todos(state) do
    todos = state.todos
    {:reply, todos, state}
  end
end
