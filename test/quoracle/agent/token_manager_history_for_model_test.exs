defmodule Quoracle.Agent.TokenManagerHistoryForModelTest do
  @moduledoc """
  Tests for TokenManager.history_tokens_for_model/2 helper.
  Packet 1: Context Token Injection - TokenManager v8.0 requirements R29-R33.
  """

  use ExUnit.Case, async: true
  alias Quoracle.Agent.TokenManager

  # Helper to build history entries matching DB format (string keys)
  defp build_history_entry(content, role \\ "user") do
    %{"role" => role, "content" => content, "timestamp" => DateTime.utc_now()}
  end

  describe "R29: Basic Token Count" do
    test "returns token count for model's history" do
      history = [
        build_history_entry("Hello, how are you today?"),
        build_history_entry("I am doing well, thanks!", "assistant")
      ]

      state = %{
        model_histories: %{
          "model-1" => history
        }
      }

      # Function doesn't exist yet - will fail with UndefinedFunctionError
      result = TokenManager.history_tokens_for_model(state, "model-1")

      # Should return positive integer (tiktoken count)
      assert is_integer(result)
      assert result > 0
    end
  end

  describe "R30: Missing Model Returns Zero" do
    test "returns 0 for missing model_id" do
      state = %{
        model_histories: %{
          "model-1" => [build_history_entry("Some content")]
        }
      }

      # Query for model not in map
      result = TokenManager.history_tokens_for_model(state, "model-2")

      assert result == 0
    end
  end

  describe "R31: Empty History Returns Zero" do
    test "returns 0 for empty model history" do
      state = %{
        model_histories: %{
          "model-1" => []
        }
      }

      result = TokenManager.history_tokens_for_model(state, "model-1")

      assert result == 0
    end
  end

  describe "R32: Consistent with estimate_history_tokens" do
    test "matches estimate_history_tokens for same history" do
      history = [
        build_history_entry("The quick brown fox jumps over the lazy dog"),
        build_history_entry("Indeed it does!", "assistant"),
        build_history_entry("What about the cat?")
      ]

      state = %{
        model_histories: %{
          "model-1" => history
        }
      }

      # Get direct calculation
      expected = TokenManager.estimate_history_tokens(history)

      # Get via helper
      actual = TokenManager.history_tokens_for_model(state, "model-1")

      # Should be identical
      assert actual == expected
    end
  end

  describe "R33: Handles Nil model_histories" do
    test "returns 0 when model_histories is nil" do
      state = %{
        model_histories: nil
      }

      result = TokenManager.history_tokens_for_model(state, "model-1")

      assert result == 0
    end

    test "returns 0 when model_histories key is missing" do
      state = %{}

      result = TokenManager.history_tokens_for_model(state, "model-1")

      assert result == 0
    end
  end
end
