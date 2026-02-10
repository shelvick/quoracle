defmodule Quoracle.Agent.ContextManagerPromptIntegrationTest do
  @moduledoc """
  Tests for field-based prompt integration.

  NOTE: Field prompt injection into consensus messages was removed from
  build_conversation_messages/2 in v5.0 to fix N× duplication bug.
  Field prompts are now injected in Consensus.ensure_system_prompts/2.

  This module tests the remaining inject_field_prompts/2 helper function.
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.ContextManager

  describe "build_conversation_messages/2 (v5.0)" do
    @tag :unit
    test "WHEN agent has conversation history THEN returns formatted messages" do
      state = %{
        model_histories: %{
          "default" => [
            %{type: :prompt, content: "Help me test this"}
          ]
        }
      }

      messages = ContextManager.build_conversation_messages(state, "default")

      # Should have history
      assert Enum.any?(messages, fn msg ->
               String.contains?(msg.content, "Help me test this")
             end)
    end

    @tag :unit
    test "WHEN model_id not in histories THEN returns empty list" do
      state = %{
        model_histories: %{
          "model-a" => [%{type: :prompt, content: "Test"}]
        }
      }

      messages = ContextManager.build_conversation_messages(state, "nonexistent")

      assert messages == []
    end
  end

  describe "inject_field_prompts/2 - prompt injection helper" do
    @tag :unit
    test "WHEN messages empty AND field prompts present THEN creates initial messages" do
      field_prompts = %{
        system_prompt: "<role>Architect</role>",
        user_prompt: "<task>Design system</task>"
      }

      messages = ContextManager.inject_field_prompts([], field_prompts)

      assert length(messages) == 2
      assert hd(messages).role == "system"
      assert hd(messages).content == "<role>Architect</role>"

      assert List.last(messages).role == "user"
      assert List.last(messages).content == "<task>Design system</task>"
    end

    @tag :unit
    test "WHEN messages exist AND field prompts present THEN prepends field prompts" do
      existing_messages = [
        %{role: "user", content: "Previous conversation"}
      ]

      field_prompts = %{
        system_prompt: "<role>Engineer</role>",
        user_prompt: "<task>Debug issue</task>"
      }

      messages = ContextManager.inject_field_prompts(existing_messages, field_prompts)

      assert length(messages) == 3

      # Field system prompt first
      assert hd(messages).role == "system"
      assert hd(messages).content == "<role>Engineer</role>"

      # Field user prompt second
      assert Enum.at(messages, 1).role == "user"
      assert Enum.at(messages, 1).content == "<task>Debug issue</task>"

      # Existing messages preserved
      assert List.last(messages).content == "Previous conversation"
    end

    @tag :unit
    test "WHEN only system_prompt present THEN injects only system prompt" do
      field_prompts = %{system_prompt: "<role>Manager</role>"}

      messages = ContextManager.inject_field_prompts([], field_prompts)

      assert length(messages) == 1
      assert hd(messages) == %{role: "system", content: "<role>Manager</role>"}
    end

    @tag :unit
    test "WHEN only user_prompt present THEN injects only user prompt" do
      field_prompts = %{user_prompt: "<task>Create report</task>"}

      messages = ContextManager.inject_field_prompts([], field_prompts)

      assert length(messages) == 1
      assert hd(messages) == %{role: "user", content: "<task>Create report</task>"}
    end
  end
end
