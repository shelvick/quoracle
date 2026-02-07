defmodule Quoracle.Agent.Consensus.PerModelQuery do
  @moduledoc """
  Per-model query functions for consensus.
  Each model is queried with its own conversation history and can condense independently.
  Extracted from AGENT_Consensus to maintain <500 line modules.
  """

  alias Quoracle.Models.ModelQuery
  alias Quoracle.Agent.ContextManager
  alias Quoracle.Agent.Consensus.MessageBuilder
  alias Quoracle.Agent.Consensus.PerModelQuery.{Condensation, Helpers}
  alias Quoracle.Consensus.{ActionParser, Aggregator, Result, Temperature}
  alias Quoracle.Utils.JsonExtractor

  require Logger

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
    # Use unified message-building helper (R65-R70)
    messages_with_system = build_query_messages(state, model_id, opts)

    query_opts = build_query_options(model_id, opts)

    # Support injectable model_query_fn for testing
    query_fn = Keyword.get(opts, :model_query_fn, &ModelQuery.query_models/3)

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
          retry_query_opts = build_query_options(model_id, opts)

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
    # Use production path when model_query_fn is provided (allows test message capture)
    has_custom_query_fn = Keyword.has_key?(opts, :model_query_fn)

    if test_mode?(opts) && !has_custom_query_fn do
      # Check for simulate_failure flag first
      if Keyword.get(opts, :simulate_failure, false) do
        {:error, :all_models_failed}
      else
        # In test mode, return mock results with proper JSON format
        # Thread state through condensation for each model
        {results, final_state} =
          Enum.map_reduce(model_pool, state, fn model_id, acc_state ->
            # Check condensation first (updates state if needed)
            updated_state = maybe_condense_for_model(acc_state, model_id, opts)

            # Build messages from this model's history (still exercised in test mode)
            _messages = ContextManager.build_conversation_messages(updated_state, model_id)

            # Return mock response with valid JSON content
            response_json =
              Jason.encode!(%{
                "action" => "orient",
                "params" => %{
                  "current_situation" => "Processing task",
                  "goal_clarity" => "Clear objectives",
                  "available_resources" => "Full capabilities",
                  "key_challenges" => "None identified",
                  "delegation_consideration" => "none"
                },
                "reasoning" => "Mock reasoning for #{model_id}",
                "wait" => true
              })

            {%{model: model_id, content: response_json}, updated_state}
          end)

        {:ok, results, final_state}
      end
    else
      # Production path - query each model, threading state through
      {results, final_state} =
        Enum.map_reduce(model_pool, state, fn model_id, acc_state ->
          # Check condensation first (updates state if needed)
          pre_query_state = maybe_condense_for_model(acc_state, model_id, opts)

          # Query returns state to propagate any condensation from retry path
          {result, post_query_state} =
            case query_single_model_with_retry(pre_query_state, model_id, opts) do
              {:ok, response, new_state} -> {{:ok, model_id, response}, new_state}
              {:error, reason, new_state} -> {{:error, model_id, reason}, new_state}
            end

          {result, post_query_state}
        end)

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

  @doc """
  Build query options for a specific model and round.
  Uses Temperature module to calculate round-appropriate temperature.
  Returns a map with :max_tokens and :temperature.
  """
  @spec build_query_options(String.t(), keyword()) :: map()
  def build_query_options(model_id, opts) do
    round = Keyword.get(opts, :round, 1)
    temperature = Temperature.calculate_round_temperature(model_id, round)

    base_opts = %{
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      temperature: temperature,
      prompt_cache: -2,
      round: round
    }

    # Pass through cost recording context and HTTP test plug
    base_opts =
      base_opts
      |> maybe_put(:sandbox_owner, opts[:sandbox_owner])
      |> maybe_put(:agent_id, opts[:agent_id])
      |> maybe_put(:task_id, opts[:task_id])
      |> maybe_put(:pubsub, opts[:pubsub])
      |> maybe_put(:plug, opts[:plug])

    if opts[:test_mode] do
      Map.merge(base_opts, build_test_options(opts))
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

    if valid == [] do
      clusters = Aggregator.cluster_responses(original_responses)

      cost_opts =
        Keyword.take(Map.get(context, :original_opts, []), [:agent_id, :task_id, :pubsub])

      result = Result.format_result(clusters, length(original_responses), round, cost_opts)
      {:ok, result}
    else
      consensus_fn.(valid, context, round + 1)
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

  defp test_mode?(opts), do: Keyword.get(opts, :test_mode, false)

  defp build_test_options(opts) do
    %{
      test_mode: true,
      seed: Keyword.get(opts, :seed),
      simulate_tie: Keyword.get(opts, :simulate_tie, false),
      simulate_no_consensus: Keyword.get(opts, :simulate_no_consensus, false),
      simulate_refinement_agreement: Keyword.get(opts, :simulate_refinement_agreement, false),
      simulate_timeout: Keyword.get(opts, :simulate_timeout, false),
      simulate_all_models_fail: Keyword.get(opts, :simulate_all_models_fail, false),
      simulate_failure: Keyword.get(opts, :simulate_failure, false)
    }
  end
end
