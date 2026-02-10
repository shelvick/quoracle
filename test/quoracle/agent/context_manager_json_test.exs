defmodule Quoracle.Agent.ContextManagerJsonTest do
  @moduledoc """
  Tests for JSON formatting in ContextManager.build_conversation_messages/1.
  Verifies that :decision and :result history entries are formatted as JSON
  instead of Elixir inspect() format for improved LLM understanding.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Quoracle.Agent.ContextManager
  alias Quoracle.Agent.StateUtils

  describe "JSON formatting for history entries (Packet 2)" do
    # R1: Decision Entry JSON Formatting
    test "formats decision entries as JSON" do
      decision_content = %{
        action: :execute_shell,
        params: %{command: "ls -la"},
        reasoning: "Need to list directory contents"
      }

      state = %{
        model_histories: %{
          "default" => [
            %{
              type: :decision,
              content: decision_content,
              timestamp: DateTime.utc_now()
            }
          ]
        },
        # No field-based prompts
        prompt_fields: nil
      }

      messages = ContextManager.build_conversation_messages(state, "default")

      # Messages include system prompt from ensure_system_prompts
      # Find the decision message (skip system prompts)
      decision_msg = Enum.find(messages, fn msg -> msg.role == "assistant" end)
      assert decision_msg != nil

      # Content should be JSON formatted
      content = decision_msg.content

      # Should contain JSON structure
      assert content =~ "\"action\": \"execute_shell\""
      assert content =~ "\"params\":"
      assert content =~ "\"command\": \"ls -la\""
      assert content =~ "\"reasoning\":"

      # Should NOT contain Elixir inspect() syntax
      refute content =~ "action: :execute_shell"
      refute content =~ "%{command:"
      refute content =~ "%{"
    end

    # R2: Result Entry JSON Formatting
    test "formats result entries as JSON" do
      action_id = "action_agent_123_5"
      result_data = {:ok, %{stdout: "file1.txt\nfile2.txt", exit_code: 0}}

      # Create state using StateUtils to get properly wrapped entry
      base_state = %{
        agent_id: "test-agent",
        action_counter: 1,
        model_histories: %{"default" => []}
      }

      state_with_result =
        StateUtils.add_history_entry_with_action(
          base_state,
          :result,
          {action_id, result_data},
          :execute_shell
        )

      state = Map.put(state_with_result, :prompt_fields, nil)

      messages = ContextManager.build_conversation_messages(state, "default")

      # Messages include system prompt from ensure_system_prompts
      # Find the result message (role: user for results)
      result_msg =
        Enum.find(messages, fn msg -> msg.role == "user" && msg.content =~ "action_agent" end)

      assert result_msg != nil

      # Content should be JSON formatted
      content = result_msg.content

      # Should contain JSON structure for the tuple
      assert content =~ "\"type\": \"ok\""
      assert content =~ "\"value\":"
      assert content =~ "\"stdout\":"
      assert content =~ "\"exit_code\": 0"

      # Should include the action_id in JSON
      assert content =~ action_id

      # Should NOT contain Elixir syntax
      refute content =~ "{:ok"
      refute content =~ "exit_code:"
      refute content =~ "%{"
    end

    # R3: No Elixir Syntax in Decisions
    test "decision output contains no Elixir syntax" do
      # Test with various Elixir-specific types in decision
      decision_content = %{
        action: :fetch_web,
        params: %{
          url: "https://example.com",
          headers: [{"User-Agent", "Test"}],
          options: %{timeout: 5000, retries: 3}
        },
        atoms: [:one, :two, :three],
        tuple: {:status, :active}
      }

      state = %{
        model_histories: %{
          "default" => [
            %{
              type: :decision,
              content: decision_content,
              timestamp: DateTime.utc_now()
            }
          ]
        },
        prompt_fields: nil
      }

      messages = ContextManager.build_conversation_messages(state, "default")

      # Find the decision message (assistant role)
      decision_msg = Enum.find(messages, fn msg -> msg.role == "assistant" end)
      assert decision_msg != nil
      content = decision_msg.content

      # Should NOT have any Elixir-specific syntax
      refute content =~ ":fetch_web"
      refute content =~ ":one"
      refute content =~ "{:status"
      # Keyword list syntax
      refute content =~ "[{\"User-Agent\""
      refute content =~ "timeout:"
      refute content =~ "%{"
      refute content =~ "=>"

      # Should have JSON equivalents
      assert content =~ "\"fetch_web\""
      assert content =~ "\"one\""
      assert content =~ "\"timeout\": 5000"
    end

    # R4: No Elixir Syntax in Results
    test "result output contains no Elixir syntax" do
      # Test with various Elixir-specific types in result
      action_id = "action_test_456"

      result_data =
        {:error,
         %{
           reason: :network_error,
           details: %{
             host: "api.example.com",
             port: 443,
             atoms: [:ssl_error, :timeout],
             metadata: [attempts: 3, last_error: :connection_refused]
           }
         }}

      # Create state using StateUtils to get properly wrapped entry
      base_state = %{
        agent_id: "test-agent",
        action_counter: 1,
        model_histories: %{"default" => []}
      }

      state_with_result =
        StateUtils.add_history_entry_with_action(
          base_state,
          :result,
          {action_id, result_data},
          :fetch_web
        )

      state = Map.put(state_with_result, :prompt_fields, nil)

      messages = ContextManager.build_conversation_messages(state, "default")

      # Find the result message (user role, contains error data)
      result_msg =
        Enum.find(messages, fn msg -> msg.role == "user" && msg.content =~ "action_test" end)

      assert result_msg != nil
      content = result_msg.content

      # Should NOT have any Elixir-specific syntax
      refute content =~ ":network_error"
      refute content =~ ":ssl_error"
      refute content =~ "{:error"
      refute content =~ "reason:"
      refute content =~ "[attempts:"
      refute content =~ ":connection_refused"

      # Should have JSON equivalents
      assert content =~ "\"network_error\""
      assert content =~ "\"ssl_error\""
      assert content =~ "\"attempts\": 3"
      assert content =~ "\"connection_refused\""
    end

    # R5: JSON Pretty-Printing
    test "history entries use pretty-printed JSON" do
      # Complex nested structure to verify pretty-printing
      decision_content = %{
        action: :call_api,
        params: %{
          endpoint: "/users",
          method: "POST",
          body: %{
            user: %{
              name: "Test User",
              email: "test@example.com",
              preferences: %{
                theme: "dark",
                notifications: true
              }
            }
          }
        }
      }

      state = %{
        model_histories: %{
          "default" => [
            %{
              type: :decision,
              content: decision_content,
              timestamp: DateTime.utc_now()
            }
          ]
        },
        prompt_fields: nil
      }

      messages = ContextManager.build_conversation_messages(state, "default")

      # Find the decision message (assistant role)
      decision_msg = Enum.find(messages, fn msg -> msg.role == "assistant" end)
      assert decision_msg != nil
      content = decision_msg.content

      # Should be pretty-printed with newlines and indentation
      assert content =~ ~r/\n\s+/
      assert content =~ "{\n"

      # Multiple levels of indentation for nested structures
      lines = String.split(content, "\n")
      # Should have varying indentation levels
      assert Enum.any?(lines, &String.starts_with?(&1, "  "))
      assert Enum.any?(lines, &String.starts_with?(&1, "    "))
    end

    # R6: Maintains Existing History Types
    # Note: consecutive same-role messages are merged to maintain alternation
    test "maintains correct processing of assistant and user messages" do
      # Create base state with result entry using StateUtils
      base_state = %{
        agent_id: "test-agent",
        action_counter: 1,
        model_histories: %{"default" => []}
      }

      state_with_result =
        StateUtils.add_history_entry_with_action(
          base_state,
          :result,
          {"action_123", {:ok, %{stdout: "file.txt"}}},
          :execute_shell
        )

      # Get the result entry that was added
      [result_entry] = state_with_result.model_histories["default"]

      # Build state with all entries
      # List order: most recent first, oldest last
      # Chronological order when processed: result -> user -> assistant -> decision
      # After merge: user, user (alternation broken by assistant in between), assistant
      # But we want: result(user) -> decision(assistant) -> assistant -> user
      # So order in list (reversed): user, assistant, decision, result
      state = %{
        model_histories: %{
          "default" => [
            %{
              type: :user,
              content: "Please list the files in the current directory.",
              timestamp: DateTime.utc_now()
            },
            %{
              type: :assistant,
              content: "I'll help you with that task.",
              timestamp: DateTime.utc_now()
            },
            %{
              type: :decision,
              content: %{action: :execute_shell, params: %{command: "ls"}},
              timestamp: DateTime.utc_now()
            },
            result_entry
          ]
        },
        prompt_fields: nil
      }

      messages = ContextManager.build_conversation_messages(state, "default")

      # History chronological: result(user), decision(assistant), assistant, user
      # After merge: user, assistant (merged decision+assistant content), user
      assert length(messages) == 3

      assistant_msgs = Enum.filter(messages, fn msg -> msg.role == "assistant" end)
      user_msgs = Enum.filter(messages, fn msg -> msg.role == "user" end)

      # Should have 1 merged assistant message containing both decision JSON and text
      assert length(assistant_msgs) == 1
      merged_assistant = hd(assistant_msgs)

      # Merged assistant contains decision JSON and the follow-up text
      assert merged_assistant.content =~ "\"action\": \"execute_shell\""
      assert merged_assistant.content =~ "I'll help you with that task."

      # Check user message (now with timestamp prefix)
      user_msg =
        Enum.find(user_msgs, fn msg ->
          String.contains?(msg.content, "Please list the files in the current directory.")
        end)

      assert user_msg != nil

      # The decision is now merged into the single assistant message
      decision_msg =
        Enum.find(assistant_msgs, fn msg -> msg.content =~ "\"action\": \"execute_shell\"" end)

      assert decision_msg != nil

      # Check result (now JSON)
      result_msg = Enum.find(user_msgs, fn msg -> msg.content =~ "\"type\": \"ok\"" end)
      assert result_msg != nil
    end

    # Test with non-serializable types
    test "handles non-serializable types in history entries" do
      pid = self()
      ref = make_ref()

      decision_content = %{
        action: :spawn_child,
        params: %{
          config: %{
            parent_pid: pid,
            monitor_ref: ref,
            task: "child task"
          }
        }
      }

      state = %{
        model_histories: %{
          "default" => [
            %{
              type: :decision,
              content: decision_content,
              timestamp: DateTime.utc_now()
            }
          ]
        },
        prompt_fields: nil
      }

      messages = ContextManager.build_conversation_messages(state, "default")

      # Find the decision message (assistant role)
      decision_msg = Enum.find(messages, fn msg -> msg.role == "assistant" end)
      assert decision_msg != nil
      content = decision_msg.content

      # Should convert non-serializable types to strings
      assert content =~ "#PID"
      assert content =~ "#Reference"

      # Should still be valid JSON structure
      assert content =~ "\"parent_pid\":"
      assert content =~ "\"monitor_ref\":"
    end

    # Test empty/nil values
    test "handles nil and empty values in history" do
      decision_content = %{
        action: :orient,
        params: nil,
        options: %{},
        items: []
      }

      state = %{
        model_histories: %{
          "default" => [
            %{
              type: :decision,
              content: decision_content,
              timestamp: DateTime.utc_now()
            }
          ]
        },
        prompt_fields: nil
      }

      messages = ContextManager.build_conversation_messages(state, "default")

      # Find the decision message (assistant role)
      decision_msg = Enum.find(messages, fn msg -> msg.role == "assistant" end)
      assert decision_msg != nil
      content = decision_msg.content

      # Should handle nil/empty properly in JSON
      assert content =~ "\"params\": null"
      assert content =~ "\"options\": {}"
      assert content =~ "\"items\": []"
    end

    # R7: Integration with Existing Tests
    test "all existing ContextManager tests pass with JSON format" do
      # This test simulates the key patterns from existing ContextManager tests
      # but expects JSON output instead of inspect() format

      # Pattern 1: Simple decision and result
      base_state = %{
        agent_id: "test-agent",
        action_counter: 1,
        model_histories: %{"default" => []}
      }

      state_with_result =
        StateUtils.add_history_entry_with_action(
          base_state,
          :result,
          {"action_agent_1", {:ok, :timeout}},
          :wait
        )

      [result_entry] = state_with_result.model_histories["default"]

      state = %{
        model_histories: %{
          "default" => [
            %{
              type: :decision,
              content: %{action: :wait, params: %{duration: 1000}},
              timestamp: DateTime.utc_now()
            },
            result_entry
          ]
        },
        prompt_fields: nil
      }

      messages = ContextManager.build_conversation_messages(state, "default")

      # Find the decision and result messages (skip system prompt)
      decision = Enum.find(messages, fn msg -> msg.role == "assistant" end)

      result =
        Enum.find(messages, fn msg -> msg.role == "user" && msg.content =~ "action_agent" end)

      assert decision != nil
      assert result != nil

      # Both should be JSON formatted
      assert decision.content =~ "\"action\": \"wait\""
      assert decision.content =~ "\"duration\": 1000"

      assert result.content =~ "\"type\": \"ok\""
      assert result.content =~ "\"timeout\""

      # Pattern 2: User message with nested content (from existing tests)
      state2 = %{
        model_histories: %{
          "default" => [
            %{
              type: :user,
              content: %{content: "nested user message"},
              timestamp: DateTime.utc_now()
            }
          ]
        },
        prompt_fields: nil
      }

      messages2 = ContextManager.build_conversation_messages(state2, "default")

      # Find the user message (skip system prompt)
      user_msg =
        Enum.find(messages2, fn msg ->
          msg.role == "user" && String.contains?(msg.content, "nested user message")
        end)

      assert user_msg != nil

      # User messages should extract nested content correctly
      assert String.contains?(user_msg.content, "nested user message")
    end
  end

  describe "edge cases and error handling" do
    test "handles empty conversation history" do
      state = %{
        model_histories: %{"default" => []},
        prompt_fields: nil
      }

      messages = ContextManager.build_conversation_messages(state, "default")

      # Only system prompt present (ensure_system_prompts adds it)
      # Filter to history messages (not system prompts)
      history_msgs = Enum.filter(messages, fn msg -> msg.role != "system" end)
      assert history_msgs == []
    end

    test "handles complex nested tuple structures in results" do
      action_id = "action_complex_789"
      # Complex nested structure with various tuple formats
      result_data =
        {:ok,
         %{
           data: {:nested, {:double, "value"}},
           status: {:error, {:retry, 3}},
           metadata: [
             {:key1, "value1"},
             {:key2, {:nested, "value2"}}
           ]
         }}

      # Create state using StateUtils to get properly wrapped entry
      base_state = %{
        agent_id: "test-agent",
        action_counter: 1,
        model_histories: %{"default" => []}
      }

      state_with_result =
        StateUtils.add_history_entry_with_action(
          base_state,
          :result,
          {action_id, result_data},
          :call_api
        )

      state = Map.put(state_with_result, :prompt_fields, nil)

      messages = ContextManager.build_conversation_messages(state, "default")

      # Find the result message
      result_msg =
        Enum.find(messages, fn msg -> msg.role == "user" && msg.content =~ "action_complex" end)

      assert result_msg != nil
      content = result_msg.content

      # Should handle complex nested tuples
      assert content =~ "\"type\": \"ok\""
      assert content =~ "\"data\":"
      assert content =~ "\"status\":"

      # No Elixir tuple syntax
      refute content =~ "{:nested"
      refute content =~ "{:double"
      refute content =~ "{:retry"
    end

    test "handles malformed history entries gracefully" do
      # Test with history entries that might not have expected structure
      # New format: result entries should have pre-wrapped content string
      # Malformed entries test graceful degradation

      state = %{
        model_histories: %{
          "default" => [
            %{
              type: :result,
              # Content should be a pre-wrapped string; nil tests graceful handling
              content: nil,
              action_id: "action_malformed_1",
              result: {:ok, "test"},
              timestamp: DateTime.utc_now()
            },
            %{
              type: :decision,
              # String instead of expected map (malformed)
              content: "string instead of map",
              timestamp: DateTime.utc_now()
            }
          ]
        },
        prompt_fields: nil
      }

      # Capture expected log from AlternationGuard about unexpected content type
      capture_log(fn ->
        messages = ContextManager.build_conversation_messages(state, "default")

        # Find the decision message (skip system prompt)
        decision_msg = Enum.find(messages, fn msg -> msg.role == "assistant" end)

        assert decision_msg != nil

        # String should be JSON-encoded for decision
        assert decision_msg.content =~ "\"string instead of map\""

        # Result with nil content should still produce a message (graceful handling)
        # The system should not crash on malformed entries
        user_msgs = Enum.filter(messages, fn msg -> msg.role == "user" end)
        assert is_list(user_msgs)
      end)
    end
  end
end
