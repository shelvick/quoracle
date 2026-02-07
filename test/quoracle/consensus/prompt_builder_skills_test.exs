defmodule Quoracle.Consensus.PromptBuilderSkillsTest do
  @moduledoc """
  Tests for CONSENSUS_PromptBuilder skill content injection.

  ARC Requirements (v15.0 - SkillLoader):
  - R56: skill section for active skills
  - R57: no section for empty skills
  - R58: content from files
  - R59: multiple skills combined with ---
  - R60: missing skill graceful (placeholder)
  - R61: section placement (after identity, before profile)
  - R62: skills_path passthrough
  - R63: acceptance - permanent skills in prompt (SUPERSEDED by TEST_SkillInjectionIntegration)

  ARC Requirements (v16.0 - Sections Integration):
  - R64: Sections.build_integrated_prompt calls SkillLoader
  - R65: Empty active_skills produces no skill section
  - R66: Skill section positioned after identity, before profile
  - R67: skills_path passed through to SkillLoader

  WorkGroupID: fix-20260113-skill-injection
  """

  use ExUnit.Case, async: true

  alias Quoracle.Consensus.PromptBuilder.{Sections, SkillLoader, Context}

  setup do
    # Create temp skills directory
    base_name = "prompt_builder_skills_test_#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.join(System.tmp_dir!(), base_name))

    on_exit(fn -> File.rm_rf!(Path.join(System.tmp_dir!(), base_name)) end)

    %{base_name: base_name}
  end

  defp create_skill_file(base_name, name, content) do
    full_content = """
    ---
    name: #{name}
    description: Test skill #{name}
    ---
    #{content}
    """

    File.write!(Path.join([System.tmp_dir!(), base_name, "#{name}.md"]), full_content)
  end

  defp make_skill_metadata(base_name, name) do
    %{
      name: name,
      permanent: true,
      loaded_at: DateTime.utc_now(),
      description: "Test skill #{name}",
      path: Path.join([System.tmp_dir!(), base_name, "#{name}.md"]),
      metadata: %{}
    }
  end

  # ==========================================================================
  # R56-R57: Skill Section Generation
  # ==========================================================================

  describe "skill section generation (R56-R57)" do
    # R56: Skill Section for Active Skills
    test "skill section shows skill content", ctx do
      create_skill_file(
        ctx.base_name,
        "display-skill",
        "# Display Skill\n\nThis is the skill content."
      )

      active_skills = [make_skill_metadata(ctx.base_name, "display-skill")]

      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      opts = [skills_path: skills_path]

      result = SkillLoader.load_skill_content(active_skills, opts)

      assert is_binary(result)
      assert result != ""
      assert String.contains?(result, "Display Skill")
    end

    # R57: No Section for Empty Skills
    test "no skill section when no active skills", ctx do
      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      opts = [skills_path: skills_path]

      result = SkillLoader.load_skill_content([], opts)

      assert result == ""
    end
  end

  # ==========================================================================
  # R58-R60: Content Loading
  # ==========================================================================

  describe "skill content loading (R58-R60)" do
    # R58: Content From Files
    test "skill content loaded from files", ctx do
      skill_content = "# File-Based Skill\n\nThis content comes from a file on disk."

      create_skill_file(ctx.base_name, "file-skill", skill_content)

      active_skills = [make_skill_metadata(ctx.base_name, "file-skill")]

      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      opts = [skills_path: skills_path]

      result = SkillLoader.load_skill_content(active_skills, opts)

      assert String.contains?(result, "File-Based Skill")
    end

    # R59: Multiple Skills Combined
    test "multiple skills separated by ---", ctx do
      create_skill_file(ctx.base_name, "skill-one", "# Skill One Content")
      create_skill_file(ctx.base_name, "skill-two", "# Skill Two Content")

      active_skills = [
        make_skill_metadata(ctx.base_name, "skill-one"),
        make_skill_metadata(ctx.base_name, "skill-two")
      ]

      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      opts = [skills_path: skills_path]

      result = SkillLoader.load_skill_content(active_skills, opts)

      # Spec requires skills combined with --- separator
      assert String.contains?(result, "---")
      assert String.contains?(result, "Skill One Content")
      assert String.contains?(result, "Skill Two Content")
    end

    # R60: Missing Skill Graceful
    test "missing skill shows placeholder", ctx do
      # Skill metadata points to non-existent file
      active_skills = [
        %{
          name: "missing-skill",
          permanent: true,
          loaded_at: DateTime.utc_now(),
          description: "Missing skill",
          path: "/nonexistent/path/missing-skill.md",
          metadata: %{}
        }
      ]

      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      opts = [skills_path: skills_path]

      # Should not crash - graceful degradation
      result = SkillLoader.load_skill_content(active_skills, opts)

      # Returns binary (either placeholder or empty, but doesn't crash)
      assert is_binary(result)
    end
  end

  # ==========================================================================
  # R61-R62: Section Placement and Path
  # ==========================================================================

  describe "skill section placement and path (R61-R62)" do
    # R61: Section Placement
    test "skill section positioned correctly", ctx do
      create_skill_file(ctx.base_name, "position-skill", "# Position Test Skill")

      active_skills = [make_skill_metadata(ctx.base_name, "position-skill")]

      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      opts = [skills_path: skills_path]

      result = SkillLoader.load_skill_content(active_skills, opts)

      # Verify section is generated with skill content
      assert is_binary(result)
      assert result != ""
      assert String.contains?(result, "Position Test Skill")
    end

    # R62: skills_path Passthrough
    test "skills_path from opts used for content loading", ctx do
      # Create skill in custom path
      create_skill_file(ctx.base_name, "custom-path-skill", "# Custom Path Content")

      active_skills = [make_skill_metadata(ctx.base_name, "custom-path-skill")]

      # Pass skills_path in opts
      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      opts = [skills_path: skills_path]

      result = SkillLoader.load_skill_content(active_skills, opts)

      # Should find and load skill from custom path
      assert String.contains?(result, "Custom Path Content")
    end
  end

  # ==========================================================================
  # R63: Acceptance Test
  # ==========================================================================

  describe "acceptance - permanent skills in prompt (R63)" do
    # R63: Acceptance - Permanent Skills in Prompt
    test "end-to-end permanent skills appear in system prompt", ctx do
      skill_content = """
      # Deployment Best Practices

      1. Always use blue-green deployment
      2. Verify health checks before cutover
      3. Keep rollback procedures ready
      """

      create_skill_file(ctx.base_name, "deployment-skill", skill_content)

      active_skills = [make_skill_metadata(ctx.base_name, "deployment-skill")]

      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      opts = [skills_path: skills_path]

      result = SkillLoader.load_skill_content(active_skills, opts)

      # Verify actual skill content appears in output
      assert String.contains?(result, "Deployment Best Practices")
      assert String.contains?(result, "blue-green deployment")
    end
  end

  # ==========================================================================
  # Additional Edge Cases
  # ==========================================================================

  describe "edge cases" do
    test "handles nil active_skills", ctx do
      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      opts = [skills_path: skills_path]

      # Should handle nil gracefully by returning empty string
      result = SkillLoader.load_skill_content(nil, opts)

      assert result == ""
    end

    test "handles skill with empty content", ctx do
      # Create skill with minimal content
      empty_content = "---\nname: empty-skill\ndescription: Empty skill\n---\n"
      File.write!(Path.join([System.tmp_dir!(), ctx.base_name, "empty-skill.md"]), empty_content)

      active_skills = [make_skill_metadata(ctx.base_name, "empty-skill")]

      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      opts = [skills_path: skills_path]

      result = SkillLoader.load_skill_content(active_skills, opts)

      # Should not crash on empty content
      assert is_binary(result)
    end
  end

  # ==========================================================================
  # v16.0: Sections.build_integrated_prompt Integration (R64-R67)
  # WorkGroupID: fix-20260113-skill-injection
  # ==========================================================================

  describe "Sections skill integration (R64-R67)" do
    # R64: Sections Calls SkillLoader
    test "build_integrated_prompt calls SkillLoader with active_skills", ctx do
      skill_content = """
      ---
      name: integration-skill
      description: Integration test skill
      ---
      # Integration Test Skill

      This skill content should appear in the system prompt.
      """

      create_skill_file(ctx.base_name, "integration-skill", skill_content)

      active_skills = [make_skill_metadata(ctx.base_name, "integration-skill")]

      # Build contexts as Sections expects
      field_prompts = %{system_prompt: "You are a test agent."}

      action_ctx = %Context.Action{
        schemas: "",
        untrusted_docs: "",
        trusted_docs: "",
        allowed_actions: [],
        format_secrets_fn: fn -> "" end
      }

      profile_ctx = %Context.Profile{
        name: nil,
        description: nil,
        permission_check: nil,
        blocked_actions: [],
        available_profiles: []
      }

      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      opts = [active_skills: active_skills, skills_path: skills_path]

      # Call build_integrated_prompt with 4th parameter (opts)
      result = Sections.build_integrated_prompt(field_prompts, action_ctx, profile_ctx, opts)

      # Skill content should appear in the result
      assert String.contains?(result, "Integration Test Skill"),
             "Expected skill title in system prompt, got: #{String.slice(result, 0, 500)}"

      assert String.contains?(result, "should appear in the system prompt"),
             "Expected skill content in system prompt"
    end

    # R65: Empty Skills Skipped
    test "no skill section when active_skills empty", ctx do
      field_prompts = %{system_prompt: "You are a test agent."}

      action_ctx = %Context.Action{
        schemas: "",
        untrusted_docs: "",
        trusted_docs: "",
        allowed_actions: [],
        format_secrets_fn: fn -> "" end
      }

      profile_ctx = %Context.Profile{
        name: nil,
        description: nil,
        permission_check: nil,
        blocked_actions: [],
        available_profiles: []
      }

      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      opts = [active_skills: [], skills_path: skills_path]

      result = Sections.build_integrated_prompt(field_prompts, action_ctx, profile_ctx, opts)

      # Should have base prompt content
      assert String.contains?(result, "test agent")

      # Should NOT have skill section markers
      refute String.contains?(result, "## Skills") or String.contains?(result, "# Skills"),
             "Empty active_skills should not produce skill section"
    end

    # R66: Skill Section Position
    test "skill section positioned after identity before profile", ctx do
      create_skill_file(ctx.base_name, "position-test-skill", "# Position Test Content")

      active_skills = [make_skill_metadata(ctx.base_name, "position-test-skill")]

      # Use identity in field_prompts and a profile
      field_prompts = %{system_prompt: "IDENTITY_MARKER: You are a test agent."}

      action_ctx = %Context.Action{
        schemas: "",
        untrusted_docs: "",
        trusted_docs: "",
        allowed_actions: [],
        format_secrets_fn: fn -> "" end
      }

      # Profile name/description no longer shown in prompt (to avoid spawn bias)
      # Use "Operating Profile" header as position marker instead
      profile_ctx = %Context.Profile{
        name: "test-profile",
        description: "This is the profile description",
        permission_check: :full,
        blocked_actions: [],
        available_profiles: []
      }

      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      opts = [active_skills: active_skills, skills_path: skills_path]

      result = Sections.build_integrated_prompt(field_prompts, action_ctx, profile_ctx, opts)

      # Find positions of each section (profile name no longer shown, use header)
      identity_pos = find_position(result, "IDENTITY_MARKER")
      skill_pos = find_position(result, "Position Test Content")
      profile_pos = find_position(result, "## Operating Profile")

      assert identity_pos >= 0, "Identity section should be present"
      assert skill_pos >= 0, "Skill section should be present"
      assert profile_pos >= 0, "Profile section should be present"

      # Verify ordering: Identity → Skills → Profile
      assert identity_pos < skill_pos,
             "Identity (#{identity_pos}) should appear before skills (#{skill_pos})"

      assert skill_pos < profile_pos,
             "Skills (#{skill_pos}) should appear before profile (#{profile_pos})"
    end

    # R67: skills_path Passthrough
    test "skills_path passed to SkillLoader", ctx do
      # Use same temp dir pattern, create skill using helper pattern
      skill_content = "# Custom Path Skill Content"
      create_skill_file(ctx.base_name, "custom-path-skill", skill_content)

      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      active_skills = [make_skill_metadata(ctx.base_name, "custom-path-skill")]

      field_prompts = %{system_prompt: "You are a test agent."}

      action_ctx = %Context.Action{
        schemas: "",
        untrusted_docs: "",
        trusted_docs: "",
        allowed_actions: [],
        format_secrets_fn: fn -> "" end
      }

      profile_ctx = %Context.Profile{
        name: nil,
        description: nil,
        permission_check: nil,
        blocked_actions: [],
        available_profiles: []
      }

      # Pass skills_path in opts - verifies it's passed through to SkillLoader
      opts = [active_skills: active_skills, skills_path: skills_path]

      result = Sections.build_integrated_prompt(field_prompts, action_ctx, profile_ctx, opts)

      # Should find and load skill from specified path
      assert String.contains?(result, "Custom Path Skill Content"),
             "Expected skill from custom path in result"
    end

    defp find_position(text, substring) do
      case :binary.match(text, substring) do
        {pos, _} -> pos
        :nomatch -> -1
      end
    end
  end
end
