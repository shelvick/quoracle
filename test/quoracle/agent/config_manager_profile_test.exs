defmodule Quoracle.Agent.ConfigManagerProfileTest do
  @moduledoc """
  Tests for AGENT_ConfigManager v6.0 - Profile fields in normalized config.

  ARC Requirements (v6.0):
  - R11: Profile name preserved
  - R12: Profile description preserved
  - R13: Model pool preserved
  - R16: Default model pool (empty list)
  - R17: All profile fields together

  ARC Requirements (v8.0 - capability_groups):
  - R8: capability_groups Extracted [UNIT]
  - R9: capability_groups Default [UNIT]
  - R10: capability_groups Preserved Through Setup [INTEGRATION]

  WorkGroupID: fix-20260108-profile-injection
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.ConfigManager

  describe "profile fields in normalize_config/1" do
    # R11: Profile Name Preserved
    test "preserves profile_name from config" do
      config = %{
        agent_id: "test-profile-1",
        test_mode: true,
        profile_name: "researcher-profile"
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.profile_name == "researcher-profile"
    end

    # R12: Profile Description Preserved
    test "preserves profile_description from config" do
      config = %{
        agent_id: "test-profile-2",
        test_mode: true,
        profile_description: "A profile for research tasks with web access"
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.profile_description == "A profile for research tasks with web access"
    end

    # R13: Model Pool Preserved
    test "preserves model_pool from config" do
      config = %{
        agent_id: "test-profile-3",
        test_mode: true,
        model_pool: ["gpt-4o", "claude-opus", "gemini-pro"]
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.model_pool == ["gpt-4o", "claude-opus", "gemini-pro"]
    end

    # R16: Model Pool Passthrough
    # NOTE: model_pool must NOT default to [] in ConfigManager - it breaks test_mode
    # because ModelPoolInit checks for nil to trigger test_model_pool() fallback.
    # Profile-provided model_pool is passed through; otherwise nil lets ModelPoolInit decide.
    test "model_pool passes through nil (lets ModelPoolInit handle default)" do
      config = %{
        agent_id: "test-profile-6",
        test_mode: true
        # No model_pool provided
      }

      normalized = ConfigManager.normalize_config(config)

      # nil allows ModelPoolInit to use test_model_pool() in test_mode
      assert normalized.model_pool == nil
    end

    # R17: All Profile Fields Together
    test "preserves all profile fields together" do
      config = %{
        agent_id: "test-profile-7",
        test_mode: true,
        profile_name: "full-profile",
        profile_description: "Complete profile with all fields",
        model_pool: ["gpt-4o-mini", "claude-sonnet"],
        capability_groups: [:hierarchy, :file_read]
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.profile_name == "full-profile"
      assert normalized.profile_description == "Complete profile with all fields"
      assert normalized.model_pool == ["gpt-4o-mini", "claude-sonnet"]
      assert normalized.capability_groups == [:hierarchy, :file_read]
    end

    test "profile fields work with keyword list config" do
      config = [
        agent_id: "test-profile-kw",
        test_mode: true,
        profile_name: "keyword-profile",
        capability_groups: [:external_api]
      ]

      normalized = ConfigManager.normalize_config(config)

      assert normalized.profile_name == "keyword-profile"
      assert normalized.capability_groups == [:external_api]
    end
  end

  # ==========================================================================
  # v8.0 - capability_groups extraction (R8-R10)
  # ==========================================================================

  describe "capability_groups in normalize_config (R8-R10)" do
    # R8: capability_groups Extracted
    test "normalize_config extracts capability_groups from config" do
      # UNIT: WHEN normalize_config called with capability_groups THEN included in output
      config = %{
        agent_id: "test-cg-1",
        test_mode: true,
        capability_groups: [:hierarchy, :file_read, :external_api]
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.capability_groups == [:hierarchy, :file_read, :external_api],
             "capability_groups should be extracted from config"
    end

    # R9: capability_groups Default
    test "capability_groups defaults to empty list when not provided" do
      # UNIT: WHEN config has no capability_groups THEN defaults to []
      config = %{
        agent_id: "test-cg-2",
        test_mode: true
        # No capability_groups provided
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.capability_groups == [],
             "capability_groups should default to empty list"
    end

    test "capability_groups with single group" do
      config = %{
        agent_id: "test-cg-3",
        test_mode: true,
        capability_groups: [:hierarchy]
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.capability_groups == [:hierarchy]
    end

    test "capability_groups preserved with all profile fields" do
      # Verify capability_groups works alongside other profile fields
      config = %{
        agent_id: "test-cg-4",
        test_mode: true,
        profile_name: "full-profile",
        profile_description: "Profile with capability groups",
        model_pool: ["gpt-4o"],
        capability_groups: [:web_access, :spawn_agents]
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.profile_name == "full-profile"
      assert normalized.profile_description == "Profile with capability groups"
      assert normalized.capability_groups == [:web_access, :spawn_agents]
    end

    test "capability_groups works with keyword list config" do
      config = [
        agent_id: "test-cg-kw",
        test_mode: true,
        capability_groups: [:file_write, :code_execution]
      ]

      normalized = ConfigManager.normalize_config(config)

      assert normalized.capability_groups == [:file_write, :code_execution]
    end
  end
end
