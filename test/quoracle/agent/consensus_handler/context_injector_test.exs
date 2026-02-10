defmodule Quoracle.Agent.ConsensusHandler.ContextInjectorTest do
  @moduledoc """
  Tests for ContextInjector - injects token count into consensus messages.

  v2.0: Counts tokens from fully-built messages (excluding system prompt),
  not from raw model_histories. This gives agents accurate context visibility.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.ConsensusHandler.ContextInjector
  alias Quoracle.Agent.TokenManager

  # Helper to extract token count from injected content
  defp extract_token_count(content) do
    case Regex.run(~r/<ctx>([\d,]+) tokens in context<\/ctx>/, content) do
      [_, count_str] ->
        count_str |> String.replace(",", "") |> String.to_integer()

      _ ->
        nil
    end
  end

  describe "R1: Basic Injection" do
    test "injects token count into last user message" do
      messages = [%{role: "user", content: "Test content"}]

      result = ContextInjector.inject_context_tokens(messages)

      assert [%{role: "user", content: content}] = result
      assert content =~ ~r/<ctx>\d+ tokens in context<\/ctx>/
    end
  end

  describe "R2: Format with Commas" do
    test "formats token count with comma separators" do
      result = ContextInjector.format_context_tokens(12_345)

      assert result == "\n<ctx>12,345 tokens in context</ctx>\n"
    end
  end

  describe "R3: Append Position" do
    test "appends to end of last user message not prepend" do
      messages = [%{role: "user", content: "Original content"}]

      result = ContextInjector.inject_context_tokens(messages)

      [%{content: content}] = result

      # Content should start with original, end with ctx tag
      assert String.starts_with?(content, "Original content")
      assert String.ends_with?(content, "</ctx>\n")
    end
  end

  describe "R4: Empty Messages" do
    test "returns empty list unchanged" do
      result = ContextInjector.inject_context_tokens([])

      assert result == []
    end
  end

  describe "R5: No User Messages" do
    test "returns messages unchanged when no user messages" do
      messages = [
        %{role: "system", content: "System prompt"},
        %{role: "assistant", content: "Response"}
      ]

      result = ContextInjector.inject_context_tokens(messages)

      assert result == messages
    end
  end

  describe "R6: Counts Non-System Messages" do
    test "counts tokens from user and assistant messages only" do
      messages = [
        %{role: "system", content: "This is a very long system prompt with many tokens"},
        %{role: "user", content: "Short"},
        %{role: "assistant", content: "Also short"}
      ]

      result = ContextInjector.inject_context_tokens(messages)

      [_system, %{content: user_content}, _assistant] = result

      # Token count should NOT include system message
      token_count = extract_token_count(user_content)

      # Calculate expected: user + assistant only
      expected =
        TokenManager.estimate_tokens("Short") + TokenManager.estimate_tokens("Also short")

      assert token_count == expected
    end

    test "excludes system prompt from token count" do
      system_content = String.duplicate("This is a long system prompt. ", 100)

      messages = [
        %{role: "system", content: system_content},
        %{role: "user", content: "Hi"}
      ]

      result = ContextInjector.inject_context_tokens(messages)

      [_system, %{content: user_content}] = result
      token_count = extract_token_count(user_content)

      # Should only count "Hi", not the huge system prompt
      expected = TokenManager.estimate_tokens("Hi")
      assert token_count == expected
    end
  end

  describe "R7: Zero Tokens" do
    test "injects zero tokens when only system message exists" do
      # Edge case: only system message, but we still inject into... wait, no user message
      # This should return messages unchanged per R5
      messages = [%{role: "system", content: "System prompt only"}]

      result = ContextInjector.inject_context_tokens(messages)

      # No user message to inject into
      assert result == messages
    end
  end

  describe "R8: Large Token Counts" do
    test "formats large numbers with commas" do
      result = ContextInjector.format_context_tokens(1_234_567)

      assert result == "\n<ctx>1,234,567 tokens in context</ctx>\n"
    end
  end

  describe "R9: Small Token Counts" do
    test "formats small numbers without unnecessary commas" do
      assert ContextInjector.format_context_tokens(123) == "\n<ctx>123 tokens in context</ctx>\n"
      assert ContextInjector.format_context_tokens(0) == "\n<ctx>0 tokens in context</ctx>\n"
    end
  end

  describe "R10: XML Tag Format" do
    test "uses <ctx> tag not <context>" do
      messages = [%{role: "user", content: "Test"}]

      result = ContextInjector.inject_context_tokens(messages)

      [%{content: content}] = result
      assert content =~ "<ctx>"
      assert content =~ "</ctx>"
      refute content =~ "<context>"
    end
  end

  describe "R11: Integration - Token count matches TokenManager" do
    test "token count matches TokenManager.estimate_messages_tokens" do
      messages = [
        %{role: "system", content: "System prompt here"},
        %{role: "user", content: "The quick brown fox jumps over the lazy dog"},
        %{role: "assistant", content: "That's a pangram!"}
      ]

      # Get expected count directly from TokenManager
      expected_tokens = TokenManager.estimate_messages_tokens(messages)

      result = ContextInjector.inject_context_tokens(messages)
      [_system, %{content: user_content}, _assistant] = result
      actual_tokens = extract_token_count(user_content)

      assert actual_tokens == expected_tokens
    end
  end

  describe "edge cases" do
    test "handles multiple user messages - injects into last only" do
      messages = [
        %{role: "user", content: "First user message"},
        %{role: "assistant", content: "Response"},
        %{role: "user", content: "Second user message"}
      ]

      result = ContextInjector.inject_context_tokens(messages)

      # First user message unchanged
      assert Enum.at(result, 0).content == "First user message"
      # Last user message has injection
      assert Enum.at(result, 2).content =~ "<ctx>"
    end

    test "preserves existing content structure" do
      original = "<budget>$10.00</budget>\n<children>...</children>"
      messages = [%{role: "user", content: original}]

      result = ContextInjector.inject_context_tokens(messages)

      [%{content: content}] = result
      # Original content preserved at start
      assert String.starts_with?(content, original)
      # ctx tag at end
      assert String.ends_with?(content, "</ctx>\n")
    end

    test "handles messages with atom keys" do
      messages = [%{role: "user", content: "Test"}]

      result = ContextInjector.inject_context_tokens(messages)

      assert [%{role: "user", content: content}] = result
      assert content =~ "<ctx>"
    end

    test "handles messages with string keys" do
      messages = [%{"role" => "user", "content" => "Test"}]

      result = ContextInjector.inject_context_tokens(messages)

      # Result preserves original key format
      assert [%{"role" => "user", "content" => content}] = result
      assert content =~ "<ctx>"
    end

    test "leaves multimodal content unchanged" do
      # Content that's a list (multimodal format) - can't append string to list
      messages = [
        %{
          role: "user",
          content: [%{type: "text", text: "Hello"}, %{type: "image_url", url: "..."}]
        }
      ]

      result = ContextInjector.inject_context_tokens(messages)

      # Should return message unchanged since we can't append to list content
      [%{content: content}] = result
      assert is_list(content)
      assert content == [%{type: "text", text: "Hello"}, %{type: "image_url", url: "..."}]
    end
  end

  describe "format_context_tokens/1 number formatting" do
    test "handles boundary cases for comma formatting" do
      # Just under 1000 - no comma
      assert ContextInjector.format_context_tokens(999) == "\n<ctx>999 tokens in context</ctx>\n"
      # Exactly 1000 - has comma
      assert ContextInjector.format_context_tokens(1000) ==
               "\n<ctx>1,000 tokens in context</ctx>\n"

      # 10,000
      assert ContextInjector.format_context_tokens(10_000) ==
               "\n<ctx>10,000 tokens in context</ctx>\n"

      # 100,000
      assert ContextInjector.format_context_tokens(100_000) ==
               "\n<ctx>100,000 tokens in context</ctx>\n"
    end
  end

  describe "TokenManager.estimate_messages_tokens/1" do
    test "returns 0 for empty list" do
      assert TokenManager.estimate_messages_tokens([]) == 0
    end

    test "excludes system messages" do
      messages = [
        %{role: "system", content: "System prompt with tokens"},
        %{role: "user", content: "Hi"}
      ]

      result = TokenManager.estimate_messages_tokens(messages)

      # Should only count "Hi"
      assert result == TokenManager.estimate_tokens("Hi")
    end

    test "sums tokens from multiple non-system messages" do
      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "World"}
      ]

      result = TokenManager.estimate_messages_tokens(messages)

      expected = TokenManager.estimate_tokens("Hello") + TokenManager.estimate_tokens("World")
      assert result == expected
    end

    test "handles string keys" do
      messages = [
        %{"role" => "user", "content" => "Test message"}
      ]

      result = TokenManager.estimate_messages_tokens(messages)

      assert result == TokenManager.estimate_tokens("Test message")
    end

    test "handles non-string content via inspect" do
      messages = [
        %{role: "user", content: %{complex: "data"}}
      ]

      result = TokenManager.estimate_messages_tokens(messages)

      # Should use inspect for non-string content
      assert result > 0
    end
  end
end
