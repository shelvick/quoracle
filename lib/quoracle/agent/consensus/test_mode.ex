defmodule Quoracle.Agent.Consensus.TestMode do
  @moduledoc """
  Handles test mode detection and configuration for consensus operations.
  Centralizes all test-related flags and provides a clean interface
  for determining when to use mock responses vs real LLM queries.
  """

  @test_flags [
    :simulate_failure,
    :simulate_no_majority,
    :force_no_consensus,
    :simulate_tie,
    :force_max_rounds,
    :simulate_refinement_failure,
    :simulate_partial_failure,
    :track_refinement,
    :seed
  ]

  @doc """
  Determines if test mode is enabled based on options.

  Returns true if:
  - test_mode option is explicitly set to true
  - Any simulation/test flags are present
  """
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts) do
    # Explicit test_mode takes precedence
    case Keyword.fetch(opts, :test_mode) do
      {:ok, value} -> value
      :error -> has_test_flags?(opts)
    end
  end

  @doc """
  Returns all recognized test flags.
  """
  @spec test_flags() :: list(atom())
  def test_flags, do: @test_flags

  @doc """
  Extracts only test-related options from a keyword list.
  """
  @spec extract_test_options(keyword()) :: keyword()
  def extract_test_options(opts) do
    Enum.filter(opts, fn {key, _} ->
      key == :test_mode or key in @test_flags
    end)
  end

  @doc """
  Removes test-related options from a keyword list.
  """
  @spec strip_test_options(keyword()) :: keyword()
  def strip_test_options(opts) do
    Enum.reject(opts, fn {key, _} ->
      key == :test_mode or key in @test_flags
    end)
  end

  @doc """
  Maps test flags to query behavior options.
  Priority order matters - first matching flag wins.
  """
  @spec build_test_options(keyword()) :: map()
  def build_test_options(opts) do
    cond do
      opts[:simulate_failure] -> %{force_failure: true}
      opts[:simulate_no_majority] || opts[:force_no_consensus] -> %{diverse_responses: true}
      opts[:simulate_tie] -> %{force_tie: true}
      opts[:force_max_rounds] || opts[:simulate_refinement_failure] -> %{no_convergence: true}
      opts[:simulate_partial_failure] -> %{partial_failure: true}
      opts[:seed] -> %{seed: opts[:seed]}
      true -> %{}
    end
  end

  # Private helpers

  defp has_test_flags?(opts) do
    Enum.any?(@test_flags, &Keyword.has_key?(opts, &1))
  end
end
