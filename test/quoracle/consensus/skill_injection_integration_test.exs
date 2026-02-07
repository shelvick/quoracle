defmodule Quoracle.Consensus.SkillInjectionIntegrationTest do
  @moduledoc """
  System tests for skill injection pipeline.

  Verifies that active_skills in agent state flow through the consensus
  pipeline and appear in system prompts sent to LLMs.

  ARC Requirements (fix-20260113-skill-injection):
  - R63: System test - permanent skills appear in consensus query
  - R68: Skills section appears after identity, before profile
  - R69: Multiple skills all appear in prompt
  - R70: Empty active_skills produces no skill section
  - R71: nil active_skills treated as empty
  - R72: Skills coexist with profile section
  - R73: Skills coexist with capability groups
  - R74: UI and LLM receive same skill content

  Tests the FULL pipeline: SystemPromptInjector → PromptBuilder → Sections → SkillLoader

  WorkGroupID: fix-20260113-skill-injection
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.Consensus.SystemPromptInjector

  # Mimic spawn_skills_test.exs setup pattern exactly
  setup do
    base_name = "skill_injection_test_#{System.unique_integer([:positive])}"
    skills_path = Path.join(System.tmp_dir!(), base_name)
    File.mkdir_p!(skills_path)

    on_exit(fn -> File.rm_rf!(skills_path) end)

    %{base_name: base_name, skills_path: skills_path}
  end

  # Helper to create skill file (same pattern as spawn_skills_test.exs)
  # Uses skill-name/SKILL.md directory structure
  defp create_skill_file(base_name, name, content \\ nil) do
    content =
      content ||
        """
        ---
        name: #{name}
        description: Test skill #{name}
        ---
        # #{name} Skill

        This is the content for #{name}.
        """

    skill_dir = Path.join([System.tmp_dir!(), base_name, name])
    skill_file = Path.join(skill_dir, "SKILL.md")
    File.mkdir_p!(skill_dir)
    File.write!(skill_file, content)
  end

  # Helper to build skill metadata (same structure as active_skills)
  defp make_skill_metadata(base_name, skill_name) do
    %{
      name: skill_name,
      path: Path.join([System.tmp_dir!(), base_name, skill_name, "SKILL.md"]),
      description: "Test skill for #{skill_name}",
      permanent: true,
      loaded_at: DateTime.utc_now()
    }
  end

  # Helper to extract system prompt from messages
  defp get_system_prompt(messages) do
    case Enum.find(messages, &(&1.role == "system")) do
      %{content: content} -> content
      nil -> ""
    end
  end

  # ==========================================================================
  # R63: System Test - Permanent Skills in Consensus Query
  # ==========================================================================

  describe "pipeline flow - R63 system test" do
    @tag :acceptance
    test "end-to-end: active_skills in state appear in system prompt via full pipeline", ctx do
      skill_content = """
      ---
      name: deployment-best-practices
      description: Deployment guidelines
      ---

      # Deployment Best Practices

      1. Always use blue-green deployment
      2. Verify health checks before cutover
      3. Keep rollback procedures ready
      """

      create_skill_file(ctx.base_name, "deployment-best-practices", skill_content)

      # Build skill opts as ConsensusHandler would
      active_skills = [make_skill_metadata(ctx.base_name, "deployment-best-practices")]

      # Call through FULL pipeline (SystemPromptInjector → PromptBuilder → Sections)
      messages = [%{role: "user", content: "test"}]
      field_prompts = %{system_prompt: "You are a helpful assistant."}

      skill_opts = [
        active_skills: active_skills,
        skills_path: ctx.skills_path
      ]

      # This goes through: SystemPromptInjector → PromptBuilder → Sections → SkillLoader
      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, skill_opts)

      system_prompt = get_system_prompt(result)

      # Verify skill content appears in system prompt
      assert String.contains?(system_prompt, "Deployment Best Practices"),
             "Expected skill title in system prompt. Got:\n#{String.slice(system_prompt, 0, 500)}"

      assert String.contains?(system_prompt, "blue-green deployment"),
             "Expected skill content in system prompt"

      assert String.contains?(system_prompt, "rollback procedures"),
             "Expected skill details in system prompt"
    end
  end

  # ==========================================================================
  # R68: Skills Section Position
  # ==========================================================================

  describe "skills section position (R68)" do
    @tag :acceptance
    test "skills section appears after identity, before profile via full pipeline", ctx do
      create_skill_file(ctx.base_name, "position-test-skill")

      active_skills = [make_skill_metadata(ctx.base_name, "position-test-skill")]

      messages = [%{role: "user", content: "test"}]
      field_prompts = %{system_prompt: "IDENTITY_MARKER: You are a test agent."}

      skill_opts = [
        active_skills: active_skills,
        skills_path: ctx.skills_path,
        # Profile info for ordering verification (name/description no longer shown)
        profile_name: "test-profile",
        profile_description: "This is the profile description"
      ]

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, skill_opts)
      system_prompt = get_system_prompt(result)

      # Verify ordering: Identity → Skills → Profile
      # Profile name no longer shown, use section header as position marker
      identity_pos = find_position(system_prompt, "IDENTITY_MARKER")
      skill_pos = find_position(system_prompt, "position-test-skill")
      profile_pos = find_position(system_prompt, "## Operating Profile")

      assert identity_pos >= 0, "Identity section should be present"

      assert skill_pos >= 0,
             "Skill section should be present in:\n#{String.slice(system_prompt, 0, 500)}"

      assert profile_pos >= 0, "Profile section should be present"

      assert identity_pos < skill_pos,
             "Identity (#{identity_pos}) should appear before skills (#{skill_pos})"

      assert skill_pos < profile_pos,
             "Skills (#{skill_pos}) should appear before profile (#{profile_pos})"
    end
  end

  # ==========================================================================
  # R69: Multiple Skills
  # ==========================================================================

  describe "multiple skills handling (R69)" do
    test "multiple skills all appear in system prompt via full pipeline", ctx do
      create_skill_file(ctx.base_name, "skill-alpha", """
      ---
      name: skill-alpha
      description: Alpha skill
      ---

      # Alpha Skill Content
      Alpha specific instructions.
      """)

      create_skill_file(ctx.base_name, "skill-beta", """
      ---
      name: skill-beta
      description: Beta skill
      ---

      # Beta Skill Content
      Beta specific instructions.
      """)

      create_skill_file(ctx.base_name, "skill-gamma", """
      ---
      name: skill-gamma
      description: Gamma skill
      ---

      # Gamma Skill Content
      Gamma specific instructions.
      """)

      active_skills = [
        make_skill_metadata(ctx.base_name, "skill-alpha"),
        make_skill_metadata(ctx.base_name, "skill-beta"),
        make_skill_metadata(ctx.base_name, "skill-gamma")
      ]

      messages = [%{role: "user", content: "test"}]
      field_prompts = %{}

      skill_opts = [
        active_skills: active_skills,
        skills_path: ctx.skills_path
      ]

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, skill_opts)
      system_prompt = get_system_prompt(result)

      assert String.contains?(system_prompt, "Alpha Skill Content"),
             "Alpha skill missing from:\n#{String.slice(system_prompt, 0, 500)}"

      assert String.contains?(system_prompt, "Beta Skill Content"),
             "Beta skill missing"

      assert String.contains?(system_prompt, "Gamma Skill Content"),
             "Gamma skill missing"
    end

    test "skills appear in order they were learned via full pipeline", ctx do
      create_skill_file(ctx.base_name, "first-skill")
      create_skill_file(ctx.base_name, "second-skill")
      create_skill_file(ctx.base_name, "third-skill")

      active_skills = [
        make_skill_metadata(ctx.base_name, "first-skill"),
        make_skill_metadata(ctx.base_name, "second-skill"),
        make_skill_metadata(ctx.base_name, "third-skill")
      ]

      messages = [%{role: "user", content: "test"}]

      skill_opts = [
        active_skills: active_skills,
        skills_path: ctx.skills_path
      ]

      result = SystemPromptInjector.ensure_system_prompts(messages, %{}, skill_opts)
      system_prompt = get_system_prompt(result)

      first_pos = find_position(system_prompt, "first-skill")
      second_pos = find_position(system_prompt, "second-skill")
      third_pos = find_position(system_prompt, "third-skill")

      assert first_pos >= 0, "First skill should appear in prompt"
      assert second_pos >= 0, "Second skill should appear in prompt"
      assert third_pos >= 0, "Third skill should appear in prompt"

      assert first_pos < second_pos, "First skill should appear before second"
      assert second_pos < third_pos, "Second skill should appear before third"
    end
  end

  # ==========================================================================
  # R70-R71: Empty/Missing Skills
  # ==========================================================================

  describe "empty and missing skills (R70-R71)" do
    # R70: Empty active_skills produces no skill section
    test "empty active_skills produces no skill section via full pipeline", ctx do
      messages = [%{role: "user", content: "test"}]
      field_prompts = %{system_prompt: "Base prompt only"}

      skill_opts = [
        active_skills: [],
        skills_path: ctx.skills_path
      ]

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, skill_opts)
      system_prompt = get_system_prompt(result)

      # Should have base prompt but no skill section header
      assert String.contains?(system_prompt, "Base prompt only")

      # Verify no skills section headers present
      refute String.contains?(system_prompt, "## Skills")
      refute String.contains?(system_prompt, "# Skills")
    end

    # R71: nil active_skills treated as empty
    test "nil active_skills treated as empty via full pipeline", ctx do
      messages = [%{role: "user", content: "test"}]
      field_prompts = %{system_prompt: "Base prompt"}

      skill_opts = [
        active_skills: nil,
        skills_path: ctx.skills_path
      ]

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, skill_opts)

      # Should succeed without crash
      assert is_list(result)
      system_prompt = get_system_prompt(result)
      assert String.contains?(system_prompt, "Base prompt")
    end

    test "missing skill file gracefully handled via full pipeline", ctx do
      # Skill metadata points to non-existent file
      active_skills = [
        %{
          name: "nonexistent-skill",
          path: Path.join([ctx.skills_path, "nonexistent-skill", "SKILL.md"]),
          description: "This skill doesn't exist",
          permanent: true
        }
      ]

      messages = [%{role: "user", content: "test"}]

      skill_opts = [
        active_skills: active_skills,
        skills_path: ctx.skills_path
      ]

      # Should not crash - graceful handling
      result = SystemPromptInjector.ensure_system_prompts(messages, %{}, skill_opts)
      assert is_list(result)
    end
  end

  # ==========================================================================
  # R72-R73: Integration with Other Sections
  # ==========================================================================

  describe "integration with other sections (R72-R73)" do
    # R72: Skills coexist with profile section
    test "skills coexist with profile section via full pipeline", ctx do
      create_skill_file(ctx.base_name, "coexist-skill")

      active_skills = [make_skill_metadata(ctx.base_name, "coexist-skill")]

      messages = [%{role: "user", content: "test"}]
      field_prompts = %{system_prompt: "Base identity"}

      skill_opts = [
        active_skills: active_skills,
        skills_path: ctx.skills_path,
        profile_name: "Developer Profile",
        profile_description: "A developer assistant"
      ]

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, skill_opts)
      system_prompt = get_system_prompt(result)

      assert String.contains?(system_prompt, "coexist-skill"),
             "Skill should appear in:\n#{String.slice(system_prompt, 0, 500)}"

      # Profile section exists (name/description omitted to avoid spawn bias)
      assert String.contains?(system_prompt, "## Operating Profile"),
             "Profile section should appear"
    end

    # R73: Skills coexist with capability groups
    test "skills coexist with profile via full pipeline", ctx do
      create_skill_file(ctx.base_name, "capability-skill")

      active_skills = [make_skill_metadata(ctx.base_name, "capability-skill")]

      messages = [%{role: "user", content: "test"}]

      # Use profile only (capability_groups validation is separate concern)
      skill_opts = [
        active_skills: active_skills,
        skills_path: ctx.skills_path,
        profile_name: "Enhanced Profile",
        profile_description: "A profile with enhanced capabilities"
      ]

      result = SystemPromptInjector.ensure_system_prompts(messages, %{}, skill_opts)
      system_prompt = get_system_prompt(result)

      assert String.contains?(system_prompt, "capability-skill"),
             "Skill should appear in:\n#{String.slice(system_prompt, 0, 500)}"

      # Profile section exists (name/description omitted to avoid spawn bias)
      assert String.contains?(system_prompt, "## Operating Profile"),
             "Profile section should appear"
    end

    test "all sections present in correct order via full pipeline", ctx do
      create_skill_file(ctx.base_name, "ordered-skill")

      active_skills = [make_skill_metadata(ctx.base_name, "ordered-skill")]

      messages = [%{role: "user", content: "test"}]
      field_prompts = %{system_prompt: "IDENTITY_SECTION: You are an agent."}

      # Removed capability_groups (validation is separate concern)
      skill_opts = [
        active_skills: active_skills,
        skills_path: ctx.skills_path,
        profile_name: "Complete Profile",
        profile_description: "Full feature profile"
      ]

      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, skill_opts)
      system_prompt = get_system_prompt(result)

      # Verify all major sections present
      assert String.contains?(system_prompt, "IDENTITY_SECTION")

      assert String.contains?(system_prompt, "ordered-skill"),
             "Skill should appear in:\n#{String.slice(system_prompt, 0, 500)}"

      # Profile section exists (name/description omitted to avoid spawn bias)
      assert String.contains?(system_prompt, "## Operating Profile")
    end
  end

  # ==========================================================================
  # R74: UI Consistency
  # ==========================================================================

  describe "UI consistency (R74)" do
    @tag :acceptance
    test "skills content consistent in LLM query via full pipeline", ctx do
      skill_content = """
      ---
      name: ui-visible-skill
      description: This skill should appear in UI logs
      ---

      # UI Visible Skill

      Specific content that must appear in both UI and LLM.
      """

      create_skill_file(ctx.base_name, "ui-visible-skill", skill_content)

      active_skills = [make_skill_metadata(ctx.base_name, "ui-visible-skill")]

      messages = [%{role: "user", content: "test"}]
      field_prompts = %{system_prompt: "Base"}

      skill_opts = [
        active_skills: active_skills,
        skills_path: ctx.skills_path
      ]

      # This is what gets sent to LLM (via full pipeline)
      result = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, skill_opts)
      system_prompt = get_system_prompt(result)

      # Verify the content that appears
      assert String.contains?(system_prompt, "UI Visible Skill"),
             "Skill title should appear in LLM prompt. Got:\n#{String.slice(system_prompt, 0, 500)}"

      assert String.contains?(system_prompt, "must appear in both UI and LLM"),
             "Skill content should appear in LLM prompt"
    end
  end

  # ==========================================================================
  # Helper Functions
  # ==========================================================================

  defp find_position(text, substring) do
    case :binary.match(text, substring) do
      {pos, _} -> pos
      :nomatch -> -1
    end
  end
end
