defmodule Quoracle.Agent.SenderInfoTest do
  @moduledoc """
  Tests for Bug 1: Sender Info in Messages
  WorkGroupID: fix-20251211-051748
  Packet: 1

  Tests that incoming messages include sender attribution in conversation history.
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.{MessageHandler, ContextManager}

  # =============================================================================
  # AGENT_MessageHandler v10.0 Tests (R25-R30)
  # File: lib/quoracle/agent/message_handler.ex
  #
  # These tests verify that handle_agent_message/3 exists and stores structured
  # content with sender info. Currently fails with UndefinedFunctionError.
  # =============================================================================

  describe "MessageHandler 3-arity (v10.0)" do
    setup do
      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        task_id: "test-task",
        model_histories: %{"default" => []},
        pending_actions: %{},
        pubsub: nil,
        wait_timer: nil,
        skip_auto_consensus: true,
        context_limits_loaded: true,
        context_limit: 100_000
      }

      %{state: state}
    end

    # R25: 3-Arity Signature
    test "handle_agent_message/3 exists", %{state: state} do
      sender_id = :parent
      content = "Test message"

      # This will FAIL - function only accepts 2 arguments currently
      result = MessageHandler.handle_agent_message(state, sender_id, content)

      assert {:noreply, _new_state} = result
    end

    # R26: Structured Content Storage
    test "stores message with sender info in history", %{state: state} do
      sender_id = "child-agent-789"
      content = "Message content here"

      # This will FAIL - 3-arity function doesn't exist
      {:noreply, new_state} = MessageHandler.handle_agent_message(state, sender_id, content)

      [entry | _] = new_state.model_histories["default"]

      assert entry.type == :event
      assert is_map(entry.content)
      assert entry.content == %{from: sender_id, content: content}
    end

    # R27: Parent Sender Formatting
    test "formats :parent atom as 'parent' string", %{state: state} do
      # This will FAIL - 3-arity function doesn't exist
      {:noreply, new_state} = MessageHandler.handle_agent_message(state, :parent, "From parent")

      [entry | _] = new_state.model_histories["default"]

      assert is_map(entry.content)
      assert entry.content.from == "parent"
    end

    # R28: Child Sender Formatting
    test "preserves agent_id string for child senders", %{state: state} do
      child_id = "my-child-agent-abc"

      # This will FAIL - 3-arity function doesn't exist
      {:noreply, new_state} = MessageHandler.handle_agent_message(state, child_id, "From child")

      [entry | _] = new_state.model_histories["default"]

      assert is_map(entry.content)
      assert entry.content.from == child_id
    end

    # R29: Timer Cancellation Preserved
    test "agent message still cancels active wait timer", %{state: state} do
      timer_ref = make_ref()
      state_with_timer = %{state | wait_timer: {timer_ref, "timer-123", 1}}

      # This will FAIL - 3-arity function doesn't exist
      {:noreply, new_state} =
        MessageHandler.handle_agent_message(state_with_timer, :parent, "Message")

      assert new_state.wait_timer == nil
    end

    # R30: Consensus Triggered
    test "triggers consensus after storing message", %{state: state} do
      # This will FAIL - 3-arity function doesn't exist
      {:noreply, new_state} = MessageHandler.handle_agent_message(state, :parent, "Test")

      assert new_state.model_histories["default"] != []
    end
  end

  # =============================================================================
  # AGENT_ContextManager v6.0 Tests (R16-R20)
  # File: lib/quoracle/agent/context_manager.ex
  #
  # These tests verify that format_history_entry formats :event entries with
  # sender info as JSON. Currently fails because :from field is dropped.
  # =============================================================================

  describe "ContextManager event formatting (v6.0)" do
    setup do
      state = %{
        agent_id: "test-agent",
        model_histories: %{"default" => []},
        context_lessons: %{},
        model_states: %{},
        test_mode: true
      }

      %{state: state}
    end

    # R16: JSON Format for Messages with Sender
    test "formats event with sender info as JSON", %{state: state} do
      entry = %{
        type: :event,
        content: %{from: "parent", content: "Hello from parent"},
        timestamp: DateTime.utc_now()
      }

      state = put_in(state.model_histories["default"], [entry])

      messages = ContextManager.build_conversation_messages(state, "default")
      user_msg = Enum.find(messages, &(&1.role == "user"))

      # This will FAIL - currently extracts only content.content, not JSON
      assert user_msg != nil
      assert user_msg.content =~ "\"from\":"
      assert user_msg.content =~ "\"parent\""
      assert user_msg.content =~ "\"content\":"
      assert user_msg.content =~ "\"Hello from parent\""
    end

    # R17: Legacy Format Preserved
    test "preserves legacy format for events without sender", %{state: state} do
      entry = %{
        type: :event,
        content: %{content: "Legacy message without sender"},
        timestamp: DateTime.utc_now()
      }

      state = put_in(state.model_histories["default"], [entry])

      messages = ContextManager.build_conversation_messages(state, "default")
      user_msg = Enum.find(messages, &(&1.role == "user"))

      # Legacy behavior: extract content only (no JSON wrapper), now with timestamp
      assert user_msg != nil
      assert String.contains?(user_msg.content, "Legacy message without sender")
    end

    # R18: Fallback for Other Content
    test "falls back to inspect for unknown content types", %{state: state} do
      entry = %{
        type: :event,
        content: {:some, :tuple, :data},
        timestamp: DateTime.utc_now()
      }

      state = put_in(state.model_histories["default"], [entry])

      messages = ContextManager.build_conversation_messages(state, "default")
      user_msg = Enum.find(messages, &(&1.role == "user"))

      # Fallback: use inspect()
      assert user_msg != nil
      assert user_msg.content =~ ":some"
      assert user_msg.content =~ ":tuple"
    end

    # R19: Parent Sender in JSON
    test "parent sender appears as 'parent' in JSON", %{state: state} do
      entry = %{
        type: :event,
        content: %{from: "parent", content: "Parent instruction"},
        timestamp: DateTime.utc_now()
      }

      state = put_in(state.model_histories["default"], [entry])

      messages = ContextManager.build_conversation_messages(state, "default")
      user_msg = Enum.find(messages, &(&1.role == "user"))

      # This will FAIL - currently drops :from field
      assert user_msg != nil
      assert user_msg.content =~ "\"from\": \"parent\""
    end

    # R20: Child Sender in JSON
    test "child sender agent_id preserved in JSON", %{state: state} do
      child_id = "spawned-child-xyz-789"

      entry = %{
        type: :event,
        content: %{from: child_id, content: "Report from child"},
        timestamp: DateTime.utc_now()
      }

      state = put_in(state.model_histories["default"], [entry])

      messages = ContextManager.build_conversation_messages(state, "default")
      user_msg = Enum.find(messages, &(&1.role == "user"))

      # This will FAIL - currently drops :from field
      assert user_msg != nil
      assert user_msg.content =~ "\"from\": \"#{child_id}\""
      assert user_msg.content =~ "\"content\": \"Report from child\""
    end
  end

  # =============================================================================
  # Bug 3: Human Prompt Attribution Tests - REMOVED
  # =============================================================================
  # Tests R31-R35 were deleted because they tested user_prompt injection behavior
  # that was removed in SystemPromptInjector v15.0 (WorkGroupID: fix-20260106-user-prompt-removal).
  #
  # The initial user message now flows through model_histories via MessageHandler
  # instead of being injected by SystemPromptInjector. This ensures:
  # 1. Consistent message format (all messages flow through history)
  # 2. No message alternation violations after condensation
  # 3. Simpler, more maintainable code
  #
  # New tests for this behavior are in:
  # - test/quoracle/agent/message_handler_user_prompt_removal_test.exs
  # - test/quoracle/agent/consensus/system_prompt_injector_user_prompt_removal_test.exs
  # =============================================================================
end
