defmodule QuoracleWeb.UI.MailboxReplyHandlerTest do
  @moduledoc """
  Tests for the newly added reply handler in Mailbox component.
  Verifies that {:send_reply, message_id, content} messages are properly handled.
  """
  use ExUnit.Case, async: true

  alias QuoracleWeb.UI.Mailbox

  setup do
    # Create isolated PubSub and Registry for test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    %{pubsub: pubsub_name, registry: registry_name}
  end

  describe "handle_info for send_reply" do
    test "routes reply to agent when agent exists", %{registry: registry, pubsub: pubsub} do
      # Start a mock agent using supervised Task
      test_pid = self()

      mock_agent =
        start_supervised!({
          Task,
          fn ->
            # The mock agent will forward whatever it receives to the test process
            receive do
              msg ->
                send(test_pid, msg)
            end
          end
        })

      # Register the mock agent
      agent_id = "agent_123"
      Registry.register(registry, {:agent, agent_id}, mock_agent)

      # Create a message from the agent
      message = %{
        id: 1,
        sender_id: agent_id,
        from: :agent,
        content: "Hello from agent",
        timestamp: DateTime.utc_now()
      }

      # Initialize socket state
      socket = %{
        assigns: %{
          messages: [message],
          registry: registry,
          pubsub: pubsub,
          expanded_messages: MapSet.new(),
          agent_alive_map: %{agent_id => true}
        }
      }

      # Simulate receiving the reply message
      reply_content = "This is my reply"
      {:noreply, _updated_socket} = Mailbox.handle_info({:send_reply, 1, reply_content}, socket)

      # Verify the agent received the GenServer cast with the correct content
      assert_receive {:"$gen_cast", {:send_user_message, ^reply_content}}, 30_000
    end

    test "handles gracefully when agent doesn't exist", %{registry: registry, pubsub: pubsub} do
      # Create a message from a non-existent agent
      message = %{
        id: 1,
        sender_id: "non_existent",
        from: :agent,
        content: "Hello",
        timestamp: DateTime.utc_now()
      }

      socket = %{
        assigns: %{
          messages: [message],
          registry: registry,
          pubsub: pubsub,
          expanded_messages: MapSet.new(),
          agent_alive_map: %{}
        }
      }

      # Should not crash when agent doesn't exist
      {:noreply, updated_socket} = Mailbox.handle_info({:send_reply, 1, "Reply"}, socket)

      # Socket should remain unchanged
      assert updated_socket == socket
    end

    test "handles gracefully when message not found", %{registry: registry, pubsub: pubsub} do
      socket = %{
        assigns: %{
          messages: [],
          registry: registry,
          pubsub: pubsub,
          expanded_messages: MapSet.new(),
          agent_alive_map: %{}
        }
      }

      # Should not crash when message doesn't exist
      {:noreply, updated_socket} = Mailbox.handle_info({:send_reply, 999, "Reply"}, socket)

      # Socket should remain unchanged
      assert updated_socket == socket
    end
  end
end
