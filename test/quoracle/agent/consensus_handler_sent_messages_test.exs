defmodule Quoracle.Agent.ConsensusHandlerSentMessagesTest do
  @moduledoc """
  Acceptance test for sent_messages in consensus log broadcasts.
  Verifies that the actual message content is included, not empty lists.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.ConsensusHandler

  describe "get_action_consensus/1 sent_messages broadcast" do
    setup do
      # Create isolated PubSub for this test
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      # Subscribe to the agent's log topic
      Phoenix.PubSub.subscribe(pubsub_name, "agents:#{agent_id}:logs")

      %{pubsub: pubsub_name, agent_id: agent_id}
    end

    test "broadcasts sent_messages with actual message content", %{
      pubsub: pubsub,
      agent_id: agent_id
    } do
      # Create state with REAL history entries (not empty)
      state = %{
        agent_id: agent_id,
        pubsub: pubsub,
        test_mode: true,
        model_pool: [:mock_model_1, :mock_model_2],
        model_histories: %{
          :mock_model_1 => [
            %{type: :prompt, content: "User said hello", timestamp: DateTime.utc_now()}
          ],
          :mock_model_2 => [
            %{type: :prompt, content: "User said hello", timestamp: DateTime.utc_now()},
            %{
              type: :decision,
              content: %{action: "wait", params: %{}},
              timestamp: DateTime.utc_now()
            }
          ]
        },
        test_opts: [
          query_fn: fn _messages, _opts ->
            {:ok, %{action: "wait", params: %{}, reasoning: "test"}}
          end
        ]
      }

      # Call get_action_consensus - this should broadcast the log
      _result = ConsensusHandler.get_action_consensus(state)

      # Check what was broadcast
      assert_receive {:log_entry, log}, 30_000

      # Verify sent_messages is present and has content
      sent_messages = log.metadata[:sent_messages]
      assert sent_messages != nil, "sent_messages should be in metadata"
      assert is_list(sent_messages), "sent_messages should be a list"
      assert sent_messages != [], "sent_messages should not be empty"

      # Each model entry should have messages with actual content
      Enum.each(sent_messages, fn model_entry ->
        assert Map.has_key?(model_entry, :model_id), "model_entry should have :model_id"
        assert Map.has_key?(model_entry, :messages), "model_entry should have :messages"

        messages = model_entry.messages
        assert is_list(messages), "messages should be a list, got: #{inspect(messages)}"

        assert messages != [],
               "messages should not be empty for model #{inspect(model_entry.model_id)}, got: #{inspect(messages)}"

        # Each message should have role and non-empty content
        Enum.each(messages, fn msg ->
          assert Map.has_key?(msg, :role), "message should have :role, got: #{inspect(msg)}"
          assert Map.has_key?(msg, :content), "message should have :content, got: #{inspect(msg)}"
          assert msg.content != nil, "content should not be nil"
          assert msg.content != "", "content should not be empty string"
        end)
      end)
    end

    test "includes system prompt in sent_messages (not just history)", %{
      pubsub: pubsub,
      agent_id: agent_id
    } do
      # Create state with user message in model_histories
      # (v15.0: user_prompt no longer injected by SystemPromptInjector,
      # initial message flows through history via MessageHandler instead)
      state = %{
        agent_id: agent_id,
        pubsub: pubsub,
        test_mode: true,
        model_pool: [:mock_model_1],
        # User message in history (as it would be after MessageHandler processes it)
        model_histories: %{
          :mock_model_1 => [
            %{
              type: :event,
              content: %{from: "parent", content: "Please help me with this task"},
              timestamp: DateTime.utc_now()
            }
          ]
        },
        context_lessons: %{},
        model_states: %{},
        test_opts: [
          query_fn: fn _messages, _opts ->
            {:ok, %{action: "wait", params: %{}, reasoning: "test"}}
          end
        ]
      }

      _result = ConsensusHandler.get_action_consensus(state)

      assert_receive {:log_entry, log}, 30_000

      sent_messages = log.metadata[:sent_messages]
      assert sent_messages != nil

      # Get the first model's messages
      [model_entry | _] = sent_messages
      messages = model_entry.messages

      # Should have at least system prompt + user message from history
      assert length(messages) >= 2,
             "Expected at least 2 messages (system + user), got #{length(messages)}: #{inspect(messages)}"

      # First message should be system prompt (from ensure_system_prompts)
      [first_msg | _] = messages

      assert first_msg.role == "system",
             "First message should be system role, got: #{first_msg.role}"

      assert first_msg.content =~ "Available Actions",
             "System prompt should contain action schema"

      # Should include the user message from history
      user_messages = Enum.filter(messages, &(&1.role == "user"))
      assert user_messages != [], "Should have user message"

      user_contents = Enum.map(user_messages, & &1.content)

      assert Enum.any?(user_contents, &(&1 =~ "Please help me with this task")),
             "User message should be included in messages, got: #{inspect(user_contents)}"
    end
  end
end
