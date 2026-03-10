defmodule Quoracle.Agent.ConfigManager.ConfigHelpers do
  @moduledoc """
  Utility helpers for agent configuration building, injection, and validation.

  Extracted from ConfigManager to keep the main module under 500 lines.
  These functions handle dependency injection patterns used primarily
  in test setup and agent-to-child configuration propagation.
  """

  @doc """
  Build agent configuration with dependency injection.
  Requires pubsub and registry in deps - no defaults.
  """
  @spec build_agent_config(map(), map()) :: map()
  def build_agent_config(base_config, deps) do
    unless deps[:pubsub], do: raise("pubsub is required in deps")
    unless deps[:registry], do: raise("registry is required in deps")

    # Use Map.put_new to avoid overwriting existing values
    base_config
    |> Map.put_new(:pubsub, deps[:pubsub])
    |> Map.put_new(:registry, deps[:registry])
    |> Map.put_new(:dynsup, deps[:dynsup])
  end

  @doc """
  Inject dependencies into configuration.
  """
  @spec inject_dependencies(map(), map()) :: map()
  def inject_dependencies(config, deps) do
    # Use Map.put_new to avoid overwriting
    Enum.reduce(deps, config, fn {key, value}, acc ->
      Map.put_new(acc, key, value)
    end)
  end

  @doc """
  Propagate parent configuration to child.
  """
  @spec propagate_to_children(map(), map()) :: map()
  def propagate_to_children(parent_config, child_base) do
    # Child can override inherited values
    parent_config
    |> Map.take([:pubsub, :registry, :dynsup])
    |> Map.merge(child_base)
  end

  @doc """
  Validate configuration including pubsub.
  """
  @spec validate_config(map()) :: :ok | {:error, atom()}
  def validate_config(config) do
    cond do
      not Map.has_key?(config, :agent_id) ->
        {:error, :missing_agent_id}

      config[:pubsub] && not is_atom(config[:pubsub]) ->
        {:error, :invalid_pubsub}

      true ->
        :ok
    end
  end
end
