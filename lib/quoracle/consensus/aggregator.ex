defmodule Quoracle.Consensus.Aggregator do
  @moduledoc """
  Handles clustering of LLM responses and refinement prompt generation.
  Groups similar actions together and manages multi-round refinement.
  """

  alias Quoracle.Actions.Schema
  alias Quoracle.Consensus.Aggregator.{ActionSummary, ParamMatching}
  alias Quoracle.Costs.Accumulator
  alias Quoracle.Models.Embeddings

  # Delegate action summary functions to extracted module (API compatibility)
  defdelegate format_action_summary(response), to: ActionSummary
  defdelegate format_reasoning_history(history), to: ActionSummary

  @doc """
  Clusters responses by action type and parameter similarity.
  Actions and params are treated as atomic units - never separated.
  """
  @spec cluster_responses([map()]) :: [map()]
  def cluster_responses([]), do: []

  def cluster_responses(responses) do
    responses
    |> Enum.group_by(&action_fingerprint/1)
    |> Enum.map(fn {fingerprint, actions} ->
      %{
        count: length(actions),
        actions: actions,
        representative: hd(actions),
        fingerprint: fingerprint
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  @doc """
  Finds a cluster meeting the consensus threshold.

  Round 1 requires 100% unanimous agreement (all models must agree).
  Rounds 2+ require >50% majority.

  This ensures all models are exposed to each other's ideas at least once,
  unless they completely agree from the start.
  """
  @spec find_majority_cluster([map()], integer(), integer()) ::
          {:majority, map()} | {:no_majority, [map()]}
  def find_majority_cluster(clusters, total_count, round \\ 2) do
    threshold_fn =
      if round == 1 do
        # Round 1: require unanimous (100%)
        fn cluster -> cluster.count == total_count end
      else
        # Rounds 2+: require majority (>50%)
        fn cluster -> cluster.count > total_count / 2 end
      end

    case Enum.find(clusters, threshold_fn) do
      nil -> {:no_majority, clusters}
      majority -> {:majority, majority}
    end
  end

  @doc """
  Creates a fingerprint for an action to enable clustering.
  Uses schema-aware comparison rules for parameters.

  For batch_sync: fingerprint is {action_type, action_type_sequence} - ignores param values.
  For batch_async: fingerprint is {action_type, sorted_action_types} - sorted for order-independence.
  """
  @spec action_fingerprint(map()) :: {atom(), term()}
  def action_fingerprint(%{action: :batch_async, params: params}) do
    actions = get_batch_actions(params)

    # Extract action types and SORT for order-independent clustering
    action_sequence =
      actions
      |> Enum.map(&extract_action_type/1)
      |> Enum.sort()

    {:batch_async, action_sequence}
  end

  def action_fingerprint(%{action: :batch_sync, params: params}) do
    actions = get_batch_actions(params)

    # Extract action types preserving order (order matters for batch_sync)
    action_sequence = Enum.map(actions, &extract_action_type/1)

    {:batch_sync, action_sequence}
  end

  def action_fingerprint(%{action: action} = response) do
    case Schema.get_schema(action) do
      {:ok, schema} ->
        # Create a signature based on schema consensus rules
        signature = create_action_signature(response, schema)
        {action, signature}

      {:error, :unknown_action} ->
        {action, :invalid}
    end
  end

  @doc """
  Checks if two actions match based on their type and parameters.
  Uses schema-specific consensus rules for comparison.
  """
  @spec actions_match?(map(), map()) :: boolean()
  def actions_match?(%{action: action1} = response1, %{action: action2} = response2) do
    if action1 != action2 do
      false
    else
      case Schema.get_schema(action1) do
        {:ok, schema} ->
          ParamMatching.params_match?(response1.params, response2.params, schema.consensus_rules)

        {:error, :unknown_action} ->
          false
      end
    end
  end

  @doc """
  Builds a refinement prompt for the next round.
  Shows JSON of all proposed actions without vote percentages.
  Explains multi-model consensus process with independent histories.
  """
  @spec build_refinement_prompt([map()], integer(), map()) :: String.t()
  def build_refinement_prompt(responses, round_num, context) do
    actions_json =
      Enum.map_join(responses, "\n\n", fn response ->
        Jason.encode!(
          %{
            reasoning: response.reasoning,
            action: response.action,
            params: response.params
          },
          pretty: true
        )
      end)

    history_text =
      if context[:reasoning_history] && context.reasoning_history != [] do
        "\n\n**Previous reasoning (all rounds):**\n" <>
          format_reasoning_history(context.reasoning_history)
      else
        ""
      end

    max_rounds = Map.get(context, :max_refinement_rounds, 4)

    final_round_hint =
      if round_num >= max_rounds,
        do: "\nThis is the final round.",
        else: ""

    """
    ## Consensus Refinement - Round #{round_num}

    You are participating in a multi-model consensus process. Multiple AI models have independently analyzed this task, each with their own conversation history and accumulated context. The proposals below represent the different approaches suggested.

    **Prompt:** #{context.prompt}

    **How this works:**
    - Each model maintains independent context and learns from its own interactions
    - Your task: Consider ALL perspectives and provide your best recommendation
    - There is no "correct" answer to match - genuine deliberation improves outcomes
    - IMPORTANT: Your final response will be executed as an action whose recipient CANNOT see this refinement discussion. Any reference to "Proposal 1/2/3" will be meaningless to them.

    **CRITICAL: Be a skeptical reviewer, not an agreeable collaborator.**
    - LLMs tend to agree too readily. Fight this tendency.
    - For each proposal: What's wrong with it? What edge cases does it miss? What would make this fail?
    - Look for: incorrect assumptions, wrong/missing parameter values, inefficient approaches, security issues
    - After critical analysis, synthesize an improved approach
    - Put your critiques in the "reasoning" field of your JSON response (1-4 sentences per proposal, then 1-4 sentences for your synthesis)

    **Current proposals (JSON format):**
    ```json
    #{actions_json}
    ```
    #{history_text}

    Respond with valid JSON only. In your "reasoning" field, briefly note the key flaw in each proposal (1-4 sentences each), then your synthesis. Then provide ONE complete, self-contained action specification.

    CRITICAL: You MUST restate ALL parameters explicitly in your response. The recipient of this action cannot see the proposals above. References like "Proposal 2" or "use the approach mentioned above" will be meaningless to them. Your response must be completely self-contained.#{final_round_hint}
    """
  end

  @doc """
  Builds the final round prompt with emphasis on decisive action.
  """
  @spec build_final_round_prompt([map()], map()) :: String.t()
  def build_final_round_prompt(responses, context) do
    actions_json =
      Enum.map_join(responses, "\n\n", fn response ->
        Jason.encode!(
          %{
            reasoning: response.reasoning,
            action: response.action,
            params: response.params
          },
          pretty: true
        )
      end)

    max_rounds = Map.get(context, :max_refinement_rounds, 4)
    total_rounds = Map.get(context, :total_rounds, max_rounds)

    """
    ## Final Consensus Round

    This is the FINAL round of multi-model deliberation. After this round, the most-supported action will be executed.

    **Prompt:** #{context.prompt}

    **Context:** Multiple models with independent histories have been deliberating. The proposals below represent the refined options after #{total_rounds - 1} rounds of discussion.

    **Final proposals:**
    ```json
    #{actions_json}
    ```

    **Your task:** Synthesize the correct response. Even at this final stage, do not simply agree with the majority - if you see a flaw that hasn't been addressed, call it out and fix it.

    Respond with valid JSON only. In your "reasoning" field, briefly explain your synthesis (1-4 sentences). Then provide your final action specification with ALL parameters explicitly stated. Do NOT reference proposals by number.
    """
  end

  @doc """
  Extracts reasoning history from previous rounds for context.
  """
  @spec extract_reasoning_history([[map()]]) :: [[String.t()]]
  def extract_reasoning_history(previous_rounds) do
    Enum.map(previous_rounds, fn round_responses ->
      Enum.map(round_responses, & &1.reasoning)
    end)
  end

  @doc """
  Calculates semantic similarity between two texts using embeddings.
  Returns a similarity score between -1.0 and 1.0.

  When `:cost_accumulator` is provided in opts, returns `{similarity, updated_acc}`.
  """
  @spec calculate_semantic_similarity(String.t(), String.t()) :: float()
  @spec calculate_semantic_similarity(String.t(), String.t(), Keyword.t()) ::
          float() | {float(), Accumulator.t()}
  def calculate_semantic_similarity(text1, text2, opts \\ []) do
    raw_embedding_fn = Keyword.get(opts, :embedding_fn)
    initial_acc = Keyword.get(opts, :cost_accumulator)
    # Include cost_accumulator in cost_opts for threading
    cost_opts = Keyword.take(opts, [:agent_id, :task_id, :pubsub, :cost_accumulator])
    cost_opts_map = Map.new(cost_opts)

    # For 2-arity fns, pass opts as map; for 1-arity, use as-is; default to Embeddings
    {embedding_fn, tracks_acc?} =
      cond do
        is_function(raw_embedding_fn, 2) ->
          {fn text, acc_map -> raw_embedding_fn.(text, acc_map) end, true}

        is_function(raw_embedding_fn, 1) ->
          {fn text, _acc_map -> raw_embedding_fn.(text) end, false}

        true ->
          {fn text, acc_map -> Embeddings.get_embedding(text, acc_map) end, true}
      end

    # Get embeddings, threading accumulator through both calls
    {result1, acc1} =
      call_embedding_with_acc(embedding_fn, text1, cost_opts_map, initial_acc, tracks_acc?)

    opts_map2 = if acc1, do: Map.put(cost_opts_map, :cost_accumulator, acc1), else: cost_opts_map
    {result2, acc2} = call_embedding_with_acc(embedding_fn, text2, opts_map2, acc1, tracks_acc?)

    similarity =
      with {:ok, embedding1} <- unwrap_embedding(result1),
           {:ok, embedding2} <- unwrap_embedding(result2) do
        cosine_similarity(embedding1, embedding2)
      else
        _ -> 0.0
      end

    # Return with accumulator if we started with one
    case acc2 do
      %Accumulator{} -> {similarity, acc2}
      _ -> similarity
    end
  end

  # Helper to call embedding fn and extract accumulator from 3-tuple response
  defp call_embedding_with_acc(embedding_fn, text, opts_map, current_acc, true) do
    case embedding_fn.(text, opts_map) do
      {:ok, result, %Accumulator{} = new_acc} -> {{:ok, result}, new_acc}
      {:ok, result} -> {{:ok, result}, current_acc}
      error -> {error, current_acc}
    end
  end

  defp call_embedding_with_acc(embedding_fn, text, opts_map, current_acc, false) do
    {embedding_fn.(text, opts_map), current_acc}
  end

  # Normalize embedding results: injected fns return {:ok, vector},
  # production Embeddings returns {:ok, %{embedding: vector}}.
  defp unwrap_embedding({:ok, %{embedding: vec}}), do: {:ok, vec}
  defp unwrap_embedding({:ok, vec}) when is_list(vec), do: {:ok, vec}
  defp unwrap_embedding(other), do: other

  @doc """
  Gets a cached embedding for text, returning metadata about cache hit.
  """
  @spec get_cached_embedding(String.t()) :: {:ok, map()} | {:error, atom()}
  @spec get_cached_embedding(String.t(), Keyword.t()) :: {:ok, map()} | {:error, atom()}
  def get_cached_embedding(text, opts \\ []) do
    # Check for mock embedding function
    embedding_fn = Keyword.get(opts, :embedding_fn)

    if embedding_fn do
      # Test mode - simulate cache behavior
      case embedding_fn.(text) do
        {:ok, embedding} -> {:ok, %{embedding: embedding, cached: false, chunks: 1}}
        error -> error
      end
    else
      Embeddings.get_embedding(text, opts)
    end
  end

  @doc """
  Computes cosine similarity between two embedding vectors.
  Returns a value between -1.0 (opposite) and 1.0 (identical).
  """
  @spec cosine_similarity([float()], [float()]) :: float()
  def cosine_similarity(vec1, vec2) when length(vec1) == length(vec2) do
    dot_product =
      Enum.zip(vec1, vec2)
      |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)

    magnitude1 = :math.sqrt(Enum.reduce(vec1, 0.0, fn x, acc -> acc + x * x end))
    magnitude2 = :math.sqrt(Enum.reduce(vec2, 0.0, fn x, acc -> acc + x * x end))

    if magnitude1 == 0.0 or magnitude2 == 0.0 do
      0.0
    else
      dot_product / (magnitude1 * magnitude2)
    end
  end

  def cosine_similarity(_vec1, _vec2), do: 0.0

  @doc """
  Checks if two texts are semantically similar using embeddings.
  Returns true if similarity exceeds the given threshold.
  """
  @spec semantic_similarity_with_embeddings(String.t(), String.t(), float()) :: boolean()
  @spec semantic_similarity_with_embeddings(String.t(), String.t(), float(), Keyword.t()) ::
          boolean()
  def semantic_similarity_with_embeddings(text1, text2, threshold, opts \\ []) do
    similarity = calculate_semantic_similarity(text1, text2, opts)
    similarity >= threshold
  end

  # Private functions

  defp create_action_signature(%{params: params} = _response, schema) do
    # For each parameter, apply the consensus rule to create a normalized signature
    Enum.reduce(schema.required_params ++ schema.optional_params, %{}, fn param, acc ->
      # Handle both string and atom keys since LLM responses have string keys
      param_str = Atom.to_string(param)
      value = Map.get(params, param) || Map.get(params, param_str)

      if value do
        rule = schema.consensus_rules[param]
        normalized = normalize_param_for_signature(value, rule)
        Map.put(acc, param, normalized)
      else
        acc
      end
    end)
  end

  defp normalize_param_for_signature(value, rule) do
    case rule do
      :exact_match ->
        # Exact values must match
        value

      {:semantic_similarity, opts} ->
        # For semantic similarity, normalize the string
        threshold = opts[:threshold] || 0.9
        normalize_semantic_string(value, threshold)

      :mode_selection ->
        # Values that need mode selection are kept as-is
        value

      :union_merge ->
        # Lists are sorted for comparison
        if is_list(value), do: Enum.sort(value), else: value

      :structural_merge ->
        # Maps are recursively sorted
        if is_map(value), do: deep_sort_map(value), else: value

      {:percentile, _n} ->
        # Numeric values are kept as-is for percentile
        value

      _ ->
        value
    end
  end

  defp normalize_semantic_string(str, threshold) when is_binary(str) do
    # Simple normalization for high similarity threshold
    if threshold >= 0.95 do
      # Very high threshold - only minor variations allowed
      str
      |> String.downcase()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> extract_key_terms()
    else
      # Lower threshold - more aggressive normalization
      str
      |> String.downcase()
      |> String.replace(~r/[^\w\s]/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> extract_key_terms()
    end
  end

  defp normalize_semantic_string(value, _threshold), do: value

  defp extract_key_terms(str) do
    # Extract the main action words (simplified without NLP)
    str
    |> String.split()
    |> Enum.filter(fn word -> String.length(word) > 3 end)
    |> Enum.sort()
    # Just key terms
    |> Enum.take(5)
    |> Enum.join("_")
  end

  defp deep_sort_map(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {k, deep_sort_map(v)} end)
    |> Enum.sort()
    |> Map.new()
  end

  defp deep_sort_map(value), do: value

  # Extract actions list from batch params, handling string/atom keys
  defp get_batch_actions(%{actions: actions}) when is_list(actions), do: actions
  defp get_batch_actions(%{"actions" => actions}) when is_list(actions), do: actions
  defp get_batch_actions(_), do: []

  # Extract action type from action spec, handling both atom and string keys/values
  defp extract_action_type(%{action: action_type}) when is_atom(action_type), do: action_type

  defp extract_action_type(%{action: action_type}) when is_binary(action_type),
    do: String.to_existing_atom(action_type)

  defp extract_action_type(%{"action" => action_type}) when is_binary(action_type),
    do: String.to_existing_atom(action_type)

  defp extract_action_type(%{"action" => action_type}) when is_atom(action_type), do: action_type
end
