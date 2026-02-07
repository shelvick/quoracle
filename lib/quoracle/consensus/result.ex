defmodule Quoracle.Consensus.Result do
  @moduledoc """
  Formats consensus results with confidence scoring and tiebreaking.
  Always returns exactly ONE action decision, never alternatives.
  """

  require Logger

  alias Quoracle.Actions.{ConsensusRules, Schema}
  alias Quoracle.Consensus.Result.Scoring

  # Delegate scoring functions to extracted module (API compatibility)
  defdelegate break_tie(clusters), to: Scoring
  defdelegate wait_score(value), to: Scoring
  defdelegate auto_complete_score(value), to: Scoring
  defdelegate cluster_wait_score(cluster), to: Scoring
  defdelegate cluster_auto_complete_score(cluster), to: Scoring

  @doc """
  Formats the final consensus result from clustered responses.
  Returns either {:consensus, action, opts} or {:forced_decision, action, opts}.
  Always returns exactly ONE action - never multiple options.

  When cost_opts includes :cost_accumulator, the returned opts will include
  :accumulator with all embedding costs from semantic_similarity merging.
  """
  @spec format_result([map()], integer(), integer(), keyword()) ::
          {:consensus, map(), keyword()} | {:forced_decision, map(), keyword()}
  def format_result(clusters, total_count, round_num, cost_opts \\ []) do
    case find_winner(clusters, total_count) do
      {:majority, cluster} ->
        {action, accumulator} = merge_cluster_params(cluster, cost_opts)
        confidence = calculate_confidence(cluster, total_count, round_num)
        {:consensus, action, build_result_opts(confidence, accumulator)}

      {:plurality, cluster} ->
        {action, accumulator} = merge_cluster_params(cluster, cost_opts)
        confidence = calculate_confidence(cluster, total_count, round_num)
        {:forced_decision, action, build_result_opts(confidence, accumulator)}
    end
  end

  defp build_result_opts(confidence, nil), do: [confidence: confidence]

  defp build_result_opts(confidence, accumulator),
    do: [confidence: confidence, accumulator: accumulator]

  @doc """
  Merges parameters within a cluster using schema-specific consensus rules.
  Returns {action, accumulator} tuple where accumulator contains embedding costs.
  For batch_sync, uses batch_sequence_merge rule for per-position merging.
  """
  @spec merge_cluster_params(map(), keyword()) ::
          {map(), Quoracle.Costs.Accumulator.t() | nil} | {:error, atom()}
  def merge_cluster_params(cluster, cost_opts \\ [])

  def merge_cluster_params(
        %{actions: actions, representative: %{action: :batch_sync}} = _cluster,
        cost_opts
      ) do
    # Extract action sequences from all responses (handle both atom and string keys)
    sequences =
      Enum.map(actions, fn action ->
        params = action.params || action[:params] || %{}
        params[:actions] || params["actions"] || []
      end)

    # batch_sync doesn't use semantic_similarity, so no accumulator threading needed
    initial_acc = Keyword.get(cost_opts, :cost_accumulator)

    case ConsensusRules.apply_rule(:batch_sequence_merge, sequences) do
      {:ok, merged_actions} ->
        build_batch_sync_action(actions, merged_actions, initial_acc)

      {:error, :no_consensus} ->
        # Fallback on param merge failure: use mode selection (matches non-batch_sync behavior)
        merged_actions = merge_sequences_with_mode(sequences)
        build_batch_sync_action(actions, merged_actions, initial_acc)

      {:error, reason} ->
        # Propagate structural errors (sequence_length_mismatch, sequence_mismatch, etc.)
        {:error, reason}
    end
  end

  def merge_cluster_params(%{actions: actions, representative: representative}, cost_opts) do
    action_type = representative.action

    case Schema.get_schema(action_type) do
      {:ok, schema} ->
        # Merge parameters according to consensus rules, threading accumulator
        {merged_params, final_acc} = merge_params_by_rules(actions, schema, cost_opts)

        # Extract wait values from actions for special handling
        wait_values =
          actions
          |> Enum.map(& &1[:wait])
          |> Enum.reject(&is_nil/1)

        # Extract auto_complete_todo values for consensus
        auto_complete_todo_values =
          actions
          |> Enum.map(& &1[:auto_complete_todo])
          |> Enum.reject(&is_nil/1)

        # Include reasoning (take first non-empty one)
        reasoning =
          actions
          |> Enum.map(& &1.reasoning)
          |> Enum.find("", &(&1 != ""))

        # Build result with wait at top level if present
        result = %{
          action: action_type,
          params: merged_params,
          reasoning: reasoning
        }

        # Add wait parameter at top level - default to false if all LLMs omit
        result =
          if Enum.empty?(wait_values) do
            Logger.warning("All LLMs omitted wait parameter - defaulting to wait: false")
            Map.put(result, :wait, false)
          else
            merged_wait = merge_wait_parameter(wait_values)
            Map.put(result, :wait, merged_wait)
          end

        # Add auto_complete_todo using conservative rule: any false → false
        action =
          if Enum.empty?(auto_complete_todo_values) do
            result
          else
            merged_auto_complete = merge_auto_complete_todo(auto_complete_todo_values)
            Map.put(result, :auto_complete_todo, merged_auto_complete)
          end

        {action, final_acc}

      {:error, :unknown_action} ->
        # Fallback for unknown actions - no accumulator threading
        initial_acc = Keyword.get(cost_opts, :cost_accumulator)
        {representative, initial_acc}
    end
  end

  # Builds batch_sync action with wait parameter and reasoning (DRY helper)
  defp build_batch_sync_action(actions, merged_actions, accumulator) do
    wait_values =
      actions
      |> Enum.map(& &1[:wait])
      |> Enum.reject(&is_nil/1)

    reasoning =
      actions
      |> Enum.map(&(&1[:reasoning] || &1.reasoning))
      |> Enum.find("", &(&1 != "" && !is_nil(&1)))

    result = %{
      action: :batch_sync,
      params: %{actions: merged_actions},
      reasoning: reasoning
    }

    action =
      if Enum.empty?(wait_values) do
        Logger.warning("All LLMs omitted wait parameter - defaulting to wait: false")
        Map.put(result, :wait, false)
      else
        merged_wait = merge_wait_parameter(wait_values)
        Map.put(result, :wait, merged_wait)
      end

    {action, accumulator}
  end

  # Fallback merging for batch_sync using mode selection
  defp merge_sequences_with_mode(sequences) do
    max_len = sequences |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    if max_len == 0 do
      []
    else
      0..(max_len - 1)
      |> Enum.map(&merge_position_with_mode(sequences, &1))
      |> Enum.reject(&is_nil/1)
    end
  end

  defp merge_position_with_mode(sequences, idx) do
    actions_at_pos =
      sequences
      |> Enum.map(&Enum.at(&1, idx))
      |> Enum.reject(&is_nil/1)

    case actions_at_pos do
      [] ->
        nil

      [single] ->
        normalize_action_map(single)

      multiple ->
        # Mode for action type
        action_type =
          multiple
          |> Enum.map(&(&1[:action] || &1["action"]))
          |> mode_value()

        # Filter to matching action type and merge params
        matching = Enum.filter(multiple, &((&1[:action] || &1["action"]) == action_type))
        all_params = Enum.map(matching, &(&1[:params] || &1["params"] || %{}))
        merged_params = merge_params_with_mode(all_params)

        %{action: action_type, params: merged_params}
    end
  end

  defp normalize_action_map(action) do
    action_type = action[:action] || action["action"]
    params = action[:params] || action["params"] || %{}
    %{action: action_type, params: normalize_param_keys(params)}
  end

  defp merge_params_with_mode(param_maps) do
    # Normalize all keys to atoms
    normalized_maps = Enum.map(param_maps, &normalize_param_keys/1)

    all_keys = normalized_maps |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()

    Enum.reduce(all_keys, %{}, fn key, acc ->
      values =
        normalized_maps
        |> Enum.map(&Map.get(&1, key))
        |> Enum.reject(&is_nil/1)

      if Enum.empty?(values) do
        acc
      else
        Map.put(acc, key, mode_value(values))
      end
    end)
  end

  # Normalize string keys to atoms for consistent merging.
  # Param names come from our schema definitions, so they exist as atoms.
  defp normalize_param_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Merge wait parameter using consensus rules
  defp merge_wait_parameter(values) do
    # Apply the wait_parameter consensus rule from ConsensusRules
    # The merge_params/3 function expects (action, param, values) where param must be :wait
    case Quoracle.Actions.ConsensusRules.merge_params(:wait, :wait, values) do
      {:ok, merged} -> merged
      # Fallback to first value
      {:error, _} -> hd(values)
    end
  end

  # Merge auto_complete_todo using conservative rule: any false → false
  defp merge_auto_complete_todo([]), do: false

  defp merge_auto_complete_todo(values) do
    if Enum.any?(values, &(&1 == false)), do: false, else: true
  end

  @doc """
  Calculates confidence score based on cluster size and round number.
  Returns a value between 0.1 and 1.0.
  """
  @spec calculate_confidence(map(), integer(), integer()) :: float()
  def calculate_confidence(%{count: cluster_count}, total_count, round_num) do
    # Base confidence from cluster proportion
    base_confidence = cluster_count / total_count

    # Bonus for strong majorities
    majority_bonus =
      cond do
        cluster_count / total_count > 0.8 -> 0.15
        cluster_count / total_count > 0.6 -> 0.10
        cluster_count / total_count > 0.5 -> 0.05
        true -> 0.0
      end

    # Penalty for later rounds (diminishing confidence)
    round_penalty = if round_num > 3, do: (round_num - 3) * 0.1, else: 0.0

    # Calculate final confidence
    confidence = base_confidence + majority_bonus - round_penalty

    # Clamp between 0.1 and 1.0
    confidence
    |> max(0.1)
    |> min(1.0)
  end

  # Private functions

  defp find_winner(clusters, total_count) do
    # Check for majority (>50%)
    majority =
      Enum.find(clusters, fn cluster ->
        cluster.count > total_count / 2
      end)

    if majority do
      {:majority, majority}
    else
      # Find plurality winner(s)
      max_count = clusters |> Enum.map(& &1.count) |> Enum.max()
      tied = Enum.filter(clusters, &(&1.count == max_count))

      # Break tie if needed
      winner = if length(tied) > 1, do: break_tie(tied), else: hd(tied)
      {:plurality, winner}
    end
  end

  # Threads accumulator through each param merge, returns {merged_params, final_accumulator}
  defp merge_params_by_rules(actions, schema, cost_opts) do
    all_params = Enum.map(actions, & &1.params)
    initial_acc = Keyword.get(cost_opts, :cost_accumulator)

    # Merge each parameter according to its rule, threading accumulator
    {merged_params, final_acc} =
      Enum.reduce(
        schema.required_params ++ schema.optional_params,
        {%{}, initial_acc},
        fn param, {params_acc, cost_acc} ->
          # Handle both string and atom keys since LLM responses have string keys
          param_str = Atom.to_string(param)

          values =
            all_params
            |> Enum.map(fn params ->
              Map.get(params, param) || Map.get(params, param_str)
            end)
            |> Enum.reject(&is_nil/1)

          if Enum.empty?(values) do
            {params_acc, cost_acc}
          else
            rule = Map.get(schema.consensus_rules, param, :mode_selection)

            # Build cost_opts with current accumulator for this iteration
            current_cost_opts =
              if cost_acc do
                Keyword.put(cost_opts, :cost_accumulator, cost_acc)
              else
                cost_opts
              end

            case ConsensusRules.apply_rule(rule, values, current_cost_opts) do
              {:ok, merged_value} ->
                {Map.put(params_acc, param, merged_value), cost_acc}

              # Handle accumulator return format - thread the updated accumulator
              {{:ok, merged_value}, %Quoracle.Costs.Accumulator{} = updated_acc} ->
                {Map.put(params_acc, param, merged_value), updated_acc}

              {{:error, _reason}, %Quoracle.Costs.Accumulator{} = updated_acc} ->
                # Fallback to mode selection, but keep the updated accumulator
                {Map.put(params_acc, param, mode_value(values)), updated_acc}

              {:error, _reason} ->
                # Fallback to mode selection
                {Map.put(params_acc, param, mode_value(values)), cost_acc}
            end
          end
        end
      )

    {merged_params, final_acc}
  end

  defp mode_value(values) do
    values
    |> Enum.frequencies()
    |> Enum.max_by(fn {_val, count} -> count end)
    |> elem(0)
  end
end
