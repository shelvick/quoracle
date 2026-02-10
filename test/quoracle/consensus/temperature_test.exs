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
      # High-temp model (max=2.0, default 4 rounds, step=1.6/3≈0.533)
      assert Temperature.calculate_round_temperature("openai:gpt-4o", 1) == 2.0
      assert Temperature.calculate_round_temperature("openai:gpt-4o", 2) == 1.5
      assert Temperature.calculate_round_temperature("openai:gpt-4o", 3) == 0.9

      # Low-temp model (max=1.0, default 4 rounds, step=0.8/3≈0.267)
      assert Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", 1) == 1.0
      assert Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", 2) == 0.7
      assert Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", 3) == 0.5
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
      # Default 4 rounds: reaches floor at round 4, round 5 stays at floor
      temps = for round <- 1..5, do: Temperature.calculate_round_temperature(model, round)
      assert temps == [1.0, 0.7, 0.5, 0.2, 0.2]
    end

    # R18: Full Descent High-Temp Model
    test "full temperature descent for high-temp model" do
      model = "openai:gpt-4o"
      # Default 4 rounds: reaches floor at round 4, round 5 stays at floor
      temps = for round <- 1..5, do: Temperature.calculate_round_temperature(model, round)
      assert temps == [2.0, 1.5, 0.9, 0.4, 0.4]
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
  # INTEGRATION AUDIT: Temperature descent adapted to max_refinement_rounds
  # WorkGroupID: feat-20260208-210722, Audit Fix
  #
  # Audit finding: Temperature descent is hardcoded at 20% per round (reaches
  # floor at round 5 regardless of profile's max_refinement_rounds). With max=2,
  # temperature barely descends. With max=9, temperature flatlines at floor for
  # rounds 6-9. The descent rate should scale to the configured max.
  # =============================================================================

  describe "calculate_round_temperature/3 opts" do
    test "adapts descent rate to max_refinement_rounds=2 for high-temp model" do
      # WHEN max_refinement_rounds=2, round 2 is the LAST round
      # THEN temperature should reach floor (0.4) by round 2
      # Currently: round 2 of gpt-4o = 1.6 (hardcoded 20% step, barely descends)
      temp =
        Temperature.calculate_round_temperature("openai:gpt-4o", 2, max_refinement_rounds: 2)

      assert temp == 0.4
    end

    test "adapts descent rate to max_refinement_rounds=9 for high-temp model" do
      # WHEN max_refinement_rounds=9, temperature should spread across all 9 rounds
      # THEN round 5 (middle) should NOT be at floor
      # Currently: round 5 = 0.4 (floor) due to hardcoded 20% step
      temp =
        Temperature.calculate_round_temperature("openai:gpt-4o", 5, max_refinement_rounds: 9)

      # With 9 rounds, round 5 is ~halfway, should be well above 0.4 floor
      assert temp > 0.4
    end

    test "adapts descent rate to max_refinement_rounds=3 for low-temp model" do
      # WHEN max_refinement_rounds=3, round 3 is the LAST round
      # THEN temperature should reach floor (0.2) by round 3
      # Currently: round 3 of claude = 0.6 (hardcoded 20% step)
      temp =
        Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", 3,
          max_refinement_rounds: 3
        )

      assert temp == 0.2
    end

    test "round 1 is always max temperature regardless of max_refinement_rounds" do
      # WHEN round=1, THEN always returns max temperature
      temp =
        Temperature.calculate_round_temperature("openai:gpt-4o", 1, max_refinement_rounds: 2)

      assert temp == 2.0
    end

    test "reaches floor at exactly max_refinement_rounds" do
      # WHEN round equals max_refinement_rounds
      # THEN temperature should be at or near floor
      temp_high =
        Temperature.calculate_round_temperature("openai:gpt-4o", 5, max_refinement_rounds: 5)

      temp_low =
        Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", 5,
          max_refinement_rounds: 5
        )

      assert temp_high == 0.4
      assert temp_low == 0.2
    end
  end

  # =============================================================================
  # INTEGRATION AUDIT: Default max_refinement_rounds alignment
  # WorkGroupID: feat-20260208-210722, Audit Finding
  #
  # Audit finding: Temperature.calculate_round_temperature/2 defaults
  # max_refinement_rounds to 5, but the rest of the system (Manager.build_context,
  # Result.calculate_confidence, Aggregator.build_refinement_prompt) all default
  # to 4. This means when no explicit max_refinement_rounds is passed, temperature
  # descent follows a 5-round curve while the consensus system expects a 4-round
  # curve. The defaults must be aligned.
  # =============================================================================

  describe "default max_rounds alignment" do
    test "2-arity reaches floor at round 4 (high-temp)" do
      # The system default is max_refinement_rounds=4 (Manager.build_context, Result, etc.)
      # Temperature's 2-arity (no opts) should also use 4, reaching floor at round 4
      # Currently: defaults to 5, so round 4 = 0.8 (NOT floor)
      temp = Temperature.calculate_round_temperature("openai:gpt-4o", 4)

      # With max_rounds=4: step = (2.0-0.4)/(4-1) = 0.533..., round 4 = floor = 0.4
      # With max_rounds=5 (bug): step = (2.0-0.4)/(5-1) = 0.4, round 4 = 2.0-3*0.4 = 0.8
      assert temp == 0.4
    end

    test "2-arity reaches floor at round 4 (low-temp)" do
      # Same check for low-temp model (floor = 0.2)
      temp = Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", 4)

      # With max_rounds=4: step = (1.0-0.2)/(4-1) = 0.267..., round 4 = floor = 0.2
      # With max_rounds=5 (bug): step = (1.0-0.2)/(5-1) = 0.2, round 4 = 1.0-3*0.2 = 0.4
      assert temp == 0.2
    end

    test "2-arity matches explicit max_rounds: 4 (high-temp)" do
      # The 2-arity (default) should behave identically to max_refinement_rounds: 4
      for round <- 1..4 do
        default_temp = Temperature.calculate_round_temperature("openai:gpt-4o", round)

        explicit_temp =
          Temperature.calculate_round_temperature("openai:gpt-4o", round,
            max_refinement_rounds: 4
          )

        assert default_temp == explicit_temp,
               "Round #{round}: default #{default_temp} != explicit(4) #{explicit_temp}"
      end
    end

    test "2-arity matches explicit max_rounds: 4 (low-temp)" do
      # Same verification for low-temp model
      for round <- 1..4 do
        default_temp =
          Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", round)

        explicit_temp =
          Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", round,
            max_refinement_rounds: 4
          )

        assert default_temp == explicit_temp,
               "Round #{round}: default #{default_temp} != explicit(4) #{explicit_temp}"
      end
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
      # Simulating a mixed model pool at round 3 (default 4 rounds)
      round = 3
      gpt_temp = Temperature.calculate_round_temperature("azure:gpt-4o", round)
      claude_temp = Temperature.calculate_round_temperature("anthropic:claude-sonnet-4", round)

      # GPT at round 3 (4 rounds): 2.0 - (2 * 0.533) = 0.9
      assert gpt_temp == 0.9
      # Claude at round 3 (4 rounds): 1.0 - (2 * 0.267) = 0.5
      assert claude_temp == 0.5

      # They should be different
      refute gpt_temp == claude_temp
    end
  end
end
