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

  @doc "Condenses model history with ACE reflection. Removes >80% tokens, oldest first."
  @spec condense_model_history_with_reflection(map(), String.t(), keyword()) :: map()
  def condense_model_history_with_reflection(state, model_id, opts) do
    history = Map.get(state.model_histories, model_id, [])

    # Token-based condensation: remove >80% of tokens, oldest first
    total_tokens = TokenManager.estimate_history_tokens(history)
    {to_discard, to_keep} = TokenManager.tokens_to_condense(history, total_tokens)

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
    reflector_fn = Keyword.get(opts, :reflector_fn, &Helpers.default_reflector/3)
    messages_for_reflection = Helpers.format_messages_for_reflection(to_discard)

    state =
      case reflector_fn.(messages_for_reflection, model_id, opts) do
        {:ok, %{lessons: lessons, state: new_state_entries}} ->
          existing_lessons = get_in(state, [:context_lessons, model_id]) || []

          # Use test embedding if in test mode without explicit embedding_fn
          lesson_opts =
            if Keyword.get(opts, :test_mode, false) && !Keyword.has_key?(opts, :embedding_fn) do
              Keyword.put(opts, :embedding_fn, &Helpers.test_embedding_fn/1)
            else
              opts
            end

          {:ok, accumulated_lessons} =
            LessonManager.accumulate_lessons(existing_lessons, lessons, lesson_opts)

          # Update model state (replaces previous, takes first entry)
          model_state =
            case new_state_entries do
              [entry | _] -> entry
              [] -> Map.get(state.model_states, model_id)
            end

          state
          |> put_in([:context_lessons, model_id], accumulated_lessons)
          |> put_in([:model_states, model_id], model_state)

        {:error, reason} ->
          # Graceful degradation - continue without lessons/state update
          Logger.warning(
            "Reflector failed for model #{model_id}: #{inspect(reason)} - no ACE lessons accumulated"
          )

          state
      end

    # Update history with kept messages only
    updated_histories = Map.put(state.model_histories, model_id, to_keep)
    final_state = %{state | model_histories: updated_histories}

    # Persist ACE state after condensation
    Persistence.persist_ace_state(final_state)

    final_state
  end
end
