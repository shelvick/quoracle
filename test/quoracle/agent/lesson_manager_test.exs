defmodule Quoracle.Agent.LessonManagerTest do
  @moduledoc """
  Tests for AGENT_LessonManager - lesson accumulation and embedding-based deduplication.
  WorkGroupID: ace-20251207-140000
  Packet: 3 (LessonManager Module)

  Tests R1-R13 from AGENT_LessonManager.md spec:
  - R1: Basic accumulation when no duplicates
  - R2: Duplicate detection via embedding similarity
  - R3: Confidence increment on merge
  - R4: Treats dissimilar lessons as new
  - R5: Configurable similarity threshold
  - R6: Pruning trigger when exceeding max_lessons
  - R7: Prune by confidence (lowest first)
  - R8: Embedding failure for new lesson - add anyway
  - R9: Embedding failure for existing lesson - skip comparison
  - R10: Empty new_lessons returns existing unchanged
  - R11: Injectable embedding function
  - R12: Uses cosine similarity for comparison (integration)
  - R13: Default max_lessons is 100
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.LessonManager
  alias Quoracle.Consensus.Aggregator

  # Helper to create lesson with defaults
  defp lesson(type, content, confidence \\ 1) do
    %{type: type, content: content, confidence: confidence}
  end

  # Mock embedding function that returns predictable vectors
  # Similar content -> similar vectors, different content -> different vectors
  defp mock_embedding_fn(text) do
    case text do
      "API requires bearer auth" ->
        {:ok, %{embedding: [1.0, 0.0, 0.0]}}

      "API needs bearer token" ->
        # Very similar to "API requires bearer auth" - cosine ~0.95
        {:ok, %{embedding: [0.95, 0.05, 0.0]}}

      "User prefers JSON output" ->
        {:ok, %{embedding: [0.0, 1.0, 0.0]}}

      "User likes JSON format" ->
        # Similar to "User prefers JSON output" - cosine ~0.92
        {:ok, %{embedding: [0.05, 0.95, 0.0]}}

      "Database uses PostgreSQL" ->
        {:ok, %{embedding: [0.0, 0.0, 1.0]}}

      "Be concise in responses" ->
        {:ok, %{embedding: [0.5, 0.5, 0.0]}}

      "Stay brief" ->
        # Somewhat similar to "Be concise" [0.5, 0.5, 0] - cosine ~0.85
        # Vector at ~77 degrees vs ~45 degrees = 32 degree difference
        {:ok, %{embedding: [0.22, 0.97, 0.0]}}

      "Completely different topic" ->
        {:ok, %{embedding: [-1.0, 0.0, 0.0]}}

      "lesson_" <> n ->
        # Generate orthogonal vectors using one-hot encoding (200-dim)
        # Each lesson gets 1.0 at its index position, all others 0.0
        # This ensures cosine similarity = 0 between different lessons
        idx = String.to_integer(n)
        embedding = List.duplicate(0.0, 200) |> List.update_at(rem(idx - 1, 200), fn _ -> 1.0 end)
        {:ok, %{embedding: embedding}}

      _ ->
        {:ok, %{embedding: [0.33, 0.33, 0.33]}}
    end
  end

  # Mock embedding function that fails for specific content
  defp failing_embedding_fn(fail_content) do
    fn text ->
      if text == fail_content do
        {:error, :embedding_failed}
      else
        mock_embedding_fn(text)
      end
    end
  end

  describe "R1: Basic Accumulation" do
    test "accumulates new lessons when no duplicates exist" do
      existing = []

      new_lessons = [
        lesson(:factual, "API requires bearer auth"),
        lesson(:behavioral, "Be concise in responses")
      ]

      opts = [embedding_fn: &mock_embedding_fn/1]

      {:ok, result} = LessonManager.accumulate_lessons(existing, new_lessons, opts)

      assert length(result) == 2
      assert Enum.any?(result, &(&1.content == "API requires bearer auth"))
      assert Enum.any?(result, &(&1.content == "Be concise in responses"))
    end

    test "accumulates to existing lessons" do
      existing = [lesson(:factual, "Database uses PostgreSQL")]

      new_lessons = [
        lesson(:factual, "API requires bearer auth")
      ]

      opts = [embedding_fn: &mock_embedding_fn/1]

      {:ok, result} = LessonManager.accumulate_lessons(existing, new_lessons, opts)

      assert length(result) == 2
      assert Enum.any?(result, &(&1.content == "Database uses PostgreSQL"))
      assert Enum.any?(result, &(&1.content == "API requires bearer auth"))
    end
  end

  describe "R2: Duplicate Detection" do
    test "detects duplicate via embedding similarity" do
      existing = [lesson(:factual, "API requires bearer auth")]
      new_lesson = lesson(:factual, "API needs bearer token")

      opts = [embedding_fn: &mock_embedding_fn/1]

      result = LessonManager.deduplicate_lesson(new_lesson, existing, opts)

      # Should merge because similarity > 0.90
      assert {:merged, merged_lesson, _old_content} = result
      # Keep NEW content (latest information)
      assert merged_lesson.content == "API needs bearer token"
    end

    test "treats different lessons as new" do
      existing = [lesson(:factual, "API requires bearer auth")]
      new_lesson = lesson(:factual, "Completely different topic")

      opts = [embedding_fn: &mock_embedding_fn/1]

      result = LessonManager.deduplicate_lesson(new_lesson, existing, opts)

      assert {:new, returned_lesson} = result
      assert returned_lesson.content == "Completely different topic"
    end
  end

  describe "R3: Confidence Increment" do
    test "increments confidence on merge" do
      existing = [lesson(:factual, "API requires bearer auth", 3)]
      new_lesson = lesson(:factual, "API needs bearer token", 1)

      opts = [embedding_fn: &mock_embedding_fn/1]

      {:merged, merged_lesson, _old} =
        LessonManager.deduplicate_lesson(new_lesson, existing, opts)

      # Confidence should be incremented, NEW content kept
      assert merged_lesson.confidence == 4
      assert merged_lesson.content == "API needs bearer token"
    end

    test "increments confidence during accumulation" do
      existing = [lesson(:factual, "User prefers JSON output", 2)]

      new_lessons = [
        lesson(:factual, "User likes JSON format")
      ]

      opts = [embedding_fn: &mock_embedding_fn/1]

      {:ok, result} = LessonManager.accumulate_lessons(existing, new_lessons, opts)

      # Should have merged, not added - NEW content kept
      assert length(result) == 1
      assert hd(result).confidence == 3
      assert hd(result).content == "User likes JSON format"
    end
  end

  describe "R4: Threshold Respect" do
    test "treats dissimilar lessons as new" do
      existing = [lesson(:behavioral, "Be concise in responses")]
      # "Stay brief" has ~0.85 similarity, below 0.90 threshold
      new_lesson = lesson(:behavioral, "Stay brief")

      opts = [embedding_fn: &mock_embedding_fn/1]

      result = LessonManager.deduplicate_lesson(new_lesson, existing, opts)

      # Should be new because 0.85 < 0.90 threshold
      assert {:new, _lesson} = result
    end
  end

  describe "R5: Configurable Threshold" do
    test "uses custom similarity threshold from opts" do
      existing = [lesson(:behavioral, "Be concise in responses")]
      # "Stay brief" has ~0.85 similarity
      new_lesson = lesson(:behavioral, "Stay brief")

      # Lower threshold to 0.80 - should now merge
      opts = [
        embedding_fn: &mock_embedding_fn/1,
        similarity_threshold: 0.80
      ]

      result = LessonManager.deduplicate_lesson(new_lesson, existing, opts)

      # Should merge with lower threshold
      assert {:merged, _lesson, _old} = result
    end

    test "custom threshold in accumulation" do
      existing = [lesson(:behavioral, "Be concise in responses")]
      new_lessons = [lesson(:behavioral, "Stay brief")]

      opts = [
        embedding_fn: &mock_embedding_fn/1,
        similarity_threshold: 0.80
      ]

      {:ok, result} = LessonManager.accumulate_lessons(existing, new_lessons, opts)

      # Should have merged with lower threshold
      assert length(result) == 1
    end
  end

  describe "R6: Pruning Trigger" do
    test "prunes when exceeding max lessons" do
      # Create 5 lessons
      existing =
        Enum.map(1..5, fn i ->
          lesson(:factual, "lesson_#{i}", i)
        end)

      # Add 3 more unique lessons
      new_lessons =
        Enum.map(6..8, fn i ->
          lesson(:factual, "lesson_#{i}", 1)
        end)

      # Set max to 6 - should prune 2
      opts = [
        embedding_fn: &mock_embedding_fn/1,
        max_lessons: 6
      ]

      {:ok, result} = LessonManager.accumulate_lessons(existing, new_lessons, opts)

      assert length(result) == 6
    end
  end

  describe "R7: Prune By Confidence" do
    test "removes lowest confidence lessons when pruning" do
      # Create lessons with varying confidence
      lessons = [
        lesson(:factual, "lesson_1", 1),
        lesson(:factual, "lesson_2", 5),
        lesson(:factual, "lesson_3", 2),
        lesson(:factual, "lesson_4", 10),
        lesson(:factual, "lesson_5", 3)
      ]

      result = LessonManager.prune_lessons(lessons, 3)

      assert length(result) == 3
      # Highest confidence lessons should remain
      confidences = Enum.map(result, & &1.confidence)
      assert 10 in confidences
      assert 5 in confidences
      assert 3 in confidences
      # Lowest should be removed
      refute 1 in confidences
      refute 2 in confidences
    end

    test "preserves order within confidence-sorted result" do
      lessons = [
        lesson(:factual, "low_conf", 1),
        lesson(:factual, "high_conf", 10),
        lesson(:factual, "mid_conf", 5)
      ]

      result = LessonManager.prune_lessons(lessons, 2)

      assert length(result) == 2
      # Only low confidence removed
      refute Enum.any?(result, &(&1.content == "low_conf"))
    end
  end

  describe "R8: Embedding Failure New" do
    test "adds lesson without dedup on embedding failure" do
      existing = [lesson(:factual, "API requires bearer auth")]
      new_lesson = lesson(:factual, "fails_to_embed")

      # Embedding fails for new lesson
      opts = [embedding_fn: failing_embedding_fn("fails_to_embed")]

      result = LessonManager.deduplicate_lesson(new_lesson, existing, opts)

      # Should add as new (no dedup possible)
      assert {:new, returned_lesson} = result
      assert returned_lesson.content == "fails_to_embed"
    end

    test "graceful degradation in accumulation" do
      existing = [lesson(:factual, "API requires bearer auth")]
      new_lessons = [lesson(:factual, "fails_to_embed")]

      opts = [embedding_fn: failing_embedding_fn("fails_to_embed")]

      {:ok, result} = LessonManager.accumulate_lessons(existing, new_lessons, opts)

      # Should have both lessons (new added without dedup)
      assert length(result) == 2
    end
  end

  describe "R9: Embedding Failure Existing" do
    test "skips comparison when existing embedding fails" do
      # Existing lesson will fail to embed
      existing = [
        lesson(:factual, "fails_to_embed"),
        lesson(:factual, "API requires bearer auth")
      ]

      # New lesson similar to "API requires bearer auth"
      new_lesson = lesson(:factual, "API needs bearer token")

      opts = [embedding_fn: failing_embedding_fn("fails_to_embed")]

      result = LessonManager.deduplicate_lesson(new_lesson, existing, opts)

      # Should still detect similarity with working embedding
      assert {:merged, merged_lesson, _old} = result
      # Keep NEW content (latest information)
      assert merged_lesson.content == "API needs bearer token"
    end
  end

  describe "R10: Empty Inputs" do
    test "returns existing when no new lessons" do
      existing = [
        lesson(:factual, "API requires bearer auth"),
        lesson(:behavioral, "Be concise")
      ]

      opts = [embedding_fn: &mock_embedding_fn/1]

      {:ok, result} = LessonManager.accumulate_lessons(existing, [], opts)

      assert result == existing
    end

    test "returns new lessons when existing empty" do
      new_lessons = [
        lesson(:factual, "API requires bearer auth"),
        lesson(:behavioral, "Be concise in responses")
      ]

      opts = [embedding_fn: &mock_embedding_fn/1]

      {:ok, result} = LessonManager.accumulate_lessons([], new_lessons, opts)

      assert length(result) == 2
    end
  end

  describe "R11: Injectable Embedding" do
    test "uses injectable embedding function" do
      # Use process-owned ETS (no named table) for call tracking
      table_name = :"call_tracker_#{System.unique_integer([:positive])}"
      call_tracker = :ets.new(table_name, [:set])
      :ets.insert(call_tracker, {:calls, 0})

      tracking_fn = fn text ->
        [{:calls, count}] = :ets.lookup(call_tracker, :calls)
        :ets.insert(call_tracker, {:calls, count + 1})
        mock_embedding_fn(text)
      end

      existing = [lesson(:factual, "API requires bearer auth")]
      new_lessons = [lesson(:factual, "Completely different topic")]

      opts = [embedding_fn: tracking_fn]

      {:ok, _result} = LessonManager.accumulate_lessons(existing, new_lessons, opts)

      # Verify our custom function was called
      [{:calls, call_count}] = :ets.lookup(call_tracker, :calls)
      assert call_count > 0

      :ets.delete(call_tracker)
    end
  end

  describe "R12: Cosine Similarity" do
    @tag :integration
    test "uses cosine similarity for lesson comparison" do
      # Verify cosine similarity calculation matches expected
      vec1 = [1.0, 0.0, 0.0]
      vec2 = [0.95, 0.05, 0.0]

      similarity = Aggregator.cosine_similarity(vec1, vec2)

      # Should be ~0.95
      assert similarity > 0.90
      assert similarity < 1.0
    end

    @tag :integration
    test "similarity used in deduplicate_lesson" do
      # Track what similarity values are being compared
      existing = [lesson(:factual, "API requires bearer auth")]
      new_lesson = lesson(:factual, "API needs bearer token")

      opts = [embedding_fn: &mock_embedding_fn/1]

      # With vectors [1.0, 0.0, 0.0] and [0.95, 0.05, 0.0]
      # Cosine similarity should be ~0.95, exceeding 0.90 threshold
      {:merged, _, _old} = LessonManager.deduplicate_lesson(new_lesson, existing, opts)
    end
  end

  describe "R13: Max Lessons Default" do
    test "defaults to 100 max lessons" do
      # Create 101 lessons
      lessons = Enum.map(1..101, fn i -> lesson(:factual, "lesson_#{i}", 1) end)

      # No max_lessons option - should use default 100
      result = LessonManager.prune_lessons(lessons, _default = nil)

      # If using default, should prune to 100
      # Note: nil triggers default behavior
      assert length(result) <= 100
    end

    test "accumulation respects default limit" do
      # Start with 99 lessons
      existing = Enum.map(1..99, fn i -> lesson(:factual, "lesson_#{i}", 1) end)

      # Add 5 more unique lessons
      new_lessons = Enum.map(100..104, fn i -> lesson(:factual, "lesson_#{i}", 1) end)

      opts = [embedding_fn: &mock_embedding_fn/1]
      # No max_lessons - should use default 100

      {:ok, result} = LessonManager.accumulate_lessons(existing, new_lessons, opts)

      # Should be pruned to 100
      assert length(result) == 100
    end
  end

  describe "Edge Cases" do
    test "handles single lesson accumulation" do
      existing = []
      new_lessons = [lesson(:factual, "Only lesson")]

      opts = [embedding_fn: &mock_embedding_fn/1]

      {:ok, result} = LessonManager.accumulate_lessons(existing, new_lessons, opts)

      assert length(result) == 1
      assert hd(result).content == "Only lesson"
    end

    test "preserves lesson type during merge" do
      existing = [lesson(:behavioral, "Be concise in responses", 2)]
      new_lessons = [lesson(:behavioral, "Be brief")]

      # Lower threshold to force merge
      opts = [
        embedding_fn: &mock_embedding_fn/1,
        similarity_threshold: 0.70
      ]

      {:ok, result} = LessonManager.accumulate_lessons(existing, new_lessons, opts)

      assert length(result) == 1
      assert hd(result).type == :behavioral
    end

    test "handles multiple merges in single accumulation" do
      existing = [
        lesson(:factual, "API requires bearer auth", 2),
        lesson(:factual, "User prefers JSON output", 3)
      ]

      new_lessons = [
        lesson(:factual, "API needs bearer token"),
        lesson(:factual, "User likes JSON format")
      ]

      opts = [embedding_fn: &mock_embedding_fn/1]

      {:ok, result} = LessonManager.accumulate_lessons(existing, new_lessons, opts)

      # Both should merge, no new lessons added
      assert length(result) == 2

      # Check confidences were incremented, NEW content kept
      api_lesson = Enum.find(result, &(&1.content == "API needs bearer token"))
      json_lesson = Enum.find(result, &(&1.content == "User likes JSON format"))

      assert api_lesson.confidence == 3
      assert json_lesson.confidence == 4
    end
  end

  # === v2.0 Cost Context Tests (fix-costs-20260129) ===

  describe "[INTEGRATION] cost context in default embedding function (R14, R16)" do
    # R14: Cost Context Flows to Default Embedding Function
    test "default embedding function receives cost context from opts" do
      # When accumulate_lessons is called with cost context in opts and NO
      # custom embedding_fn, the default embedding function should pass
      # cost context to Embeddings.get_embedding/2 (the 2-arity version).
      #
      # After implementation, default_embedding_fn becomes a closure that
      # captures cost context from opts and calls get_embedding(text, cost_opts).
      #
      # We verify by providing a capturing_fn that expects 2 args (text + opts).
      # Current implementation uses default_embedding_fn/1 which ignores cost
      # context, so this test will fail until the implementation is updated.
      test_pid = self()

      # Embedding function that expects cost context as second argument
      capturing_fn = fn text, cost_opts ->
        send(test_pid, {:embedding_called, text, cost_opts})
        {:ok, %{embedding: [1.0, 0.0, 0.0]}}
      end

      existing = [lesson(:factual, "Existing lesson", 1)]
      new_lessons = [lesson(:factual, "New lesson", 1)]

      # Pass cost context AND the 2-arity capturing fn
      opts = [
        embedding_fn: capturing_fn,
        agent_id: "test-agent",
        task_id: 123,
        pubsub: :test_pubsub
      ]

      {:ok, _result} = LessonManager.accumulate_lessons(existing, new_lessons, opts)

      # Verify embedding function was called WITH cost context
      assert_receive {:embedding_called, _text, cost_opts}
      assert Keyword.get(cost_opts, :agent_id) == "test-agent"
    end

    # R16: No Cost Context Still Works
    test "works without cost context in opts" do
      # accumulate_lessons with no cost context and a custom embedding_fn
      # should work without error
      capturing_fn = fn _text ->
        {:ok, %{embedding: [1.0, 0.0, 0.0]}}
      end

      existing = []
      new_lessons = [lesson(:factual, "A new fact", 1)]

      # No cost context keys at all — just embedding_fn
      opts = [embedding_fn: capturing_fn]

      {:ok, result} = LessonManager.accumulate_lessons(existing, new_lessons, opts)
      assert length(result) == 1
    end
  end
end
