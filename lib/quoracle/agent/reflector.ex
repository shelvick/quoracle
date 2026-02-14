defmodule Quoracle.Agent.Reflector do
  @moduledoc """
  Context Reflector for ACE (Agentic Context Engineering).

  Extracts lessons and state from messages being condensed via LLM reflection.
  The same model whose history is being condensed performs the reflection
  (self-reflection pattern).

  Returns structured JSON with:
  - lessons: factual + behavioral knowledge (accumulated over time)
  - state: task progress + situational context (replaced each condensation)
  """

  alias Quoracle.Agent.TokenManager
  alias Quoracle.Utils.ContentStringifier
  alias Quoracle.Utils.JsonExtractor

  require Logger

  @default_max_retries 2

  @reflection_prompt """
  You are analyzing conversation history that is about to be condensed.
  Extract valuable information that would be ACTIONABLE if encountered later.
  Ask: "What specific details would I need to act on this without re-discovering it?"

  LESSONS - Reusable knowledge (accumulated over time, deduplicated by similarity):
  - Factual: Specific, precise facts with enough detail to act on.
    GOOD: "Stripe webhook endpoint /api/webhooks/stripe requires idempotency-key header; without it, duplicate charges occur"
    BAD: "Stripe needs a header"
  - Behavioral: How to act, with context for when/why.
    GOOD: "User wants shell commands confirmed before execution, especially rm and database operations"
    BAD: "Be careful with commands"

  STATE - Current situational context (replaced each condensation):
  - Task progress with specific details: what's done, what's next, what's blocked and why
  - Decisions made and their rationale (so we don't revisit them)
  - Failures encountered: what was tried, why it failed, what worked instead

  Return JSON:
  {
    "lessons": [
      {"type": "factual", "content": "..."},
      {"type": "behavioral", "content": "..."}
    ],
    "state": [
      {"summary": "Implementing auth module: login/logout done, password reset blocked by missing SMTP config. Tried SendGrid but rate-limited; switching to Mailgun."}
    ]
  }

  If no valuable lessons/state found, return empty arrays.
  Messages to analyze:
  """

  @type lesson :: %{
          type: :factual | :behavioral,
          content: String.t(),
          confidence: pos_integer()
        }

  @type state_entry :: %{
          summary: String.t(),
          updated_at: DateTime.t()
        }

  @type reflection_result :: %{
          lessons: [lesson()],
          state: [state_entry()]
        }

  @doc """
  Reflects on messages to extract lessons and state.

  ## Options

  - `:test_mode` - Skip LLM call, return mock result
  - `:mock_response` - JSON string to use in test mode
  - `:query_fn` - Injectable query function for tests
  - `:max_retries` - Override retry count (default: 2)
  - `:delay_fn` - Injectable delay for tests

  ## Examples

      iex> messages = [%{role: "user", content: "Help me debug"}]
      iex> Reflector.reflect(messages, "anthropic:claude-sonnet-4", test_mode: true, mock_response: ~s({"lessons":[],"state":[]}))
      {:ok, %{lessons: [], state: []}}
  """
  @spec reflect(messages :: [map()], model_id :: String.t(), opts :: keyword()) ::
          {:ok, reflection_result()} | {:error, atom()}
  def reflect([], _model_id, _opts), do: {:error, :invalid_input}

  def reflect(messages, model_id, opts) when is_list(messages) do
    if Keyword.get(opts, :test_mode, false) do
      handle_test_mode(opts)
    else
      handle_reflection(messages, model_id, opts)
    end
  end

  # Test mode: parse mock response directly
  defp handle_test_mode(opts) do
    mock_response = Keyword.get(opts, :mock_response, ~s({"lessons":[],"state":[]}))
    parse_response(mock_response)
  end

  # Real mode: query LLM with retries
  defp handle_reflection(messages, model_id, opts) do
    retry_ctx = %{
      query_fn: Keyword.get(opts, :query_fn, &default_query/3),
      delay_fn: Keyword.get(opts, :delay_fn, &default_delay/1),
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      attempt: 0,
      opts: opts
    }

    do_reflect_with_retry(messages, model_id, retry_ctx)
  end

  defp do_reflect_with_retry(messages, model_id, %{query_fn: query_fn, attempt: attempt} = ctx) do
    case query_fn.(messages, model_id, ctx.opts) do
      {:ok, response} ->
        case parse_response(response) do
          {:ok, _result} = success ->
            success

          {:error, :malformed_response} ->
            Logger.warning("Reflector malformed response on attempt #{attempt + 1}: #{response}")
            maybe_retry(messages, model_id, ctx, :malformed)
        end

      {:error, _reason} ->
        maybe_retry(messages, model_id, ctx, :transport)
    end
  end

  defp maybe_retry(
         messages,
         model_id,
         %{attempt: attempt, max_retries: max_retries} = ctx,
         failure_type
       ) do
    if attempt < max_retries do
      # Exponential backoff: 100ms, 200ms, 400ms...
      backoff_ms = (100 * :math.pow(2, attempt)) |> round()
      ctx.delay_fn.(backoff_ms)

      do_reflect_with_retry(messages, model_id, %{ctx | attempt: attempt + 1})
    else
      case failure_type do
        :malformed -> {:error, :malformed_response_after_retries}
        :transport -> {:error, :reflection_failed}
      end
    end
  end

  defp parse_response(json_string) when is_binary(json_string) do
    case JsonExtractor.decode_with_extraction(json_string) do
      {:ok, data} ->
        validate_and_transform(data)

      {:error, reason} ->
        Logger.warning("Reflector JSON decode failed: #{reason}\nResponse: #{json_string}")

        {:error, :malformed_response}
    end
  end

  defp validate_and_transform(data) when is_map(data) do
    with {:ok, lessons_raw} <- Map.fetch(data, "lessons"),
         {:ok, state_raw} <- Map.fetch(data, "state"),
         true <- is_list(lessons_raw),
         true <- is_list(state_raw),
         {:ok, lessons} <- validate_lessons(lessons_raw),
         {:ok, state} <- validate_state(state_raw) do
      {:ok, %{lessons: lessons, state: state}}
    else
      error ->
        Logger.warning("Reflector validation failed: #{inspect(error)}\nData: #{inspect(data)}")

        {:error, :malformed_response}
    end
  end

  defp validate_and_transform(_), do: {:error, :malformed_response}

  defp validate_lessons(lessons_raw) do
    validated =
      Enum.reduce_while(lessons_raw, [], fn lesson, acc ->
        case validate_lesson(lesson) do
          {:ok, validated_lesson} -> {:cont, [validated_lesson | acc]}
          :error -> {:halt, :error}
        end
      end)

    case validated do
      :error -> {:error, :malformed_response}
      lessons -> {:ok, Enum.reverse(lessons)}
    end
  end

  defp validate_lesson(%{"type" => type, "content" => content})
       when type in ["factual", "behavioral"] and is_binary(content) do
    {:ok,
     %{
       type: String.to_existing_atom(type),
       content: content,
       confidence: 1
     }}
  end

  defp validate_lesson(_), do: :error

  defp validate_state(state_raw) do
    validated =
      Enum.reduce_while(state_raw, [], fn entry, acc ->
        case validate_state_entry(entry) do
          {:ok, validated_entry} -> {:cont, [validated_entry | acc]}
          :error -> {:halt, :error}
        end
      end)

    case validated do
      :error -> {:error, :malformed_response}
      state -> {:ok, Enum.reverse(state)}
    end
  end

  defp validate_state_entry(%{"summary" => summary}) when is_binary(summary) do
    {:ok,
     %{
       summary: summary,
       updated_at: DateTime.utc_now()
     }}
  end

  defp validate_state_entry(_), do: :error

  # Default delay function (used in production, injectable via delay_fn for tests)
  defp default_delay(ms) do
    # credo:disable-for-next-line Credo.Check.Warning.NoProcessSleep
    Process.sleep(ms)
  end

  # Default query function - calls MODEL_Query
  # Signature: query_models([message()], [model_ids], opts)
  defp default_query(messages, model_id, opts) do
    prompt = build_reflection_prompt(messages)

    # Convert prompt to message format expected by ModelQuery
    query_messages = [%{role: "user", content: prompt}]

    # Calculate dynamic max_tokens to prevent context window overflow.
    # Without this, ReqLLM injects LLMDB limits.output as max_tokens, which
    # for models like DeepSeek-V3.2 (128K output / 131K context) leaves
    # insufficient room for the input and causes HTTP 400 errors.
    max_tokens = calculate_max_tokens(query_messages, model_id)

    # Build cost context for ModelQuery (condensation costs tracked separately)
    query_opts = %{
      agent_id: Keyword.get(opts, :agent_id),
      task_id: Keyword.get(opts, :task_id),
      pubsub: Keyword.get(opts, :pubsub),
      cost_type: "llm_condensation",
      max_tokens: max_tokens
    }

    case Quoracle.Models.ModelQuery.query_models(query_messages, [model_id], query_opts) do
      {:ok, %{successful_responses: [response | _rest]}} ->
        # Extract text from first response
        text = extract_text_from_response(response)
        {:ok, text}

      {:ok, %{successful_responses: []}} ->
        {:error, :no_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Dynamic max_tokens: min(context_window - input_tokens, output_limit)
  # Mirrors PerModelQuery.calculate_max_tokens/2 for the Reflector code path.
  @spec calculate_max_tokens(list(map()), String.t()) :: pos_integer()
  defp calculate_max_tokens(messages, model_id) do
    context_window = TokenManager.get_model_context_limit(model_id)
    input_tokens = TokenManager.estimate_all_messages_tokens(messages)
    output_limit = TokenManager.get_model_output_limit(model_id)

    (context_window - input_tokens)
    |> max(1)
    |> min(output_limit)
  end

  defp build_reflection_prompt(messages) do
    messages_text =
      Enum.map_join(messages, "\n", fn msg ->
        role = Map.get(msg, :role) || Map.get(msg, "role", "unknown")
        content = Map.get(msg, :content) || Map.get(msg, "content", "")
        "#{role}: #{ContentStringifier.stringify(content)}"
      end)

    @reflection_prompt <> "\n" <> messages_text
  end

  defp extract_text_from_response(response) do
    # Handle ReqLLM.Response struct
    cond do
      is_struct(response, ReqLLM.Response) ->
        ReqLLM.Response.text(response)

      is_map(response) and is_binary(Map.get(response, :text)) ->
        Map.get(response, :text)

      is_map(response) and is_binary(Map.get(response, "text")) ->
        Map.get(response, "text")

      true ->
        ""
    end
  end
end
