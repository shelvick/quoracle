defmodule Quoracle.Consensus.PromptBuilderProfileEnumTest do
  @moduledoc """
  Tests for CONSENSUS_PromptBuilder v14.0 - Profile Enum Injection

  These tests verify that spawn_child action schema includes profile names
  as an enum when profiles exist in the database.

  WorkGroupID: fix-20260108-profile-injection
  ARC Requirements: R51-R55
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Consensus.PromptBuilder
  alias Quoracle.Consensus.PromptBuilder.SchemaFormatter
  alias Quoracle.Profiles.TableProfiles

  # All capability groups to include all actions in prompts
  @all_capability_groups [:file_read, :file_write, :external_api, :hierarchy, :local_execution]

  describe "R51: Profile enum in spawn_child schema" do
    test "spawn_child profile param shows enum with profile names when opts provided" do
      # UNIT: WHEN action_to_json_schema(:spawn_child, opts) called with profile_names
      # THEN profile param has enum array
      opts = [profile_names: ["worker", "researcher", "analyst"]]

      json_schema = SchemaFormatter.action_to_json_schema(:spawn_child, opts)

      # Find profile in properties
      profile_spec = json_schema["params"]["properties"]["profile"]

      assert profile_spec != nil, "profile parameter should exist in spawn_child schema"
      assert profile_spec["type"] == "string", "profile should be string type"

      assert profile_spec["enum"] == ["worker", "researcher", "analyst"],
             "profile should have enum with provided profile names"
    end
  end

  describe "R52: Profile names from database" do
    test "profile enum populated from database profiles", %{sandbox_owner: sandbox_owner} do
      # INTEGRATION: WHEN build_system_prompt called
      # THEN queries Resolver.list_names() for profile enum

      # Seed test profiles
      {:ok, _} =
        Repo.insert(%TableProfiles{
          name: "test-worker",
          description: "Test worker profile",
          model_pool: ["gpt-4o"],
          capability_groups: ["hierarchy", "file_read"]
        })

      {:ok, _} =
        Repo.insert(%TableProfiles{
          name: "test-researcher",
          description: "Test researcher profile",
          model_pool: ["claude-3-opus"],
          capability_groups: ["external_api"]
        })

      # Build system prompt with sandbox access
      prompt =
        PromptBuilder.build_system_prompt(
          sandbox_owner: sandbox_owner,
          capability_groups: @all_capability_groups
        )

      # Verify profile names appear as enum in spawn_child schema
      assert prompt =~ "test-worker"
      assert prompt =~ "test-researcher"

      # Profile should appear as enum value in JSON schema format
      # Expected: "enum": ["test-worker", "test-researcher"]
      assert prompt =~ ~r/"enum".*"test-worker"/s,
             "Profile names should appear as enum values in spawn_child schema"
    end
  end

  describe "R53: Empty profiles fallback" do
    test "profile param is plain string when profile_names is empty list" do
      # UNIT: WHEN no profiles in database (profile_names is [])
      # THEN profile param is plain string (no enum)
      opts = [profile_names: []]

      # This should return schema without enum for profile
      json_schema = SchemaFormatter.action_to_json_schema(:spawn_child, opts)

      profile_spec = json_schema["params"]["properties"]["profile"]

      assert profile_spec != nil, "profile parameter should exist in spawn_child schema"
      assert profile_spec["type"] == "string", "profile should be string type"

      refute Map.has_key?(profile_spec, "enum"),
             "Profile should NOT have enum when profile_names is empty"
    end

    test "profile param is plain string when profile_names not provided in opts" do
      # UNIT: WHEN opts doesn't include profile_names at all
      # THEN profile param is plain string (no enum) - same as empty list

      # Call with empty opts (no profile_names key)
      json_schema = SchemaFormatter.action_to_json_schema(:spawn_child, [])

      profile_spec = json_schema["params"]["properties"]["profile"]

      assert profile_spec != nil, "profile parameter should exist in spawn_child schema"
      assert profile_spec["type"] == "string", "profile should be string type"

      refute Map.has_key?(profile_spec, "enum"),
             "Profile should NOT have enum when profile_names not provided"
    end
  end

  describe "R54: Sandbox handling" do
    test "profile loading respects sandbox_owner for test isolation", %{
      sandbox_owner: sandbox_owner
    } do
      # INTEGRATION: WHEN sandbox_owner in opts
      # THEN allows DB access for profile query

      # Insert a profile in our sandbox
      {:ok, _} =
        Repo.insert(%TableProfiles{
          name: "sandbox-test-profile",
          description: "Profile for sandbox test",
          model_pool: ["gpt-4o"],
          capability_groups: ["hierarchy"]
        })

      # Build prompt with sandbox_owner - should see our profile
      prompt =
        PromptBuilder.build_system_prompt(
          sandbox_owner: sandbox_owner,
          capability_groups: @all_capability_groups
        )

      assert prompt =~ "sandbox-test-profile",
             "Profile from sandboxed DB should appear in prompt"
    end

    test "profile loading without sandbox_owner gracefully degrades" do
      # INTEGRATION: WHEN sandbox_owner not provided
      # THEN should not crash, falls back to empty profiles

      # This should not crash even without sandbox access
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Should still generate valid prompt
      assert is_binary(prompt)
      assert prompt =~ "spawn_child"
    end
  end

  describe "R55: Acceptance - LLM sees profile options" do
    @tag :acceptance
    test "end-to-end agent prompt contains profile enum values", %{sandbox_owner: sandbox_owner} do
      # SYSTEM: WHEN user creates task
      # THEN agent's system prompt shows profile enum with valid options

      # Setup: Create profiles that would exist in production
      profiles = ["default", "code-reviewer", "data-analyst"]

      for profile_name <- profiles do
        {:ok, _} =
          Repo.insert(%TableProfiles{
            name: profile_name,
            description: "#{profile_name} profile",
            model_pool: ["gpt-4o"],
            capability_groups: ["hierarchy"]
          })
      end

      # Action: Build system prompt as it would be for an agent
      prompt =
        PromptBuilder.build_system_prompt(
          sandbox_owner: sandbox_owner,
          capability_groups: @all_capability_groups
        )

      # Assert: All profile names should appear as valid enum options
      for profile_name <- profiles do
        assert prompt =~ profile_name,
               "Profile '#{profile_name}' should appear in system prompt"
      end

      # Assert: Profile enum should be in spawn_child action context
      # The prompt should show spawn_child with profile as enum in JSON schema format
      assert prompt =~ "spawn_child"

      # Expected JSON schema format: "enum": ["default", "code-reviewer", ...]
      assert prompt =~ ~r/"enum".*"default"/s,
             "Profile should have enum constraint in spawn_child schema"
    end
  end
end
