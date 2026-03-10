defmodule Quoracle.Agent.Consensus.PerModelQuery do
  @moduledoc """
  Per-model query functions for consensus.
  Each model is queried with its own conversation history and can condense independently.
  Extracted from AGENT_Consensus to maintain <500 line modules.
  """

  alias Quoracle.Agent.{ContextManager, TokenManager}
  alias Quoracle.Agent.Consensus.MessageBuilder
  alias Quoracle.Agent.Consensus.PerModelQuery.{Condensation, Helpers, StateMerge}
  alias Quoracle.Agent.Core.Persistence
  alias Quoracle.Consensus.{ActionParser, Aggregator, Result, Temperature}
  alias Quoracle.Utils.JsonExtractor

  require Logger

  # Minimum output budget before forcing proactive condensation
  @output_floor 4096

  # Safety margin for token estimation variance across tokenizers.
  # cl100k_base undercounts for non-GPT models by up to ~9% (observed 8.7% for GLM-5).
  # Per-message overhead (~4 tokens/msg for role markers) adds ~1-2% unaccounted.
  # Combined with LLMDB context window inaccuracies (up to ~1%), 12% absorbs all three.
  @token_safety_margin 0.12

  # Delegate helper functions
  defdelegate context_length_error?(error), to: Helpers

  # Delegate condensation functions (extracted for <500 line limit)
  defdelegate maybe_inline_condense(state, model_id, raw_response, opts), to: Condensation
  defdelegate condense_n_oldest_messages(state, model_id, n, opts), to: Condensation
  defdelegate condense_model_history_with_reflection(state, model_id, opts), to: Condensation
  defdelegate maybe_condense_for_model(state, model_id, opts), to: Condensation

  @doc """
  Queries a single model with retry on context_length_exceeded error.
  Condenses history and retries once on overflow. Returns error if retry fails.

  Returns `{:ok, response, updated_state}` or `{:error, reason, state}`.
  The state is returned to propagate any condensation that occurred during retry.
  """
  @spec query_single_model_with_retry(map(), String.t(), keyword()) ::
          {:ok, any(), map()} | {:error, atom(), map()}
  def query_single_model_with_retry(state, model_id, opts) do
    cond do
      opts[:simulate_persistent_overflow] ->
        {:error, :context_length_exceeded, state}

      opts[:simulate_context_overflow] ->
        {:ok, %{model: model_id, content: "Mock response after retry"}, state}

      true ->
        query_model_with_retry_logic(state, model_id, opts)
    end
  end

  defp query_model_with_retry_logic(state, model_id, opts) do
    lightweight? = Helpers.lightweight_test_query?(opts)

    # Skip token counting in message builder for lightweight mode
    build_opts =
      if lightweight?, do: Keyword.put(opts, :skip_context_tokens, true), else: opts

    # Use unified message-building helper (R65-R70)
    messages_with_system = build_query_messages(state, model_id, build_opts)

    # In lightweight mode, skip proactive condensation + dynamic max_tokens
    # (eliminates tiktoken BPE encoding + LLMDB scans per model per round)
    {messages_with_system, state, dynamic_max_tokens} =
      if lightweight? do
        {messages_with_system, state, @output_floor}
      else
        {condensed_msgs, condensed_state} =
          maybe_proactive_condense(messages_with_system, state, model_id, opts)

        {condensed_msgs, condensed_state, calculate_max_tokens(condensed_msgs, model_id)}
      end

    query_opts = build_query_options(model_id, Keyword.put(opts, :max_tokens, dynamic_max_tokens))

    # Support injectable model_query_fn for testing.
    # In test mode without an injected query function, use deterministic mock responses
    # instead of hitting external providers.
    query_fn = Helpers.resolve_query_fn(opts)

    case query_fn.(messages_with_system, [model_id], query_opts) do
      {:ok, %{successful_responses: [response | _]}} ->
        # R80: Check for condense parameter in raw response and trigger inline condensation
        raw_map = extract_raw_response_map(response)
        updated_state = maybe_inline_condense(state, model_id, raw_map, opts)
        {:ok, response, updated_state}

      {:ok, %{successful_responses: [], failed_models: [{_model, reason} | _]}} ->
        # Check if this is a context length error (handles both atom and struct formats)
        if context_length_error?(reason) do
          # Context overflow - condense and retry once
          condensed_state = condense_model_history_with_reflection(state, model_id, opts)

          # Use same message-building helper for retry (R65-R70)
          retry_messages = build_query_messages(condensed_state, model_id, opts)

          # Recalculate dynamic max_tokens for retry with condensed messages
          retry_max_tokens = calculate_max_tokens(retry_messages, model_id)

          retry_query_opts =
            build_query_options(model_id, Keyword.put(opts, :max_tokens, retry_max_tokens))

          case query_fn.(retry_messages, [model_id], retry_query_opts) do
            {:ok, %{successful_responses: [response | _]}} ->
              # R80: Also check condense on retry path
              raw_map = extract_raw_response_map(response)
              updated_state = maybe_inline_condense(condensed_state, model_id, raw_map, opts)
              {:ok, response, updated_state}

            {:ok, %{successful_responses: []}} ->
              {:error, :context_length_exceeded, condensed_state}

            {:error, retry_reason} ->
              {:error, retry_reason, condensed_state}
          end
        else
          {:error, reason, state}
        end

      {:ok, %{successful_responses: []}} ->
        {:error, :no_response, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Calculates dynamic max_tokens based on available context space.
  # Formula: max_tokens = min(context_window - buffered_input, output_limit)
  # Applies @token_safety_margin to estimated input tokens to absorb tokenizer variance.
  @spec calculate_max_tokens(list(map()), String.t()) :: pos_integer()
  defp calculate_max_tokens(messages, model_id) do
    context_window = TokenManager.get_model_context_limit(model_id)
    input_tokens = TokenManager.estimate_all_messages_tokens(messages)
    output_limit = TokenManager.get_model_output_limit(model_id)

    buffered_input = ceil(input_tokens * (1 + @token_safety_margin))
    available_output = max(context_window - buffered_input, 1)
    min(available_output, output_limit)
  end

  # Proactive condensation: if available output space is below @output_floor,
  # condense history before querying to free up context space.
  @spec maybe_proactive_condense(list(map()), map(), String.t(), keyword()) ::
          {list(map()), map()}
  defp maybe_proactive_condense(messages, state, model_id, opts) do
    context_window = TokenManager.get_model_context_limit(model_id)
    available_output = available_output_budget(messages, context_window)

    if available_output < @output_floor do
      condense_until_floor_or_stable(messages, state, model_id, opts, context_window)
    else
      {messages, state}
    end
  end

  defp condense_until_floor_or_stable(_messages, state, model_id, opts, context_window) do
    condensed_state = condense_model_history_with_reflection(state, model_id, opts)
    rebuilt_messages = build_query_messages(condensed_state, model_id, opts)
    post_available = available_output_budget(rebuilt_messages, context_window)

    if post_available >= @output_floor do
      {rebuilt_messages, condensed_state}
    else
      old_len = state.model_histories |> Map.get(model_id, []) |> length()
      new_len = condensed_state.model_histories |> Map.get(model_id, []) |> length()

      if new_len < old_len do
        condense_until_floor_or_stable(
          rebuilt_messages,
          condensed_state,
          model_id,
          opts,
          context_window
        )
      else
        Logger.warning(
          "Dynamic max_tokens: available output #{post_available} still below " <>
            "floor #{@output_floor} after condensation for model #{model_id}"
        )

        {rebuilt_messages, condensed_state}
      end
    end
  end

  defp available_output_budget(messages, context_window) do
    input_tokens = TokenManager.estimate_all_messages_tokens(messages)
    buffered_input = ceil(input_tokens * (1 + @token_safety_margin))
    context_window - buffered_input
  end

  @doc """
  Builds query messages with all injectors applied.
  Delegates to MessageBuilder for single source of truth.

  v16.0: Consolidated into MessageBuilder module to eliminate duplication
  with ConsensusHandler UI message building path.
  """
  @spec build_query_messages(map(), String.t(), keyword()) :: list(map())
  def build_query_messages(state, model_id, opts) do
    MessageBuilder.build_messages_for_model(state, model_id, opts)
  end

  @doc """
  Queries each model in the pool with its own history.
  Returns list of results from all models plus the updated state.

  ## Returns

  - `{:ok, responses, updated_state}` - Success with responses and state after any condensation
  - `{:error, reason}` - Error (no state returned on error path)
  """
  @spec query_models_with_per_model_histories(map(), list(String.t()), keyword()) ::
          {:ok, list(), map()} | {:error, atom()}
  def query_models_with_per_model_histories(state, model_pool, opts) do
    # In test mode, preserve test-specific hooks and limits from state as a defensive fallback.
    # This prevents option loss when callers construct consensus opts manually.
    opts = Helpers.merge_state_test_opts(state, opts)

    # Use production path when model_query_fn is provided (allows test message capture)
    has_custom_query_fn = Keyword.has_key?(opts, :model_query_fn)

    if Helpers.test_mode?(opts) && !has_custom_query_fn &&
         !Keyword.get(opts, :force_token_management, false) do
      # Check for simulate_failure flag first
      # When simulate_failure is an atom (e.g., :all_responses_invalid),
      # return that specific error. When it's `true`, default to :all_models_failed.
      case Keyword.get(opts, :simulate_failure, false) do
        false ->
          # In test mode, return mock results with proper JSON format
          # Thread state through condensation for each model
          {results, final_state} =
            Enum.map_reduce(model_pool, state, fn model_id, acc_state ->
              # Check condensation first (updates state if needed)
              updated_state = maybe_condense_for_model(acc_state, model_id, opts)

              # Build messages from this model's history (still exercised in test mode)
              _messages = ContextManager.build_conversation_messages(updated_state, model_id)

              {Helpers.mock_successful_response(model_id), updated_state}
            end)

          {:ok, results, final_state}

        true ->
          {:error, :all_models_failed}

        error_atom when is_atom(error_atom) ->
          {:error, error_atom}
      end
    else
      # Production path - query models concurrently
      lightweight? = Helpers.lightweight_test_query?(opts)

      # Suppress per-model persistence during parallel queries
      # (each model's condensation would write ALL models' state to the same DB row,
      # causing lost-update race conditions). Single persist after merge.
      parallel_opts = Keyword.put(opts, :persist_fn, fn _state -> :ok end)

      {results, final_state} =
        if length(model_pool) == 1 do
          # Single model: skip Task overhead, call directly
          # Uses parallel_opts (no-op persist_fn) so the deferred persist below
          # is the only persist call — same as the multi-model path.
          [model_id] = model_pool

          {result, post_state} =
            query_single_model_in_pool(state, model_id, lightweight?, parallel_opts)

          {[result], post_state}
        else
          # Multiple models: parallel fan-out
          query_models_parallel(state, model_pool, lightweight?, parallel_opts)
        end

      # Persist ACE state once after all models complete (if any condensation occurred)
      if StateMerge.state_changed?(state, final_state) do
        persist_fn = Keyword.get(opts, :persist_fn, &Persistence.persist_ace_state/1)
        persist_fn.(final_state)
      end

      # Log failures before filtering them out
      failed = Enum.filter(results, &match?({:error, _, _}, &1))

      Enum.each(failed, fn {:error, model_id, reason} ->
        Logger.warning("Model query failed: model=#{model_id}, reason=#{inspect(reason)}")
      end)

      # Aggregate results
      successful = Enum.filter(results, &match?({:ok, _, _}, &1))
      responses = Enum.map(successful, fn {:ok, _model_id, response} -> response end)

      if responses == [] do
        {:error, :all_models_failed}
      else
        {:ok, responses, final_state}
      end
    end
  end

  # Parallel fan-out: spawn a Task per model, await all, merge state slices.
  # Traps exits to prevent linked Task crashes from killing the caller before
  # Task.await_many can handle them, then restores the original trap_exit flag.
  @spec query_models_parallel(map(), list(String.t()), boolean(), keyword()) ::
          {list(), map()}
  defp query_models_parallel(state, model_pool, lightweight?, opts) do
    sandbox_owner = Keyword.get(opts, :sandbox_owner)
    old_trap = Process.flag(:trap_exit, true)

    tasks =
      Enum.map(model_pool, fn model_id ->
        Task.async(fn ->
          if sandbox_owner do
            Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, sandbox_owner, self())
          end

          query_single_model_in_pool(state, model_id, lightweight?, opts)
        end)
      end)

    task_results =
      try do
        Task.await_many(tasks, :infinity)
      catch
        :exit, reason ->
          Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
          Process.flag(:trap_exit, old_trap)
          StateMerge.unwrap_task_exit(reason)
      end

    Process.flag(:trap_exit, old_trap)

    # Merge: each task returns {result_tuple, per_model_state}
    # Per-model state slices are disjoint (each model only modifies its own key)
    StateMerge.merge_parallel_results(state, task_results)
  end

  # Query a single model within the pool (shared by both single-model and parallel paths).
  @spec query_single_model_in_pool(map(), String.t(), boolean(), keyword()) ::
          {{:ok | :error, String.t(), any()}, map()}
  defp query_single_model_in_pool(state, model_id, lightweight?, opts) do
    pre_query_state =
      if lightweight?,
        do: state,
        else: maybe_condense_for_model(state, model_id, opts)

    case query_single_model_with_retry(pre_query_state, model_id, opts) do
      {:ok, response, new_state} -> {{:ok, model_id, response}, new_state}
      {:error, reason, new_state} -> {{:error, model_id, reason}, new_state}
    end
  end

  @doc """
  Build query options for a specific model and round.
  Uses Temperature module to calculate round-appropriate temperature.
  Returns a map with :max_tokens and :temperature.
  """
  @spec build_query_options(String.t(), keyword()) :: map()
  def build_query_options(model_id, opts) do
    round = Keyword.get(opts, :round, 1)
    temp_opts = [max_refinement_rounds: Keyword.get(opts, :max_refinement_rounds, 4)]
    temperature = Temperature.calculate_round_temperature(model_id, round, temp_opts)

    base_opts = %{
      temperature: temperature,
      prompt_cache: -2,
      round: round
    }

    # Pass through caller-provided max_tokens (from dynamic calculation)
    base_opts =
      case Keyword.get(opts, :max_tokens) do
        nil -> base_opts
        max_tokens -> Map.put(base_opts, :max_tokens, max_tokens)
      end

    # Pass through cost recording context and HTTP test plug
    base_opts =
      base_opts
      |> maybe_put(:sandbox_owner, opts[:sandbox_owner])
      |> maybe_put(:agent_id, opts[:agent_id])
      |> maybe_put(:task_id, opts[:task_id])
      |> maybe_put(:pubsub, opts[:pubsub])
      |> maybe_put(:plug, opts[:plug])

    if opts[:test_mode] do
      Map.merge(base_opts, Helpers.build_test_options(opts))
    else
      base_opts
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Handles parsed refinement responses, filtering nils and re-entering consensus process."
  @spec handle_refinement_responses(list(), list(), map(), integer(), function()) ::
          {:ok, tuple()}
  def handle_refinement_responses(
        refined_responses,
        original_responses,
        context,
        round,
        consensus_fn
      ) do
    parsed = ActionParser.parse_llm_responses(refined_responses)
    nil_count = Enum.count(parsed, &is_nil/1)

    if nil_count > 0 do
      Logger.warning(
        "Filtered #{nil_count} nil responses from #{length(parsed)} parsed (refinement path)"
      )
    end

    valid = Enum.filter(parsed, &(&1 != nil))

    # Validate refined responses before clustering (matches initial consensus paths)
    {validated, _invalid_count} = Quoracle.Agent.Consensus.filter_invalid_responses(valid)

    if validated == [] do
      clusters = Aggregator.cluster_responses(original_responses)

      cost_opts =
        Keyword.take(Map.get(context, :original_opts, []), [
          :agent_id,
          :task_id,
          :pubsub,
          :max_refinement_rounds,
          :cost_accumulator
        ])

      result = Result.format_result(clusters, length(original_responses), round, cost_opts)
      {:ok, result}
    else
      consensus_fn.(validated, context, round + 1)
    end
  end

  # Private helpers

  # R80: Extract raw JSON map from response for condense parameter checking
  # Uses JsonExtractor to handle markdown-wrapped JSON from LLMs
  defp extract_raw_response_map(%{content: content}) when is_binary(content) do
    case JsonExtractor.decode_with_extraction(content) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp extract_raw_response_map(%ReqLLM.Response{} = response) do
    case JsonExtractor.decode_with_extraction(ReqLLM.Response.text(response)) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp extract_raw_response_map(_), do: %{}
end
