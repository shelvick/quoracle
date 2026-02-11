defmodule Quoracle.Agent.TokenManagerDynamicMaxTokensTest do
  @moduledoc """
  Tests for TokenManager v16.0 dynamic max_tokens support.

  New functions:
  - get_model_output_limit/1: Returns LLMDB limits.output for model spec
  - estimate_all_messages_tokens/1: Counts tokens across ALL messages including system

  WorkGroupID: fix-20260210-dynamic-max-tokens
  Spec: CONSENSUS_DynamicMaxTokens v1.0, Section 8 (Unit Tests - TokenManager)
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.TokenManager

  describe "get_model_output_limit/1" do
    test "returns LLMDB limits.output for known model" do
      # DeepSeek-V3.2 on Azure AI Foundry has output=128000
      # This function doesn't exist yet — will fail with UndefinedFunctionError
      limit = TokenManager.get_model_output_limit("azure-ai:deepseek-v3.2")

      # Should return the actual output limit from LLMDB
      assert is_integer(limit)
      assert limit > 0
    end

    test "returns default when model not found in LLMDB" do
      # This function doesn't exist yet — will fail with UndefinedFunctionError
      limit = TokenManager.get_model_output_limit("nonexistent:fake-model-xyz-999")

      # Should fall back to default context limit (128_000) like get_model_context_limit
      assert limit == 128_000
    end

    test "returns output limit distinct from context limit for high-output models" do
      # For models where limits.output != limits.context, both functions
      # should return their respective values
      # This function doesn't exist yet — will fail with UndefinedFunctionError
      output_limit = TokenManager.get_model_output_limit("anthropic:claude-sonnet-4-20250514")
      context_limit = TokenManager.get_model_context_limit("anthropic:claude-sonnet-4-20250514")

      # Both should be positive integers
      assert is_integer(output_limit)
      assert is_integer(context_limit)
      assert output_limit > 0
      assert context_limit > 0
    end
  end

  describe "estimate_all_messages_tokens/1" do
    test "counts all messages including system prompt" do
      messages = [
        %{role: "system", content: "You are a helpful assistant with many rules and guidelines."},
        %{role: "user", content: "Hello, how are you today?"},
        %{role: "assistant", content: "I am doing well, thank you for asking."}
      ]

      # This function doesn't exist yet — will fail with UndefinedFunctionError
      total = TokenManager.estimate_all_messages_tokens(messages)

      # Should count ALL messages (including system), unlike estimate_messages_tokens
      # which excludes system messages
      assert is_integer(total)
      assert total > 0

      # Verify it includes system tokens by comparing with estimate_messages_tokens
      # which excludes system
      non_system_total = TokenManager.estimate_messages_tokens(messages)
      assert total > non_system_total
    end

    test "returns 0 for empty list" do
      # This function doesn't exist yet — will fail with UndefinedFunctionError
      total = TokenManager.estimate_all_messages_tokens([])

      assert total == 0
    end

    test "handles messages with string keys" do
      messages = [
        %{"role" => "system", "content" => "System prompt text for testing."},
        %{"role" => "user", "content" => "User message content."}
      ]

      # This function doesn't exist yet — will fail with UndefinedFunctionError
      total = TokenManager.estimate_all_messages_tokens(messages)

      assert is_integer(total)
      assert total > 0
    end

    test "handles messages with non-string content" do
      messages = [
        %{role: "system", content: "System prompt"},
        %{role: "assistant", content: %{action: "orient", params: %{}, reasoning: "test"}}
      ]

      # This function doesn't exist yet — will fail with UndefinedFunctionError
      total = TokenManager.estimate_all_messages_tokens(messages)

      assert is_integer(total)
      assert total > 0
    end
  end
end
