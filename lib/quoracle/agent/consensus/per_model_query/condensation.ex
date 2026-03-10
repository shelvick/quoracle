defmodule Quoracle.Agent.Consensus.PerModelQuery.Condensation do
  @moduledoc """
  Condensation logic for per-model history management.
  Extracted from PerModelQuery for <500 line module limit.

  Handles:
  - Inline condensation triggered by model's `condense` parameter
  - Token-based condensation for context overflow
  - ACE reflection during condensation (lesson extraction)
  """

  alias Quoracle.Agent.{TokenManager, LessonManager}
  alias Quoracle.Agent.Core.Persistence
  alias Quoracle.Agent.Consensus.PerModelQuery.Helpers
  alias Quoracle.Consensus.ActionParser
  alias Quoracle.Models.{ConfigModelSettings, ModelQuery}

  require Logger

  @doc """
  Hook for inline condensation triggered by model's condense parameter.
  Called after receiving a model response, before consensus aggregation.

  Extracts condense value from raw response and triggers condensation if valid.
  Returns original state unchanged if no valid condense value.

  ## Parameters

  - `state` - Current agent state with model_histories
  - `model_id` - The model that made the condense request
  - `raw_response` - Raw JSON map from LLM (before parsing)
  - `opts` - Options passed to condensation (reflector_fn, test_mode, etc.)

  ## Returns

  Updated state with condensed history, or original state if no condensation needed.
  """
  @spec maybe_inline_condense(map(), String.t(), map(), keyword()) :: map()
  def maybe_inline_condense(state, model_id, raw_response, opts) do
    case ActionParser.extract_condense(raw_response) do
      nil ->
        state

      n when is_integer(n) and n > 0 ->
        condense_n_oldest_messages(state, model_id, n, opts)
    end
  end

  @doc """
  Condenses N oldest messages from a model's history.
  Uses TokenManager.messages_to_condense/2 for splitting, then runs Reflector.

  ## Validation

  - N is clamped to max allowed (history_length - 2)
  - If history has ≤2 messages, condensation is skipped
  - Logs info/warning for edge cases

  ## Parameters

  - `state` - Current agent state with model_histories
  - `model_id` - The model whose history to condense
  - `n` - Number of oldest messages to condense
  - `opts` - Options (reflector_fn, test_mode, etc.)

  ## Returns

  Updated state with condensed history and accumulated lessons.
  """
  @spec condense_n_oldest_messages(map(), String.t(), pos_integer(), keyword()) :: map()
  def condense_n_oldest_messages(state, model_id, n, opts) do
    history = Map.get(state.model_histories, model_id, [])
    history_length = length(history)

    # Must keep at least 2 messages: last assistant (candidate) + last user (prompt/refinement context)
    # These form the working pair for consensus refinement and must never be condensed
    max_n = max(history_length - 2, 0)

    cond do
      history_length <= 2 ->
        Logger.info("Inline condense skipped: history too short (#{history_length} messages)")
        state

      n > max_n ->
        Logger.warning(
          "Condense N=#{n} exceeds max=#{max_n} for history length #{history_length}, clamping"
        )

        do_condense_n_messages(state, model_id, max_n, history, opts)

      true ->
        do_condense_n_messages(state, model_id, n, history, opts)
    end
  end

  # Actually performs the N-message condensation
  defp do_condense_n_messages(state, model_id, n, history, opts) do
    {to_discard, to_keep} = TokenManager.messages_to_condense(history, n)
    apply_reflection_and_finalize(state, model_id, to_discard, to_keep, opts)
  end

  @doc "Condenses model history with ACE reflection. Removes >80% of context window worth of tokens, oldest first."
  @spec condense_model_history_with_reflection(map(), String.t(), keyword()) :: map()
  def condense_model_history_with_reflection(state, model_id, opts) do
    history = Map.get(state.model_histories, model_id, [])

    # Token-based condensation: remove >80% of tokens, oldest first.
    # Capped at context_limit so to_discard never exceeds the model's context window
    # (critical because the same model does self-reflection on discarded messages).
    total_tokens = TokenManager.estimate_history_tokens(history)
    context_limit = TokenManager.get_model_context_limit(model_id)

    {to_discard, to_keep} =
      TokenManager.tokens_to_condense(history, min(total_tokens, context_limit))

    apply_reflection_and_finalize(state, model_id, to_discard, to_keep, opts)
  end

  @doc """
  Checks if a model needs condensation and condenses if over threshold.
  Uses TokenManager.should_condense_for_model?/2 to check limit.

  ## Options

  - `:force_condense` - Force condensation regardless of token count (for tests)
  """
  @spec maybe_condense_for_model(map(), String.t(), keyword()) :: map()
  def maybe_condense_for_model(state, model_id, opts) do
    should_condense =
      Keyword.get(opts, :force_condense, false) ||
        TokenManager.should_condense_for_model?(state, model_id)

    if should_condense do
      condense_model_history_with_reflection(state, model_id, opts)
    else
      state
    end
  end

  # Shared helper: Calls Reflector, accumulates lessons, updates state, persists.
  # Used by both message-count condensation (inline condense) and token-count condensation (overflow).
  @doc false
  @spec apply_reflection_and_finalize(map(), String.t(), list(map()), list(map()), keyword()) ::
          map()
  def apply_reflection_and_finalize(state, model_id, to_discard, to_keep, opts) do
    opts = merge_condensation_opts(state, opts)
    discard_tokens = TokenManager.estimate_history_tokens(to_discard)
    keep_tokens = TokenManager.estimate_history_tokens(to_keep)

    Logger.debug(
      "Condensation: model=#{model_id}, " <>
        "discard=#{length(to_discard)} msgs (#{discard_tokens} tokens), " <>
        "keep=#{length(to_keep)} msgs (#{keep_tokens} tokens)"
    )

    reflector_fn = Keyword.get(opts, :reflector_fn, &Helpers.default_reflector/3)

    state =
      to_discard
      |> create_reflection_batches(model_id, opts)
      |> batch_reflect_and_accumulate(state, model_id, reflector_fn, opts)

    # Update history with kept messages only
    updated_histories = Map.put(state.model_histories, model_id, to_keep)
    final_state = %{state | model_histories: updated_histories}

    # Persist ACE state after all reflection batches complete.
    persist_fn = Keyword.get(opts, :persist_fn, &Persistence.persist_ace_state/1)
    persist_fn.(final_state)

    final_state
  end

  defp create_reflection_batches([], _model_id, _opts), do: []

  defp create_reflection_batches(to_discard, model_id, opts) do
    budget = get_reflection_budget(model_id, opts)
    messages = Helpers.format_messages_for_reflection(to_discard)

    # Accumulate batches and current batch in reverse (prepend), reverse at end
    {rev_batches, rev_current, _current_tokens} =
      Enum.reduce(messages, {[], [], 0}, fn message, {acc_batches, acc_current, acc_tokens} ->
        message_tokens = TokenManager.estimate_tokens(message.content)

        cond do
          acc_current == [] ->
            {acc_batches, [message], message_tokens}

          acc_tokens + message_tokens <= budget ->
            {acc_batches, [message | acc_current], acc_tokens + message_tokens}

          true ->
            {[Enum.reverse(acc_current) | acc_batches], [message], message_tokens}
        end
      end)

    final_batches =
      if rev_current == [] do
        rev_batches
      else
        [Enum.reverse(rev_current) | rev_batches]
      end

    Enum.reverse(final_batches)
  end

  defp batch_reflect_and_accumulate(batches, state, model_id, reflector_fn, opts) do
    Enum.reduce(batches, state, fn batch, acc_state ->
      {:ok, %{lessons: lessons, state: new_state_entries}} =
        maybe_reflect_batch(batch, model_id, reflector_fn, opts)

      apply_batch_result(acc_state, model_id, lessons, new_state_entries, opts)
    end)
  end

  defp maybe_reflect_batch(batch, model_id, reflector_fn, opts) do
    case maybe_pre_summarize_entry(batch, model_id, opts) do
      {:ok, reflected_batch} ->
        case reflector_fn.(reflected_batch, model_id, opts) do
          {:ok, result} ->
            {:ok, result}

          {:error, reason} ->
            Logger.warning(
              "Reflector failed for batch on model #{model_id}: #{inspect(reason)} - creating fallback artifact"
            )

            {:ok, create_fallback_artifact(batch)}
        end

      {:error, reason} ->
        Logger.warning(
          "Pre-summarization failed for model #{model_id}: #{inspect(reason)} - creating fallback artifact"
        )

        {:ok, create_fallback_artifact(batch)}
    end
  end

  defp maybe_pre_summarize_entry(formatted_messages, model_id, opts) do
    budget = get_reflection_budget(model_id, opts)

    case formatted_messages do
      [single_entry] ->
        entry_tokens = TokenManager.estimate_tokens(single_entry.content)

        if entry_tokens <= budget do
          {:ok, formatted_messages}
        else
          resolve_summarization(formatted_messages, budget, opts)
        end

      _ ->
        {:ok, formatted_messages}
    end
  end

  # Resolves which summarization path to take:
  # - Injected summarization_model via opts: use it (test isolation, no global state)
  # - Configured model from DB: use it (production path)
  # - Neither: cannot summarize, return error
  defp resolve_summarization(messages, budget, opts) do
    summarize_fn = Keyword.get(opts, :summarize_fn, &default_summarize/3)

    case Keyword.fetch(opts, :summarization_model) do
      {:ok, model} ->
        recursive_summarize(messages, budget, model, summarize_fn, opts, 0)

      :error ->
        case ConfigModelSettings.get_summarization_model() do
          {:ok, model} ->
            recursive_summarize(messages, budget, model, summarize_fn, opts, 0)

          {:error, _reason} ->
            {:error, :summarization_not_available}
        end
    end
  end

  defp recursive_summarize(messages, budget, summarize_model, summarize_fn, opts, depth) do
    max_depth = Keyword.get(opts, :max_summarize_depth, 5)

    if depth >= max_depth do
      {:error, :summarization_depth_exceeded}
    else
      text = format_as_text(messages)
      chunks = split_at_semantic_boundaries(text, budget)

      with {:ok, summaries} <- summarize_chunks(chunks, summarize_model, summarize_fn, opts) do
        combined = Enum.join(summaries, "\n\n")

        if TokenManager.estimate_tokens(combined) <= budget do
          {:ok, [%{role: "user", content: combined}]}
        else
          recursive_summarize(
            [%{role: "user", content: combined}],
            budget,
            summarize_model,
            summarize_fn,
            opts,
            depth + 1
          )
        end
      end
    end
  end

  defp summarize_chunks(chunks, summarize_model, summarize_fn, opts) do
    result =
      Enum.reduce_while(chunks, {:ok, []}, fn chunk, {:ok, rev_acc} ->
        case summarize_fn.(chunk, summarize_model, opts) do
          {:ok, summary} when is_binary(summary) ->
            {:cont, {:ok, [summary | rev_acc]}}

          {:ok, summary} ->
            {:cont, {:ok, [to_string(summary) | rev_acc]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, rev_summaries} -> {:ok, Enum.reverse(rev_summaries)}
      error -> error
    end
  end

  # Split text at semantic boundaries, trying progressively finer granularity:
  # paragraphs → lines → sentences → token boundaries (last resort)
  @semantic_delimiters ["\n\n", "\n", ". "]

  defp split_at_semantic_boundaries(text, budget) when is_binary(text) do
    Enum.find_value(@semantic_delimiters, fn delimiter ->
      chunks = split_with_delimiter(text, delimiter, budget)
      if length(chunks) > 1, do: chunks
    end) || split_at_token_boundaries(text, budget)
  end

  defp split_with_delimiter(text, delimiter, budget) do
    parts = String.split(text, delimiter, trim: true)

    if length(parts) <= 1 do
      [text]
    else
      {rev_chunks, current} =
        Enum.reduce(parts, {[], ""}, fn part, {acc_chunks, acc_current} ->
          candidate =
            if acc_current == "" do
              part
            else
              acc_current <> delimiter <> part
            end

          if acc_current != "" and TokenManager.estimate_tokens(candidate) > budget do
            {[acc_current | acc_chunks], part}
          else
            {acc_chunks, candidate}
          end
        end)

      rev_chunks
      |> then(fn chunks -> if current == "", do: chunks, else: [current | chunks] end)
      |> Enum.reverse()
    end
  end

  # Last-resort splitter for oversized single chunks: token-bounded word windows.
  defp split_at_token_boundaries(text, budget) when is_binary(text) do
    words = String.split(text, ~r/\s+/, trim: true)

    if words == [] do
      [text]
    else
      {rev_chunks, rev_current_words} =
        Enum.reduce(words, {[], []}, fn word, {acc_chunks, acc_current} ->
          # acc_current is reversed; build candidate by reversing + appending
          candidate_words = Enum.reverse([word | acc_current])
          candidate = Enum.join(candidate_words, " ")

          if acc_current != [] and TokenManager.estimate_tokens(candidate) > budget do
            {[Enum.join(Enum.reverse(acc_current), " ") | acc_chunks], [word]}
          else
            {acc_chunks, [word | acc_current]}
          end
        end)

      rev_chunks =
        if rev_current_words == [] do
          rev_chunks
        else
          [Enum.join(Enum.reverse(rev_current_words), " ") | rev_chunks]
        end

      case Enum.reverse(rev_chunks) do
        [] -> [text]
        chunks -> chunks
      end
    end
  end

  defp default_summarize(text, summarize_model, opts) do
    messages = [
      %{
        role: "system",
        content:
          "Summarize the following content concisely, preserving factual information, key decisions, and important context."
      },
      %{role: "user", content: text}
    ]

    query_opts =
      %{skip_json_mode: true}
      |> maybe_put(:sandbox_owner, Keyword.get(opts, :sandbox_owner))
      |> maybe_put(:agent_id, Keyword.get(opts, :agent_id))
      |> maybe_put(:task_id, Keyword.get(opts, :task_id))
      |> maybe_put(:pubsub, Keyword.get(opts, :pubsub))
      |> maybe_put(:plug, Keyword.get(opts, :plug))

    case ModelQuery.query_models(messages, [summarize_model], query_opts) do
      {:ok, %{successful_responses: [response | _]}} ->
        {:ok, extract_summary_text(response)}

      {:ok, %{successful_responses: [], failed_models: [{_model, reason} | _]}} ->
        {:error, reason}

      {:ok, %{successful_responses: []}} ->
        {:error, :no_summary_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_summary_text(%ReqLLM.Response{} = response), do: ReqLLM.Response.text(response)
  defp extract_summary_text(%{content: content}) when is_binary(content), do: content
  defp extract_summary_text(summary), do: to_string(summary)

  defp create_fallback_artifact(formatted_messages) do
    content = format_as_text(formatted_messages)
    token_count = TokenManager.estimate_tokens(content)
    truncated = String.slice(content, 0, 500)

    %{
      lessons: [
        %{
          type: :factual,
          content: "Unreflected content discarded (#{token_count} tokens): #{truncated}...",
          confidence: 0
        }
      ],
      state: []
    }
  end

  defp apply_batch_result(state, model_id, lessons, new_state_entries, opts) do
    existing_lessons = get_in(state, [:context_lessons, model_id]) || []

    lesson_opts =
      if Keyword.get(opts, :test_mode, false) && !Keyword.has_key?(opts, :embedding_fn) do
        Keyword.put(opts, :embedding_fn, &Helpers.test_embedding_fn/1)
      else
        opts
      end

    {:ok, accumulated_lessons} =
      LessonManager.accumulate_lessons(existing_lessons, lessons, lesson_opts)

    model_state =
      case new_state_entries do
        [entry | _] -> entry
        [] -> Map.get(state.model_states, model_id)
      end

    state
    |> put_in([:context_lessons, model_id], accumulated_lessons)
    |> put_in([:model_states, model_id], model_state)
  end

  defp get_reflection_budget(model_id, opts) do
    max(Keyword.get(opts, :max_batch_tokens, TokenManager.get_model_context_limit(model_id)), 1)
  end

  # Merge state-level test hooks into opts while preserving explicit caller overrides.
  defp merge_condensation_opts(state, opts) do
    state |> Map.get(:test_opts, []) |> List.wrap() |> Keyword.merge(opts)
  end

  defp format_as_text(messages) do
    Enum.map_join(messages, "\n\n", &Map.get(&1, :content, ""))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
