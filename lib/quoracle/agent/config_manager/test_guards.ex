defmodule Quoracle.Agent.ConfigManager.TestGuards do
  @moduledoc """
  Test-only validation guards for ConfigManager.
  Extracted to keep ConfigManager under 500 lines.
  """

  # Dialyzer: test branch returns nil (implicit if), dev branch returns :ok.
  # Spec says :ok. Suppress in-module to avoid cross-environment unnecessary skips.
  @dialyzer :no_contracts

  @doc """
  Validates that tests don't use the global PubSub instance.
  Only active in test environment - no-op in dev/prod.
  """
  @spec validate_pubsub_isolation(map(), atom()) :: :ok
  if Mix.env() == :test do
    def validate_pubsub_isolation(config, pubsub) do
      if pubsub == Quoracle.PubSub do
        raise """
        Agent #{config[:agent_id]} attempted to use global Quoracle.PubSub in test environment!

        This causes cross-test contamination. You MUST inject an isolated PubSub instance:

          # In setup:
          pubsub = :"test_pubsub_\#{System.unique_integer([:positive])}"
          start_supervised({Phoenix.PubSub, name: pubsub})

          # When creating agent:
          config = %{
            agent_id: agent_id,
            pubsub: pubsub,  # <- Add this
            registry: test_registry,
            ...
          }

        Or use Test.IsolationHelpers.create_isolated_deps() for all dependencies.
        See test/quoracle/agent/core_pubsub_test.exs for examples.
        """
      end
    end
  else
    def validate_pubsub_isolation(_config, _pubsub), do: :ok
  end
end
