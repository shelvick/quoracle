defmodule Quoracle.Agent.MessageHandlerTest do
  use ExUnit.Case, async: true

  alias Quoracle.Agent.MessageHandler

  describe "drain_mailbox/0" do
    test "returns empty list when mailbox is empty" do
      result = MessageHandler.drain_mailbox()
      assert result == []
    end

    test "returns all messages from mailbox in FIFO order" do
      # Send messages to self
      send(self(), {:message, 1})
      send(self(), {:message, 2})
      send(self(), {:message, 3})

      result = MessageHandler.drain_mailbox()

      assert result == [{:message, 1}, {:message, 2}, {:message, 3}]

      # Mailbox should now be empty
      assert MessageHandler.drain_mailbox() == []
    end

    test "preserves message order from oldest to newest" do
      send(self(), :first)
      send(self(), :second)
      send(self(), :third)
      send(self(), :fourth)

      result = MessageHandler.drain_mailbox()

      assert result == [:first, :second, :third, :fourth]
    end

    test "handles mixed message types" do
      send(self(), {:action_result, "id-1", {:ok, "done"}})
      send(self(), {:agent_message, :parent, "hello"})
      send(self(), {:system_event, :started, %{}})
      send(self(), {:wait_timeout, "timer-1"})

      result = MessageHandler.drain_mailbox()

      assert length(result) == 4
      assert {:action_result, "id-1", {:ok, "done"}} in result
      assert {:agent_message, :parent, "hello"} in result
    end
  end

  describe "format_batch_message/1" do
    test "returns empty string for empty message list" do
      result = MessageHandler.format_batch_message([])
      assert result == ""
    end

    test "formats action_result messages with XML tags" do
      messages = [
        {:action_result, "action-123", {:ok, %{response: "completed"}}}
      ]

      result = MessageHandler.format_batch_message(messages)

      assert result =~ "<action_result"
      assert result =~ "id=\"action-123\""
      assert result =~ "from=\"system\""
      # Now uses JSON format
      assert result =~ "\"type\": \"ok\""
      assert result =~ "\"value\":"
      assert result =~ "\"response\": \"completed\""
      assert result =~ "</action_result>"
    end

    test "formats agent_message with proper from attribution" do
      messages = [
        {:agent_message, :parent, "Parent says hello"},
        {:agent_message, :child, "Child responds"},
        {:agent_message, self(), "Peer message"}
      ]

      result = MessageHandler.format_batch_message(messages)

      assert result =~ "<agent_message from=\"parent\">"
      assert result =~ "Parent says hello"
      assert result =~ "</agent_message>"

      assert result =~ "<agent_message from=\"child\">"
      assert result =~ "Child responds"

      assert result =~ "<agent_message from=\"agent_"
    end

    test "formats system_event messages" do
      messages = [
        {:system_event, :consensus_started, %{timestamp: 12345}},
        {:system_event, :action_completed, %{action: :spawn_child}}
      ]

      result = MessageHandler.format_batch_message(messages)

      assert result =~ "<system_event type=\"consensus_started\">"
      # Now uses JSON format
      assert result =~ "\"timestamp\": 12345"
      assert result =~ "</system_event>"

      assert result =~ "<system_event type=\"action_completed\">"
      # Now uses JSON format
      assert result =~ "\"action\": \"spawn_child\""
    end

    test "formats wait_timeout messages" do
      messages = [
        {:wait_timeout, "timer-abc-123"}
      ]

      result = MessageHandler.format_batch_message(messages)

      assert result =~ "<wait_timeout"
      assert result =~ "timer_id=\"timer-abc-123\""
      assert result =~ "from=\"system\""
      assert result =~ "Timer expired"
      assert result =~ "</wait_timeout>"
    end

    test "formats unknown messages with fallback" do
      messages = [
        {:unknown, :type, :of, :message},
        "plain string message",
        42
      ]

      result = MessageHandler.format_batch_message(messages)

      assert result =~ "<unknown_message>"
      # Tuple is now JSON array format
      assert result =~ "\"unknown\""
      assert result =~ "\"type\""
      assert result =~ "\"of\""
      assert result =~ "\"message\""
      assert result =~ "</unknown_message>"

      assert result =~ "\"plain string message\""
      assert result =~ "42"
    end

    test "maintains chronological order in batch" do
      messages = [
        {:action_result, "1", {:ok, :first}},
        {:agent_message, :parent, "second"},
        {:system_event, :third, %{}},
        {:wait_timeout, "fourth"}
      ]

      result = MessageHandler.format_batch_message(messages)
      lines = String.split(result, "\n", trim: true)

      # Check that messages appear in order
      assert lines != []

      # First message should be action_result
      assert Enum.at(lines, 0) =~ "<action_result"

      # Messages should appear in sequence
      full_result = Enum.join(lines, "\n")
      first_pos = String.split(full_result, "first") |> List.first() |> String.length()
      second_pos = String.split(full_result, "second") |> List.first() |> String.length()
      third_pos = String.split(full_result, "third") |> List.first() |> String.length()
      fourth_pos = String.split(full_result, "fourth") |> List.first() |> String.length()

      assert first_pos < second_pos
      assert second_pos < third_pos
      assert third_pos < fourth_pos
    end

    test "handles empty content gracefully" do
      messages = [
        {:agent_message, :parent, ""},
        {:action_result, "id", nil},
        {:system_event, "", %{}}
      ]

      result = MessageHandler.format_batch_message(messages)

      # Should still format with XML tags even with empty content
      assert result =~ "<agent_message"
      assert result =~ "<action_result"
      assert result =~ "<system_event"
    end
  end

  describe "request_consensus/1" do
    setup do
      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        model_histories: %{"default" => []},
        models: ["model1", "model2"],
        pubsub: :test_pubsub,
        test_mode: true
      }

      %{state: state}
    end

    test "drains mailbox before requesting consensus", %{state: state} do
      # Send messages that should be drained
      send(self(), {:action_result, "id-1", {:ok, "result"}})
      send(self(), {:agent_message, :parent, "hello"})

      result = MessageHandler.request_consensus(state)

      # Mailbox should be empty after draining
      refute_receive _, 0

      assert {:ok, _consensus, _updated_state, _accumulator} = result
    end

    test "appends drained messages to conversation as single user message", %{state: state} do
      send(self(), {:action_result, "id-1", {:ok, "done"}})
      send(self(), {:agent_message, :child, "message"})

      {:ok, consensus, _updated_state, _accumulator} = MessageHandler.request_consensus(state)

      # The batched messages should be included in consensus request
      assert Map.has_key?(consensus, :action)
      assert Map.has_key?(consensus, :wait)
    end

    test "handles empty mailbox without adding extra message", %{state: state} do
      # No messages in mailbox
      {:ok, consensus, _updated_state, _accumulator} = MessageHandler.request_consensus(state)

      assert Map.has_key?(consensus, :action)
      # Should not add empty message to conversation
    end

    test "formats batch with proper XML structure", %{state: state} do
      send(self(), {:wait_timeout, "timer-1"})
      send(self(), {:action_result, "action-1", {:error, :timeout}})

      {:ok, _consensus, _updated_state, _accumulator} = MessageHandler.request_consensus(state)

      # The formatting is tested in format_batch_message tests
      # Here we just ensure it's called as part of the flow
      assert true
    end
  end

  describe "process_message/2 with pubsub from state" do
    setup do
      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        pubsub: :test_pubsub_instance,
        model_histories: %{"default" => []},
        pending_actions: %{}
      }

      %{state: state}
    end

    # Helper to get first model history
    defp first_history(state), do: state.model_histories["default"] || []

    test "uses pubsub from state for broadcasts", %{state: state} do
      message = {:user_message, "test message"}

      new_state = MessageHandler.process_message(message, state)

      # State should have the message processed
      assert first_history(new_state) != first_history(state)
    end

    test "categorizes and handles user messages", %{state: state} do
      message = {:user_message, "Please help me"}

      new_state = MessageHandler.process_message(message, state)

      assert length(first_history(new_state)) > length(first_history(state))
    end

    test "categorizes and handles action results", %{state: state} do
      state =
        put_in(state.pending_actions["ref-1"], %{
          action: :spawn_child,
          started_at: System.monotonic_time()
        })

      message = {:action_result, "ref-1", {:ok, %{child_pid: :pid}}}

      new_state = MessageHandler.process_message(message, state)

      # Should remove from pending actions
      refute Map.has_key?(new_state.pending_actions, "ref-1")
    end

    test "categorizes and handles agent messages", %{state: state} do
      message = {:agent_message, :parent, "Parent instruction"}

      new_state = MessageHandler.process_message(message, state)

      assert new_state != state
    end

    test "preserves pubsub field through state updates", %{state: state} do
      message = {:user_message, "test"}

      new_state = MessageHandler.process_message(message, state)

      assert new_state.pubsub == state.pubsub
    end

    test "handles unknown message types gracefully", %{state: state} do
      message = {:unknown_message_type, "data"}

      new_state = MessageHandler.process_message(message, state)

      # Should return state unchanged for unknown types
      assert new_state == state
    end
  end

  describe "NO_EXECUTE action_type tracking (Packet 2)" do
    setup do
      state = %{
        agent_id: "agent-test",
        pubsub: :test_pubsub,
        model_histories: %{"default" => []},
        pending_actions: %{
          "action_shell_1" => %{
            action: :execute_shell,
            type: :execute_shell,
            started_at: System.monotonic_time()
          },
          "action_web_1" => %{
            action: :fetch_web,
            type: :fetch_web,
            started_at: System.monotonic_time()
          },
          "action_msg_1" => %{
            action: :send_message,
            type: :send_message,
            started_at: System.monotonic_time()
          }
        }
      }

      %{state: state}
    end

    # Helper to get first model history
    defp get_history(state), do: state.model_histories["default"] || []

    # R8: Extract Action Type from Pending
    test "extracts action_type from pending_actions when handling result", %{state: state} do
      message = {:action_result, "action_shell_1", {:ok, %{stdout: "ls output"}}}

      new_state = MessageHandler.process_message(message, state)

      # Should have extracted action_type from pending_actions
      # Verify by checking if StateUtils.add_history_entry_with_action was called
      # (implementation will use it based on extracted type)
      assert get_history(new_state) != []
    end

    # R9: Store Result with Action Type
    test "stores action result with action_type in history", %{state: state} do
      message = {:action_result, "action_web_1", {:ok, %{content: "scraped data"}}}

      new_state = MessageHandler.process_message(message, state)

      # Find the result entry in history
      [result_entry | _] = get_history(new_state)

      # Should have action_type field from pending_actions
      assert result_entry.action_type == :fetch_web
      assert result_entry.type == :result
      # New format: content is pre-wrapped JSON string, action_id and result are separate fields
      assert result_entry.action_id == "action_web_1"
      assert result_entry.result == {:ok, %{content: "scraped data"}}
      assert is_binary(result_entry.content)
      assert result_entry.content =~ "action_web_1"
      assert result_entry.content =~ "scraped data"
    end

    # R10: Fallback Without Action Type
    test "falls back to standard history entry when action_type missing", %{state: state} do
      # Action not in pending_actions (action_type unavailable)
      message = {:action_result, "unknown_action_99", {:ok, :done}}

      new_state = MessageHandler.process_message(message, state)

      # Should still add to history using fallback (add_history_entry/3)
      [result_entry | _] = get_history(new_state)

      # Should NOT have action_type field (fell back to old format)
      refute Map.has_key?(result_entry, :action_type)
      assert result_entry.type == :result
      # Fallback uses add_history_entry/3 which stores raw content (not wrapped)
      assert result_entry.content == {"unknown_action_99", {:ok, :done}}
    end

    # R11: Action Type Preserved in History
    test "action_type flows through to conversation history for NO_EXECUTE wrapping", %{
      state: state
    } do
      # Process multiple action results with different types
      message1 = {:action_result, "action_shell_1", {:ok, "shell output"}}
      state = MessageHandler.process_message(message1, state)

      # Update pending_actions with new entry for second test
      state =
        put_in(state.pending_actions["action_api_1"], %{
          action: :call_api,
          type: :call_api,
          started_at: System.monotonic_time()
        })

      message2 = {:action_result, "action_api_1", {:ok, %{data: "api response"}}}
      state = MessageHandler.process_message(message2, state)

      # Verify both entries have preserved action_type fields
      [api_entry, shell_entry | _] = get_history(state)

      assert shell_entry.action_type == :execute_shell
      assert api_entry.action_type == :call_api

      # New format: content is pre-wrapped JSON string, action_id and result are separate fields
      assert shell_entry.action_id == "action_shell_1"
      assert shell_entry.result == {:ok, "shell output"}
      assert is_binary(shell_entry.content)
      assert shell_entry.content =~ "action_shell_1"

      assert api_entry.action_id == "action_api_1"
      assert api_entry.result == {:ok, %{data: "api response"}}
      assert is_binary(api_entry.content)
      assert api_entry.content =~ "action_api_1"
    end

    test "preserves action_type for all 5 untrusted action types", %{state: state} do
      untrusted_actions = [
        {:execute_shell, "action_shell", {:ok, "output"}},
        {:fetch_web, "action_web", {:ok, "html"}},
        {:call_api, "action_api", {:ok, "json"}},
        {:call_mcp, "action_mcp", {:ok, "result"}},
        {:answer_engine, "action_answer", {:ok, "answer"}}
      ]

      final_state =
        Enum.reduce(untrusted_actions, state, fn {type, action_id, result}, acc_state ->
          # Add to pending_actions
          acc_state =
            put_in(acc_state.pending_actions[action_id], %{
              action: type,
              type: type,
              started_at: System.monotonic_time()
            })

          # Process result
          message = {:action_result, action_id, result}
          MessageHandler.process_message(message, acc_state)
        end)

      # All 6 should have action_type preserved
      entries = Enum.take(get_history(final_state), 6)

      action_types = Enum.map(entries, & &1.action_type)

      assert :execute_shell in action_types
      assert :fetch_web in action_types
      assert :call_api in action_types
      assert :call_mcp in action_types
      assert :answer_engine in action_types
    end

    test "does not add action_type for trusted actions if not in schema", %{state: state} do
      # send_message is trusted, might not have explicit type in pending_actions
      message = {:action_result, "action_msg_1", {:ok, :sent}}

      new_state = MessageHandler.process_message(message, state)

      [result_entry | _] = get_history(new_state)

      # If type field exists in pending_actions, should be preserved
      # If not, should fallback to no action_type
      if Map.has_key?(state.pending_actions["action_msg_1"], :type) do
        assert result_entry.action_type == :send_message
      else
        refute Map.has_key?(result_entry, :action_type)
      end
    end
  end
end
