defmodule Test.CoreTestHelpers do
  @moduledoc """
  Test-specific helpers for Agent.Core testing.

  These functions provide test-only capabilities that should NOT be in production code.
  They allow tests to trigger specific PubSub broadcasts and state changes for
  verification purposes.
  """

  alias Quoracle.Agent.Core

  @doc """
  Trigger a test broadcast from an agent.

  This is a test-only helper that broadcasts a message on the agent's log topic.
  Use this instead of the removed {:broadcast_test, _} handler.

  ## Examples

      iex> broadcast_test_message(agent_pid, pubsub, "test message")
      :ok
  """
  @spec broadcast_test_message(pid(), atom(), String.t()) :: :ok
  def broadcast_test_message(agent_pid, pubsub, message) do
    # Get agent's ID from its state
    {:ok, state} = Core.get_state(agent_pid)
    agent_id = state.agent_id

    # Broadcast using the agent's pubsub
    Phoenix.PubSub.broadcast(
      pubsub,
      "agents:#{agent_id}:logs",
      {:log_entry, %{agent_id: agent_id, message: message}}
    )
  end

  @doc """
  Update agent state and trigger broadcast.

  This is a test-only helper that updates agent state and broadcasts the change.
  Use this instead of the removed {:update_state, _} handler.

  ## Examples

      iex> update_state_and_broadcast(agent_pid, pubsub, %{status: :active})
      :ok
  """
  @spec update_state_and_broadcast(pid(), atom(), map()) :: :ok
  def update_state_and_broadcast(agent_pid, pubsub, updates) do
    # Get current state
    {:ok, state} = Core.get_state(agent_pid)
    agent_id = state.agent_id

    # In a real scenario, we would update the agent's state here
    # But since this is test-only, we just broadcast the update
    # The actual state update would need to go through proper GenServer calls

    # Broadcast state update
    Phoenix.PubSub.broadcast(
      pubsub,
      "agents:#{agent_id}:state",
      {:agent_state_update, Map.merge(%{agent_id: agent_id}, updates)}
    )
  end
end
