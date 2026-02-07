defmodule Quoracle.Agent.TestHelpers do
  @moduledoc """
  Test-specific helper functions for Agent message broadcasting.
  Extracted from MessageHandler to keep it under 500 lines.
  """

  @doc """
  Broadcast that a message was received (for tests).
  Used in test mode to verify message receipt through PubSub.
  """
  @spec broadcast_message_received(any(), map()) :: :ok
  def broadcast_message_received(message, state) do
    pubsub = state.pubsub

    Phoenix.PubSub.broadcast(
      pubsub,
      "messages:all",
      {:message_received, %{agent_id: state.agent_id, message: message}}
    )

    Phoenix.PubSub.broadcast(
      pubsub,
      "agents:#{state.agent_id}:messages",
      {:message_received, %{agent_id: state.agent_id, message: message}}
    )
  end

  @doc """
  Broadcast that a message was sent (for tests).
  """
  @spec broadcast_message_sent(any(), map()) :: :ok
  def broadcast_message_sent(message, state) do
    pubsub = state.pubsub

    Phoenix.PubSub.broadcast(
      pubsub,
      "messages:all",
      {:message_sent, %{agent_id: state.agent_id, message: message}}
    )
  end

  @doc """
  Handle threaded messages with pubsub from state (for tests).
  """
  @spec handle_threaded_message(map(), map()) :: {:ok, map()}
  def handle_threaded_message(message, state) do
    thread_id = message.thread_id
    pubsub = state.pubsub

    # Track thread
    # Use Map.get for optional fields (works with both structs and maps)
    threads = Map.put_new(Map.get(state, :threads, %{}), thread_id, [])
    new_state = Map.put(state, :threads, threads)

    # Broadcast thread update
    Phoenix.PubSub.broadcast(
      pubsub,
      "messages:threads:#{thread_id}",
      {:thread_updated, %{thread_id: thread_id}}
    )

    {:ok, new_state}
  end
end
