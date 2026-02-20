defmodule Quoracle.Models.Embeddings.CostHelper do
  @moduledoc """
  Cost computation and recording helpers for embedding operations.
  Extracted from Embeddings to keep the main module under 500 lines.
  """

  alias Quoracle.Costs.Accumulator
  alias Quoracle.Models.ConfigModelSettings
  alias Quoracle.Models.ModelQuery.UsageHelper

  @doc """
  Computes embedding cost from LLMDB pricing for a model_spec and usage map.
  Returns a Decimal cost or nil if the model has no pricing data.
  """
  @spec compute_embedding_cost(String.t(), map()) :: Decimal.t() | nil
  def compute_embedding_cost(model_spec, usage) when is_binary(model_spec) do
    input_tokens = Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0

    case ReqLLM.model(model_spec) do
      {:ok, %{cost: %{input: cost_per_million}}} when not is_nil(cost_per_million) ->
        "#{cost_per_million}"
        |> Decimal.new()
        |> Decimal.mult(input_tokens)
        |> Decimal.div(1_000_000)

      _ ->
        nil
    end
  end

  @doc """
  Record cost directly for a non-cached embedding via UsageHelper.
  """
  @spec record_cost(map(), integer(), map()) :: :ok
  def record_cost(options, chunks, usage) do
    model_spec = resolve_configured_model_spec()

    # Compute cost from LLMDB pricing and inject into usage for UsageHelper
    input_tokens = get_in(usage, ["usage", "prompt_tokens"]) || 0
    total_cost = compute_embedding_cost(model_spec, %{input_tokens: input_tokens})

    usage_with_cost =
      if total_cost do
        %{usage | "usage" => Map.put(usage["usage"] || %{}, "total_cost", total_cost)}
      else
        usage
      end

    cost_options = %{
      agent_id: Map.get(options, :agent_id),
      task_id: Map.get(options, :task_id),
      pubsub: Map.get(options, :pubsub),
      model_spec: model_spec
    }

    extra_metadata = %{chunks: chunks, cached: false}

    UsageHelper.record_single_request(
      usage_with_cost,
      "llm_embedding",
      cost_options,
      extra_metadata
    )
  end

  @doc """
  Accumulate cost entry instead of recording directly (R14-R16).
  Returns updated accumulator.
  """
  @spec accumulate_cost(Accumulator.t(), map(), integer(), map()) :: Accumulator.t()
  def accumulate_cost(acc, options, chunks, usage) do
    model_spec = resolve_configured_model_spec()

    input_tokens = get_in(usage, ["usage", "prompt_tokens"]) || 0
    total_cost = compute_embedding_cost(model_spec, %{input_tokens: input_tokens})

    entry = %{
      agent_id: Map.get(options, :agent_id),
      task_id: Map.get(options, :task_id),
      cost_type: "llm_embedding",
      cost_usd: total_cost,
      metadata: %{
        "model_spec" => model_spec,
        "chunks" => chunks,
        "cached" => false
      }
    }

    Accumulator.add(acc, entry)
  end

  # Resolve the configured embedding model spec, falling back to "unknown".
  @spec resolve_configured_model_spec() :: String.t()
  defp resolve_configured_model_spec do
    case ConfigModelSettings.get_embedding_model() do
      {:ok, model_id} -> model_id
      _ -> "unknown"
    end
  end
end
