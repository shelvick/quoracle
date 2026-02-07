defmodule Quoracle.Agent.ConfigManagerSkillsTest do
  @moduledoc """
  Tests for AGENT_ConfigManager v9.0 - Skills config fields.

  ARC Requirements (v9.0):
  - R19: skills field preserved
  - R20: active_skills field preserved
  - R21: skills defaults to empty list
  - R22: active_skills defaults to empty list
  - R23: both fields together

  WorkGroupID: feat-20260112-skills-system
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.ConfigManager

  describe "skills fields in normalize_config/1 (R19-R23)" do
    # R19: Skills Field Preserved
    test "preserves skills from config" do
      config = %{
        agent_id: "test-skills-1",
        test_mode: true,
        skills: ["deployment", "security-audit"]
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.skills == ["deployment", "security-audit"]
    end

    # R20: Active Skills Field Preserved
    test "preserves active_skills from config" do
      skill_metadata = [
        %{
          name: "pre-loaded-skill",
          permanent: true,
          loaded_at: DateTime.utc_now(),
          description: "A pre-loaded skill",
          path: "/path/to/skill.md",
          metadata: %{}
        }
      ]

      config = %{
        agent_id: "test-skills-2",
        test_mode: true,
        active_skills: skill_metadata
      }

      normalized = ConfigManager.normalize_config(config)

      assert length(normalized.active_skills) == 1
      assert hd(normalized.active_skills).name == "pre-loaded-skill"
    end

    # R21: Skills Default Empty List
    test "skills defaults to empty list" do
      config = %{
        agent_id: "test-skills-3",
        test_mode: true
        # No skills provided
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.skills == []
    end

    # R22: Active Skills Default Empty List
    test "active_skills defaults to empty list" do
      config = %{
        agent_id: "test-skills-4",
        test_mode: true
        # No active_skills provided
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.active_skills == []
    end

    # R23: Both Fields Together
    test "preserves both skills fields together" do
      skill_metadata = [
        %{
          name: "active-skill",
          permanent: true,
          loaded_at: DateTime.utc_now(),
          description: "An active skill",
          path: "/path/to/active.md",
          metadata: %{}
        }
      ]

      config = %{
        agent_id: "test-skills-5",
        test_mode: true,
        skills: ["pending-skill-1", "pending-skill-2"],
        active_skills: skill_metadata
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.skills == ["pending-skill-1", "pending-skill-2"]
      assert length(normalized.active_skills) == 1
      assert hd(normalized.active_skills).name == "active-skill"
    end

    test "skills fields work with keyword list config" do
      config = [
        agent_id: "test-skills-kw",
        test_mode: true,
        skills: ["keyword-skill"]
      ]

      normalized = ConfigManager.normalize_config(config)

      assert normalized.skills == ["keyword-skill"]
    end

    test "skills fields work with all profile fields" do
      # Verify skills work alongside other profile fields
      config = %{
        agent_id: "test-skills-profile",
        test_mode: true,
        profile_name: "research-profile",
        capability_groups: [:hierarchy, :external_api],
        skills: ["research-skill"],
        active_skills: []
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.profile_name == "research-profile"
      assert normalized.skills == ["research-skill"]
      assert normalized.active_skills == []
    end
  end
end
