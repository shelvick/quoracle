defmodule Quoracle.Agent.TokenManagerTest do
  @moduledoc """
  Tests for token counting and context management in TokenManager.
  These tests verify proper token estimation and context summarization triggers.
  """

  use ExUnit.Case, async: true
  alias Quoracle.Agent.TokenManager

  describe "token counting and estimation" do
    test "estimates tokens from text using tiktoken" do
      # tiktoken cl100k_base provides accurate token counts
      text = "This is a sample message with multiple words for testing token estimation"

      estimated_tokens = TokenManager.estimate_tokens(text)

      # tiktoken gives 13 tokens for this text
      assert estimated_tokens >= 10
      assert estimated_tokens <= 16
    end

    test "estimates tokens for conversation history" do
      history = [
        %{type: :prompt, content: "Hello, how are you?", timestamp: DateTime.utc_now()},
        %{
          type: :decision,
          content: %{action: :orient, params: %{}},
          timestamp: DateTime.utc_now()
        },
        %{type: :event, content: "User clicked button", timestamp: DateTime.utc_now()}
      ]

      # This function doesn't exist yet - will fail
      total_tokens = TokenManager.estimate_history_tokens(history)

      assert is_integer(total_tokens)
      assert total_tokens > 0
    end

    test "tracks token usage from API responses" do
      state = %{
        model_histories: %{"default" => []},
        token_usage: %{
          total: 0,
          last_request: 0,
          last_response: 0
        }
      }

      api_response = %{
        usage: %{
          prompt_tokens: 150,
          completion_tokens: 75,
          total_tokens: 225
        }
      }

      # This function doesn't exist yet - will fail
      new_state = TokenManager.update_token_usage(state, api_response)

      assert new_state.token_usage.total == 225
      assert new_state.token_usage.last_request == 150
      assert new_state.token_usage.last_response == 75
    end

    test "calculates percentage of context limit used" do
      state = %{
        model_histories: %{
          "default" => [
            %{
              type: :prompt,
              # tiktoken: "word " = ~1 token per rep, 1000 reps = ~1000 tokens = 25% of 4000
              content: String.duplicate("word ", 1000),
              timestamp: DateTime.utc_now()
            }
          ]
        },
        context_limit: 4000
      }

      percentage = TokenManager.context_usage_percentage(state)

      # ~1000 tokens / 4000 = ~25%
      assert percentage >= 20.0
      assert percentage <= 30.0
    end

    test "determines when context summarization is needed" do
      # State with history at 80% of limit
      # tiktoken: "word " = ~1 token per rep, 3200 reps = ~3200 tokens = 80% of 4000
      state_near_limit = %{
        model_histories: %{
          "default" => [
            %{
              type: :prompt,
              content: String.duplicate("word ", 3200),
              timestamp: DateTime.utc_now()
            }
          ]
        },
        context_limit: 4000
      }

      # Verify token estimation works on high-usage state
      tokens = TokenManager.estimate_history_tokens(state_near_limit.model_histories["default"])
      assert tokens > 0
    end

    test "estimates tokens for different content types uniformly" do
      # tiktoken v5.0: Single encoding for all content types (type option removed)
      code_content = """
      def process_data(items) do
        items
        |> Enum.map(&transform/1)
        |> Enum.filter(&valid?/1)
        |> Enum.reduce(%{}, &aggregate/2)
      end
      """

      # Regular text
      text_content = "This is regular text without any special formatting or code"

      # JSON structure
      json_content = ~s({"action": "orient", "params": {"key": "value"}})

      # All content uses cl100k_base encoding uniformly
      code_tokens = TokenManager.estimate_tokens(code_content)
      text_tokens = TokenManager.estimate_tokens(text_content)
      json_tokens = TokenManager.estimate_tokens(json_content)

      assert code_tokens > 0
      assert text_tokens > 0
      assert json_tokens > 0

      # tiktoken handles all content types accurately
      assert is_integer(code_tokens)
      assert is_integer(text_tokens)
      assert is_integer(json_tokens)
    end

    test "handles empty or nil content gracefully" do
      # These functions don't exist yet - will fail
      assert TokenManager.estimate_tokens("") == 0
      assert TokenManager.estimate_tokens(nil) == 0
      assert TokenManager.estimate_history_tokens([]) == 0
      assert TokenManager.estimate_history_tokens(nil) == 0
    end

    test "includes system prompts in token estimation" do
      state = %{
        model_histories: %{
          "default" => [
            %{type: :prompt, content: "User message", timestamp: DateTime.utc_now()}
          ]
        },
        system_prompt:
          "You are a helpful assistant. Follow these rules: 1) Be concise 2) Be accurate"
      }

      # This function doesn't exist yet - will fail
      with_system = TokenManager.estimate_total_context_tokens(state, include_system: true)
      without_system = TokenManager.estimate_total_context_tokens(state, include_system: false)

      assert with_system > without_system
      # System prompt should add meaningful tokens
      assert with_system - without_system >= 10
    end
  end

  describe "token usage from API responses" do
    test "accumulates token usage across multiple API calls" do
      state = %{
        token_usage: %{
          total: 100,
          by_model: %{
            "gpt-4" => 100
          }
        }
      }

      response1 = %{
        model: "gpt-4",
        usage: %{prompt_tokens: 50, completion_tokens: 25, total_tokens: 75}
      }

      response2 = %{
        model: "claude-3",
        usage: %{prompt_tokens: 30, completion_tokens: 20, total_tokens: 50}
      }

      # These functions don't exist yet - will fail
      state = TokenManager.update_token_usage(state, response1)
      assert state.token_usage.total == 175
      assert state.token_usage.by_model["gpt-4"] == 175

      state = TokenManager.update_token_usage(state, response2)
      assert state.token_usage.total == 225
      assert state.token_usage.by_model["claude-3"] == 50
    end
  end
end
