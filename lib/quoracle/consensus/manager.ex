defmodule Quoracle.Consensus.Manager do
  @moduledoc """
  Configuration management for consensus operations.
  Stateless module providing model pools and consensus parameters.
  Agents call this synchronously and are allowed to block.

  Model pool comes from profile (required for all tasks/spawns).
  Passed via opts[:model_pool] - no global fallback.
  """

  # Simple majority
  @default_threshold 0.5
  # For refinement history
  @sliding_window_size 2

  # Default model pool for tests (avoids requiring profile injection)
  @test_model_pool [
    "mock:consensus-model-1",
    "mock:consensus-model-2",
    "mock:consensus-model-3"
  ]

  @doc """
  Returns the default test model pool for use in test opts.
  """
  @spec test_model_pool() :: [String.t()]
  def test_model_pool, do: @test_model_pool

  @doc """
  Get the model pool for consensus.

  Resolution order:
  1. opts[:model_pool] - explicit injection (from profile, required in production)
  2. opts[:test_mode] - returns mock test pool for test isolation
  3. Raises RuntimeError if neither provided (model_pool must come from profile)
  """
  @spec get_model_pool(keyword()) :: [String.t()]
  def get_model_pool(opts \\ []) do
    case Keyword.get(opts, :model_pool) do
      nil ->
        # Check test_mode (DI pattern for test isolation)
        if Keyword.get(opts, :test_mode, false) do
          test_model_pool()
        else
          # Production path - model_pool must come from profile
          raise RuntimeError,
                "model_pool not provided. Profile is required - model_pool must be passed via opts."
        end

      models when is_list(models) ->
        # Explicit model_pool injection from profile - use directly
        models
    end
  end

  @doc """
  Get consensus threshold (>50% required).
  Returns the simple majority threshold.
  """
  @spec get_consensus_threshold() :: float()
  def get_consensus_threshold do
    @default_threshold
  end

  @doc """
  Get sliding window size for refinement history.
  Returns the number of rounds to keep in history.
  """
  @spec get_sliding_window_size() :: integer()
  def get_sliding_window_size do
    @sliding_window_size
  end

  @doc """
  Build initial consensus context.
  Creates a new context map with prompt, history, and metadata.

  Accepts optional `opts` keyword list:
  - `:max_refinement_rounds` - max rounds for consensus (default: 4)
  """
  @spec build_context(String.t(), list(), keyword()) :: map()
  def build_context(prompt, conversation_history, opts \\ []) do
    %{
      prompt: prompt,
      conversation_history: conversation_history,
      # Will accumulate reasoning from each round
      reasoning_history: [],
      # Track proposals from each round
      round_proposals: [],
      start_time: System.monotonic_time(:millisecond),
      max_refinement_rounds: Keyword.get(opts, :max_refinement_rounds, 4)
    }
  end

  @doc """
  Build consensus context with ACE lessons and state.
  Used when querying models with accumulated knowledge.

  Accepts optional `opts` keyword list, propagated to `build_context/3`.
  """
  @spec build_context_with_ace(String.t(), list(), [map()], map() | nil, keyword()) :: map()
  def build_context_with_ace(prompt, model_history, lessons, model_state, opts \\ []) do
    base_context = build_context(prompt, model_history, opts)

    base_context
    |> Map.put(:lessons, lessons)
    |> Map.put(:model_state, model_state)
  end

  @doc """
  Update context with refinement round.
  Adds response context (action + params + reasoning) to sliding window.
  Tracks proposals for audit (action + params only).
  """
  @spec update_context_with_round(map(), integer(), list()) :: map()
  def update_context_with_round(context, round, responses) do
    # Extract full response context (action + params + reasoning) for history
    response_context =
      Enum.map(responses, fn r ->
        %{
          action: r[:action],
          params: r[:params] || %{},
          reasoning: r[:reasoning]
        }
      end)

    # Keep sliding window of response context (last N rounds)
    window_size = get_sliding_window_size()

    updated_reasoning =
      (context.reasoning_history ++ [response_context])
      |> Enum.take(-window_size)

    # Track proposals for audit trail
    proposals =
      Enum.map(responses, fn r ->
        %{action: r[:action], params: r[:params] || %{}}
      end)

    %{
      context
      | reasoning_history: updated_reasoning,
        round_proposals: context.round_proposals ++ [{round, proposals}]
    }
  end
end
