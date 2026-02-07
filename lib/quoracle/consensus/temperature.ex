defmodule Quoracle.Consensus.Temperature do
  @moduledoc """
  Temperature calculation for consensus rounds.

  Provides provider/family-based max temperature lookup and round-based
  temperature calculation. Starts creative (max temp) and converges toward
  deterministic (min temp) as consensus rounds progress.

  ## Temperature Tables

  **max=1.0 models (Anthropic, Bedrock, Llama, etc.):**
  | Round | Temperature |
  |-------|-------------|
  | 1     | 1.0         |
  | 2     | 0.8         |
  | 3     | 0.6         |
  | 4     | 0.4         |
  | 5     | 0.2         |

  **max=2.0 models (GPT, O-series, Gemini):**
  | Round | Temperature |
  |-------|-------------|
  | 1     | 2.0         |
  | 2     | 1.6         |
  | 3     | 1.2         |
  | 4     | 0.8         |
  | 5     | 0.4         |
  """

  @high_temp_families ["gpt", "o1", "o3", "o4", "gemini"]
  @max_temp_high 2.0
  @max_temp_low 1.0
  @min_temp_high 0.4
  @min_temp_low 0.2

  @doc """
  Check if model belongs to a high-temperature family.

  High-temp families: gpt, o1, o3, o4, gemini
  Detection is case-insensitive.
  """
  @spec high_temp_family?(String.t()) :: boolean()
  def high_temp_family?(model_name) when is_binary(model_name) do
    model_lower = String.downcase(model_name)

    Enum.any?(@high_temp_families, fn family ->
      String.starts_with?(model_lower, family)
    end)
  end

  def high_temp_family?(_), do: false

  @doc """
  Get max temperature for a model based on its family.

  Returns 2.0 for high-temp families (GPT, O-series, Gemini),
  1.0 for all others (conservative default).
  """
  @spec get_max_temperature(String.t() | nil) :: float()
  def get_max_temperature(model_spec) when is_binary(model_spec) and model_spec != "" do
    model_name = get_model_name(model_spec)

    if high_temp_family?(model_name) do
      @max_temp_high
    else
      @max_temp_low
    end
  end

  def get_max_temperature(_), do: @max_temp_low

  @doc """
  Calculate temperature for a specific consensus round.

  Temperature descends by 20% of max per round:
  - Round 1: max_temp
  - Round 2: max_temp - (max_temp * 0.2)
  - Round 3: max_temp - (max_temp * 0.4)
  - etc.

  Clamped to floor (0.4 for max=2.0, 0.2 for max=1.0).
  """
  @spec calculate_round_temperature(String.t() | nil, integer()) :: float()
  def calculate_round_temperature(model_spec, round)
      when is_integer(round) and round >= 1 do
    max_temp = get_max_temperature(model_spec)
    min_temp = if max_temp == @max_temp_high, do: @min_temp_high, else: @min_temp_low
    step = max_temp * 0.2

    calculated = max_temp - (round - 1) * step
    # Round to 1 decimal place to avoid floating point precision issues
    Float.round(max(min_temp, calculated), 1)
  end

  def calculate_round_temperature(model_spec, _round) do
    # Invalid round - return max temp as safe default
    get_max_temperature(model_spec)
  end

  @doc """
  Extract model name from model_spec.

  Examples:
  - "openai:gpt-4o" -> "gpt-4o"
  - "azure:gpt-4o-mini" -> "gpt-4o-mini"
  - "gpt-4o" -> "gpt-4o" (no colon, return as-is)
  """
  @spec get_model_name(String.t()) :: String.t()
  def get_model_name(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [_provider, model_name] -> model_name
      [model_only] -> model_only
    end
  end

  def get_model_name(_), do: ""
end
