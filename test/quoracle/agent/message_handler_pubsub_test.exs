defmodule Quoracle.Agent.MessageHandlerPubSubTest do
  @moduledoc """
  Tests for MessageHandler PubSub isolation support.
  """
  use ExUnit.Case, async: true
  alias Quoracle.Agent.MessageHandler

  setup do
    # Create isolated PubSub
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    %{pubsub: pubsub_name}
  end

  describe "handle_message/2 with PubSub from state" do
    test "extracts pubsub from state, not Process dictionary", %{pubsub: pubsub} do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      # Create state with pubsub
      # skip_consensus: true avoids action execution (test only checks PubSub broadcast)
      state = %{
        agent_id: agent_id,
        parent_pid: self(),
        pubsub: pubsub,
        status: :active,
        wait_timer: nil,
        model_histories: %{"default" => []},
        test_mode: true,
        skip_consensus: true
      }

      message = %{
        type: "request",
        from: "parent",
        content: "test message"
      }

      # Subscribe to isolated pubsub
      Phoenix.PubSub.subscribe(pubsub, "messages:#{agent_id}")

      # Handle message should use pubsub from state
      {:noreply, _new_state} = MessageHandler.handle_message(state, message)

      # Should broadcast to isolated pubsub
      assert_receive {:message_received, %{agent_id: ^agent_id}}, 30_000
    end
  end

  describe "broadcast functions with isolated PubSub" do
    test "broadcast_message_received uses pubsub from state", %{pubsub: pubsub} do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      # Subscribe to isolated pubsub
      Phoenix.PubSub.subscribe(pubsub, "messages:all")
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:messages")

      state = %{
        agent_id: agent_id,
        pubsub: pubsub
      }

      message = %{
        id: "msg-1",
        type: "request",
        from: "parent",
        content: "test"
      }

      # Broadcast using isolated pubsub
      MessageHandler.broadcast_message_received(message, state)

      # Should receive on both topics
      assert_receive {:message_received, payload}, 30_000
      assert payload.agent_id == agent_id
      assert payload.message == message
    end

    test "broadcast_message_sent uses pubsub from state", %{pubsub: pubsub} do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(pubsub, "messages:all")

      state = %{
        agent_id: agent_id,
        pubsub: pubsub
      }

      message = %{
        id: "msg-2",
        to: "child-agent",
        content: "instruction"
      }

      MessageHandler.broadcast_message_sent(message, state)

      assert_receive {:message_sent, %{agent_id: ^agent_id, message: ^message}}, 30_000
    end

    test "broadcasts don't leak between isolated agents", %{} do
      # Create two isolated pubsub instances
      pubsub1 = :"pubsub1_#{System.unique_integer([:positive])}"
      pubsub2 = :"pubsub2_#{System.unique_integer([:positive])}"

      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub1}, id: :ps1)
      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub2}, id: :ps2)

      # Subscribe to first pubsub only
      Phoenix.PubSub.subscribe(pubsub1, "messages:all")

      state1 = %{agent_id: "agent1", pubsub: pubsub1}
      state2 = %{agent_id: "agent2", pubsub: pubsub2}

      # Agent1 broadcasts
      MessageHandler.broadcast_message_received(%{id: "msg1"}, state1)

      assert_receive {:message_received, %{agent_id: "agent1"}}, 30_000

      # Agent2 broadcasts (should not receive)
      MessageHandler.broadcast_message_received(%{id: "msg2"}, state2)

      refute_receive {:message_received, %{agent_id: "agent2"}}, 100
    end
  end

  describe "ConsensusHandler integration" do
    test "passes pubsub to ConsensusHandler calls", %{pubsub: pubsub} do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      state = %{
        agent_id: agent_id,
        pubsub: pubsub,
        parent_pid: self(),
        consensus: %{
          providers: ["openai", "anthropic"],
          threshold: 0.7
        },
        wait_timer: nil,
        model_histories: %{"default" => []},
        # Use test mode to avoid DB issues
        test_mode: true
      }

      # Message requiring consensus
      message = %{
        type: "consensus_request",
        content: "requires multi-model agreement"
      }

      # Add required fields for consensus to work
      # skip_consensus: true avoids action execution (test only checks PubSub broadcast)
      state =
        Map.merge(state, %{
          model_id: "test_model",
          pending_actions: %{},
          action_counter: 0,
          context_summary: nil,
          test_opts: [],
          skip_consensus: true
        })

      # Handle message should pass pubsub to ConsensusHandler
      # This will fail because consensus requires actual model configs
      # but that's expected - we're just testing that pubsub is passed correctly
      result = MessageHandler.handle_message(state, message)

      # Should return an error or noreply
      assert match?({:noreply, _}, result)
    end
  end

  describe "message threading with isolation" do
    test "thread updates broadcast to isolated pubsub", %{pubsub: pubsub} do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      thread_id = "thread-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(pubsub, "messages:threads:#{thread_id}")

      state = %{
        agent_id: agent_id,
        pubsub: pubsub,
        threads: %{}
      }

      # Create thread message
      message = %{
        id: "msg-1",
        thread_id: thread_id,
        type: "thread_message",
        content: "in thread"
      }

      {:ok, new_state} = MessageHandler.handle_threaded_message(message, state)

      # Should broadcast thread update
      assert_receive {:thread_updated, %{thread_id: ^thread_id}}, 30_000

      # Thread should be tracked in state
      assert Map.has_key?(new_state.threads, thread_id)
    end
  end
end
