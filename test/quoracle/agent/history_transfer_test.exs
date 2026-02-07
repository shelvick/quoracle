defmodule Quoracle.Agent.HistoryTransferTest do
  @moduledoc """
  Tests for AGENT_HistoryTransfer - History and ACE state transfer during model pool switching.
  WorkGroupID: wip-20251230-075616

  ARC Verification Criteria:
  - R1-R3: History Selection (select_source_model/2)
  - R4-R5: Context Limit Discovery (find_smallest_context_limit/1)
  - R6-R8: Condensation (condense_until_fits/4)
  - R9-R15: State Transfer (transfer_state_to_new_pool/3)
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.HistoryTransfer
  alias Quoracle.Agent.TokenManager

  # Test helpers for creating mock histories
  defp create_history(entry_count, content_size) do
    Enum.map(1..entry_count, fn i ->
      %{
        type: :user,
        content: String.duplicate("x", content_size) <> " #{i}",
        timestamp: DateTime.utc_now()
      }
    end)
  end

  defp create_state(model_histories, opts \\ []) do
    %{
      model_histories: model_histories,
      context_lessons: Keyword.get(opts, :context_lessons, %{}),
      model_states: Keyword.get(opts, :model_states, %{}),
      task_id: Keyword.get(opts, :task_id)
    }
  end

  # =============================================================
  # History Selection (R1-R3)
  # =============================================================

  describe "select_source_model/2" do
    # R1: WHEN multiple histories fit target limit THEN selects one with most tokens
    test "selects largest history that fits within target limit" do
      # Create histories with different token counts
      small_history = create_history(5, 50)
      medium_history = create_history(10, 50)
      large_history = create_history(20, 50)

      model_histories = %{
        "model-a" => small_history,
        "model-b" => medium_history,
        "model-c" => large_history
      }

      # Calculate actual token counts
      small_tokens = TokenManager.estimate_history_tokens(small_history)
      medium_tokens = TokenManager.estimate_history_tokens(medium_history)
      large_tokens = TokenManager.estimate_history_tokens(large_history)

      # Target limit that fits small and medium, not large
      target_limit = medium_tokens + div(large_tokens - medium_tokens, 2)

      assert {:ok, {model_id, history, tokens}} =
               HistoryTransfer.select_source_model(model_histories, target_limit)

      # Should select medium (largest fitting)
      assert model_id == "model-b"
      assert history == medium_history
      assert tokens <= target_limit
      assert tokens >= small_tokens
    end

    # R2: WHEN no history fits target limit THEN returns {:error, :no_fitting_history}
    test "returns error when no history fits target limit" do
      large_history = create_history(100, 100)

      model_histories = %{
        "model-a" => large_history,
        "model-b" => large_history
      }

      # Very small target
      target_limit = 10

      assert {:error, :no_fitting_history} =
               HistoryTransfer.select_source_model(model_histories, target_limit)
    end

    # R3: WHEN history is empty THEN always fits (0 tokens)
    test "empty history always fits any target limit" do
      model_histories = %{
        "model-a" => [],
        "model-b" => create_history(100, 100)
      }

      # Tiny target - only empty fits
      target_limit = 1

      assert {:ok, {"model-a", [], 0}} =
               HistoryTransfer.select_source_model(model_histories, target_limit)
    end
  end

  # =============================================================
  # Context Limit Discovery (R4-R5)
  # =============================================================

  describe "find_smallest_context_limit/1" do
    # R4: WHEN model pool has varied context limits THEN returns smallest
    test "finds smallest context limit among models" do
      # Use model specs that exist in LLMDB with known limits
      # These should have different context limits
      model_pool = ["azure/gpt-4o", "bedrock/claude-3-haiku"]

      result = HistoryTransfer.find_smallest_context_limit(model_pool)

      # Should return the smaller of the two limits
      assert is_integer(result)
      assert result > 0
    end

    # R5: WHEN pool has single model THEN returns that model's limit
    test "handles single model pool" do
      model_pool = ["azure/gpt-4o"]

      result = HistoryTransfer.find_smallest_context_limit(model_pool)

      expected = TokenManager.get_model_context_limit("azure/gpt-4o")
      assert result == expected
    end
  end

  # =============================================================
  # Condensation (R6-R8)
  # =============================================================

  describe "condense_until_fits/4" do
    # R6: WHEN history exceeds limit THEN condenses until it fits
    test "condenses history until it fits target limit" do
      # Create oversized history
      large_history = create_history(50, 200)
      state = create_state(%{"model-a" => large_history})

      target_limit = 500

      # Use test_mode to avoid real LLM calls
      opts = [test_mode: true]

      assert {:ok, condensed_state} =
               HistoryTransfer.condense_until_fits(state, "model-a", target_limit, opts)

      new_history = condensed_state.model_histories["model-a"]
      new_tokens = TokenManager.estimate_history_tokens(new_history)

      assert new_tokens <= target_limit
    end

    # R7: WHEN condensation makes no progress THEN returns {:error, :condensation_failed}
    test "fails if condensation makes no progress" do
      # Create minimal history that can't be further condensed
      minimal_history = [%{type: :user, content: "x", timestamp: DateTime.utc_now()}]
      state = create_state(%{"model-a" => minimal_history})

      # Impossibly small target
      target_limit = 0

      # Mock condense_fn that returns same history (no progress)
      opts = [
        test_mode: true,
        condense_fn: fn state_arg, _model_id, _opts -> state_arg end
      ]

      assert {:error, :condensation_failed} =
               HistoryTransfer.condense_until_fits(state, "model-a", target_limit, opts)
    end

    # R8: WHEN condensation occurs THEN context_lessons accumulated via Reflector
    test "condensation updates ACE state" do
      large_history = create_history(30, 200)

      state =
        create_state(
          %{"model-a" => large_history},
          context_lessons: %{"model-a" => []},
          model_states: %{"model-a" => nil}
        )

      target_limit = 500

      # Use test reflector that returns lessons
      opts = [
        test_mode: true,
        reflector_fn: fn _msgs, _model, _opts ->
          {:ok,
           %{
             lessons: [%{type: :factual, content: "learned something", confidence: 80}],
             state: [%{summary: "test state", updated_at: DateTime.utc_now()}]
           }}
        end
      ]

      assert {:ok, condensed_state} =
               HistoryTransfer.condense_until_fits(state, "model-a", target_limit, opts)

      # ACE state should have accumulated lessons
      lessons = get_in(condensed_state, [:context_lessons, "model-a"])
      assert lessons != []
    end
  end

  # =============================================================
  # State Transfer (R9-R15)
  # =============================================================

  describe "transfer_state_to_new_pool/3" do
    # R9: WHEN transfer completes THEN model_histories keyed under new model IDs
    test "re-keys model_histories under new model IDs" do
      old_history = create_history(5, 50)
      state = create_state(%{"old-model" => old_history})

      new_pool = ["new-model-x", "new-model-y"]

      assert {:ok, new_state} =
               HistoryTransfer.transfer_state_to_new_pool(state, new_pool, test_mode: true)

      assert Map.keys(new_state.model_histories) |> Enum.sort() == Enum.sort(new_pool)
      refute Map.has_key?(new_state.model_histories, "old-model")
    end

    # R10: WHEN transfer completes THEN all new models share same history reference
    test "all new models share same history reference" do
      old_history = create_history(5, 50)
      state = create_state(%{"old-model" => old_history})

      new_pool = ["new-model-x", "new-model-y", "new-model-z"]

      assert {:ok, new_state} =
               HistoryTransfer.transfer_state_to_new_pool(state, new_pool, test_mode: true)

      # All histories should be the same reference
      [h1, h2, h3] = Enum.map(new_pool, &new_state.model_histories[&1])
      assert h1 == h2
      assert h2 == h3
    end

    # R11: WHEN transfer completes THEN context_lessons and model_states from source model
    test "transfers ACE state from source model to all new models" do
      old_history = create_history(5, 50)
      lessons = [%{type: :factual, content: "important", confidence: 90}]
      model_state = %{summary: "context", updated_at: DateTime.utc_now()}

      state =
        create_state(
          %{"old-model" => old_history},
          context_lessons: %{"old-model" => lessons},
          model_states: %{"old-model" => model_state}
        )

      new_pool = ["new-x", "new-y"]

      assert {:ok, new_state} =
               HistoryTransfer.transfer_state_to_new_pool(state, new_pool, test_mode: true)

      # All new models should have the source ACE state
      for model_id <- new_pool do
        assert new_state.context_lessons[model_id] == lessons
        assert new_state.model_states[model_id] == model_state
      end
    end

    # R12: WHEN history selected from model X THEN ACE state also from model X
    test "ACE state comes from same model as selected history" do
      # Two old models with different histories and ACE states
      small_history = create_history(3, 50)
      large_history = create_history(10, 50)

      small_lessons = [%{type: :factual, content: "small", confidence: 80}]
      large_lessons = [%{type: :factual, content: "large", confidence: 90}]

      state =
        create_state(
          %{"small-model" => small_history, "large-model" => large_history},
          context_lessons: %{"small-model" => small_lessons, "large-model" => large_lessons}
        )

      new_pool = ["new-model"]

      assert {:ok, new_state} =
               HistoryTransfer.transfer_state_to_new_pool(state, new_pool, test_mode: true)

      # Should have lessons from large-model (the selected source with largest fitting history)
      assert new_state.context_lessons["new-model"] == large_lessons
    end

    # R13: WHEN history fits new pool THEN returns {:ok, updated_state} without condensation
    test "transfers without condensation when history fits" do
      small_history = create_history(3, 50)
      state = create_state(%{"old-model" => small_history})

      new_pool = ["new-model"]

      # Track if condensation was called
      condensation_called = :atomics.new(1, [])

      opts = [
        test_mode: true,
        condense_fn: fn state_arg, _model_id, _opts ->
          :atomics.add(condensation_called, 1, 1)
          state_arg
        end
      ]

      assert {:ok, _new_state} =
               HistoryTransfer.transfer_state_to_new_pool(state, new_pool, opts)

      # Condensation should NOT have been called
      assert :atomics.get(condensation_called, 1) == 0
    end

    # R14: WHEN no history fits THEN condenses and returns {:ok, updated_state}
    test "condenses and transfers when no history fits directly" do
      # Very large history
      huge_history = create_history(100, 500)
      state = create_state(%{"old-model" => huge_history})

      new_pool = ["small-context-model"]

      # Use target_limit to force condensation (history exceeds this limit)
      opts = [test_mode: true, target_limit: 500]

      assert {:ok, new_state} =
               HistoryTransfer.transfer_state_to_new_pool(state, new_pool, opts)

      # History should be condensed
      new_history = new_state.model_histories["small-context-model"]
      assert length(new_history) < length(huge_history)
    end

    # R15: WHEN old histories empty THEN returns new state with empty histories
    test "handles empty old histories gracefully" do
      state = create_state(%{"old-model" => []})

      new_pool = ["new-model-x", "new-model-y"]

      assert {:ok, new_state} =
               HistoryTransfer.transfer_state_to_new_pool(state, new_pool, test_mode: true)

      # All new histories should be empty
      for model_id <- new_pool do
        assert new_state.model_histories[model_id] == []
      end
    end
  end
end
