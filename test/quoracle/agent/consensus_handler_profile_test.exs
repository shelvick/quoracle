defmodule Quoracle.Agent.ConsensusHandlerProfileTest do
  @moduledoc """
  Tests for AGENT_ConsensusHandler v19.0 - Profile Injection

  ARC Requirements:
  - R38: Profile Opts Extracted from State [UNIT]
  - R39: Profile Opts Passed to ensure_system_prompts [UNIT]
  - R40: Default Empty capability_groups [UNIT]
  - R41: Acceptance - Profile Section in System Prompt [SYSTEM]

  WorkGroupID: fix-20260108-profile-injection

  Note: R40 "default empty capability_groups" is implemented in State.new (Packet 2).
  This file tests the ConsensusHandler integration - passing profile_opts to
  SystemPromptInjector.ensure_system_prompts.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Consensus.SystemPromptInjector

  describe "profile_opts support (R38-R39)" do
    # R38/R39: These tests verify that SystemPromptInjector SHOULD add profile
    # section when profile_opts are passed. Currently it does NOT - tests fail.
    # Once SystemPromptInjector is updated, ConsensusHandler just needs to pass opts.

    test "ensure_system_prompts/3 includes profile section when profile_opts provided" do
      # UNIT R38: SystemPromptInjector should add profile section with profile_opts
      messages = [%{role: "user", content: "test task"}]
      field_prompts = %{system_prompt: nil}

      profile_opts = [
        profile_name: "r38-unique-xyzzy",
        profile_description: "A test profile",
        capability_groups: [:hierarchy]
      ]

      # Call with 3rd argument (profile_opts)
      result =
        SystemPromptInjector.ensure_system_prompts(
          messages,
          field_prompts,
          profile_opts
        )

      # Find the system message
      system_msg = Enum.find(result, &(&1.role == "system"))
      assert system_msg != nil, "Should have system message"

      # Profile section exists with permissions
      assert system_msg.content =~ "## Operating Profile",
             "System prompt should contain Operating Profile section when profile_opts passed"

      # Profile name intentionally omitted to avoid biasing spawn decisions
      # Use unique name that won't match any seeded database profiles
      refute system_msg.content =~ "r38-unique-xyzzy",
             "Profile name should NOT appear (prevents spawn bias)"
    end

    test "profile section includes capability groups" do
      # UNIT R39: Profile section should list capability groups
      messages = [%{role: "user", content: "test"}]
      field_prompts = %{system_prompt: nil}

      profile_opts = [
        profile_name: "worker-profile",
        profile_description: "A worker with limited access",
        capability_groups: [:file_read, :external_api]
      ]

      result =
        SystemPromptInjector.ensure_system_prompts(
          messages,
          field_prompts,
          profile_opts
        )

      system_msg = Enum.find(result, &(&1.role == "system"))

      # CRITICAL: FAILS until implementation includes capabilities in profile section
      assert system_msg.content =~ "file_read",
             "Profile section should list file_read capability"

      assert system_msg.content =~ "external_api",
             "Profile section should list external_api capability"
    end

    test "profile section omits description to avoid spawn bias" do
      # UNIT R39: Profile description intentionally omitted
      messages = [%{role: "user", content: "test"}]
      field_prompts = %{system_prompt: nil}

      profile_opts = [
        profile_name: "researcher",
        profile_description: "Specializes in web research and data gathering",
        capability_groups: [:external_api]
      ]

      result =
        SystemPromptInjector.ensure_system_prompts(
          messages,
          field_prompts,
          profile_opts
        )

      system_msg = Enum.find(result, &(&1.role == "system"))

      # Description intentionally omitted to avoid biasing spawn decisions
      refute system_msg.content =~ "Specializes in web research",
             "Profile description should NOT appear (prevents spawn bias)"

      # But capability groups still appear
      assert system_msg.content =~ "external_api"
    end
  end

  describe "R40: empty capability_groups handling" do
    test "profile section works with empty capability_groups" do
      # UNIT R40: Should handle empty capability_groups gracefully
      messages = [%{role: "user", content: "test"}]
      field_prompts = %{system_prompt: nil}

      profile_opts = [
        profile_name: "basic-profile",
        profile_description: nil,
        capability_groups: []
      ]

      result =
        SystemPromptInjector.ensure_system_prompts(
          messages,
          field_prompts,
          profile_opts
        )

      system_msg = Enum.find(result, &(&1.role == "system"))

      # Profile section exists with permissions
      assert system_msg.content =~ "## Operating Profile",
             "Profile section should appear even with empty capabilities"

      # Profile name intentionally omitted
      refute system_msg.content =~ "basic-profile",
             "Profile name should NOT appear (prevents spawn bias)"
    end

    test "profile section works with nil capability_groups" do
      # UNIT R40: Should handle nil capability_groups (treat as empty)
      messages = [%{role: "user", content: "test"}]
      field_prompts = %{system_prompt: nil}

      profile_opts = [
        profile_name: "nil-cg-profile",
        profile_description: nil,
        capability_groups: nil
      ]

      result =
        SystemPromptInjector.ensure_system_prompts(
          messages,
          field_prompts,
          profile_opts
        )

      system_msg = Enum.find(result, &(&1.role == "system"))

      # Profile section exists
      assert system_msg.content =~ "## Operating Profile"
      # Profile name intentionally omitted
      refute system_msg.content =~ "nil-cg-profile"
    end
  end

  describe "R41: acceptance - profile section" do
    @tag :acceptance
    test "system prompt contains profile section with permissions" do
      # SYSTEM R41: End-to-end verification that profile section appears
      messages = [%{role: "user", content: "Please help me with a task"}]
      field_prompts = %{system_prompt: nil}

      profile_opts = [
        profile_name: "code-reviewer",
        profile_description: "Reviews code for quality and security issues",
        capability_groups: [:file_read, :external_api]
      ]

      result =
        SystemPromptInjector.ensure_system_prompts(
          messages,
          field_prompts,
          profile_opts
        )

      system_msg = Enum.find(result, &(&1.role == "system"))

      # Profile section exists with capability groups
      assert system_msg.content =~ "## Operating Profile"
      assert system_msg.content =~ "file_read"
      assert system_msg.content =~ "external_api"

      # Name and description intentionally omitted to avoid spawn bias
      refute system_msg.content =~ "code-reviewer"
      refute system_msg.content =~ "Reviews code for quality"
    end
  end
end
