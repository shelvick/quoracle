defmodule Quoracle.Agent.MessageFormatterTest do
  use ExUnit.Case, async: true

  alias Quoracle.Agent.MessageFormatter

  describe "format_single_message/1 - action results" do
    # R1: Action Result JSON Formatting
    test "formats action results with JSON-encoded data" do
      result = {:ok, %{status: "success", data: [1, 2, 3]}}
      action_id = "action_agent_123_5"

      formatted = MessageFormatter.format_single_message({:action_result, action_id, result})

      # Should contain JSON formatting, not Elixir inspect() format
      refute String.contains?(formatted, "{:ok")
      refute String.contains?(formatted, "status: ")

      # Should have JSON structure
      assert String.contains?(formatted, "\"type\"")
      assert String.contains?(formatted, "\"value\"")
      assert String.contains?(formatted, "\"status\"")
    end

    # R2: Action Result XML Structure
    test "wraps action result JSON in proper XML tags" do
      result = {:ok, "simple result"}
      action_id = "action_agent_456_2"

      formatted = MessageFormatter.format_single_message({:action_result, action_id, result})

      # Check XML structure
      assert String.contains?(formatted, "<action_result")
      assert String.contains?(formatted, "id=\"#{action_id}\"")
      assert String.contains?(formatted, "from=\"system\"")
      assert String.contains?(formatted, "</action_result>")
    end

    # R7: JSON Pretty-Printing
    test "action result JSON is pretty-printed" do
      result = {:ok, %{nested: %{data: "value"}, items: [1, 2]}}
      action_id = "action_agent_789_3"

      formatted = MessageFormatter.format_single_message({:action_result, action_id, result})

      # Pretty-printed JSON should have newlines and indentation
      assert String.contains?(formatted, "\n  ")
      assert String.contains?(formatted, "{\n")
    end

    # R8: Ok Tuple Normalization
    test "normalizes ok tuples to JSON objects in action results" do
      result = {:ok, %{message: "Success"}}
      action_id = "action_agent_001_1"

      formatted = MessageFormatter.format_single_message({:action_result, action_id, result})

      # Should have JSON structure for {:ok, data}
      assert String.contains?(formatted, "\"type\": \"ok\"")
      assert String.contains?(formatted, "\"value\":")
      assert String.contains?(formatted, "\"message\": \"Success\"")
    end

    # R9: Error Tuple Normalization
    test "normalizes error tuples to JSON objects in action results" do
      result = {:error, :timeout}
      action_id = "action_agent_002_2"

      formatted = MessageFormatter.format_single_message({:action_result, action_id, result})

      # Should have JSON structure for {:error, reason}
      assert String.contains?(formatted, "\"type\": \"error\"")
      assert String.contains?(formatted, "\"reason\": \"timeout\"")
    end

    test "handles complex nested action results" do
      result =
        {:ok,
         %{
           pids: [self()],
           ref: make_ref(),
           atom: :test_atom,
           nested: {:error, "nested error"}
         }}

      action_id = "action_agent_003_3"

      formatted = MessageFormatter.format_single_message({:action_result, action_id, result})

      # Should handle non-serializable types
      # PID converted to string
      assert String.contains?(formatted, "#PID")
      # Ref converted to string
      assert String.contains?(formatted, "#Reference")

      # No Elixir syntax
      refute String.contains?(formatted, ":test_atom")
      refute String.contains?(formatted, "{:error")
    end
  end

  describe "format_single_message/1 - other message types" do
    # R3: Agent Message Formatting
    test "formats agent messages with from attribute" do
      from = :parent
      content = "Hello from parent"

      formatted = MessageFormatter.format_single_message({:agent_message, from, content})

      assert String.contains?(formatted, "<agent_message")
      assert String.contains?(formatted, "from=\"parent\"")
      assert String.contains?(formatted, content)
      assert String.contains?(formatted, "</agent_message>")
    end

    test "formats agent messages with PID from attribute" do
      pid = self()
      content = "Message content"

      formatted = MessageFormatter.format_single_message({:agent_message, pid, content})

      assert String.contains?(formatted, "<agent_message")
      assert String.contains?(formatted, "from=\"agent_")
      assert String.contains?(formatted, content)
      assert String.contains?(formatted, "</agent_message>")
    end

    # R4: User Message Formatting (not in current implementation, but in spec)
    test "formats user messages as plain text" do
      content = "User input message"

      # Note: Current implementation doesn't have :user_message,
      # but spec requires it - this should fail
      formatted = MessageFormatter.format_single_message({:user_message, content})

      # Should return plain text, no XML wrapping
      assert formatted == content
    end

    test "formats system events with JSON data" do
      type = "agent_spawned"
      data = %{child_id: "child_123", config: %{role: "test"}}

      formatted = MessageFormatter.format_single_message({:system_event, type, data})

      assert String.contains?(formatted, "<system_event")
      assert String.contains?(formatted, "type=\"#{type}\"")
      assert String.contains?(formatted, "</system_event>")

      # Data should be JSON formatted
      # No Elixir map syntax
      refute String.contains?(formatted, "child_id:")
      assert String.contains?(formatted, "\"child_id\"")
      assert String.contains?(formatted, "\"child_123\"")
    end

    test "formats wait timeout messages" do
      timer_id = "timer_456"

      formatted = MessageFormatter.format_single_message({:wait_timeout, timer_id})

      assert String.contains?(formatted, "<wait_timeout")
      assert String.contains?(formatted, "timer_id=\"#{timer_id}\"")
      assert String.contains?(formatted, "Timer expired")
      assert String.contains?(formatted, "</wait_timeout>")
    end

    test "formats unknown messages with JSON" do
      unknown_data = %{type: :unknown, data: [1, 2, 3]}

      formatted = MessageFormatter.format_single_message(unknown_data)

      assert String.contains?(formatted, "<unknown_message>")
      assert String.contains?(formatted, "</unknown_message>")

      # Should use JSON format
      # No Elixir syntax
      refute String.contains?(formatted, "type:")
      assert String.contains?(formatted, "\"type\"")
      assert String.contains?(formatted, "\"data\"")
    end
  end

  describe "format_batch_message/1" do
    # R5: Batch Message Combination
    test "combines multiple messages with newlines" do
      messages = [
        {:action_result, "action_001", {:ok, "result1"}},
        {:agent_message, :parent, "parent message"},
        {:system_event, "test", %{data: "value"}}
      ]

      formatted = MessageFormatter.format_batch_message(messages)

      # Should contain all three message blocks
      assert String.contains?(formatted, "<action_result")
      assert String.contains?(formatted, "<agent_message")
      assert String.contains?(formatted, "<system_event")

      # Should be separated by newlines
      lines = String.split(formatted, "\n")
      assert length(lines) > 3
    end

    # R6: Empty Batch Handling
    test "returns empty string for empty batch" do
      assert MessageFormatter.format_batch_message([]) == ""
    end

    test "handles single message batch" do
      messages = [{:action_result, "action_001", {:ok, "single"}}]

      formatted = MessageFormatter.format_batch_message(messages)

      assert String.contains?(formatted, "<action_result")
      assert String.contains?(formatted, "\"type\": \"ok\"")
    end

    # R10: Backwards Compatibility
    test "maintains compatibility with existing MessageHandler behavior" do
      # Test the exact format expected by MessageHandler
      messages = [
        {:action_result, "action_agent_123_1", {:ok, %{output: "test"}}},
        {:agent_message, :child, "child response"}
      ]

      formatted = MessageFormatter.format_batch_message(messages)

      # Should maintain the XML structure that MessageHandler expects
      assert formatted =~ ~r/<action_result.*id="action_agent_123_1".*from="system">/
      assert formatted =~ ~r/<agent_message.*from="child">/

      # But with JSON content instead of inspect()
      # No Elixir map syntax
      refute String.contains?(formatted, "%{output:")
      assert String.contains?(formatted, "\"output\"")
    end
  end

  describe "edge cases" do
    test "handles nil values in results" do
      result = {:ok, nil}
      action_id = "action_nil_test"

      formatted = MessageFormatter.format_single_message({:action_result, action_id, result})

      assert String.contains?(formatted, "\"type\": \"ok\"")
      assert String.contains?(formatted, "\"value\": null")
    end

    test "handles empty maps and lists" do
      result = {:ok, %{empty_map: %{}, empty_list: []}}
      action_id = "action_empty_test"

      formatted = MessageFormatter.format_single_message({:action_result, action_id, result})

      assert String.contains?(formatted, "\"empty_map\": {}")
      assert String.contains?(formatted, "\"empty_list\": []")
    end

    test "handles binary data in results" do
      # Invalid UTF-8
      result = {:ok, %{binary: <<232, 17>>}}
      action_id = "action_binary_test"

      formatted = MessageFormatter.format_single_message({:action_result, action_id, result})

      # Should handle invalid UTF-8 gracefully
      assert String.contains?(formatted, "\"binary\"")
      # Should contain the inspect representation
      assert String.contains?(formatted, "<<232, 17>>")
    end

    test "formats deeply nested structures" do
      result =
        {:ok,
         %{
           level1: %{
             level2: %{
               level3: %{
                 data: "deep value"
               }
             }
           }
         }}

      action_id = "action_deep_test"

      formatted = MessageFormatter.format_single_message({:action_result, action_id, result})

      # Should maintain nested structure in JSON
      assert String.contains?(formatted, "\"level1\"")
      assert String.contains?(formatted, "\"level2\"")
      assert String.contains?(formatted, "\"level3\"")
      assert String.contains?(formatted, "\"deep value\"")

      # Should be properly indented
      assert formatted =~ ~r/\n\s+/
    end
  end
end
