defmodule Quoracle.Agent.ContextManagerACERemovalTest do
  @moduledoc """
  Tests for ContextManager v7.0 - removal of ACE system message injection.

  ACE context (lessons + model_state) is now injected by AceInjector into the
  first user message, NOT as a system message by ContextManager.

  WorkGroupID: wip-20260104-ace-injector
  Packet: 1 (ACE Injector)

  ARC Verification Criteria: R13-R15
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.ContextManager

  # ========== TEST HELPERS ==========

  defp make_lesson(content, type \\ :factual, confidence \\ 0.8) do
    %{
      content: content,
      type: type,
      confidence: confidence
    }
  end

  defp make_model_state(summary) do
    %{summary: summary}
  end

  defp make_history_entry(type, content) do
    %{type: type, content: content, timestamp: DateTime.utc_now()}
  end

  defp make_result_entry(action_id, result) do
    %{
      type: :result,
      content: Jason.encode!([action_id, result], pretty: true),
      action_id: action_id,
      result: result,
      timestamp: DateTime.utc_now()
    }
  end

  defp make_state_with_ace(model_id) do
    %{
      agent_id: "test-agent",
      task_id: "test-task",
      model_histories: %{
        model_id => [
          make_history_entry(:user, "Hello"),
          make_history_entry(:assistant, "Hi there")
        ]
      },
      context_lessons: %{
        model_id => [
          make_lesson("Important lesson 1"),
          make_lesson("Important lesson 2", :behavioral)
        ]
      },
      model_states: %{
        model_id => make_model_state("Task is 50% complete")
      },
      context_summary: nil,
      additional_context: []
    }
  end

  # ========== R13: NO ACE SYSTEM MESSAGE ==========

  describe "R13: no ACE system message" do
    test "no system message with lessons content added" do
      model_id = "test-model"
      state = make_state_with_ace(model_id)

      messages = ContextManager.build_conversation_messages(state, model_id)

      # Check that no message contains <lessons> tag (which would indicate ACE injection)
      system_messages = Enum.filter(messages, &(&1.role == "system"))

      for msg <- system_messages do
        refute msg.content =~ "<lessons>", "System message should not contain <lessons>"

        refute msg.content =~ "Important lesson",
               "System message should not contain lesson content"
      end
    end

    test "no system message with state content added" do
      model_id = "test-model"
      state = make_state_with_ace(model_id)

      messages = ContextManager.build_conversation_messages(state, model_id)

      system_messages = Enum.filter(messages, &(&1.role == "system"))

      for msg <- system_messages do
        refute msg.content =~ "<state>", "System message should not contain <state>"
        refute msg.content =~ "50% complete", "System message should not contain state summary"
      end
    end

    test "no ACE content in any system message" do
      model_id = "anthropic:claude-sonnet-4"
      state = make_state_with_ace(model_id)

      messages = ContextManager.build_conversation_messages(state, model_id)

      # No system message should contain any ACE-related content
      system_messages = Enum.filter(messages, &(&1.role == "system"))

      for msg <- system_messages do
        refute msg.content =~ "[Fact]", "System message should not contain [Fact] label"
        refute msg.content =~ "[Pattern]", "System message should not contain [Pattern] label"
      end
    end
  end

  # ========== R14: LESSONS VARIABLES REMOVED ==========

  describe "R14: ignores ACE state fields" do
    test "does not access context_lessons field" do
      model_id = "test-model"

      state = %{
        agent_id: "test-agent",
        task_id: "test-task",
        model_histories: %{
          model_id => [make_history_entry(:user, "Hello")]
        },
        context_lessons: %{model_id => [make_lesson("Lesson")]},
        model_states: %{},
        context_summary: nil,
        additional_context: []
      }

      # Should not include lesson content in output
      messages = ContextManager.build_conversation_messages(state, model_id)

      all_content = Enum.map_join(messages, " ", & &1.content)
      refute all_content =~ "Lesson", "Should not include lesson content"
    end

    test "does not access model_states field for system message" do
      model_id = "test-model"

      state = %{
        agent_id: "test-agent",
        task_id: "test-task",
        model_histories: %{
          model_id => [make_history_entry(:user, "Hello")]
        },
        context_lessons: %{},
        model_states: %{model_id => make_model_state("State summary")},
        context_summary: nil,
        additional_context: []
      }

      messages = ContextManager.build_conversation_messages(state, model_id)

      # Check system messages don't contain state summary
      system_messages = Enum.filter(messages, &(&1.role == "system"))

      for msg <- system_messages do
        refute msg.content =~ "State summary", "System message should not contain model state"
      end
    end

    test "works correctly even with rich ACE data present" do
      model_id = "google:gemini-2.0-flash"

      # State with lots of ACE data that should be ignored
      state = %{
        agent_id: "test-agent",
        task_id: "test-task",
        model_histories: %{
          model_id => [
            make_history_entry(:user, "User message"),
            make_history_entry(:assistant, "Assistant response")
          ]
        },
        context_lessons: %{
          model_id => [
            make_lesson("Lesson 1"),
            make_lesson("Lesson 2"),
            make_lesson("Lesson 3", :behavioral)
          ]
        },
        model_states: %{
          model_id => make_model_state("Rich state summary with details")
        },
        context_summary: nil,
        additional_context: []
      }

      # Should complete without errors and not include ACE content
      messages = ContextManager.build_conversation_messages(state, model_id)

      assert is_list(messages)
      all_content = Enum.map_join(messages, " ", & &1.content)
      refute all_content =~ "Lesson 1"
      refute all_content =~ "Rich state summary"
    end
  end

  # ========== R15: EXISTING FUNCTIONALITY PRESERVED ==========

  describe "R15: preserves existing functionality" do
    test "still handles context_summary correctly" do
      model_id = "test-model"

      state = %{
        agent_id: "test-agent",
        task_id: "test-task",
        model_histories: %{
          model_id => [make_history_entry(:user, "Hello")]
        },
        context_summary: "This is a summary of previous conversation",
        additional_context: [],
        context_lessons: %{},
        model_states: %{}
      }

      messages = ContextManager.build_conversation_messages(state, model_id)

      # context_summary should still be included somewhere in messages
      all_content = Enum.map_join(messages, " ", & &1.content)
      assert all_content =~ "summary of previous conversation"
    end

    test "still handles additional_context correctly" do
      model_id = "test-model"

      state = %{
        agent_id: "test-agent",
        task_id: "test-task",
        model_histories: %{
          model_id => [make_history_entry(:user, "Hello")]
        },
        context_summary: nil,
        additional_context: [%{role: "system", content: "Additional context for this task"}],
        context_lessons: %{},
        model_states: %{}
      }

      messages = ContextManager.build_conversation_messages(state, model_id)

      # additional_context should still be included
      all_content = Enum.map_join(messages, " ", & &1.content)
      assert all_content =~ "Additional context for this task"
    end

    test "history entries still processed correctly" do
      model_id = "test-model"

      state = %{
        agent_id: "test-agent",
        task_id: "test-task",
        model_histories: %{
          model_id => [
            make_history_entry(:user, "User said this"),
            make_history_entry(:assistant, "Assistant replied"),
            make_history_entry(:decision, %{action: "orient", params: %{}}),
            make_result_entry("action_123", %{result: "success"})
          ]
        },
        context_lessons: %{model_id => [make_lesson("Ignored")]},
        model_states: %{model_id => make_model_state("Also ignored")},
        context_summary: nil,
        additional_context: []
      }

      messages = ContextManager.build_conversation_messages(state, model_id)

      # Should have processed history entries (may be merged, no ACE system msg)
      assert length(messages) >= 2

      # User and assistant messages should be present
      roles = Enum.map(messages, & &1.role)
      assert "user" in roles
      assert "assistant" in roles
    end

    test "event entries still processed correctly" do
      model_id = "test-model"

      state = %{
        agent_id: "test-agent",
        task_id: "test-task",
        model_histories: %{
          model_id => [
            make_history_entry(:event, %{from: "parent", content: "Message from parent"})
          ]
        },
        context_lessons: %{},
        model_states: %{},
        context_summary: nil,
        additional_context: []
      }

      messages = ContextManager.build_conversation_messages(state, model_id)

      # Event should be processed (as user message typically)
      assert messages != []
      all_content = Enum.map_join(messages, " ", & &1.content)
      # Event with sender info is JSON formatted, should contain parent attribution
      assert all_content =~ "parent"
    end
  end
end
