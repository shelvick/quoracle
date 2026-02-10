defmodule Quoracle.Consensus.Aggregator.ParamMatching do
  @moduledoc """
  Parameter matching functions for consensus clustering.
  Extracted from Aggregator to keep module under 500 lines.
  """

  @doc "Check if params match according to consensus rules."
  @spec params_match?(map(), map(), map()) :: boolean()
  def params_match?(params1, params2, consensus_rules) do
    Enum.all?(consensus_rules, fn {param, rule} ->
      # Handle both string and atom keys since LLM responses have string keys
      param_str = Atom.to_string(param)
      val1 = Map.get(params1, param) || Map.get(params1, param_str)
      val2 = Map.get(params2, param) || Map.get(params2, param_str)

      param_values_match?(val1, val2, rule)
    end)
  end

  defp param_values_match?(nil, nil, _rule), do: true
  defp param_values_match?(nil, _val2, _rule), do: false
  defp param_values_match?(_val1, nil, _rule), do: false

  defp param_values_match?(val1, val2, rule) do
    case rule do
      :exact_match ->
        val1 == val2

      {:semantic_similarity, opts} ->
        threshold = opts[:threshold] || 0.9
        semantic_match_with_embeddings?(val1, val2, threshold)

      _ ->
        # For other rules, exact match for clustering
        val1 == val2
    end
  end

  defp semantic_match_with_embeddings?(str1, str2, threshold)
       when is_binary(str1) and is_binary(str2) do
    # Use simplified matching for basic similarity
    norm1 = normalize_semantic_string(str1, threshold)
    norm2 = normalize_semantic_string(str2, threshold)

    if norm1 == norm2 do
      true
    else
      # Use key term overlap as approximation
      terms1 = String.split(norm1, "_") |> MapSet.new()
      terms2 = String.split(norm2, "_") |> MapSet.new()

      intersection = MapSet.intersection(terms1, terms2) |> MapSet.size()
      union = MapSet.union(terms1, terms2) |> MapSet.size()

      if union == 0 do
        true
      else
        intersection / union >= threshold * 0.8
      end
    end
  end

  defp semantic_match_with_embeddings?(_val1, _val2, _threshold), do: false

  defp normalize_semantic_string(str, _threshold) do
    str
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
    |> Enum.sort()
    |> Enum.take(5)
    |> Enum.join("_")
  end
end
