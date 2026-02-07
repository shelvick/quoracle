defmodule Quoracle.Agent.TokenManagerACETest do
  @moduledoc """
  Tests for AGENT_TokenManager v3.0 ACE reactive condensation.
  WorkGroupID: ace-20251207-140000
  Packet: 1 (Foundation)

  Tests R10-R14 from AGENT_TokenManager_PerModelHistories.md v3.0 spec:
  - R10: No 80% Threshold - does not trigger at 80%
  - R11: Trigger at 100% - triggers at 100% of limit
  - R12: Token-Based Removal Target - removes >80% of tokens
  - R13: Oldest First Removal - oldest messages removed first
  - R14: Token Counting Accuracy - counts tokens not messages
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.TokenManager

  # Helper to create history entries with specific token counts
  # tiktoken: "word " = ~1 token per rep, so word_count ≈ token_count
  defp create_entry(id, word_count) do
    content = String.duplicate("word ", word_count) |> String.trim()

    %{
      id: id,
      type: :user,
      content: content,
      timestamp: DateTime.utc_now()
    }
  end

  describe "R10: No 80% Threshold" do
    test "does not trigger at 80% threshold" do
      # openrouter:openai/gpt-3.5-turbo-0613 has 4095 token limit in LLMDB
      # 80% of 4095 = 3276 tokens
      # tiktoken: word_count ≈ token_count
      history_at_80_percent = [
        create_entry(1, 3276)
      ]

      state = %{
        model_histories: %{
          "openrouter:openai/gpt-3.5-turbo-0613" => history_at_80_percent
        }
      }

      # ACE v3.0: Should NOT trigger at 80% - only at 100%
      result =
        TokenManager.should_condense_for_model?(state, "openrouter:openai/gpt-3.5-turbo-0613")

      assert result == false,
             "should_condense_for_model? must NOT trigger at 80% threshold (ACE v3.0 removes threshold)"
    end

    test "does not trigger at 90% of limit" do
      # 90% of 4095 = 3685 tokens
      # tiktoken: word_count ≈ token_count
      history_at_90_percent = [
        create_entry(1, 3685)
      ]

      state = %{
        model_histories: %{
          "openrouter:openai/gpt-3.5-turbo-0613" => history_at_90_percent
        }
      }

      # ACE v3.0: Should NOT trigger at 90% either
      result =
        TokenManager.should_condense_for_model?(state, "openrouter:openai/gpt-3.5-turbo-0613")

      assert result == false,
             "should_condense_for_model? must NOT trigger at 90% (only at 100%)"
    end
  end

  describe "R11: Trigger at 100%" do
    test "triggers condensation at 100% of limit" do
      # openrouter:openai/gpt-3.5-turbo-0613 has 4095 token limit in LLMDB
      # tiktoken: word_count ≈ token_count, so use 4100 words to exceed limit
      history_at_100_percent = [
        create_entry(1, 4100)
      ]

      state = %{
        model_histories: %{
          "openrouter:openai/gpt-3.5-turbo-0613" => history_at_100_percent
        }
      }

      # ACE v3.0: Should trigger at >= 100%
      result =
        TokenManager.should_condense_for_model?(state, "openrouter:openai/gpt-3.5-turbo-0613")

      assert result == true,
             "should_condense_for_model? must trigger at 100% of limit"
    end

    test "triggers condensation when over 100% of limit" do
      # 120% of 4095 = 4914 tokens
      # tiktoken: word_count ≈ token_count
      history_over_limit = [
        create_entry(1, 4914)
      ]

      state = %{
        model_histories: %{
          "openrouter:openai/gpt-3.5-turbo-0613" => history_over_limit
        }
      }

      result =
        TokenManager.should_condense_for_model?(state, "openrouter:openai/gpt-3.5-turbo-0613")

      assert result == true,
             "should_condense_for_model? must trigger when over limit"
    end
  end

  describe "R12: Token-Based Removal Target" do
    test "removes more than half of total tokens" do
      # Create history with 4 entries of varying sizes
      # Entry 1 (oldest): 100 words = ~133 tokens
      # Entry 2: 200 words = ~266 tokens
      # Entry 3: 150 words = ~199 tokens
      # Entry 4 (newest): 50 words = ~67 tokens
      # Total: 500 words = ~665 tokens
      # Target removal: >532 tokens (>80%)
      history = [
        create_entry(1, 100),
        create_entry(2, 200),
        create_entry(3, 150),
        create_entry(4, 50)
      ]

      total_tokens = TokenManager.estimate_history_tokens(history)

      # This function doesn't exist yet - will fail
      {to_remove, to_keep} = TokenManager.tokens_to_condense(history, total_tokens)

      removed_tokens = TokenManager.estimate_history_tokens(to_remove)
      kept_tokens = TokenManager.estimate_history_tokens(to_keep)

      # Must remove >80% of total tokens
      assert removed_tokens > div(total_tokens * 80, 100),
             "tokens_to_condense must remove >80% of total tokens"

      # Sanity check: removed + kept should equal total (approximately)
      assert_in_delta removed_tokens + kept_tokens,
                      total_tokens,
                      5,
                      "removed + kept tokens should equal total"
    end
  end

  describe "R13: Oldest First Removal" do
    test "removes oldest messages first" do
      # Create history with 4 entries of varying sizes (newest-first)
      # Entry 1 (oldest): 200 words = ~266 tokens
      # Entry 2: 150 words = ~199 tokens
      # Entry 3: 100 words = ~133 tokens
      # Entry 4 (newest): 50 words = ~67 tokens
      # Total: ~665 tokens, 80% target = ~532 tokens
      # Entries 1+2+3 = ~598 tokens > 532, so entry 4 kept
      history = [
        create_entry(4, 50),
        create_entry(3, 100),
        create_entry(2, 150),
        create_entry(1, 200)
      ]

      total_tokens = TokenManager.estimate_history_tokens(history)

      {to_remove, to_keep} = TokenManager.tokens_to_condense(history, total_tokens)

      # Get IDs of removed and kept entries
      removed_ids = Enum.map(to_remove, & &1.id)
      kept_ids = Enum.map(to_keep, & &1.id)

      # Oldest entries (1, 2, 3) should be removed first
      assert 1 in removed_ids, "oldest entry (id=1) should be removed"
      assert 2 in removed_ids, "second oldest entry (id=2) should be removed"
      assert 3 in removed_ids, "third oldest entry (id=3) should be removed"

      # Newest should be kept (removing 1,2,3 gives >80%)
      assert 4 in kept_ids, "newest entry (id=4) should be kept"
    end

    test "removes from oldest until >80% tokens removed" do
      # Create history with varying sizes (newest-first order)
      # Entry 4 (newest): 10 words = ~13 tokens
      # Entry 3: 100 words = ~133 tokens
      # Entry 2: 10 words = ~13 tokens
      # Entry 1 (oldest): 10 words = ~13 tokens
      # Total: 130 words = ~172 tokens
      # Target: >137 tokens (80%)
      # Entry 1+2 = ~26 tokens (not enough)
      # Entry 1+2+3 = ~159 tokens (>137, done)
      history = [
        create_entry(4, 10),
        create_entry(3, 100),
        create_entry(2, 10),
        create_entry(1, 10)
      ]

      total_tokens = TokenManager.estimate_history_tokens(history)

      # This function doesn't exist yet - will fail
      {to_remove, to_keep} = TokenManager.tokens_to_condense(history, total_tokens)

      removed_ids = Enum.map(to_remove, & &1.id)
      kept_ids = Enum.map(to_keep, & &1.id)

      # Entries 1, 2, 3 should be removed (oldest first until >80%)
      assert 1 in removed_ids
      assert 2 in removed_ids
      assert 3 in removed_ids

      # Entry 4 (newest) should be kept
      assert kept_ids == [4], "only newest entry should remain"
    end
  end

  describe "R14: Token Counting Accuracy" do
    test "counts tokens not message count" do
      # Create 2 messages: one large, one small
      # Large: 300 words = ~399 tokens
      # Small: 10 words = ~13 tokens
      # Total: 310 words = ~412 tokens
      # 80% target = ~329 tokens
      # If counting messages: would remove 1 message (either)
      # If counting tokens: must remove large message (399 > 329)
      history = [
        create_entry(1, 300),
        create_entry(2, 10)
      ]

      total_tokens = TokenManager.estimate_history_tokens(history)
      target_removal = div(total_tokens * 80, 100) + 1

      # This function doesn't exist yet - will fail
      {to_remove, _to_keep} = TokenManager.tokens_to_condense(history, total_tokens)

      removed_tokens = TokenManager.estimate_history_tokens(to_remove)

      # Must remove enough TOKENS (not just 1 message)
      assert removed_tokens > target_removal,
             "must remove based on token count, not message count"

      # The large message (entry 1) should be removed since it alone exceeds 80%
      removed_ids = Enum.map(to_remove, & &1.id)
      assert 1 in removed_ids, "large message should be removed to meet token target"
    end

    test "small messages accumulate until token target met" do
      # Create 10 small messages of 20 words each = ~26 tokens each
      # Total: 200 words = ~266 tokens
      # 80% target = ~212 tokens
      # Need to remove ~8-9 messages to hit target
      history =
        Enum.map(1..10, fn id ->
          create_entry(id, 20)
        end)

      total_tokens = TokenManager.estimate_history_tokens(history)
      target_removal = div(total_tokens * 80, 100) + 1

      # This function doesn't exist yet - will fail
      {to_remove, to_keep} = TokenManager.tokens_to_condense(history, total_tokens)

      removed_count = length(to_remove)
      kept_count = length(to_keep)
      removed_tokens = TokenManager.estimate_history_tokens(to_remove)

      # Should remove multiple small messages (80% = ~8-9 of 10)
      assert removed_count >= 8, "most small messages should be removed"
      assert kept_count <= 2, "few messages should remain"
      assert removed_tokens > target_removal, "removed tokens must exceed target"
    end
  end

  describe "Edge cases" do
    test "empty history returns empty lists" do
      # This function doesn't exist yet - will fail
      {to_remove, to_keep} = TokenManager.tokens_to_condense([], 0)

      assert to_remove == []
      assert to_keep == []
    end

    test "single message history" do
      history = [create_entry(1, 100)]
      total_tokens = TokenManager.estimate_history_tokens(history)

      # This function doesn't exist yet - will fail
      {to_remove, to_keep} = TokenManager.tokens_to_condense(history, total_tokens)

      # Single message: must remove it to meet >80% target
      assert length(to_remove) == 1
      assert to_keep == []
    end
  end
end
