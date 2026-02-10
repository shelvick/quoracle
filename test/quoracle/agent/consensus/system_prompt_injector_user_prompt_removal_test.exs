defmodule Quoracle.Agent.Consensus.SystemPromptInjectorUserPromptRemovalTest do
  @moduledoc """
  Tests for AGENT_Consensus v15.0: Remove user_prompt injection from SystemPromptInjector.

  WorkGroupID: fix-20260106-user-prompt-removal
  Packet: 1 (Message Flow)

  These tests verify that ensure_system_prompts does NOT inject user_prompt
  as a separate message. The initial message should flow through history instead.
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.Consensus.SystemPromptInjector

  describe "R81: No user_prompt Injection" do
    test "ensure_system_prompts does not inject user_prompt" do
      # Input: messages without user content, field_prompts with user_prompt
      messages = [
        %{role: "user", content: "existing user message"}
      ]

      field_prompts = %{
        user_prompt: "This is the initial task prompt",
        user_prompt_timestamp: DateTime.utc_now(),
        system_prompt: "<role>Test Agent</role>"
      }

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, [])

      # Count user messages
      user_messages = Enum.filter(result, &(&1.role == "user"))

      # FAIL: Currently SystemPromptInjector adds user_prompt as a second user message
      # After fix: Should only have the original user message (1 message)
      assert length(user_messages) == 1,
             "Should NOT inject user_prompt - expected 1 user message, got #{length(user_messages)}"

      # Verify the existing message is preserved
      [user_msg] = user_messages
      assert user_msg.content == "existing user message"
    end

    test "ensure_system_prompts does not add user_prompt when messages are empty" do
      # When there are no messages, user_prompt should NOT be injected
      messages = []

      field_prompts = %{
        user_prompt: "Task to perform",
        user_prompt_timestamp: DateTime.utc_now()
      }

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, [])

      # Filter user messages
      user_messages = Enum.filter(result, &(&1.role == "user"))

      # FAIL: Currently adds user_prompt as user message
      # After fix: Should have 0 user messages (user_prompt not injected)
      assert user_messages == [],
             "Should NOT inject user_prompt into empty messages - got #{length(user_messages)} user messages"
    end
  end

  describe "R82: Only System Messages Added" do
    test "ensure_system_prompts only adds system messages" do
      # Input messages with one user message
      messages = [
        %{role: "user", content: "Hello AI"}
      ]

      field_prompts = %{
        user_prompt: "Initial prompt that should NOT be injected",
        system_prompt: "<role>Agent</role>"
      }

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, [])

      # Count messages by role
      system_count = Enum.count(result, &(&1.role == "system"))
      user_count = Enum.count(result, &(&1.role == "user"))

      # Should have 1 system message (added) and 1 user message (original)
      assert system_count >= 1, "Should add system message"

      # FAIL: Currently user_count is 2 (original + injected user_prompt)
      # After fix: user_count should be 1 (only original)
      assert user_count == 1,
             "Should only have 1 user message (no injection) - got #{user_count}"
    end

    test "ensure_system_prompts does not modify user role messages" do
      original_user_content = "Original user message content"

      messages = [
        %{role: "user", content: original_user_content}
      ]

      field_prompts = %{
        user_prompt: "Injected prompt",
        system_prompt: "<role>Test</role>"
      }

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, [])

      # Get all user messages
      user_messages = Enum.filter(result, &(&1.role == "user"))

      # FAIL: Currently there are 2 user messages
      # After fix: Should be exactly 1 user message with original content
      assert length(user_messages) == 1,
             "Should not add any user messages - expected 1, got #{length(user_messages)}"

      # Original content should be preserved
      [user_msg] = user_messages
      assert user_msg.content == original_user_content
    end
  end

  describe "R83: Field Prompts Ignored for User" do
    test "user_prompt in field_prompts is ignored" do
      messages = [
        %{role: "user", content: "My question"}
      ]

      # field_prompts contains user_prompt that should be ignored
      field_prompts = %{
        user_prompt: "This should be completely ignored",
        user_prompt_timestamp: DateTime.utc_now(),
        system_prompt: "<role>Helper</role>"
      }

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, [])

      # Check that the ignored user_prompt content is NOT in the result
      all_content = Enum.map_join(result, " ", & &1.content)

      # FAIL: Currently the user_prompt content IS in the result
      # After fix: user_prompt content should NOT appear
      refute String.contains?(all_content, "This should be completely ignored"),
             "user_prompt from field_prompts should be ignored - found it in result"
    end

    test "user_prompt_timestamp in field_prompts is ignored" do
      messages = []
      timestamp = ~U[2025-01-01 12:00:00Z]

      field_prompts = %{
        user_prompt: "Prompt with timestamp",
        user_prompt_timestamp: timestamp,
        system_prompt: "<role>Agent</role>"
      }

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, [])

      # Get user messages
      user_messages = Enum.filter(result, &(&1.role == "user"))

      # FAIL: Currently there is 1 user message with the timestamp prepended
      # After fix: There should be 0 user messages (user_prompt ignored)
      assert user_messages == [],
             "user_prompt_timestamp should be ignored - no user messages should be added"
    end
  end

  describe "R84: No Duplicate Check Needed" do
    test "no duplicate user message checking logic" do
      # The current implementation has `has_field_user` logic to check for duplicates
      # After fix, this logic should not exist because user_prompt is never injected

      user_prompt_content = "Task description"

      messages = [
        %{role: "user", content: user_prompt_content}
      ]

      field_prompts = %{
        user_prompt: user_prompt_content,
        system_prompt: "<role>Agent</role>"
      }

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, [])

      _user_messages = Enum.filter(result, &(&1.role == "user"))

      # Current implementation: has_field_user check prevents duplicate
      # This test would pass with current impl because duplicate is prevented
      # But the point is: after fix, there's no duplicate check because user_prompt is never injected

      # FAIL: We need to verify the duplicate check logic doesn't exist
      # by checking that even with matching content, behavior is the same

      # With matching content (current: skips injection because duplicate detected)
      result_matching =
        SystemPromptInjector.ensure_system_prompts(messages, field_prompts, [])

      # With non-matching content (current: injects because no duplicate)
      field_prompts_different = %{
        user_prompt: "Different content that doesn't match",
        system_prompt: "<role>Agent</role>"
      }

      result_different =
        SystemPromptInjector.ensure_system_prompts(messages, field_prompts_different, [])

      matching_user_count = Enum.count(result_matching, &(&1.role == "user"))
      different_user_count = Enum.count(result_different, &(&1.role == "user"))

      # FAIL: Currently matching_user_count=1, different_user_count=2
      # (duplicate check prevents injection only when content matches)
      # After fix: Both should be 1 (no injection regardless of content)
      assert matching_user_count == different_user_count,
             "Behavior should be same regardless of content matching - " <>
               "matching: #{matching_user_count}, different: #{different_user_count}"

      assert different_user_count == 1,
             "Should not inject user_prompt even when content differs - got #{different_user_count}"
    end

    test "no has_field_user variable or check in logic" do
      # This test verifies the behavior that proves has_field_user check is removed
      # When user_prompt doesn't match any existing message, current impl injects it

      messages = [
        %{role: "user", content: "Existing message A"}
      ]

      field_prompts = %{
        user_prompt: "Completely different user_prompt B",
        system_prompt: "<role>Agent</role>"
      }

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, [])

      user_messages = Enum.filter(result, &(&1.role == "user"))

      # FAIL: Currently has 2 user messages (existing + injected because no duplicate)
      # After fix: Should have 1 user message (no injection at all)
      assert length(user_messages) == 1,
             "Should not inject user_prompt regardless of duplicate check - " <>
               "expected 1 user message, got #{length(user_messages)}"
    end
  end

  describe "Integration: System prompt handling unchanged" do
    test "system prompt is still added correctly" do
      # Verify that system prompt handling is NOT affected by user_prompt removal
      messages = [
        %{role: "user", content: "Hello"}
      ]

      field_prompts = %{
        user_prompt: "Should be ignored",
        system_prompt: "<role>Test Agent</role>"
      }

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, [])

      # Should have system message
      system_messages = Enum.filter(result, &(&1.role == "system"))
      assert system_messages != [], "System prompt should still be added"

      # System message should be first
      [first | _] = result
      assert first.role == "system", "System message should be at position 0"
    end
  end
end
