defmodule Quoracle.Consensus.ActionParserTodoTest do
  use ExUnit.Case, async: true

  alias Quoracle.Consensus.ActionParser

  describe "parse_json_response/1 with todo action" do
    test "parses todo action with items list" do
      json = """
      {
        "action": "todo",
        "params": {
          "items": [
            {"content": "First task", "state": "todo"},
            {"content": "Second task", "state": "pending"},
            {"content": "Third task", "state": "done"}
          ]
        },
        "reasoning": "Testing basic todo parsing",
        "wait": false
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      assert parsed.action == :todo
      assert is_list(parsed.params["items"])
      assert length(parsed.params["items"]) == 3
      assert parsed.wait == false
    end

    test "parses todo action from markdown code block" do
      response = """
      Here's my plan:

      ```json
      {
        "action": "todo",
        "params": {
          "items": [
            {"content": "Analyze requirements", "state": "done"},
            {"content": "Implement feature", "state": "todo"}
          ]
        },
        "reasoning": "Testing markdown extraction",
        "wait": true
      }
      ```
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(response)
      assert parsed.action == :todo
      assert length(parsed.params["items"]) == 2
      assert parsed.wait == true
    end

    test "todo is in valid actions list" do
      # Get all valid actions (this might be a private function, but we can test indirectly)
      valid_json = """
      {
        "action": "todo",
        "params": {"items": []},
        "reasoning": "Testing todo action validity",
        "wait": false
      }
      """

      # Should not return invalid_action error
      assert {:ok, parsed} = ActionParser.parse_json_response(valid_json)
      assert parsed.action == :todo
    end

    test "parses todo with empty items list" do
      json = """
      {
        "action": "todo",
        "params": {"items": []},
        "reasoning": "Testing empty list handling",
        "wait": false
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      assert parsed.action == :todo
      assert parsed.params["items"] == []
    end

    test "parses todo with string states (converts to atoms)" do
      json = """
      {
        "action": "todo",
        "params": {
          "items": [
            {"content": "Task", "state": "todo"}
          ]
        },
        "reasoning": "Testing string to atom conversion"
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      assert parsed.action == :todo

      # Parser should convert string "todo" to atom :todo
      [item | _] = parsed.params["items"]
      # Raw JSON keeps strings
      assert item["state"] == "todo"
    end

    test "parses todo with reasoning field" do
      json = """
      {
        "action": "todo",
        "params": {
          "items": [
            {"content": "Update database", "state": "pending"}
          ]
        },
        "wait": false,
        "reasoning": "Organizing tasks for better workflow"
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      assert parsed.action == :todo
      assert parsed.reasoning == "Organizing tasks for better workflow"
    end

    test "parses todo with numeric wait value" do
      json = """
      {
        "action": "todo",
        "params": {
          "items": [
            {"content": "Long task", "state": "todo"}
          ]
        },
        "reasoning": "Testing numeric wait value",
        "wait": 5
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      assert parsed.action == :todo
      assert parsed.wait == 5
    end

    test "returns error for invalid todo params structure" do
      json = """
      {
        "action": "todo",
        "params": "not an object"
      }
      """

      assert {:error, _} = ActionParser.parse_json_response(json)
    end

    test "handles todo action in mixed action responses" do
      # When LLMs return multiple possible actions
      json = """
      {
        "action": "todo",
        "alternate_action": "wait",
        "params": {
          "items": [
            {"content": "Planning task", "state": "todo"}
          ]
        },
        "reasoning": "Mixed action response test"
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      assert parsed.action == :todo
    end
  end

  describe "backwards compatibility" do
    test "todo works with existing action parsing flow" do
      # Ensure todo doesn't break existing patterns (using correct action names)
      actions = [
        :spawn_child,
        :wait,
        :send_message,
        :orient,
        :answer_engine,
        :fetch_web,
        :execute_shell,
        :call_api,
        :call_mcp,
        # New action
        :todo
      ]

      for action <- actions do
        json = """
        {
          "action": "#{action}",
          "params": {},
          "reasoning": "Testing backward compatibility",
          "wait": false
        }
        """

        assert {:ok, parsed} = ActionParser.parse_json_response(json)
        assert parsed.action == action
      end
    end

    test "invalid action still returns error" do
      json = """
      {
        "action": "not_a_real_action",
        "params": {},
        "reasoning": "Testing invalid action handling",
        "wait": false
      }
      """

      assert {:error, :unknown_action} = ActionParser.parse_json_response(json)
    end

    test "todo action works with consensus flow types" do
      # Test that todo returns proper action_response type
      json = """
      {
        "action": "todo",
        "params": {"items": []},
        "reasoning": "Testing consensus flow types",
        "wait": false
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)

      # Should have expected fields for action_response
      assert Map.has_key?(parsed, :action)
      assert Map.has_key?(parsed, :params)
      assert Map.has_key?(parsed, :wait)
    end
  end

  describe "auto_complete_todo extraction" do
    test "extracts auto_complete_todo when true" do
      json = """
      {
        "action": "wait",
        "params": {"wait": 0},
        "reasoning": "Testing auto_complete_todo extraction",
        "auto_complete_todo": true
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      assert parsed.auto_complete_todo == true
    end

    test "extracts auto_complete_todo when false" do
      json = """
      {
        "action": "orient",
        "params": {
          "current_situation": "test",
          "goal_clarity": "clear",
          "available_resources": "test",
          "key_challenges": "none"
        },
        "reasoning": "Testing auto_complete_todo false",
        "auto_complete_todo": false
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      assert parsed.auto_complete_todo == false
    end

    test "returns nil for auto_complete_todo when absent" do
      json = """
      {
        "action": "wait",
        "params": {"wait": 0},
        "reasoning": "Testing auto_complete_todo absence"
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      assert parsed.auto_complete_todo == nil
    end

    test "returns nil for auto_complete_todo on :todo action" do
      json = """
      {
        "action": "todo",
        "params": {"items": []},
        "reasoning": "Testing auto_complete_todo on todo action",
        "auto_complete_todo": true
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      # For :todo action, auto_complete_todo should be nil (same pattern as wait)
      assert parsed.auto_complete_todo == nil
    end

    test "auto_complete_todo works with all action types" do
      # Test that auto_complete_todo can be extracted for any non-todo action
      actions = [:spawn_child, :wait, :send_message, :orient, :answer_engine]

      for action <- actions do
        json = """
        {
          "action": "#{action}",
          "params": {},
          "reasoning": "Testing auto_complete_todo on #{action}",
          "auto_complete_todo": true
        }
        """

        assert {:ok, parsed} = ActionParser.parse_json_response(json)
        assert parsed.auto_complete_todo == true, "auto_complete_todo should work for #{action}"
      end
    end
  end

  describe "unicode wrapper extraction (byte/grapheme alignment)" do
    test "parses JSON when prose contains smart quotes" do
      # Smart quotes are 3 bytes each but 1 grapheme
      # This tests the byte/grapheme position alignment in extract_json_from_wrapper
      response = """
      Here's why the "spawn_child" action is correct—it already embodies the planning.

      ```json
      {"action": "wait", "params": {}, "reasoning": "test", "wait": true}
      ```
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(response)
      assert parsed.action == :wait
      assert parsed.wait == true
    end

    test "parses JSON when prose contains many em-dashes" do
      # Each em-dash (—) is 3 bytes but 1 grapheme
      # With enough multi-byte chars, byte position > grapheme position
      # causing the guard `end_pos >= start_pos` to potentially fail
      em_dashes = String.duplicate("—", 30)

      response = """
      Analysis#{em_dashes}the proposal is sound#{em_dashes}proceed with action:

      ```json
      {"action": "orient", "params": {"current_situation": "test", "goal_clarity": "clear", "available_resources": "test", "key_challenges": "none"}, "reasoning": "multi-byte test"}
      ```
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(response)
      assert parsed.action == :orient
    end

    test "parses JSON when prose contains mixed unicode punctuation" do
      # Mix of multi-byte characters: smart quotes, em-dashes, ellipses
      response = """
      Let's analyze this… The "best" approach—considering all factors—is clear.

      Here's my recommendation:

      ```json
      {"action": "todo", "params": {"items": [{"content": "Test task", "state": "todo"}]}, "reasoning": "unicode test"}
      ```
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(response)
      assert parsed.action == :todo
      assert length(parsed.params["items"]) == 1
    end

    test "parses JSON with extreme unicode density before brace" do
      # Worst case: many multi-byte chars causing large byte/grapheme divergence
      # 50 em-dashes = 150 bytes but only 50 graphemes = 100 byte drift
      # Using codepoint for smart quote to avoid heredoc syntax issue
      smart_quote = <<0xE2, 0x80, 0x9C>>
      unicode_prefix = String.duplicate("—", 50) <> String.duplicate(smart_quote, 20)

      response =
        unicode_prefix <> ~s({"action": "wait", "params": {}, "reasoning": "extreme test"})

      assert {:ok, parsed} = ActionParser.parse_json_response(response)
      assert parsed.action == :wait
      assert parsed.reasoning == "extreme test"
    end
  end

  describe "edge cases" do
    test "handles todo with very long item lists" do
      # Generate 50 items
      items =
        for i <- 1..50 do
          ~s({"content": "Task #{i}", "state": "todo"})
        end

      json = """
      {
        "action": "todo",
        "params": {
          "items": [#{Enum.join(items, ",")}]
        },
        "reasoning": "Testing long item lists",
        "wait": false
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      assert parsed.action == :todo
      assert length(parsed.params["items"]) == 50
    end

    test "handles todo with unicode content" do
      json = """
      {
        "action": "todo",
        "params": {
          "items": [
            {"content": "任务 🎯 测试", "state": "todo"},
            {"content": "Ñoño café ☕", "state": "pending"}
          ]
        },
        "reasoning": "Testing unicode content"
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      assert parsed.action == :todo
      assert length(parsed.params["items"]) == 2
    end

    test "handles todo with escaped JSON characters" do
      json = """
      {
        "action": "todo",
        "params": {
          "items": [
            {"content": "Task with \\"quotes\\"", "state": "todo"},
            {"content": "Task with\\nnewline", "state": "done"}
          ]
        },
        "reasoning": "Testing escaped JSON characters"
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      assert parsed.action == :todo

      [first, second] = parsed.params["items"]
      assert first["content"] =~ "quotes"
      assert second["content"] =~ "newline"
    end
  end

  describe "bug_report extraction from wrapped JSON" do
    test "extracts bug_report from Claude-style markdown-wrapped JSON" do
      # Claude often wraps responses in ```json blocks
      log_path = "/tmp/bug_report_test_#{System.unique_integer([:positive])}.log"

      wrapped_json = """
      ```json
      {
        "action": "wait",
        "params": {},
        "reasoning": "Testing bug_report extraction",
        "bug_report": "Claude found an issue with the prompt"
      }
      ```
      """

      # Parse with opts to trigger bug_report extraction
      assert {:ok, parsed} = ActionParser.parse_json_response(wrapped_json, log_path: log_path)
      assert parsed.action == :wait

      # Verify bug_report was logged
      assert File.exists?(log_path)
      content = File.read!(log_path)
      assert content =~ "Claude found an issue with the prompt"

      # Cleanup
      File.rm(log_path)
    end

    test "extracts bug_report from GPT-style raw JSON" do
      # GPT/Gemini typically return raw JSON without wrapper
      log_path = "/tmp/bug_report_test_#{System.unique_integer([:positive])}.log"

      raw_json = """
      {
        "action": "orient",
        "params": {
          "current_situation": "test",
          "goal_clarity": "clear",
          "available_resources": "test",
          "key_challenges": "none"
        },
        "reasoning": "Testing raw JSON bug_report",
        "bug_report": "GPT detected a configuration problem"
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(raw_json, log_path: log_path)
      assert parsed.action == :orient

      # Verify bug_report was logged
      assert File.exists?(log_path)
      content = File.read!(log_path)
      assert content =~ "GPT detected a configuration problem"

      # Cleanup
      File.rm(log_path)
    end

    test "handles wrapped JSON without bug_report gracefully" do
      log_path = "/tmp/bug_report_test_#{System.unique_integer([:positive])}.log"

      wrapped_json = """
      ```json
      {
        "action": "wait",
        "params": {},
        "reasoning": "No bug_report field here"
      }
      ```
      """

      # Should parse successfully without error
      assert {:ok, parsed} = ActionParser.parse_json_response(wrapped_json, log_path: log_path)
      assert parsed.action == :wait

      # No log file should be created (no bug_report to log)
      refute File.exists?(log_path)
    end

    test "handles empty bug_report string gracefully" do
      log_path = "/tmp/bug_report_test_#{System.unique_integer([:positive])}.log"

      json = """
      {
        "action": "wait",
        "params": {},
        "reasoning": "Empty bug_report test",
        "bug_report": ""
      }
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(json, log_path: log_path)
      assert parsed.action == :wait

      # Empty bug_report should not create log file
      refute File.exists?(log_path)
    end
  end

  describe "multiple JSON objects (last wins)" do
    test "extracts last JSON when LLM preamble contains braces" do
      # LLM says "Here's an example: {...}" then gives real action
      response = """
      I'll use the wait action. For example, {"action": "orient"} would be wrong.

      {"action": "wait", "params": {}, "reasoning": "last object wins"}
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(response)
      assert parsed.action == :wait
      assert parsed.reasoning == "last object wins"
    end

    test "extracts last JSON when multiple complete objects present" do
      response = """
      {"action": "orient", "params": {}, "reasoning": "first"}
      {"action": "wait", "params": {}, "reasoning": "second"}
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(response)
      assert parsed.action == :wait
      assert parsed.reasoning == "second"
    end

    test "handles last object with nested braces" do
      response = """
      {"action": "wait", "params": {}, "reasoning": "first"}
      {"action": "spawn_child", "params": {"config": {"nested": "value"}}, "reasoning": "nested last"}
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(response)
      assert parsed.action == :spawn_child
      assert parsed.params["config"]["nested"] == "value"
      assert parsed.reasoning == "nested last"
    end

    test "single object still works (regression)" do
      response = ~s({"action": "wait", "params": {}, "reasoning": "only one"})

      assert {:ok, parsed} = ActionParser.parse_json_response(response)
      assert parsed.action == :wait
      assert parsed.reasoning == "only one"
    end

    test "handles prose with braces followed by real JSON" do
      response = """
      The syntax {like this} or {that} is common in templates.

      Here's the actual action:
      {"action": "todo", "params": {"items": []}, "reasoning": "after prose"}
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(response)
      assert parsed.action == :todo
      assert parsed.reasoning == "after prose"
    end

    test "deeply nested last object extracted correctly" do
      response = """
      {"simple": true}
      {"action": "execute_shell", "params": {"command": "echo", "args": {"nested": {"deep": "value"}}}, "reasoning": "deep"}
      """

      assert {:ok, parsed} = ActionParser.parse_json_response(response)
      assert parsed.action == :execute_shell
      assert parsed.reasoning == "deep"
    end
  end
end
