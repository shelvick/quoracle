defmodule Quoracle.Agent.TokenManagerPerModelTest do
  @moduledoc """
  Tests for per-model context limit checking in TokenManager.
  Packet 3: Context Operations - TokenManager requirements R1-R9.
  """

  use ExUnit.Case, async: true
  alias Quoracle.Agent.TokenManager

  describe "R1: Per-Model Limit Check" do
    test "checks context limit for specific model history" do
      state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => [
            %{
              type: :user,
              content: String.duplicate("word ", 1000),
              timestamp: DateTime.utc_now()
            }
          ],
          "google:gemini-2.0-flash" => [
            %{type: :user, content: "short message", timestamp: DateTime.utc_now()}
          ]
        }
      }

      # This function doesn't exist yet - will fail
      # Claude history has ~1330 tokens, Gemini has ~3 tokens
      claude_result = TokenManager.should_condense_for_model?(state, "anthropic:claude-sonnet-4")
      gemini_result = TokenManager.should_condense_for_model?(state, "google:gemini-2.0-flash")

      # Claude should potentially need condensation (depends on limit)
      # Gemini definitely should not
      assert is_boolean(claude_result)
      assert gemini_result == false
    end
  end

  describe "R2: LLMDB Context Limit Lookup" do
    test "retrieves context limit from LLMDB model data" do
      # This function doesn't exist yet - will fail
      # Claude Sonnet 4 has 200k context limit
      limit = TokenManager.get_model_context_limit("anthropic:claude-sonnet-4-20250514")

      # Should retrieve actual limit from LLMDB
      assert is_integer(limit)
      assert limit > 0
    end
  end

  describe "R3: Default Context Limit" do
    test "uses 128000 default when model not found" do
      # This function doesn't exist yet - will fail
      limit = TokenManager.get_model_context_limit("nonexistent:fake-model-999")

      # Should use default when model not in LLMDB
      assert limit == 128_000
    end
  end

  describe "R4: Nil Limits Handling" do
    test "uses default when limits.context is nil" do
      # This function doesn't exist yet - will fail
      # A model that exists but might have nil limits (mock scenario)
      # In practice, we'd need to mock LLMDB for this
      limit = TokenManager.get_model_context_limit("test:model-with-nil-limits")

      # Should fall back to default
      assert limit == 128_000
    end
  end

  describe "R5: 100% Threshold (ACE v3.0)" do
    test "triggers condensation at 100% of context limit" do
      # openrouter:openai/gpt-3.5-turbo-0613 has 4095 token limit in LLMDB
      # ACE v3.0: Trigger at 100%, not 80%
      # tiktoken: "word " = ~1 token per rep, 4100 reps = ~4100 tokens >= 100% of 4095
      large_history = [
        %{type: :user, content: String.duplicate("word ", 4100), timestamp: DateTime.utc_now()}
      ]

      state = %{
        model_histories: %{
          "openrouter:openai/gpt-3.5-turbo-0613" => large_history
        }
      }

      result =
        TokenManager.should_condense_for_model?(state, "openrouter:openai/gpt-3.5-turbo-0613")

      assert result == true
    end
  end

  describe "R6: Under Threshold" do
    test "does not trigger condensation under threshold" do
      # Create history well under 80% of limit
      # 100 words * 1.3 = 130 tokens, way under any reasonable limit
      small_history = [
        %{type: :user, content: String.duplicate("word ", 100), timestamp: DateTime.utc_now()}
      ]

      state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => small_history
        }
      }

      # This function doesn't exist yet - will fail
      result = TokenManager.should_condense_for_model?(state, "anthropic:claude-sonnet-4")

      assert result == false
    end
  end

  describe "R7: Empty History" do
    test "returns false for empty model history" do
      state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => []
        }
      }

      # This function doesn't exist yet - will fail
      result = TokenManager.should_condense_for_model?(state, "anthropic:claude-sonnet-4")

      assert result == false
    end

    test "returns false for model not in histories" do
      state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => [
            %{type: :user, content: "some content", timestamp: DateTime.utc_now()}
          ]
        }
      }

      # This function doesn't exist yet - will fail
      # Model not in map should be treated as empty
      result = TokenManager.should_condense_for_model?(state, "google:gemini-2.0-flash")

      assert result == false
    end
  end

  describe "R8: Token Estimation Uses tiktoken" do
    test "token estimation uses tiktoken cl100k_base encoding" do
      # tiktoken provides accurate token counts
      history = [
        %{
          type: :user,
          content: "one two three four five six seven eight nine ten",
          timestamp: DateTime.utc_now()
        }
      ]

      # tiktoken: 10 words = ~10 tokens (varies by word)
      tokens = TokenManager.estimate_history_tokens(history)

      assert tokens >= 8
      assert tokens <= 12
    end
  end

  describe "R9: Different Models Different Limits" do
    test "different models use different context limits" do
      # Create identical histories for two models with different context limits
      # openrouter:openai/gpt-3.5-turbo-0613 has 4095 context, Claude has 200k
      # ACE v3.0: Trigger at 100%, not 80%
      # tiktoken: "word " = ~1 token per rep, 4100 reps = ~4100 tokens
      # For Claude 200k: 4100/200000 = 2% (under 100%)
      # For GPT-3.5: 4100/4095 = 100%+ (at limit, triggers)
      history = [
        %{type: :user, content: String.duplicate("word ", 4100), timestamp: DateTime.utc_now()}
      ]

      state = %{
        model_histories: %{
          # 200k context - 4100 tokens = 2%
          "anthropic:claude-sonnet-4-20250514" => history,
          # 4095 context - 4100 tokens = 100%+
          "openrouter:openai/gpt-3.5-turbo-0613" => history
        }
      }

      claude_result =
        TokenManager.should_condense_for_model?(state, "anthropic:claude-sonnet-4-20250514")

      small_result =
        TokenManager.should_condense_for_model?(state, "openrouter:openai/gpt-3.5-turbo-0613")

      # Claude has huge context, should not need condensation
      assert claude_result == false
      # GPT-3.5 has smaller context (at 100%), should need condensation
      assert small_result == true
    end
  end
end
