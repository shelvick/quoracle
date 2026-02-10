defmodule Quoracle.Agent.TokenManagerStringKeysTest do
  @moduledoc """
  Tests for TokenManager v4.0 - String Key Pattern Matching Fix.
  WorkGroupID: fix-20251225-consensus-bugs, Packet 1

  These tests verify that token estimation works correctly with DB-sourced
  history entries that use string keys (e.g., %{"content" => "..."}) instead
  of atom keys (e.g., %{content: "..."}).

  Bug Context: Agent root-84d767cb-e5b1-46f1-9fca-765a7d639f47 accumulated
  295K tokens (~1.1MB) without condensation because token estimation returned 0
  for all DB-sourced entries (pattern matching used atom keys, DB uses strings).

  Requirements: R15-R20
  """

  use ExUnit.Case, async: true
  alias Quoracle.Agent.TokenManager

  # DB-format fixtures - these match what actually comes from PostgreSQL/Ecto
  # Note: All keys are STRINGS, not atoms

  defp db_format_simple_entry do
    %{
      "type" => "user",
      "content" => "Hello, this is a test message with several words",
      "timestamp" => "2025-12-25T10:00:00Z"
    }
  end

  defp db_format_decision_entry do
    %{
      "type" => "decision",
      "content" => %{
        "action" => "orient",
        "params" => %{
          "current_situation" => "Analyzing user request",
          "goal_clarity" => "Clear objectives identified"
        },
        "reasoning" => "Need to understand the context before taking action"
      },
      "timestamp" => "2025-12-25T10:01:00Z"
    }
  end

  defp db_format_event_entry do
    %{
      "type" => "event",
      "content" => "Action completed successfully with result data",
      "timestamp" => "2025-12-25T10:02:00Z"
    }
  end

  defp db_format_complex_content_entry do
    %{
      "type" => "result",
      "content" => %{
        "status" => "success",
        "data" => %{"key" => "value", "nested" => %{"deep" => "data"}}
      },
      "timestamp" => "2025-12-25T10:03:00Z"
    }
  end

  describe "R15: String Key Content Extraction" do
    test "extracts content from string-keyed entry" do
      # DB-format entry with string key "content"
      entry = db_format_simple_entry()

      # The function should extract the content using string key pattern matching
      # Currently FAILS because patterns use atom keys: %{content: content}
      # Fix requires: %{"content" => content}
      tokens = TokenManager.estimate_history_tokens([entry])

      # "Hello, this is a test message with several words" = 9 words
      # 9 words * 1.33 tokens/word ≈ 12 tokens
      assert tokens > 0, "Token count should be non-zero for string-keyed entry"
      assert tokens >= 10
      assert tokens <= 15
    end
  end

  describe "R16: String Key Decision Entry" do
    test "formats decision entry with string keys" do
      # DB-format decision entry with nested string-keyed content
      entry = db_format_decision_entry()

      # The function should extract action/params/reasoning using string keys
      # Currently FAILS because patterns use atom keys: %{content: %{action: _, params: params, reasoning: reasoning}}
      # Fix requires: %{"content" => %{"action" => _, "params" => params, "reasoning" => reasoning}}
      tokens = TokenManager.estimate_history_tokens([entry])

      # Should extract params and reasoning, generating meaningful token count
      # Reasoning alone: "Need to understand the context before taking action" = 8 words
      # Plus params inspection
      assert tokens > 0, "Token count should be non-zero for decision entry with string keys"
      assert tokens >= 8
    end
  end

  describe "R17: Non-Zero Token Count for DB History" do
    test "estimates non-zero tokens for string-keyed history" do
      # Full DB-format history with multiple entry types
      history = [
        db_format_simple_entry(),
        db_format_decision_entry(),
        db_format_event_entry()
      ]

      # This is the core bug fix verification
      # Currently returns 0 because all patterns fall through to _ -> ""
      tokens = TokenManager.estimate_history_tokens(history)

      # Combined content should generate substantial token count
      # Simple: ~12 tokens, Decision: ~8+ tokens, Event: ~6 tokens = ~26+ tokens
      assert tokens > 0, "Token count MUST be non-zero for DB-sourced history"
      assert tokens >= 20, "Token count should reflect actual content size"
    end

    test "counts tokens proportional to content length" do
      # Create entries with known content lengths
      short_entry = %{
        "type" => "user",
        "content" => "short",
        "timestamp" => "2025-12-25T10:00:00Z"
      }

      long_entry = %{
        "type" => "user",
        "content" => String.duplicate("word ", 100),
        "timestamp" => "2025-12-25T10:00:00Z"
      }

      short_tokens = TokenManager.estimate_history_tokens([short_entry])
      long_tokens = TokenManager.estimate_history_tokens([long_entry])

      # Long entry should have significantly more tokens
      assert long_tokens > short_tokens * 10,
             "Token count should scale with content length"
    end
  end

  describe "R18: Condensation Triggers for Large DB History" do
    @tag :integration
    test "should_condense_for_model returns true for large DB-format history" do
      # Create a large DB-format history that should exceed context limit
      # openrouter:openai/gpt-3.5-turbo-0613 has 4095 token limit in LLMDB
      # tiktoken: "word " = ~1 token per rep, need 4100 reps to exceed 4095
      large_content = String.duplicate("word ", 4100)

      large_history = [
        %{
          "type" => "user",
          "content" => large_content,
          "timestamp" => "2025-12-25T10:00:00Z"
        }
      ]

      state = %{
        model_histories: %{
          "openrouter:openai/gpt-3.5-turbo-0613" => large_history
        }
      }

      # This should return true because token count exceeds context limit
      result =
        TokenManager.should_condense_for_model?(state, "openrouter:openai/gpt-3.5-turbo-0613")

      assert result == true,
             "Condensation should trigger for large DB-format history exceeding context limit"
    end

    @tag :integration
    test "condensation triggers for DB-sourced history exceeding limit" do
      # Acceptance test: Simulates what happens with real DB-sourced data
      # This is the user-observable behavior: agent with long history should condense

      # Build history that mimics actual DB storage format
      # openrouter:openai/gpt-3.5-turbo-0613 has 4095 token limit in LLMDB
      # Each entry: ~2 words prefix + 50*2=100 words content = 102 words
      # 50 entries × 102 words = 5100 words ≈ 5100 tokens (exceeds 4095)
      entries =
        for i <- 1..50 do
          %{
            "type" => "user",
            "content" => "Entry #{i}: " <> String.duplicate("conversation content ", 50),
            "timestamp" => "2025-12-25T10:#{String.pad_leading(to_string(i), 2, "0")}:00Z"
          }
        end

      state = %{
        model_histories: %{
          "openrouter:openai/gpt-3.5-turbo-0613" => entries
        }
      }

      # User expectation: condensation triggers before context overflow
      result =
        TokenManager.should_condense_for_model?(state, "openrouter:openai/gpt-3.5-turbo-0613")

      # POSITIVE: Condensation should trigger
      assert result == true, "Condensation must trigger for large DB-sourced history"

      # NEGATIVE: Should not be zero tokens (the bug)
      estimated = TokenManager.estimate_history_tokens(entries)
      refute estimated == 0, "Token estimation must not return 0 for valid content"
    end
  end

  describe "R19: Empty Content Handling" do
    test "returns 0 tokens for empty content entries" do
      # Entry with empty string content
      empty_content_entry = %{
        "type" => "user",
        "content" => "",
        "timestamp" => "2025-12-25T10:00:00Z"
      }

      tokens = TokenManager.estimate_history_tokens([empty_content_entry])

      assert tokens == 0, "Empty content should result in 0 tokens"
    end

    test "returns 0 tokens for missing content key" do
      # Entry without content key at all
      no_content_entry = %{
        "type" => "system",
        "timestamp" => "2025-12-25T10:00:00Z"
      }

      tokens = TokenManager.estimate_history_tokens([no_content_entry])

      assert tokens == 0, "Missing content key should result in 0 tokens (graceful handling)"
    end

    test "returns 0 tokens for nil content" do
      # Entry with nil content
      nil_content_entry = %{
        "type" => "user",
        "content" => nil,
        "timestamp" => "2025-12-25T10:00:00Z"
      }

      tokens = TokenManager.estimate_history_tokens([nil_content_entry])

      assert tokens == 0, "Nil content should result in 0 tokens"
    end
  end

  describe "R20: Mixed Format Robustness" do
    test "handles mixed entry formats gracefully" do
      # Mix of different DB-format entry types
      mixed_history = [
        db_format_simple_entry(),
        db_format_decision_entry(),
        db_format_event_entry(),
        db_format_complex_content_entry(),
        # Entry with empty content (should contribute 0)
        %{"type" => "system", "content" => "", "timestamp" => "2025-12-25T10:04:00Z"},
        # Entry with no content key (should contribute 0)
        %{"type" => "marker", "timestamp" => "2025-12-25T10:05:00Z"}
      ]

      tokens = TokenManager.estimate_history_tokens(mixed_history)

      # Should extract content from valid entries, skip empty/missing
      # Valid entries should contribute meaningful tokens
      assert tokens > 0, "Mixed history should have non-zero token count from valid entries"
    end

    test "handles history with only unrecognized formats" do
      # All entries have unrecognized structure
      unrecognized_history = [
        %{"type" => "unknown", "data" => "something"},
        %{"other_key" => "other_value"},
        %{}
      ]

      tokens = TokenManager.estimate_history_tokens(unrecognized_history)

      # Should gracefully return 0, not crash
      assert tokens == 0, "Unrecognized formats should gracefully return 0"
    end
  end
end
