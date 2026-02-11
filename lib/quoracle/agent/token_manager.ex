defmodule Quoracle.Agent.TokenManager do
  @moduledoc """
  Token counting and context limit management for AGENT_Core.
  Handles token estimation, usage tracking, and context percentage calculations.
  """

  @default_context_limit 128_000

  @doc """
  Estimates tokens from text using tiktoken library.
  Uses cl100k_base encoding (GPT-4, Claude, Gemini compatible).
  """
  @spec estimate_tokens(String.t() | nil) :: non_neg_integer()
  def estimate_tokens(nil), do: 0
  def estimate_tokens(""), do: 0

  def estimate_tokens(text) when is_binary(text) do
    # cl100k_base encoding - accurate for GPT-4, Claude, Gemini (~3-5% variance)
    # Tiktoken.CL100K is a NIF-generated module available at runtime only
    {:ok, tokens} = apply(Tiktoken.CL100K, :encode, [text])
    length(tokens)
  end

  @doc """
  Estimates tokens for conversation history.
  """
  @spec estimate_history_tokens(list() | nil) :: non_neg_integer()
  def estimate_history_tokens(nil), do: 0
  def estimate_history_tokens([]), do: 0

  def estimate_history_tokens(history) when is_list(history) do
    Enum.reduce(history, 0, fn entry, acc ->
      content =
        case entry do
          # DB-format: string keys from PostgreSQL/Ecto JSON storage
          %{"content" => %{"action" => _, "params" => params, "reasoning" => reasoning}} ->
            "#{inspect(params)} #{reasoning}"

          %{"content" => content} when is_binary(content) ->
            content

          %{"content" => nil} ->
            ""

          %{"content" => content} ->
            inspect(content)

          # In-memory format: atom keys (backward compatibility)
          %{content: %{action: _, params: params, reasoning: reasoning}} ->
            "#{inspect(params)} #{reasoning}"

          %{content: content} when is_binary(content) ->
            content

          %{content: nil} ->
            ""

          %{content: content} ->
            inspect(content)

          _ ->
            ""
        end

      acc + estimate_tokens(content)
    end)
  end

  @doc """
  Updates token usage tracking from API response.
  """
  @spec update_token_usage(map(), map()) :: map()
  def update_token_usage(state, api_response) do
    usage = Map.get(api_response, :usage, %{})
    prompt_tokens = Map.get(usage, :prompt_tokens, 0)
    completion_tokens = Map.get(usage, :completion_tokens, 0)
    total_tokens = Map.get(usage, :total_tokens, 0)
    model = Map.get(api_response, :model)

    # Use Map.get for optional fields (works with both structs and maps)
    current_usage = Map.get(state, :token_usage, %{total: 0, by_model: %{}})

    updated_usage = %{
      total: current_usage.total + total_tokens,
      last_request: prompt_tokens,
      last_response: completion_tokens,
      by_model:
        if model do
          Map.update(
            Map.get(current_usage, :by_model, %{}),
            model,
            total_tokens,
            &(&1 + total_tokens)
          )
        else
          Map.get(current_usage, :by_model, %{})
        end
    }

    Map.put(state, :token_usage, updated_usage)
  end

  @doc """
  Calculates percentage of context limit used across all model histories.
  """
  @spec context_usage_percentage(map()) :: float()
  def context_usage_percentage(state) do
    limit = state.context_limit
    all_entries = state.model_histories |> Map.values() |> List.flatten()
    history_tokens = estimate_history_tokens(all_entries)
    history_tokens / limit * 100.0
  end

  @doc """
  Returns the token count for a specific model's conversation history.
  Used by ContextInjector to show agents their context accumulation.

  Returns 0 if model_id not found in model_histories.
  """
  @spec history_tokens_for_model(map(), String.t()) :: non_neg_integer()
  def history_tokens_for_model(state, model_id) do
    history = get_in(state, [:model_histories, model_id]) || []
    estimate_history_tokens(history)
  end

  @doc """
  Estimates total tokens from consensus messages, excluding system prompt.

  Takes the fully-built message list (after all injections) and counts tokens
  from all non-system messages. This gives agents accurate visibility into
  their context accumulation for informed condensation decisions.

  System prompt is excluded because it's constant overhead the agent can't control.
  """
  @spec estimate_messages_tokens(list(map())) :: non_neg_integer()
  def estimate_messages_tokens([]), do: 0

  def estimate_messages_tokens(messages) when is_list(messages) do
    messages
    |> Enum.reject(&system_message?/1)
    |> Enum.reduce(0, fn msg, acc ->
      content = extract_message_content(msg)
      acc + estimate_tokens(content)
    end)
  end

  # Check if message has system role (supports both atom and string keys)
  defp system_message?(%{role: "system"}), do: true
  defp system_message?(%{"role" => "system"}), do: true
  defp system_message?(_), do: false

  # Extract content from message (supports both atom and string keys)
  defp extract_message_content(%{content: content}) when is_binary(content), do: content
  defp extract_message_content(%{"content" => content}) when is_binary(content), do: content
  defp extract_message_content(%{content: content}), do: inspect(content)
  defp extract_message_content(%{"content" => content}), do: inspect(content)
  defp extract_message_content(_), do: ""

  @doc """
  Estimates total context tokens including optional system prompt.
  """
  @spec estimate_total_context_tokens(map(), keyword()) :: non_neg_integer()
  def estimate_total_context_tokens(state, opts \\ []) do
    include_system = Keyword.get(opts, :include_system, false)
    all_entries = state.model_histories |> Map.values() |> List.flatten()
    history_tokens = estimate_history_tokens(all_entries)

    if include_system do
      # Use Map.get for optional fields (works with both structs and maps)
      system_prompt = Map.get(state, :system_prompt, "")
      history_tokens + estimate_tokens(system_prompt)
    else
      history_tokens
    end
  end

  @doc """
  Checks if a specific model's history needs condensation.
  ACE v3.0: Returns true if token count >= 100% of the model's context limit.
  Reactive condensation - only triggers when actually at limit.
  """
  @spec should_condense_for_model?(map(), String.t()) :: boolean()
  def should_condense_for_model?(state, model_id) do
    history = Map.get(state.model_histories, model_id, [])
    token_count = estimate_history_tokens(history)
    context_limit = get_model_context_limit(model_id)

    # ACE v3.0: Trigger at 100% - reactive condensation
    token_count >= context_limit
  end

  @doc """
  Determines which history entries to condense based on token count.
  ACE v3.0: Removes >80% of total tokens, oldest first.

  Returns `{to_remove, to_keep}` tuple where:
  - to_remove: entries to be condensed (oldest first, >80% of tokens)
  - to_keep: entries to preserve (newest)

  ## Examples

      iex> history = [%{id: 1, content: "old"}, %{id: 2, content: "new"}]
      iex> {to_remove, to_keep} = TokenManager.tokens_to_condense(history, 100)
      iex> length(to_remove) >= 1
      true
  """
  @spec tokens_to_condense(list(), non_neg_integer()) :: {list(), list()}
  def tokens_to_condense([], _total_tokens), do: {[], []}

  def tokens_to_condense(history, total_tokens) when total_tokens <= 0 do
    {[], history}
  end

  def tokens_to_condense(history, total_tokens) do
    target_removal = div(total_tokens * 80, 100) + 1

    # History is stored newest-first. Reverse to iterate from oldest.
    reversed = Enum.reverse(history)

    # Accumulate from oldest until we exceed 80% of tokens
    {to_remove, removed_tokens, remaining} =
      Enum.reduce_while(reversed, {[], 0, reversed}, fn entry, {removed, tokens_so_far, rest} ->
        entry_tokens = estimate_entry_tokens(entry)
        new_total = tokens_so_far + entry_tokens
        new_removed = removed ++ [entry]
        new_rest = tl(rest)

        if new_total > target_removal do
          # We've removed enough tokens
          {:halt, {new_removed, new_total, new_rest}}
        else
          # Continue removing
          {:cont, {new_removed, new_total, new_rest}}
        end
      end)

    # Reverse remaining back to newest-first order
    to_keep = Enum.reverse(remaining)

    # Edge case: if we went through all entries without exceeding target,
    # check if we should remove all (single entry case)
    if removed_tokens <= target_removal and to_keep == [] do
      {to_remove, []}
    else
      {to_remove, to_keep}
    end
  end

  @doc """
  Split history into messages to condense and messages to keep based on count.
  Returns {to_remove, to_keep} where to_remove contains the N oldest messages.

  Unlike tokens_to_condense/2 which splits based on token count (>80% of tokens),
  this function splits based on message count (exactly N oldest messages).

  ## Parameters
  - history: List of message entries (stored newest-first via prepend)
  - n: Number of oldest messages to remove

  ## Returns
  - {to_remove, to_keep} tuple where:
    - to_remove: List of N oldest messages (oldest-first, for Reflector)
    - to_keep: Remaining messages (newest-first, same order as input)
  """
  @spec messages_to_condense(list(map()), pos_integer()) :: {list(map()), list(map())}
  def messages_to_condense(history, n) when is_list(history) and is_integer(n) and n > 0 do
    # History is stored newest-first. Reverse to work with oldest-first.
    reversed = Enum.reverse(history)

    # Split: first n are oldest (to remove), rest are newer (to keep)
    {to_remove, to_keep_reversed} = Enum.split(reversed, n)

    # to_remove stays oldest-first (for Reflector to process chronologically)
    # to_keep reversed back to newest-first (matches storage convention)
    {to_remove, Enum.reverse(to_keep_reversed)}
  end

  def messages_to_condense(history, _n), do: {[], history}

  # Estimate tokens for a single history entry
  # Supports both string keys (DB-format) and atom keys (in-memory)
  defp estimate_entry_tokens(entry) do
    content =
      case entry do
        # DB-format: string keys from PostgreSQL/Ecto JSON storage
        %{"content" => %{"action" => _, "params" => params, "reasoning" => reasoning}} ->
          "#{inspect(params)} #{reasoning}"

        %{"content" => content} when is_binary(content) ->
          content

        %{"content" => nil} ->
          ""

        %{"content" => content} ->
          inspect(content)

        # In-memory format: atom keys (backward compatibility)
        %{content: %{action: _, params: params, reasoning: reasoning}} ->
          "#{inspect(params)} #{reasoning}"

        %{content: content} when is_binary(content) ->
          content

        %{content: nil} ->
          ""

        %{content: content} ->
          inspect(content)

        _ ->
          ""
      end

    estimate_tokens(content)
  end

  @doc """
  Gets the context limit for a model from LLMDB.
  Returns 128000 default if model not found or limits.context is nil.
  """
  @spec get_model_context_limit(String.t()) :: integer()
  def get_model_context_limit(model_spec) do
    # Find model in LLMDB by matching spec
    case find_model_by_spec(model_spec) do
      {:ok, model} ->
        get_in(model, [:limits, :context]) || @default_context_limit

      :error ->
        @default_context_limit
    end
  end

  @doc """
  Gets the output limit for a model from LLMDB.
  Returns `limits.output` from the LLMDB model entry.
  Falls back to `@default_context_limit` if model not found or limits.output is nil.
  """
  @spec get_model_output_limit(String.t()) :: integer()
  def get_model_output_limit(model_spec) do
    case find_model_by_spec(model_spec) do
      {:ok, model} ->
        get_in(model, [:limits, :output]) || @default_context_limit

      :error ->
        @default_context_limit
    end
  end

  @doc """
  Estimates total tokens across ALL messages, including system prompt.

  Unlike `estimate_messages_tokens/1` which excludes system messages, this
  counts every message -- needed for accurate input token calculation when
  computing dynamic max_tokens to prevent context window overflow.
  """
  @spec estimate_all_messages_tokens(list(map())) :: non_neg_integer()
  def estimate_all_messages_tokens([]), do: 0

  def estimate_all_messages_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      content = extract_message_content(msg)
      acc + estimate_tokens(content)
    end)
  end

  # Find a model in LLMDB by its spec string
  defp find_model_by_spec(model_spec) do
    LLMDB.models()
    |> Enum.find(fn model -> LLMDB.Model.spec(model) == model_spec end)
    |> case do
      nil -> :error
      model -> {:ok, Map.from_struct(model)}
    end
  end
end
