defmodule Quoracle.Consensus.TemperatureTest do
  @moduledoc """
  Tests for CONSENSUS_Temperature.

  Tests the descending temperature strategy for consensus rounds.
  High-temp families (gpt, o1, o3, o4, gemini) get max 2.0.
  All other models get max 1.0.

  Temperature descends by 20% of max per round, clamped to floor.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Consensus.Temperature

  # =============================================================================
  # R1-R5: High-Temp Family Detection
  # =============================================================================

  describe "high-temp family detection" do
    # R1: GPT Family Detection
    test "detects gpt family models" do
      assert Temperature.high_temp_family?("gpt-4o")
      assert Temperature.high_temp_family?("gpt-4o-mini")
      assert Temperature.high_temp_family?("gpt-3.5-turbo")
      assert Temperature.high_temp_family?("gpt-5")
    end

    # R2: O-Series Detection
    test "detects o-series reasoning models" do
      assert Temperature.high_temp_family?("o1")
      assert Temperature.high_temp_family?("o1-preview")
      assert Temperature.high_temp_family?("o1-mini")
      assert Temperature.high_temp_family?("o3")
      assert Temperature.high_temp_family?("o3-mini")
      assert Temperature.high_temp_family?("o4-mini")
    end

    # R3: Gemini Detection
    test "detects gemini family models" do
      assert Temperature.high_temp_family?("gemini-2.0-flash")
      assert Temperature.high_temp_family?("gemini-2.5-pro")
      assert Temperature.high_temp_family?("gemini-1.5-pro")
      assert Temperature.high_temp_family?("gemini-pro")
    end

    # R4: Non-High-Temp Families
    test "returns false for non-high-temp families" do
      refute Temperature.high_temp_family?("claude-sonnet-4")
      refute Temperature.high_temp_family?("claude-3-opus")
      refute Temperature.high_temp_family?("llama-3")
      refute Temperature.high_temp_family?("llama-70b")
      refute Temperature.high_temp_family?("mistral-large")
      refute Temperature.high_temp_family?("unknown-model")
    end

    # R5: Case Insensitivity
    test "family detection is case insensitive" do
      assert Temperature.high_temp_family?("GPT-4o")
      assert Temperature.high_temp_family?("Gpt-4o")
      assert Temperature.high_temp_family?("GEMINI-2.0-flash")
      assert Temperature.high_temp_family?("Gemini-Pro")
      assert Temperature.high_temp_family?("O1-preview")
      assert Temperature.high_temp_family?("O3")
    end
  end

  # =============================================================================
  # R6-R12: Max Temperature Lookup
  # =============================================================================

  describe "get_max_temperature/1" do
    # R6: Max Temp for High-Temp Models
    test "returns 2.0 for gpt models" do
      assert Temperature.get_max_temperature("openai:gpt-4o") == 2.0
      assert Temperature.get_max_temperature("openai:gpt-4o-mini") == 2.0
    end

    # R7: Max Temp for Low-Temp Models
    test "returns 1.0 for claude models" do
      assert Temperature.get_max_temperature("anthropic:claude-sonnet-4") == 1.0
      assert Temperature.get_max_temperature("anthropic:claude-3-opus") == 1.0
    end

    # R8: Max Temp Azure GPT
    test "azure gpt models get max temp 2.0" do
      assert Temperature.get_max_temperature("azure:gpt-4o") == 2.0
      assert Temperature.get_max_temperature("azure:gpt-4") == 2.0
      assert Temperature.get_max_temperature("azure:o1") == 2.0
      assert Temperature.get_max_temperature("azure:o3") == 2.0
    end

    # R9: Max Temp Azure Non-GPT
    test "azure non-gpt models get max temp 1.0" do
      assert Temperature.get_max_temperature("azure:llama-3") == 1.0
      assert Temperature.get_max_temperature("azure:mistral-large") == 1.0
    end

    # R10: Max Temp Google Vertex Gemini
    test "google vertex gemini models get max temp 2.0" do
      assert Temperature.get_max_temperature("google-vertex:gemini-2.5-pro") == 2.0
      assert Temperature.get_max_temperature("google-vertex:gemini-2.0-flash") == 2.0
    end

    # R11: Max Temp Google Vertex Non-Gemini
    test "google vertex non-gemini models get max temp 1.0" do
      assert Temperature.get_max_temperature("google-vertex:claude-3-opus") == 1.0
      assert Temperature.get_max_temperature("google-vertex:llama-3") == 1.0
    end

    # R12: Invalid Model Spec
    test "returns 1.0 for invalid model_spec" do
      assert Temperature.get_max_temperature(nil) == 1.0
      assert Temperature.get_max_temperature("") == 1.0
      assert Temperature.get_max_temperature("invalid") == 1.0
      assert Temperature.get_max_temperature(123) == 1.0
    end
  end

  # =============================================================================
  # R13-R19: Round Temperature Calculation
  # =============================================================================

  describe "calculate_round_temperature/2" do
    # R13: Round 1 Temperature
    test "round 1 returns max temperature" do
      # High-temp model
      assert Temperature.calculate_round_temperature("openai:gpt-4o", 1) == 2.0
      # Low-temp model
      assert Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", 1) == 1.0
    end

    # R14: Descending Temperature
    test "temperature descends by 20% of max per round" do
      # High-temp model (max=2.0, step=0.4)
      assert Temperature.calculate_round_temperature("openai:gpt-4o", 1) == 2.0
      assert Temperature.calculate_round_temperature("openai:gpt-4o", 2) == 1.6
      assert Temperature.calculate_round_temperature("openai:gpt-4o", 3) == 1.2

      # Low-temp model (max=1.0, step=0.2)
      assert Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", 1) == 1.0
      assert Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", 2) == 0.8
      assert Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", 3) == 0.6
    end

    # R15: Min Temp Floor (Low)
    test "low-temp models clamp to 0.2 floor" do
      # Round 5 should hit exactly 0.2
      assert Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", 5) == 0.2
      # Round 6+ should still be 0.2 (clamped)
      assert Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", 6) == 0.2
      assert Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", 10) == 0.2
    end

    # R16: Min Temp Floor (High)
    test "high-temp models clamp to 0.4 floor" do
      # Round 5 should hit exactly 0.4
      assert Temperature.calculate_round_temperature("openai:gpt-4o", 5) == 0.4
      # Round 6+ should still be 0.4 (clamped)
      assert Temperature.calculate_round_temperature("openai:gpt-4o", 6) == 0.4
      assert Temperature.calculate_round_temperature("openai:gpt-4o", 10) == 0.4
    end

    # R17: Full Descent Low-Temp Model
    test "full temperature descent for low-temp model" do
      model = "anthropic:claude-sonnet-4"
      temps = for round <- 1..5, do: Temperature.calculate_round_temperature(model, round)
      assert temps == [1.0, 0.8, 0.6, 0.4, 0.2]
    end

    # R18: Full Descent High-Temp Model
    test "full temperature descent for high-temp model" do
      model = "openai:gpt-4o"
      temps = for round <- 1..5, do: Temperature.calculate_round_temperature(model, round)
      assert temps == [2.0, 1.6, 1.2, 0.8, 0.4]
    end

    # R19: Invalid Round
    test "invalid round returns max temperature" do
      # Round 0
      assert Temperature.calculate_round_temperature("openai:gpt-4o", 0) == 2.0
      # Negative round
      assert Temperature.calculate_round_temperature("openai:gpt-4o", -1) == 2.0
      # Non-integer (handled by guard)
      assert Temperature.calculate_round_temperature("openai:gpt-4o", 1.5) == 2.0
    end
  end

  # =============================================================================
  # R20-R21: Model Name Extraction
  # =============================================================================

  describe "get_model_name/1" do
    # R20: Extract Model Name
    test "extracts model name from model_spec" do
      assert Temperature.get_model_name("openai:gpt-4o") == "gpt-4o"
      assert Temperature.get_model_name("anthropic:claude-sonnet-4") == "claude-sonnet-4"
      assert Temperature.get_model_name("azure:gpt-4o-mini") == "gpt-4o-mini"
      assert Temperature.get_model_name("google-vertex:gemini-2.5-pro") == "gemini-2.5-pro"
    end

    # R21: Invalid Format
    test "returns original string for invalid format" do
      assert Temperature.get_model_name("no-colon-here") == "no-colon-here"
      assert Temperature.get_model_name("gpt-4o") == "gpt-4o"
      assert Temperature.get_model_name("") == ""
    end
  end

  # =============================================================================
  # Additional Edge Cases
  # =============================================================================

  describe "edge cases" do
    test "handles all high-temp prefixes across providers" do
      # GPT family across providers
      assert Temperature.get_max_temperature("openai:gpt-4") == 2.0
      assert Temperature.get_max_temperature("azure:gpt-4") == 2.0

      # Gemini across providers
      assert Temperature.get_max_temperature("google:gemini-pro") == 2.0
      assert Temperature.get_max_temperature("google-vertex:gemini-2.0-flash") == 2.0

      # O-series across providers
      assert Temperature.get_max_temperature("openai:o1") == 2.0
      assert Temperature.get_max_temperature("azure:o3") == 2.0
      assert Temperature.get_max_temperature("openai:o4-mini") == 2.0
    end

    test "mixed model pool would get different temperatures" do
      # Simulating a mixed model pool at round 3
      round = 3
      gpt_temp = Temperature.calculate_round_temperature("azure:gpt-4o", round)
      claude_temp = Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", round)

      # GPT at round 3: 2.0 - (2 * 0.4) = 1.2
      assert gpt_temp == 1.2
      # Claude at round 3: 1.0 - (2 * 0.2) = 0.6
      assert claude_temp == 0.6

      # They should be different
      refute gpt_temp == claude_temp
    end
  end
end
