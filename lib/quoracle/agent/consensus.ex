defmodule Quoracle.Agent.Consensus do
  @moduledoc """
  Emergent statistical consensus mechanism for ALL agent decision-making.
  Always returns exactly ONE action decision - no alternatives.
  Treats actions and parameters as atomic units throughout.
  """

  alias Quoracle.Models.ModelQuery
  alias Quoracle.Consensus.{ActionParser, Aggregator, Manager, Result, Temperature}
  alias Quoracle.Actions.Validator

  require Logger

  alias Quoracle.Agent.Consensus.{
    MockResponseGenerator,
    TestMode,
    PerModelQuery,
    SystemPromptInjector
  }

  @type consensus_result ::
          {:consensus, action_response(), Keyword.t()}
          | {:forced_decision, action_response(), Keyword.t()}

  @type action_response :: %{
          action: atom(),
          params: map(),
          reasoning: String.t(),
          wait: boolean() | integer() | nil,
          auto_complete_todo: boolean() | nil
        }

  @doc "Build query options (max_tokens, temperature) for a model/round. Delegates to PerModelQuery."
  @spec build_query_options(String.t(), keyword()) :: map()
  defdelegate build_query_options(model_id, opts), to: PerModelQuery

  @doc "Get consensus from multiple models. Returns exactly ONE action decision."
  @spec get_consensus(
          String.t() | list(map()) | nil,
          list(map()) | Keyword.t() | nil,
          Keyword.t()
        ) ::
          {:ok, consensus_result()} | {:error, atom()}
  def get_consensus(messages_or_prompt, history_or_opts \\ [], opts \\ [])

  def get_consensus(messages, opts, []) when is_list(messages) and is_list(opts) do
    get_consensus_with_messages(messages, opts)
  end

  def get_consensus(_, _, _) do
    {:error, :invalid_arguments}
  end

  @doc """
  Get consensus using per-model histories from agent state.
  Each model is queried with its own conversation history.

  Returns {:ok, {result_type, action, meta}, updated_state} or {:error, reason}.
  The meta map includes per_model_queries: true to indicate per-model flow was used.
  The updated_state contains any changes from condensation (model_histories, context_lessons, model_states).
  """
  @spec get_consensus_with_state(map(), keyword()) ::
          {:ok, consensus_result(), map()} | {:error, atom()}
  def get_consensus_with_state(state, opts) do
    # Validate model_histories field exists
    case Map.get(state, :model_histories) do
      nil ->
        {:error, :missing_model_histories}

      model_histories when is_map(model_histories) ->
        # Get model pool from opts or derive from histories
        model_pool = Keyword.get(opts, :model_pool, Map.keys(model_histories))

        # Query each model with its own history
        case query_models_with_per_model_histories(state, model_pool, opts) do
          {:ok, responses, updated_state} ->
            # Log raw LLM responses for initial consensus round (mirrors query_models_with_messages)
            if opts[:agent_id] && opts[:pubsub] do
              Quoracle.PubSub.AgentEvents.broadcast_log(
                opts[:agent_id],
                :debug,
                "Received #{length(responses)} LLM responses (initial round)",
                %{raw_responses: slim_responses_for_logging(responses)},
                opts[:pubsub]
              )
            end

            # Parse, filter nil, then validate before clustering
            parsed_responses = ActionParser.parse_llm_responses(responses)
            nil_count = Enum.count(parsed_responses, &is_nil/1)

            if nil_count > 0 do
              Logger.warning(
                "Filtered #{nil_count} nil responses from #{length(parsed_responses)} parsed (per-model path)"
              )
            end

            non_nil_responses = Enum.filter(parsed_responses, &(&1 != nil))
            {valid_responses, invalid_count} = filter_invalid_responses(non_nil_responses)

            cond do
              valid_responses == [] and invalid_count > 0 ->
                {:error, :all_responses_invalid}

              valid_responses == [] ->
                {:error, :all_models_failed}

              true ->
                # Build context for consensus - extract actual last user message
                prompt = extract_last_user_content(model_histories)
                context = Manager.build_context(prompt, [])
                context = Map.put(context, :model_pool, model_pool)
                context = Map.put(context, :original_opts, opts)
                # Include updated state for per-model refinement access (v10.0)
                context = Map.put(context, :state, updated_state)

                # Execute consensus and add per_model_queries flag to result meta
                {:ok, {result_type, action, meta}} =
                  execute_consensus_process(valid_responses, context, 1)

                # Add per_model_queries: true to meta
                updated_meta = Keyword.put(meta, :per_model_queries, true)

                # Track temperatures if requested
                updated_meta =
                  if Keyword.get(opts, :track_temperatures, false) do
                    round = Keyword.get(opts, :round, 1)

                    temperatures =
                      Map.new(model_pool, fn model_id ->
                        {model_id, Temperature.calculate_round_temperature(model_id, round)}
                      end)

                    Keyword.put(updated_meta, :temperatures, temperatures)
                  else
                    updated_meta
                  end

                {:ok, {result_type, action, updated_meta}, updated_state}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp get_consensus_with_messages(messages, opts) do
    prompt = extract_prompt_for_context(messages)

    # Config-driven model pool (v3.0) with DI support for test isolation
    model_pool = Manager.get_model_pool(opts)

    context = Manager.build_context(prompt, messages)
    context = Map.put(context, :model_pool, model_pool)
    context = Map.put(context, :original_opts, opts)

    field_prompts = extract_field_prompts(messages)

    messages_with_system = ensure_system_prompts(messages, field_prompts, opts)

    # Log the injected system prompt for debugging (post-injection visibility)
    if opts[:agent_id] && opts[:pubsub] do
      system_msg = Enum.find(messages_with_system, &(&1.role == "system"))

      if system_msg do
        Quoracle.PubSub.AgentEvents.broadcast_log(
          opts[:agent_id],
          :debug,
          "System prompt injected",
          %{
            system_prompt_length: String.length(system_msg.content)
          },
          opts[:pubsub]
        )
      end
    end

    case query_models_with_messages(messages_with_system, model_pool, opts) do
      {:ok, responses} ->
        parsed_responses = ActionParser.parse_llm_responses(responses)
        nil_count = Enum.count(parsed_responses, &is_nil/1)

        if nil_count > 0 do
          Logger.warning(
            "Filtered #{nil_count} nil responses from #{length(parsed_responses)} parsed (messages path)"
          )
        end

        non_nil_responses = Enum.filter(parsed_responses, &(&1 != nil))

        # Filter invalid responses before clustering
        {valid_responses, invalid_count} = filter_invalid_responses(non_nil_responses)

        cond do
          valid_responses == [] and invalid_count > 0 ->
            {:error, :all_responses_invalid}

          valid_responses == [] ->
            {:error, :all_models_failed}

          true ->
            execute_consensus_process(valid_responses, context, 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Extract the last user message as prompt for refinement context."
  @spec extract_prompt_for_context(list(map())) :: String.t()
  def extract_prompt_for_context(messages) do
    messages
    |> Enum.filter(fn msg -> msg.role == "user" end)
    |> List.last()
    |> case do
      %{content: content} -> content
      nil -> "Agent decision"
    end
  end

  @doc false
  @spec filter_invalid_responses([map()]) :: {[map()], non_neg_integer()}
  def filter_invalid_responses(responses) do
    # Use reduce to both filter AND apply validated/coerced params
    # Bug fix: Previously discarded coerced params (e.g., %{} -> [] for lists)
    {valid_reversed, invalid_count} =
      Enum.reduce(responses, {[], 0}, fn response, {valid_acc, inv_count} ->
        action = response.action
        params = response.params

        case Validator.validate_params(action, params) do
          {:ok, validated_params} ->
            # Use validated params with coercions applied (e.g., %{} -> [] for list types)
            updated_response = %{response | params: validated_params}
            {[updated_response | valid_acc], inv_count}

          {:error, reason} ->
            Logger.warning(
              "Filtered invalid consensus response: action=#{action}, reason=#{inspect(reason)}"
            )

            {valid_acc, inv_count + 1}
        end
      end)

    {Enum.reverse(valid_reversed), invalid_count}
  end

  defp execute_consensus_process(responses, context, round) do
    clusters = Aggregator.cluster_responses(responses)
    total = length(context.model_pool)
    max_rounds = Manager.get_max_refinement_rounds()
    cost_opts = extract_cost_opts(context)

    case Aggregator.find_majority_cluster(clusters, total, round) do
      {:majority, _cluster} ->
        result = Result.format_result(clusters, total, round, cost_opts)
        {:ok, result}

      {:no_majority, _clusters} when round >= max_rounds ->
        result = Result.format_result(clusters, total, round, cost_opts)
        {:ok, result}

      {:no_majority, _clusters} ->
        execute_refinement(responses, context, round)
    end
  end

  defp execute_refinement(responses, context, round) do
    # Build refinement prompt BEFORE updating context to show only PAST rounds' reasoning
    prompt = Aggregator.build_refinement_prompt(responses, round, context)
    # Now update context with current round for next iteration
    context = Manager.update_context_with_round(context, round, responses)
    opts = Map.get(context, :original_opts, [])

    # Get state from context for per-model refinement (v10.0)
    # State is required for refinement - messages-based API returns forced_decision
    case Map.get(context, :state) do
      nil ->
        # No state = messages-based API, refinement not possible without per-model histories
        # Return forced_decision with current best cluster
        clusters = Aggregator.cluster_responses(responses)
        cost_opts = extract_cost_opts(context)
        result = Result.format_result(clusters, length(responses), round, cost_opts)
        {:ok, result}

      state ->
        # Per-model path: each model gets its history + refinement prompt
        opts_with_round = Keyword.put(opts, :round, round + 1)
        opts_with_refinement = Keyword.put(opts_with_round, :refinement_prompt, prompt)

        case query_models_with_per_model_histories(
               state,
               context.model_pool,
               opts_with_refinement
             ) do
          {:ok, refined_responses, updated_state} ->
            # Log refinement responses for UI (mirrors initial round at lines 78-86)
            if opts[:agent_id] && opts[:pubsub] do
              Quoracle.PubSub.AgentEvents.broadcast_log(
                opts[:agent_id],
                :debug,
                "Received #{length(refined_responses)} LLM responses (refinement round #{round + 1})",
                %{raw_responses: slim_responses_for_logging(refined_responses)},
                opts[:pubsub]
              )
            end

            # Update context with condensed state for subsequent rounds
            context = Map.put(context, :state, updated_state)

            PerModelQuery.handle_refinement_responses(
              refined_responses,
              responses,
              context,
              round,
              &execute_consensus_process/3
            )

          {:error, _reason} ->
            clusters = Aggregator.cluster_responses(responses)
            cost_opts = extract_cost_opts(context)
            result = Result.format_result(clusters, length(responses), round, cost_opts)
            {:ok, result}
        end
    end
  end

  # Extract the last user message content from model histories.
  # Histories are newest-first; pick any model since user messages are identical across models.
  # Handles both history entry format (%{type: :user}) and raw message format (%{role: "user"}).
  defp extract_last_user_content(model_histories) do
    model_histories
    |> Map.values()
    |> List.first([])
    |> Enum.find(&user_entry?/1)
    |> case do
      %{content: content} when is_binary(content) -> content
      %{content: %{content: content}} when is_binary(content) -> content
      _ -> "Agent decision"
    end
  end

  defp user_entry?(%{type: :user}), do: true
  defp user_entry?(%{role: "user"}), do: true
  defp user_entry?(_), do: false

  # v24.0: Added :cost_accumulator for embedding cost batching (feat-20260203-194408)
  defp extract_cost_opts(context) do
    opts = Map.get(context, :original_opts, [])
    Keyword.take(opts, [:agent_id, :task_id, :pubsub, :cost_accumulator])
  end

  @doc "Ensures messages array has both action schema and field-based prompts."
  @spec ensure_system_prompts(list(map()), map()) :: list(map())
  defdelegate ensure_system_prompts(messages, field_prompts), to: SystemPromptInjector

  @doc "Ensures messages have combined system prompt with field-based configuration."
  @spec ensure_system_prompts(list(map()), map(), keyword()) :: list(map())
  defdelegate ensure_system_prompts(messages, field_prompts, opts), to: SystemPromptInjector

  @doc "Extracts field-based prompts (system_prompt, user_prompt) from messages."
  @spec extract_field_prompts(list(map())) :: map()
  defdelegate extract_field_prompts(messages), to: SystemPromptInjector

  # Query models with messages
  defp query_models_with_messages(messages, model_pool, opts) do
    if TestMode.enabled?(opts) do
      MockResponseGenerator.generate(model_pool, opts)
    else
      case ModelQuery.query_models(messages, model_pool, build_query_options(opts)) do
        {:ok, result} ->
          maybe_log_responses(result, opts)
          {:ok, result.successful_responses}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp maybe_log_responses(result, opts) do
    if opts[:agent_id] && opts[:pubsub] do
      Quoracle.PubSub.AgentEvents.broadcast_log(
        opts[:agent_id],
        :debug,
        "Received #{length(result.successful_responses)} LLM responses",
        %{
          raw_responses: slim_responses_for_logging(result.successful_responses),
          failed_models: result.failed_models,
          total_latency_ms: result.total_latency_ms,
          aggregate_usage: result.aggregate_usage
        },
        opts[:pubsub]
      )
    end
  end

  # Build query options from consensus opts
  defp build_query_options(opts) do
    base_opts =
      %{}
      |> maybe_put(:sandbox_owner, opts[:sandbox_owner])
      |> maybe_put(:agent_id, opts[:agent_id])
      |> maybe_put(:task_id, opts[:task_id])
      |> maybe_put(:pubsub, opts[:pubsub])

    Map.merge(base_opts, TestMode.build_test_options(opts))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Extracts only the fields needed for UI display from ReqLLM.Response objects.
  # Drops the `context` field which contains the full conversation history and
  # causes O(n²) memory growth when stored in log metadata.
  defp slim_responses_for_logging(responses) when is_list(responses) do
    Enum.map(responses, &slim_single_response/1)
  end

  defp slim_single_response(%ReqLLM.Response{} = response) do
    # Keep all UI-needed fields, drop only the massive context field
    %{
      model: response.model,
      usage: response.usage,
      text: ReqLLM.Response.text(response),
      finish_reason: response.finish_reason,
      latency_ms: Map.get(response, :latency_ms)
    }
  end

  defp slim_single_response(response) when is_map(response) do
    # Fallback for non-struct responses (tests, legacy)
    # Preserve all fields except context to maintain UI compatibility
    response
    |> Map.drop([:context, "context"])
    |> Map.put_new(:text, response[:content] || response["content"])
  end

  defp slim_single_response(other) do
    # Catch-all for nil, error tuples, or unexpected types
    %{model: nil, usage: nil, text: inspect(other), finish_reason: nil, latency_ms: nil}
  end

  @doc "Parse JSON response from LLM into action map. Delegates to ActionParser."
  @spec parse_json_response(String.t()) :: {:ok, action_response()} | {:error, atom()}
  defdelegate parse_json_response(json_string), to: ActionParser

  @doc "Parse list of raw LLM responses into action maps. Delegates to ActionParser."
  @spec parse_llm_responses([any()]) :: [action_response() | nil]
  defdelegate parse_llm_responses(raw_responses), to: ActionParser

  # Per-Model History Functions (Packet 4)

  # Per-model query functions delegated to PerModelQuery module
  @doc "Condenses a model's history with ACE reflection (Reflector + LessonManager)."
  @spec condense_model_history_with_reflection(map(), String.t(), keyword()) :: map()
  defdelegate condense_model_history_with_reflection(state, model_id, opts), to: PerModelQuery

  @doc "Checks if a model needs condensation and condenses if over threshold."
  @spec maybe_condense_for_model(map(), String.t(), keyword()) :: map()
  defdelegate maybe_condense_for_model(state, model_id, opts), to: PerModelQuery

  @doc "Queries a single model with retry on context_length_exceeded error."
  @spec query_single_model_with_retry(map(), String.t(), keyword()) ::
          {:ok, any(), map()} | {:error, atom(), map()}
  defdelegate query_single_model_with_retry(state, model_id, opts), to: PerModelQuery

  @doc "Queries each model in the pool with its own history."
  @spec query_models_with_per_model_histories(map(), list(String.t()), keyword()) ::
          {:ok, list(), map()} | {:error, atom()}
  defdelegate query_models_with_per_model_histories(state, model_pool, opts), to: PerModelQuery
end
