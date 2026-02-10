defmodule Quoracle.Agent.ConfigManager.ModelPoolInit do
  @moduledoc """
  Model pool initialization helpers for ConfigManager.
  Extracted to maintain <500 line modules.
  """

  alias Quoracle.Consensus.Manager

  @doc """
  Gets model pool for initializing per-model histories.
  Priority: explicit model_pool > test_mode pool > production DB query.
  """
  @spec get_model_pool_for_init(map(), boolean()) :: list()
  def get_model_pool_for_init(config, test_mode) do
    cond do
      # Explicit model_pool in config takes highest priority
      Map.has_key?(config, :model_pool) && config.model_pool != nil ->
        config.model_pool

      # Test mode uses Manager.test_model_pool()
      test_mode ->
        Manager.test_model_pool()

      # Production mode queries DB (may raise if not configured)
      true ->
        Manager.get_model_pool()
    end
  end

  @doc """
  Initializes model_histories map with empty list for each model.
  """
  @spec initialize_model_histories(list()) :: map()
  def initialize_model_histories(model_pool) do
    Map.new(model_pool, fn model_id -> {model_id, []} end)
  end
end
