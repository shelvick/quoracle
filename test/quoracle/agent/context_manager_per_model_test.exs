defmodule Quoracle.Agent.ContextManagerPerModelTest do
  @moduledoc """
  Tests for per-model context building in ContextManager.
  WorkGroupID: ace-20251207-140000
  Packet 3: Context Operations - ContextManager requirements R1-R7.

  Note: v4.0 R8-R12 (ACE injection as system message) removed in v7.0.
  ACE context is now injected by AceInjector into first user message.
  See context_manager_ace_removal_test.exs for v7.0 R13-R15 tests.
  """

  use ExUnit.Case, async: true
  alias Quoracle.Agent.ContextManager
  alias Quoracle.Agent.StateUtils

  describe "R1: Model-Specific History" do
    test "builds messages from specific model history" do
      state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => [
            %{type: :user, content: "Hello Claude", timestamp: DateTime.utc_now()},
            %{type: :assistant, content: "Hi there!", timestamp: DateTime.utc_now()}
          ],
          "google:gemini-2.0-flash" => [
            %{type: :user, content: "Hello Gemini", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      # This 2-arity function doesn't exist yet - will fail
      messages = ContextManager.build_conversation_messages(state, "anthropic:claude-sonnet-4")

      # Should have messages from Claude's history (with timestamp prefix)
      assert is_list(messages)
      contents = Enum.map(messages, & &1.content)
      assert Enum.any?(contents, &String.contains?(&1, "Hello Claude"))
      assert Enum.any?(contents, &String.contains?(&1, "Hi there!"))
      refute Enum.any?(contents, &String.contains?(&1, "Hello Gemini"))
    end
  end

  describe "R2: Different Models Different Histories" do
    test "returns different messages for different model histories" do
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "Message for A", timestamp: DateTime.utc_now()}
          ],
          "model-b" => [
            %{type: :user, content: "Message for B", timestamp: DateTime.utc_now()},
            %{type: :assistant, content: "Response from B", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      # This 2-arity function doesn't exist yet - will fail
      messages_a = ContextManager.build_conversation_messages(state, "model-a")
      messages_b = ContextManager.build_conversation_messages(state, "model-b")

      # Should have different content
      assert length(messages_a) != length(messages_b)

      contents_a = Enum.map(messages_a, & &1.content)
      contents_b = Enum.map(messages_b, & &1.content)

      assert Enum.any?(contents_a, &String.contains?(&1, "Message for A"))
      refute Enum.any?(contents_a, &String.contains?(&1, "Message for B"))

      assert Enum.any?(contents_b, &String.contains?(&1, "Message for B"))
      # Assistant messages don't have timestamps, so exact match is fine
      assert "Response from B" in contents_b
      refute Enum.any?(contents_b, &String.contains?(&1, "Message for A"))
    end
  end

  describe "R3: Model Not Found" do
    test "returns empty list when model not in histories" do
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "Only in A", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      # This 2-arity function doesn't exist yet - will fail
      messages = ContextManager.build_conversation_messages(state, "nonexistent-model")

      # Should return empty list for missing model
      assert messages == []
    end
  end

  describe "R4: Preserves Message Order" do
    test "messages in chronological order" do
      # History stored newest-first (prepended), but output should be oldest-first
      now = DateTime.utc_now()

      state = %{
        model_histories: %{
          "model-a" => [
            # Newest first in storage
            %{type: :user, content: "Third message", timestamp: DateTime.add(now, 20, :second)},
            %{
              type: :assistant,
              content: "Second message",
              timestamp: DateTime.add(now, 10, :second)
            },
            %{type: :user, content: "First message", timestamp: now}
          ]
        },
        test_mode: true
      }

      # This 2-arity function doesn't exist yet - will fail
      messages = ContextManager.build_conversation_messages(state, "model-a")

      # Output should be oldest first (chronological for LLM)
      # User messages now have timestamp prefix
      contents = Enum.map(messages, & &1.content)
      assert String.contains?(List.first(contents), "First message")
      assert String.contains?(List.last(contents), "Third message")
    end
  end

  describe "R5: JSON Formatting Preserved" do
    test "decision entries formatted as JSON" do
      state = %{
        model_histories: %{
          "model-a" => [
            %{
              type: :decision,
              content: %{action: :send_message, params: %{target: "parent", content: "test"}},
              timestamp: DateTime.utc_now()
            }
          ]
        },
        test_mode: true
      }

      # This 2-arity function doesn't exist yet - will fail
      messages = ContextManager.build_conversation_messages(state, "model-a")

      # Decision should be formatted as JSON string
      assert length(messages) == 1
      [decision_msg] = messages
      assert decision_msg.role == "assistant"
      # Content should be valid JSON
      assert {:ok, _} = Jason.decode(decision_msg.content)
    end

    test "result entries formatted as JSON" do
      # Create state with result entry using StateUtils for proper format
      base_state = %{
        agent_id: "test-agent",
        action_counter: 1,
        model_histories: %{"model-a" => []}
      }

      state_with_result =
        StateUtils.add_history_entry_with_action(
          base_state,
          :result,
          {"action_123", {:ok, %{status: :ok, data: "completed"}}},
          :orient
        )

      state = Map.put(state_with_result, :test_mode, true)

      messages = ContextManager.build_conversation_messages(state, "model-a")

      # Result should be formatted as JSON string (with timestamp prefix)
      assert length(messages) == 1
      [result_msg] = messages
      assert result_msg.role == "user"
      # Content has timestamp prefix, extract JSON part after newline
      [_timestamp, json_part] = String.split(result_msg.content, "\n", parts: 2)
      assert {:ok, _} = Jason.decode(json_part)
    end
  end

  describe "R6: Empty History" do
    test "returns empty list for empty model history" do
      state = %{
        model_histories: %{
          "model-a" => []
        },
        test_mode: true
      }

      # This 2-arity function doesn't exist yet - will fail
      messages = ContextManager.build_conversation_messages(state, "model-a")

      assert messages == []
    end
  end

  describe "R7: Backward Compatibility" do
    test "existing entry formatting works with model_id parameter" do
      # Test all entry types work correctly
      # Note: consecutive same-role messages are merged to maintain alternation
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "User message", timestamp: DateTime.utc_now()},
            %{type: :assistant, content: "Assistant response", timestamp: DateTime.utc_now()},
            %{type: :prompt, content: "Initial prompt", timestamp: DateTime.utc_now()},
            %{type: :event, content: "System event", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      messages = ContextManager.build_conversation_messages(state, "model-a")

      # Should have 3 messages: user, assistant, user (prompt+event merged)
      # Consecutive user messages (prompt, event) are merged for alternation
      assert length(messages) == 3

      # Check roles are assigned correctly
      roles = Enum.map(messages, & &1.role)
      assert "user" in roles
      assert "assistant" in roles

      # Verify merged content contains both prompt and event
      merged_user =
        Enum.find(messages, fn m -> m.role == "user" && m.content =~ "Initial prompt" end)

      assert merged_user.content =~ "System event"
    end

    test "handles divergent histories after condensation" do
      # Simulate histories that diverged due to different condensation
      # Note: consecutive same-role messages are merged to maintain alternation
      state = %{
        model_histories: %{
          "model-a" => [
            # Model A was condensed - has summary
            %{
              type: :user,
              content: "Summary: Previous discussion about X",
              timestamp: DateTime.utc_now()
            },
            %{type: :user, content: "New question", timestamp: DateTime.utc_now()}
          ],
          "model-b" => [
            # Model B not condensed - has full history (properly alternating)
            %{type: :user, content: "Original message 1", timestamp: DateTime.utc_now()},
            %{type: :assistant, content: "Response 1", timestamp: DateTime.utc_now()},
            %{type: :user, content: "Original message 2", timestamp: DateTime.utc_now()},
            %{type: :assistant, content: "Response 2", timestamp: DateTime.utc_now()},
            %{type: :user, content: "New question", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      messages_a = ContextManager.build_conversation_messages(state, "model-a")
      messages_b = ContextManager.build_conversation_messages(state, "model-b")

      # Model A: two consecutive user messages merged into 1
      assert length(messages_a) == 1
      # Verify both contents are merged
      merged = hd(messages_a)
      assert merged.content =~ "Summary: Previous discussion about X"
      assert merged.content =~ "New question"

      # Model B: properly alternating, no merging needed
      assert length(messages_b) == 5
    end
  end

  # ==========================================================================
  # NOTE: v4.0 R8-R12 (ACE injection as system message) REMOVED in v7.0
  # ACE context is now injected by AceInjector into first user message.
  # See context_manager_ace_removal_test.exs for v7.0 R13-R15 tests.
  # ==========================================================================
end
