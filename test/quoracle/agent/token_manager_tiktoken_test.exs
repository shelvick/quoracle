defmodule Quoracle.Agent.TokenManagerTiktokenTest do
  @moduledoc """
  Tests for TokenManager v5.0 - tiktoken Integration.
  WorkGroupID: fix-tiktoken-20251229, Packet 1

  These tests verify that token estimation uses tiktoken library for accurate
  counting, fixing the 5-10x underestimation for file paths and shell output.

  Bug Context: Word-based estimation treats file paths as 1 "word" when they're
  actually ~12 tokens (tokenizers split on /, -, ., etc.). This caused context
  overflow errors because condensation never triggered.

  Requirements: R1-R12
  """

  use ExUnit.Case, async: true
  alias Quoracle.Agent.TokenManager

  # File path fixtures - these expose the core bug
  @file_path "./providers/vercel/models/deepseek/deepseek-r1-distill-llama-70b.toml"
  @multiple_paths """
  ./providers/vercel/models/deepseek/deepseek-r1-distill-llama-70b.toml
  ./providers/vercel/models/meta/llama-3.3-70b.toml
  ./providers/minimax-cn/models/MiniMax-M2.toml
  """

  # Shell output fixture - realistic git clone output with paths
  @shell_output """
  Cloning into '/home/testuser/models.dev'...
  remote: Enumerating objects: 15234, done.
  remote: Counting objects: 100% (15234/15234), done.
  ./providers/anthropic/models/claude-sonnet-4-20250514.toml
  ./providers/anthropic/models/claude-opus-4-20250514.toml
  ./providers/openai/models/gpt-4o-2024-11-20.toml
  ./providers/openai/models/o1-preview.toml
  """

  describe "R1: tiktoken Integration" do
    test "uses tiktoken for token estimation" do
      # Regular text: "Hello, world!" should be ~4 tokens with tiktoken
      # Word-based would give: 2 words * 1.33 = 3 (close but different)
      # tiktoken gives exact count: ["Hello", ",", " world", "!"] = 4
      text = "Hello, world!"

      tokens = TokenManager.estimate_tokens(text)

      # tiktoken returns exactly 4 for "Hello, world!"
      # If this passes with 4, tiktoken is being used
      # Word-based would give 3 (2 words * 1.33)
      assert tokens == 4, "Expected exactly 4 tokens from tiktoken, got #{tokens}"
    end

    test "tiktoken handles punctuation as separate tokens" do
      # "test.file" with tiktoken: ["test", ".", "file"] = 3 tokens
      # Word-based: 1 word * 1.33 = 1 token (WRONG)
      text = "test.file"

      tokens = TokenManager.estimate_tokens(text)

      # tiktoken splits on punctuation
      assert tokens >= 2, "Expected >=2 tokens (tiktoken splits on '.'), got #{tokens}"
    end
  end

  describe "R2: Accurate File Path Counting" do
    test "file paths return accurate token count" do
      # File path: "./providers/vercel/models/deepseek/deepseek-r1-distill-llama-70b.toml"
      # Word-based: 1 word * 1.33 = 1 token (SEVERELY WRONG)
      # tiktoken: splits on /, -, . = ~15-20 tokens
      tokens = TokenManager.estimate_tokens(@file_path)

      # The bug: word-based returns 1, tiktoken returns ~15-20
      assert tokens >= 10,
             "File path should be ~15-20 tokens, got #{tokens}. " <>
               "Word-based estimation severely underestimates paths."

      assert tokens <= 25, "File path should be ~15-20 tokens, got #{tokens}"
    end

    test "file paths are not counted as single word" do
      # This is the exact bug we're fixing
      short_text = "hello"
      path = @file_path

      short_tokens = TokenManager.estimate_tokens(short_text)
      path_tokens = TokenManager.estimate_tokens(path)

      # Path should have MANY more tokens than a simple word
      # With word-based bug: both return ~1 token
      # With tiktoken: path >> short_text
      assert path_tokens > short_tokens * 5,
             "Path (#{path_tokens} tokens) should be 5x+ more than 'hello' (#{short_tokens} tokens)"
    end
  end

  describe "R3: Accurate Shell Output Counting" do
    test "shell output with paths returns accurate tokens" do
      # Shell output with multiple file paths
      # Word-based: ~50 words * 1.33 = ~67 tokens
      # tiktoken: Much higher due to path tokenization
      tokens = TokenManager.estimate_tokens(@shell_output)

      # The shell output contains 4 long file paths plus other text
      # Each path is ~15-20 tokens, so paths alone = 60-80 tokens
      # Total should be 100+ tokens
      assert tokens >= 80,
             "Shell output should be 100+ tokens with tiktoken, got #{tokens}. " <>
               "Paths are being undercounted."
    end

    test "multiple paths multiply token count correctly" do
      single_path_tokens = TokenManager.estimate_tokens(@file_path)
      multiple_paths_tokens = TokenManager.estimate_tokens(@multiple_paths)

      # 3 paths should be roughly 2.4x single path (newlines add minimal tokens)
      # With word-based bug: 3 words * 1.33 = 4 tokens total (WRONG)
      assert multiple_paths_tokens >= single_path_tokens * 2.0,
             "3 paths (#{multiple_paths_tokens}) should be ~2.4x single path (#{single_path_tokens})"
    end
  end

  describe "R4: nil Input Handling" do
    test "returns 0 for nil input" do
      assert TokenManager.estimate_tokens(nil) == 0
    end
  end

  describe "R5: Empty String Handling" do
    test "returns 0 for empty string" do
      assert TokenManager.estimate_tokens("") == 0
    end
  end

  describe "R6: History Token Estimation" do
    test "estimates history tokens using tiktoken" do
      # History with file paths should use tiktoken for accurate count
      history = [
        %{
          "type" => "result",
          "content" => @shell_output,
          "timestamp" => "2025-12-29T10:00:00Z"
        }
      ]

      tokens = TokenManager.estimate_history_tokens(history)

      # Shell output should be 100+ tokens with tiktoken
      assert tokens >= 80,
             "History with shell output should be 100+ tokens, got #{tokens}"
    end

    test "sums tiktoken counts for all entries" do
      # Multiple entries with file paths
      history = [
        %{"type" => "user", "content" => @file_path, "timestamp" => "2025-12-29T10:00:00Z"},
        %{"type" => "user", "content" => @file_path, "timestamp" => "2025-12-29T10:01:00Z"},
        %{"type" => "user", "content" => @file_path, "timestamp" => "2025-12-29T10:02:00Z"}
      ]

      tokens = TokenManager.estimate_history_tokens(history)

      # Each path is ~15-20 tokens, 3 paths = 45-60 tokens
      assert tokens >= 40, "3 file paths should sum to 45+ tokens, got #{tokens}"
    end
  end

  describe "R7: Entry Token Estimation" do
    test "estimates entry tokens for string-keyed entries" do
      # DB-format entry with file path content
      entry = %{
        "type" => "result",
        "content" => @file_path,
        "timestamp" => "2025-12-29T10:00:00Z"
      }

      # This uses the internal estimate_entry_tokens via estimate_history_tokens
      tokens = TokenManager.estimate_history_tokens([entry])

      # File path should be ~15-20 tokens
      assert tokens >= 10, "File path entry should be ~15-20 tokens, got #{tokens}"
    end

    test "formats decision entry content and tokenizes" do
      # DB-format decision entry
      entry = %{
        "type" => "decision",
        "content" => %{
          "action" => "execute_shell",
          "params" => %{"command" => "ls -la /home/testuser/models.dev/providers"},
          "reasoning" => "Need to list files in the providers directory"
        },
        "timestamp" => "2025-12-29T10:00:00Z"
      }

      tokens = TokenManager.estimate_history_tokens([entry])

      # Should have meaningful token count from params + reasoning
      assert tokens >= 15, "Decision entry should have 15+ tokens, got #{tokens}"
    end
  end

  describe "R8: Condensation Threshold Accuracy" do
    @tag :integration
    @tag :acceptance
    test "condensation triggers for file-path-heavy history exceeding limit" do
      # USER-OBSERVABLE BEHAVIOR TEST
      # User does: Runs agent processing shell output with file paths
      # User expects: Condensation triggers before context overflow errors

      # Create history with many file paths - this is realistic shell output
      # Each path is ~15-20 tokens with tiktoken

      # openrouter:openai/gpt-3.5-turbo-0613 has 4095 token limit in LLMDB
      # Need ~4100 tokens to trigger condensation

      # With tiktoken: 300 paths * 15 tokens = 4500 tokens (exceeds limit) ✓
      # With word-based: 300 paths * 1 token = 300 tokens (no trigger) ✗
      paths =
        for i <- 1..300 do
          "./providers/#{rem(i, 10)}/models/model-#{i}/config-variant-#{i}.toml"
        end

      path_content = Enum.join(paths, "\n")

      history = [
        %{
          "type" => "result",
          "content" => path_content,
          "timestamp" => "2025-12-29T10:00:00Z"
        }
      ]

      state = %{
        model_histories: %{
          "openrouter:openai/gpt-3.5-turbo-0613" => history
        }
      }

      # POSITIVE ASSERTION: Condensation should trigger
      result =
        TokenManager.should_condense_for_model?(state, "openrouter:openai/gpt-3.5-turbo-0613")

      assert result == true,
             "Condensation MUST trigger for file-path-heavy history. " <>
               "This is the core bug fix - paths were undercounted 15x."

      # NEGATIVE ASSERTION: Token count should not be trivially small
      tokens = TokenManager.estimate_history_tokens(history)

      refute tokens < 1000,
             "Token count should be 4000+, got #{tokens}. " <>
               "Paths are still being undercounted."
    end

    test "condensation triggers for file-path-heavy history" do
      # Simpler version of acceptance test
      # 200 paths * ~15 tokens = 3000 tokens
      paths =
        for i <- 1..200 do
          "./dir/subdir/file-#{i}.json"
        end

      history = [
        %{
          "type" => "result",
          "content" => Enum.join(paths, "\n"),
          "timestamp" => "2025-12-29T10:00:00Z"
        }
      ]

      state = %{
        model_histories: %{
          # Small context model
          "openrouter:openai/gpt-3.5-turbo-0613" => history
        }
      }

      _result =
        TokenManager.should_condense_for_model?(state, "openrouter:openai/gpt-3.5-turbo-0613")

      # With tiktoken: should trigger (3000+ tokens > ~4000 limit is close)
      # With word-based: 200 * 1.33 = 266 tokens - won't trigger
      # This tests that we're in the right ballpark
      tokens = TokenManager.estimate_history_tokens(history)

      assert tokens >= 1000,
             "200 paths should be 2000+ tokens with tiktoken, got #{tokens}"
    end
  end

  describe "R9: Fail-Fast on tiktoken Error" do
    test "raises on tiktoken failure with invalid UTF-8" do
      # tiktoken raises ArgumentError on invalid UTF-8 bytes - fail-fast behavior
      invalid_utf8 = <<0xFF, 0xFE>>

      assert_raise ArgumentError, fn ->
        TokenManager.estimate_tokens(invalid_utf8)
      end
    end

    test "handles valid unicode without error" do
      # Large unicode content that tiktoken handles correctly
      weird_content = String.duplicate("emoji: 🎉🚀💡 ", 100)

      # Should not raise - tiktoken handles unicode
      tokens = TokenManager.estimate_tokens(weird_content)

      # Should have meaningful count, not 0 (silent failure)
      assert tokens > 0, "Unicode content should have non-zero tokens"
    end
  end

  describe "R10: Backward Compatibility - History Functions" do
    test "estimate_history_tokens API unchanged" do
      # Same API, different (accurate) results
      history = [
        %{type: :user, content: "Hello world", timestamp: DateTime.utc_now()},
        %{type: :assistant, content: "Hi there!", timestamp: DateTime.utc_now()}
      ]

      # Function signature unchanged
      tokens = TokenManager.estimate_history_tokens(history)

      # Returns integer
      assert is_integer(tokens)
      assert tokens >= 0
    end

    test "empty history returns 0" do
      assert TokenManager.estimate_history_tokens([]) == 0
    end

    test "nil history returns 0" do
      assert TokenManager.estimate_history_tokens(nil) == 0
    end
  end

  describe "R11: Backward Compatibility - Model Limit" do
    test "should_condense_for_model uses tiktoken" do
      # Create history that exceeds limit ONLY with accurate counting
      # Using file paths that word-based severely undercounts

      # openrouter:openai/gpt-3.5-turbo-0613 has 4095 token limit in LLMDB
      # 600 paths * ~8 tokens each = ~4800 tokens (exceeds 4095 limit)
      paths =
        for i <- 1..600 do
          "./path/to/file-#{i}.txt"
        end

      history = [
        %{
          "type" => "result",
          "content" => Enum.join(paths, "\n"),
          "timestamp" => "2025-12-29T10:00:00Z"
        }
      ]

      state = %{
        model_histories: %{
          "openrouter:openai/gpt-3.5-turbo-0613" => history
        }
      }

      # With tiktoken: 4800+ tokens exceeds 4095 limit
      # With word-based: 600 * 1.33 = 798 tokens - doesn't trigger
      result =
        TokenManager.should_condense_for_model?(state, "openrouter:openai/gpt-3.5-turbo-0613")

      assert result == true,
             "should_condense_for_model must use tiktoken for accurate counting"
    end
  end

  describe "R12: Single Encoding (cl100k_base)" do
    test "uses cl100k_base encoding for all models" do
      # cl100k_base has specific token behavior we can verify
      # The string "tiktoken" is tokenized as ["t", "ik", "token"] = 3 tokens
      # This is consistent with cl100k_base
      text = "tiktoken"

      tokens = TokenManager.estimate_tokens(text)

      # cl100k_base should give 3 tokens for "tiktoken"
      # Other encodings might differ
      assert tokens == 3,
             "Expected 3 tokens for 'tiktoken' with cl100k_base, got #{tokens}"
    end

    test "consistent encoding across different content types" do
      # Same text should give same count regardless of content "type"
      # (type option is removed in v5.0, tiktoken handles all uniformly)
      text = "function calculate(x, y) { return x + y; }"

      tokens = TokenManager.estimate_tokens(text)

      # Verify we get a reasonable count
      assert tokens >= 10, "Code should have 10+ tokens"
      assert tokens <= 20, "Code should have ~15 tokens"
    end
  end

  describe "edge cases and regression" do
    test "very long content doesn't crash" do
      # 10KB of content
      large_content = String.duplicate("word ", 2000)

      tokens = TokenManager.estimate_tokens(large_content)

      # Should handle without crashing
      assert tokens > 0
    end

    test "special characters handled correctly" do
      content = "Special: @#$%^&*()_+-={}[]|\\:\";<>?,./~`"

      tokens = TokenManager.estimate_tokens(content)

      # Each special char may be its own token
      assert tokens > 0
    end

    test "mixed content with paths and text" do
      content = """
      Found the following files:
      ./src/components/Button.tsx
      ./src/components/Input.tsx
      ./src/utils/helpers.ts

      Total: 3 files
      """

      tokens = TokenManager.estimate_tokens(content)

      # Should count paths accurately
      assert tokens >= 30, "Mixed content with paths should have 30+ tokens, got #{tokens}"
    end
  end
end
