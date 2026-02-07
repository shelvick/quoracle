defmodule Quoracle.Actions.Orient do
  @moduledoc """
  Strategic reflection action for agent self-assessment.
  Broadcasts events through PubSub for UI updates.
  """

  alias Quoracle.PubSub.AgentEvents

  @required_params [:current_situation, :goal_clarity, :available_resources, :key_challenges]

  # Ensure the atoms exist for String.to_existing_atom/1
  _ = [
    :current_situation,
    :goal_clarity,
    :available_resources,
    :key_challenges,
    :delegation_consideration
  ]

  @doc """
  Processes strategic reflection parameters and returns formatted assessment.
  Accepts optional opts keyword list for dependency injection (e.g., :pubsub).
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def execute(params, agent_id, opts \\ []) do
    pubsub = Keyword.fetch!(opts, :pubsub)

    # Validate required parameters
    case validate_params(params) do
      :ok ->
        # Generate reflection
        reflection = generate_reflection(params)
        timestamp = DateTime.utc_now()

        # Determine log level
        level = if params[:detailed_analysis] == true, do: :debug, else: :info

        # Build metadata
        metadata = build_metadata(params, reflection, timestamp)

        # Broadcast as log entry with explicit pubsub
        AgentEvents.broadcast_log(
          agent_id,
          level,
          "Orientation complete",
          metadata,
          pubsub
        )

        {:ok, %{action: "orient"}}

      {:error, reason} ->
        # Broadcast error log with explicit pubsub
        AgentEvents.broadcast_log(
          agent_id,
          :error,
          "Orient failed",
          %{error: reason, action: "orient"},
          pubsub
        )

        {:error, reason}
    end
  end

  defp validate_params(params) do
    params_map = normalize_keys(params)

    missing = Enum.reject(@required_params, &Map.has_key?(params_map, &1))

    cond do
      missing != [] ->
        {:error, :missing_required_param}

      Enum.any?(@required_params, fn key ->
        params_map[key] == nil || params_map[key] == ""
      end) ->
        {:error, :empty_required_params}

      true ->
        :ok
    end
  end

  defp normalize_keys(params) do
    params
    |> Enum.map(fn {k, v} -> {to_atom_key(k), v} end)
    |> Map.new()
  end

  defp to_atom_key(key) when is_atom(key), do: key

  defp to_atom_key(key) when is_binary(key) do
    # Use existing atoms only to prevent memory leaks
    String.to_existing_atom(key)
  rescue
    # Keep as string if atom doesn't exist
    ArgumentError -> key
  end

  defp generate_reflection(params) do
    params_map = normalize_keys(params)

    # Generate reflection based on energy level if present
    base_reflection =
      "Based on the current situation: #{params_map.current_situation}, " <>
        "with goal clarity: #{params_map.goal_clarity}, " <>
        "available resources: #{params_map.available_resources}, " <>
        "and key challenges: #{params_map.key_challenges}"

    # Adapt tone based on energy level
    case params_map[:energy_level] do
      "Low" ->
        base_reflection <> ". Proceeding with methodical and careful approach to conserve energy."

      "High" ->
        base_reflection <> ". Ready to tackle challenges with full engagement."

      _ ->
        base_reflection <> ". Moving forward with balanced consideration."
    end
  end

  defp build_metadata(params, reflection, timestamp) do
    params_map = normalize_keys(params)

    base_metadata = %{
      action: "orient",
      reflection: reflection,
      orientation_timestamp: timestamp
    }

    # Add all parameters to metadata
    Enum.reduce(params_map, base_metadata, fn {k, v}, acc ->
      Map.put(acc, k, v)
    end)
  end
end
