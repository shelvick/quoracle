defmodule Quoracle.Actions.ConsensusRules do
  @moduledoc """
  Implements consensus rules for merging action parameters from multiple LLM responses.
  Each rule defines how to combine or select values when multiple models suggest different parameters.
  """

  alias Quoracle.Actions.Schema
  alias Quoracle.Models.ModelQuery
  alias Quoracle.Costs.Accumulator

  @doc """
  Applies a consensus rule to a list of values.
  Returns {:ok, consensus_value} or {:error, reason}.
  The 3-arity version threads cost context opts to embedding calls.
  """
  @spec apply_rule(atom() | tuple(), list(), keyword()) ::
          {:ok, any()} | {:error, atom()} | {{:ok, any()} | {:error, atom()}, Accumulator.t()}
  def apply_rule({:semantic_similarity, opts}, values, cost_opts) do
    threshold = Keyword.get(opts, :threshold, 0.9)
    plug = Keyword.get(opts, :plug)
    # Check both rule opts and cost_opts for embedding_fn (R49)
    embedding_fn = Keyword.get(opts, :embedding_fn) || Keyword.get(cost_opts, :embedding_fn)

    case semantic_similarity_check(values, threshold, plug, cost_opts, embedding_fn) do
      {:ok, representative, acc} -> {{:ok, representative}, acc}
      {:ok, representative} -> {:ok, representative}
      # v4.0: Return accumulator on error too
      {:error, acc} when is_struct(acc) -> {{:error, :no_consensus}, acc}
      :error -> {:error, :no_consensus}
    end
  end

  def apply_rule(:batch_sequence_merge, [], _cost_opts), do: {:ok, []}
  def apply_rule(:batch_sequence_merge, [single_sequence], _cost_opts), do: {:ok, single_sequence}

  def apply_rule(:batch_sequence_merge, sequences, cost_opts) when is_list(sequences) do
    lengths = Enum.map(sequences, &length/1)

    if Enum.uniq(lengths) |> length() > 1 do
      {:error, :sequence_length_mismatch}
    else
      merge_sequences(sequences, cost_opts)
    end
  end

  def apply_rule(rule, values, _cost_opts), do: apply_rule(rule, values)

  @spec apply_rule(atom() | tuple(), list()) :: {:ok, any()} | {:error, atom()}
  def apply_rule(:exact_match, []), do: {:error, :no_values}
  def apply_rule(:exact_match, [value]), do: {:ok, value}

  def apply_rule(:exact_match, values) do
    case Enum.uniq(values) do
      [single_value] -> {:ok, single_value}
      _ -> {:error, :no_consensus}
    end
  end

  def apply_rule({:semantic_similarity, opts}, values) do
    threshold = Keyword.get(opts, :threshold, 0.9)
    plug = Keyword.get(opts, :plug)

    # Uses embeddings + cosine similarity for semantic comparison
    case semantic_similarity_check(values, threshold, plug) do
      {:ok, representative} -> {:ok, representative}
      :error -> {:error, :no_consensus}
    end
  end

  def apply_rule(:mode_selection, []), do: {:error, :no_values}

  def apply_rule(:mode_selection, values) do
    frequencies = Enum.frequencies(values)
    {most_common, _count} = Enum.max_by(frequencies, fn {_val, count} -> count end)
    {:ok, most_common}
  end

  def apply_rule(:union_merge, values) do
    merged = values |> List.flatten() |> Enum.uniq()
    {:ok, merged}
  end

  def apply_rule(:structural_merge, values) do
    # Reduce left to right, with later values overriding earlier
    merged =
      Enum.reduce(values, %{}, fn value, acc ->
        deep_merge(acc, value)
      end)

    {:ok, merged}
  end

  def apply_rule({:percentile, percentile}, values) when is_list(values) and values != [] do
    numeric_values = Enum.filter(values, &is_number/1)

    if numeric_values == [] do
      # No numeric values (e.g., all booleans) - fall back to mode selection
      apply_rule(:mode_selection, values)
    else
      sorted = Enum.sort(numeric_values)
      index = calculate_percentile_index(length(sorted), percentile)
      result = calculate_percentile_value(sorted, index)
      {:ok, result}
    end
  end

  def apply_rule(:batch_sequence_merge, []), do: {:ok, []}
  def apply_rule(:batch_sequence_merge, [single_sequence]), do: {:ok, single_sequence}

  def apply_rule(:batch_sequence_merge, sequences) when is_list(sequences) do
    apply_rule(:batch_sequence_merge, sequences, [])
  end

  def apply_rule(:wait_parameter, []), do: {:error, :no_values}

  def apply_rule(:wait_parameter, values) do
    {booleans, integers} = Enum.split_with(values, &is_boolean/1)

    # Check special boolean-only cases first
    cond do
      # All values are boolean false
      integers == [] and booleans != [] and Enum.all?(booleans, &(&1 == false)) ->
        {:ok, false}

      # All values are boolean true
      integers == [] and booleans != [] and Enum.all?(booleans, &(&1 == true)) ->
        {:ok, true}

      # Mixed booleans (3+ values) with any true returns true
      # (self_contained_actions auto-correction prevents stalling)
      integers == [] and length(booleans) >= 3 and Enum.any?(booleans, &(&1 == true)) ->
        {:ok, true}

      # Only integers
      booleans == [] and integers != [] ->
        sorted = Enum.sort(integers)
        median = calculate_median(sorted)
        {:ok, median}

      # Mixed types or 2 mixed booleans - convert and calculate median
      true ->
        converted =
          Enum.map(values, fn
            false ->
              0

            true ->
              # If there are integers, use the max; otherwise use 30
              max_int = if integers == [], do: 30, else: Enum.max(integers)
              max_int

            int when is_integer(int) ->
              int
          end)

        sorted = Enum.sort(converted)
        median = calculate_median(sorted)
        {:ok, median}
    end
  end

  def apply_rule(_, []), do: {:error, :no_values}
  def apply_rule(_, _), do: {:error, :unknown_rule}

  @doc """
  Merges parameter values for a specific action and parameter using the appropriate consensus rule.
  """
  @spec merge_params(atom(), atom(), list()) :: {:ok, any()} | {:error, atom()}
  def merge_params(_action, :wait, values) do
    # The :wait parameter uses its own special consensus rule
    apply_rule(:wait_parameter, values)
  end

  def merge_params(action, param, values) do
    with {:ok, schema} <- Schema.get_schema(action),
         {:ok, rule} <- get_consensus_rule(schema, param) do
      apply_rule(rule, values)
    else
      {:error, :unknown_action} -> {:error, :unknown_action}
      {:error, :no_rule} -> {:error, :unknown_param}
    end
  end

  @doc """
  Computes cosine similarity between two vectors.
  Returns a float between -1.0 and 1.0, where 1.0 means identical direction.
  """
  @spec cosine_similarity(list(float()), list(float())) :: float()
  def cosine_similarity(vec1, vec2) when length(vec1) != length(vec2) do
    raise ArgumentError, "Vectors must have the same length"
  end

  def cosine_similarity(vec1, vec2) do
    # Compute dot product and magnitudes
    {dot_product, mag1_sq, mag2_sq} =
      Enum.zip(vec1, vec2)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {v1, v2}, {dot, m1, m2} ->
        {dot + v1 * v2, m1 + v1 * v1, m2 + v2 * v2}
      end)

    mag1 = :math.sqrt(mag1_sq)
    mag2 = :math.sqrt(mag2_sq)

    # Handle zero vectors
    if mag1 == 0.0 or mag2 == 0.0 do
      0.0
    else
      dot_product / (mag1 * mag2)
    end
  end

  # Private functions

  defp get_consensus_rule(schema, param) do
    case Map.get(schema.consensus_rules, param) do
      nil -> {:error, :no_rule}
      rule -> {:ok, rule}
    end
  end

  defp semantic_similarity_check(values, threshold, plug) do
    semantic_similarity_check(values, threshold, plug, [], nil)
  end

  defp semantic_similarity_check(values, threshold, plug, cost_opts, embedding_fn) do
    case values do
      [] ->
        :error

      _values ->
        case use_embeddings_similarity(values, threshold, plug, cost_opts, embedding_fn) do
          # v4.0: Handle wrapped tuple format with accumulator
          {{:ok, representative}, acc} ->
            {:ok, representative, acc}

          {{:error, _reason}, acc} ->
            {:error, acc}

          # Without accumulator (optimization path or no cost_opts)
          {:ok, representative} ->
            {:ok, representative}

          {:error, _} ->
            :error
        end
    end
  end

  defp use_embeddings_similarity(values, threshold, plug, cost_opts, embedding_fn) do
    # Optimization: if all values are identical, no need for embeddings
    case Enum.uniq(values) do
      [] ->
        {:error, :no_values}

      [single_value] ->
        {:ok, single_value}

      _different_values ->
        # Build options for embedding calls (supports req_cassette plug + cost context)
        base_opts = if plug, do: %{plug: plug}, else: %{}
        embed_opts = Map.merge(base_opts, Map.new(cost_opts))

        # Get embeddings for all values, threading accumulator if present
        initial_acc = Keyword.get(cost_opts, :cost_accumulator)

        {embeddings_with_values, final_acc} =
          get_embeddings_for_values(values, embed_opts, embedding_fn, initial_acc)

        if length(embeddings_with_values) == length(values) do
          # All embeddings obtained successfully
          result =
            case embeddings_with_values do
              [{_single_value, _}] when length(values) > 1 ->
                # Only got one embedding when we expected multiple - no consensus possible
                {:error, :no_consensus}

              [{first_value, first_embedding} | rest] ->
                # Check if all are similar enough to the first one
                if Enum.all?(rest, fn {_, embedding} ->
                     cosine_similarity(first_embedding, embedding) >= threshold
                   end) do
                  {:ok, first_value}
                else
                  {:error, :no_consensus}
                end
            end

          # Return with accumulator if we have one (v4.0: also return on error)
          case {result, final_acc} do
            {{:ok, value}, %Accumulator{} = acc} -> {{:ok, value}, acc}
            {{:error, reason}, %Accumulator{} = acc} -> {{:error, reason}, acc}
            _ -> result
          end
        else
          # Some embeddings failed, fall back
          {:error, :embedding_failed}
        end
    end
  end

  # Get embeddings for all values, threading accumulator through calls
  defp get_embeddings_for_values(values, embed_opts, embedding_fn, initial_acc) do
    Enum.reduce(values, {[], initial_acc}, fn value, {results, acc} ->
      current_opts = if acc, do: Map.put(embed_opts, :cost_accumulator, acc), else: embed_opts

      case call_embedding(value, current_opts, embedding_fn) do
        {:ok, %{embedding: embedding}, new_acc} ->
          {[{value, embedding} | results], new_acc}

        {:ok, %{embedding: embedding}} ->
          {[{value, embedding} | results], acc}

        _ ->
          {results, acc}
      end
    end)
    |> then(fn {results, acc} -> {Enum.reverse(results), acc} end)
  end

  # Call embedding function (custom or default)
  defp call_embedding(value, opts, nil) do
    ModelQuery.get_embedding(value, opts)
  end

  defp call_embedding(value, opts, embedding_fn) when is_function(embedding_fn, 2) do
    embedding_fn.(value, opts)
  end

  defp deep_merge(map1, map2) when is_map(map1) and is_map(map2) do
    Map.merge(map1, map2, fn _key, val1, val2 ->
      case {is_map(val1), is_map(val2)} do
        {true, true} -> deep_merge(val1, val2)
        # Later value wins for non-map conflicts
        _ -> val2
      end
    end)
  end

  defp deep_merge(_, map2) when is_map(map2), do: map2
  defp deep_merge(map1, _) when is_map(map1), do: map1

  defp calculate_percentile_index(count, percentile) do
    percentile / 100.0 * (count - 1)
  end

  defp calculate_percentile_value(sorted, index) do
    lower_idx = trunc(index)
    upper_idx = min(lower_idx + 1, length(sorted) - 1)
    fraction = index - lower_idx

    lower_val = Enum.at(sorted, lower_idx)
    upper_val = Enum.at(sorted, upper_idx)

    # Linear interpolation between the two values
    # For 75th percentile of [100,200,300,400]: index=2.25, so 300 + 0.25*(400-300) = 325
    result = lower_val + (upper_val - lower_val) * fraction
    round(result)
  end

  defp calculate_median(sorted_list) do
    count = length(sorted_list)
    mid = div(count, 2)

    if rem(count, 2) == 0 do
      # Even number of elements - average the two middle values
      left = Enum.at(sorted_list, mid - 1)
      right = Enum.at(sorted_list, mid)
      div(left + right, 2)
    else
      # Odd number of elements - take the middle value
      Enum.at(sorted_list, mid)
    end
  end

  # Merges action sequences position by position
  defp merge_sequences(sequences, cost_opts) do
    # Transpose: [[a1,a2], [b1,b2]] -> [[a1,b1], [a2,b2]]
    transposed = Enum.zip_with(sequences, & &1)

    # Merge each position
    Enum.reduce_while(transposed, {:ok, []}, fn actions_at_position, {:ok, acc} ->
      case merge_position(actions_at_position, cost_opts) do
        {:ok, merged_action} -> {:cont, {:ok, acc ++ [merged_action]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Merges actions at a single position
  defp merge_position(actions, cost_opts) do
    # Normalize keys (handle string keys from LLM)
    normalized = Enum.map(actions, &normalize_action_keys/1)

    # Check all actions have the same type
    action_types = Enum.map(normalized, & &1.action)

    case Enum.uniq(action_types) do
      [action_type] ->
        # All same type - merge params using that action's consensus rules
        merge_action_params(action_type, normalized, cost_opts)

      _ ->
        {:error, :sequence_mismatch}
    end
  end

  defp normalize_action_keys(action) when is_map(action) do
    action_atom =
      case Map.get(action, :action) || Map.get(action, "action") do
        a when is_atom(a) -> a
        s when is_binary(s) -> String.to_existing_atom(s)
      end

    params =
      case Map.get(action, :params) || Map.get(action, "params") do
        nil -> %{}
        p -> p
      end

    %{action: action_atom, params: params}
  end

  # Merges params for actions of the same type
  defp merge_action_params(action_type, actions, cost_opts) do
    params_list = Enum.map(actions, & &1.params)

    # Get all unique param keys across all actions
    all_keys =
      params_list
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()

    # Merge each param using the action's consensus rule
    case Schema.get_schema(action_type) do
      {:ok, schema} ->
        merge_params_with_rules(action_type, all_keys, params_list, schema, cost_opts)

      {:error, _} ->
        {:error, :unknown_action}
    end
  end

  defp merge_params_with_rules(action_type, keys, params_list, schema, cost_opts) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      # Collect values for this param from all actions (filter out nils)
      values =
        params_list
        |> Enum.map(&Map.get(&1, key))
        |> Enum.reject(&is_nil/1)

      if values == [] do
        # No values for this param - skip
        {:cont, {:ok, acc}}
      else
        # Get the consensus rule for this param
        rule = Map.get(schema.consensus_rules, key, :exact_match)

        case apply_rule(rule, values, cost_opts) do
          {:ok, merged_value} ->
            {:cont, {:ok, Map.put(acc, key, merged_value)}}

          {:error, _} ->
            {:halt, {:error, :no_consensus}}
        end
      end
    end)
    |> case do
      {:ok, merged_params} -> {:ok, %{action: action_type, params: merged_params}}
      error -> error
    end
  end
end
