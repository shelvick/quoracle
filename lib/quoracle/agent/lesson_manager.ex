defmodule Quoracle.Agent.LessonManager do
  @moduledoc """
  Lesson Manager for ACE (Agentic Context Engineering).

  Manages lesson accumulation and embedding-based deduplication. When new lessons
  arrive from Reflector, compares against existing lessons using cosine similarity.
  Similar lessons (threshold 0.90) are merged with confidence incremented.
  Handles pruning when lesson count exceeds limit (100 per model).
  """

  alias Quoracle.Consensus.Aggregator
  alias Quoracle.Models.Embeddings

  @default_similarity_threshold 0.90
  @default_max_lessons 100

  @type lesson :: %{
          type: :factual | :behavioral,
          content: String.t(),
          confidence: pos_integer()
        }

  @doc """
  Accumulates new lessons into existing list with deduplication.

  Similar lessons (cosine similarity >= threshold) are merged with confidence
  incremented. New lessons are added with confidence: 1. Result is pruned if
  exceeding max_lessons.

  ## Options

  - `:similarity_threshold` - Override threshold (default: 0.90)
  - `:max_lessons` - Override limit (default: 100)
  - `:embedding_fn` - Injectable embedding function for tests

  ## Examples

      iex> existing = [%{type: :factual, content: "API uses REST", confidence: 2}]
      iex> new_lessons = [%{type: :factual, content: "API is RESTful", confidence: 1}]
      iex> LessonManager.accumulate_lessons(existing, new_lessons, [])
      {:ok, [%{type: :factual, content: "API is RESTful", confidence: 3}]}
  """
  @spec accumulate_lessons(
          existing :: [lesson()],
          new_lessons :: [lesson()],
          opts :: keyword()
        ) :: {:ok, [lesson()]}
  def accumulate_lessons(existing, [], _opts), do: {:ok, existing}

  def accumulate_lessons(existing, new_lessons, opts) do
    max_lessons = Keyword.get(opts, :max_lessons, @default_max_lessons)

    # Accumulate each new lesson, deduplicating against accumulated list
    # Track new lessons separately for O(n) performance (prepend + reverse)
    {updated_existing, new_lessons_acc} =
      Enum.reduce(new_lessons, {existing, []}, fn new_lesson, {acc, new_acc} ->
        case deduplicate_lesson(new_lesson, acc, opts) do
          {:merged, merged_lesson, old_content} ->
            # Replace the old lesson (matched by old_content) with merged version
            {replace_lesson_by_content(acc, old_content, merged_lesson), new_acc}

          {:new, lesson} ->
            # Prepend to new_acc (will reverse at end)
            {acc, [lesson | new_acc]}
        end
      end)

    # Combine: existing (with merges) + new lessons (reversed for correct order)
    accumulated = updated_existing ++ Enum.reverse(new_lessons_acc)

    # Prune if over limit
    final = prune_lessons(accumulated, max_lessons)

    {:ok, final}
  end

  @doc """
  Checks if a lesson is a duplicate of any existing lesson.

  Returns `{:merged, lesson}` if similar (confidence incremented) or
  `{:new, lesson}` if no match found.

  ## Options

  - `:similarity_threshold` - Override threshold (default: 0.90)
  - `:embedding_fn` - Injectable embedding function for tests
  """
  @spec deduplicate_lesson(
          lesson :: lesson(),
          existing :: [lesson()],
          opts :: keyword()
        ) :: {:merged, lesson(), String.t()} | {:new, lesson()}
  def deduplicate_lesson(lesson, [], _opts), do: {:new, lesson}

  def deduplicate_lesson(lesson, existing, opts) do
    threshold = Keyword.get(opts, :similarity_threshold, @default_similarity_threshold)
    raw_embedding_fn = Keyword.get(opts, :embedding_fn)
    cost_opts = Keyword.take(opts, [:agent_id, :task_id, :pubsub])

    # Normalize embedding_fn to always be 1-arity internally.
    # If user provides a 2-arity fn, wrap it with cost_opts.
    # If no fn provided, use default with cost context.
    embedding_fn =
      cond do
        is_function(raw_embedding_fn, 2) ->
          fn text -> raw_embedding_fn.(text, cost_opts) end

        is_function(raw_embedding_fn, 1) ->
          raw_embedding_fn

        true ->
          fn text -> default_embedding_fn(text, cost_opts) end
      end

    # Get embedding for new lesson
    case embedding_fn.(lesson.content) do
      {:ok, %{embedding: new_embedding}} ->
        find_similar_lesson(lesson, new_embedding, existing, threshold, embedding_fn)

      {:error, _reason} ->
        # Embedding failed for new lesson - add without dedup (graceful degradation)
        {:new, lesson}
    end
  end

  @doc """
  Prunes lessons to max_count, removing lowest confidence first.

  ## Examples

      iex> lessons = [%{confidence: 1}, %{confidence: 5}, %{confidence: 2}]
      iex> LessonManager.prune_lessons(lessons, 2)
      [%{confidence: 5}, %{confidence: 2}]
  """
  @spec prune_lessons(lessons :: [lesson()], max_count :: pos_integer() | nil) :: [lesson()]
  def prune_lessons(lessons, nil), do: prune_lessons(lessons, @default_max_lessons)

  def prune_lessons(lessons, max_count) when length(lessons) <= max_count do
    lessons
  end

  def prune_lessons(lessons, max_count) do
    # Sort by confidence descending, keep top max_count
    lessons
    |> Enum.sort_by(& &1.confidence, :desc)
    |> Enum.take(max_count)
  end

  # Find a similar lesson in the existing list
  defp find_similar_lesson(new_lesson, new_embedding, existing, threshold, embedding_fn) do
    # Check each existing lesson for similarity
    result =
      Enum.reduce_while(existing, nil, fn existing_lesson, _acc ->
        case embedding_fn.(existing_lesson.content) do
          {:ok, %{embedding: existing_embedding}} ->
            similarity = Aggregator.cosine_similarity(new_embedding, existing_embedding)

            if similarity >= threshold do
              # Found a match - keep NEW content with incremented confidence
              merged = %{new_lesson | confidence: existing_lesson.confidence + 1}
              {:halt, {:merged, merged, existing_lesson.content}}
            else
              {:cont, nil}
            end

          {:error, _reason} ->
            # Embedding failed for existing lesson - skip this comparison
            {:cont, nil}
        end
      end)

    result || {:new, new_lesson}
  end

  # Replace lesson matching old_content with new_lesson
  defp replace_lesson_by_content(lessons, old_content, new_lesson) do
    Enum.map(lessons, fn lesson ->
      if lesson.content == old_content do
        new_lesson
      else
        lesson
      end
    end)
  end

  # Default embedding function using MODEL_Embeddings, with cost context
  defp default_embedding_fn(text, cost_opts) do
    Embeddings.get_embedding(text, Map.new(cost_opts))
  end
end
