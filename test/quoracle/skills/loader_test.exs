defmodule Quoracle.Skills.LoaderTest do
  @moduledoc """
  Unit tests for SKILL_Loader module.
  Tests SKILL.md parsing, directory listing, and error handling with isolated temp directories.

  ARC Criteria: R1-R15 from SKILL_Loader spec
  """
  use ExUnit.Case, async: true

  @moduletag :feat_skills_system

  alias Quoracle.Skills.Loader

  setup do
    # Create unique temp directory per test for isolation
    # Use a base_name that can be used with System.tmp_dir!() in helpers
    base_name = "skills_test/#{System.unique_integer([:positive])}"
    temp_dir = Path.join(System.tmp_dir!(), base_name)

    File.mkdir_p!(temp_dir)

    on_exit(fn -> File.rm_rf!(temp_dir) end)

    %{skills_path: temp_dir, base_name: base_name}
  end

  # Helper to create test skill with valid SKILL.md format
  # Inlines System.tmp_dir!() directly in File.* calls (for git hook static analysis)
  defp create_skill(base_name, name, opts \\ []) do
    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, name]))

    description = Keyword.get(opts, :description, "Test skill description for #{name}")
    metadata = Keyword.get(opts, :metadata, %{})
    content = Keyword.get(opts, :content, "# #{name}\n\nTest content for #{name}")

    # Build YAML frontmatter manually to avoid dependency on YamlElixir in tests
    metadata_yaml =
      if map_size(metadata) > 0 do
        metadata_lines =
          Enum.map_join(metadata, "\n", fn {k, v} ->
            "  #{k}: #{inspect(v)}"
          end)

        "metadata:\n#{metadata_lines}"
      else
        ""
      end

    skill_content = """
    ---
    name: #{name}
    description: #{description}
    #{metadata_yaml}
    ---

    #{content}
    """

    File.write!(Path.join([System.tmp_dir!(), base_name, name, "SKILL.md"]), skill_content)
    Path.join([System.tmp_dir!(), base_name, name])
  end

  # Helper to check if running as root (root ignores file permissions).
  # Used by GAP-3/GAP-4 permission tests to gracefully skip when root.
  defp running_as_root? do
    {uid_str, 0} = System.cmd("id", ["-u"])
    String.trim(uid_str) == "0"
  end

  # Helper to create skill with raw content (for testing malformed YAML)
  defp create_skill_raw(base_name, name, raw_content) do
    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, name]))
    File.write!(Path.join([System.tmp_dir!(), base_name, name, "SKILL.md"]), raw_content)
    Path.join([System.tmp_dir!(), base_name, name])
  end

  # =============================================================================
  # R1-R3: Directory Listing Tests
  # =============================================================================

  describe "list_skills/1" do
    @tag :r1
    test "lists all skills in directory", %{skills_path: path, base_name: base_name} do
      # R1: WHEN list_skills/1 called IF skills directory exists THEN returns list of skill metadata
      create_skill(base_name, "skill-one")
      create_skill(base_name, "skill-two")

      {:ok, skills} = Loader.list_skills(skills_path: path)

      assert length(skills) == 2
      assert Enum.any?(skills, &(&1.name == "skill-one"))
      assert Enum.any?(skills, &(&1.name == "skill-two"))

      # Verify metadata structure (no content in list results)
      skill = Enum.find(skills, &(&1.name == "skill-one"))
      assert Map.has_key?(skill, :name)
      assert Map.has_key?(skill, :description)
      assert Map.has_key?(skill, :path)
      assert Map.has_key?(skill, :metadata)
      refute Map.has_key?(skill, :content)
    end

    @tag :r2
    test "returns empty list for empty directory", %{skills_path: path, base_name: _base_name} do
      # R2: WHEN list_skills/1 called IF directory is empty THEN returns empty list
      {:ok, skills} = Loader.list_skills(skills_path: path)
      assert skills == []
    end

    @tag :r3
    test "returns empty list when directory doesn't exist" do
      # R3: WHEN list_skills/1 called IF directory doesn't exist THEN returns empty list (not error)
      nonexistent_path = "/nonexistent/path/#{System.unique_integer([:positive])}"
      {:ok, skills} = Loader.list_skills(skills_path: nonexistent_path)
      assert skills == []
    end
  end

  # =============================================================================
  # R4-R7: Load Skills Tests
  # =============================================================================

  describe "load_skill/2" do
    @tag :r4
    test "loads skill by name with full content", %{skills_path: path, base_name: base_name} do
      # R4: WHEN load_skill/2 called IF skill exists THEN returns full skill with content
      create_skill(base_name, "deployment", content: "# Deploy\n\nDeploy stuff to production")

      {:ok, skill} = Loader.load_skill("deployment", skills_path: path)

      assert skill.name == "deployment"
      assert skill.content =~ "Deploy stuff"
      assert skill.path =~ "deployment"
      assert Map.has_key?(skill, :description)
      assert Map.has_key?(skill, :metadata)
    end

    @tag :r5
    test "returns error for non-existent skill", %{skills_path: path, base_name: _base_name} do
      # R5: WHEN load_skill/2 called IF skill doesn't exist THEN returns {:error, :not_found}
      assert {:error, :not_found} = Loader.load_skill("nonexistent", skills_path: path)
    end
  end

  describe "load_skills/2" do
    @tag :r6
    test "loads multiple skills by name", %{skills_path: path, base_name: base_name} do
      # R6: WHEN load_skills/2 called IF all skills exist THEN returns list of skills
      create_skill(base_name, "skill-a", content: "Content A")
      create_skill(base_name, "skill-b", content: "Content B")

      {:ok, skills} = Loader.load_skills(["skill-a", "skill-b"], skills_path: path)

      assert length(skills) == 2
      assert Enum.any?(skills, &(&1.name == "skill-a"))
      assert Enum.any?(skills, &(&1.name == "skill-b"))
      # Verify content is included
      assert Enum.any?(skills, &(&1.content =~ "Content A"))
      assert Enum.any?(skills, &(&1.content =~ "Content B"))
    end

    @tag :r7
    test "returns error with missing skill name when any not found", %{
      skills_path: path,
      base_name: base_name
    } do
      # R7: WHEN load_skills/2 called IF any skill missing THEN returns error with missing name
      create_skill(base_name, "exists")

      assert {:error, {:not_found, "missing"}} =
               Loader.load_skills(["exists", "missing"], skills_path: path)
    end

    @tag :r6
    test "preserves order of requested skills", %{skills_path: path, base_name: base_name} do
      # Additional test: order preservation
      create_skill(base_name, "first")
      create_skill(base_name, "second")
      create_skill(base_name, "third")

      {:ok, skills} = Loader.load_skills(["third", "first", "second"], skills_path: path)

      assert Enum.map(skills, & &1.name) == ["third", "first", "second"]
    end

    @tag :r6
    test "returns empty list for empty input", %{skills_path: _path} do
      # Edge case: empty list input
      {:ok, skills} = Loader.load_skills([], skills_path: "/any/path")
      assert skills == []
    end
  end

  # =============================================================================
  # R8-R11: Parsing Tests
  # =============================================================================

  describe "parse_skill_file/2" do
    @tag :r8
    test "parses valid SKILL.md frontmatter", %{skills_path: path, base_name: _base_name} do
      # R8: WHEN parse_skill_file/2 called IF valid YAML frontmatter THEN extracts name, description, metadata
      content = """
      ---
      name: test-skill
      description: A test skill for parsing
      metadata:
        complexity: high
      ---

      # Content here
      """

      {:ok, skill} = Loader.parse_skill_file(path, content)

      assert skill.name == "test-skill"
      assert skill.description == "A test skill for parsing"
      assert skill.metadata["complexity"] == "high"
    end

    @tag :r9
    test "extracts markdown body content", %{skills_path: path, base_name: _base_name} do
      # R9: WHEN parse_skill_file/2 called IF valid format THEN extracts markdown body after frontmatter
      content = """
      ---
      name: test
      description: desc
      ---

      # Heading

      Body text here with **markdown**.

      - List item 1
      - List item 2
      """

      {:ok, skill} = Loader.parse_skill_file(path, content)

      assert skill.content =~ "# Heading"
      assert skill.content =~ "Body text here"
      assert skill.content =~ "**markdown**"
      assert skill.content =~ "- List item 1"
    end

    @tag :r10
    test "returns error for malformed YAML", %{skills_path: path, base_name: _base_name} do
      # R10: WHEN parse_skill_file/2 called IF invalid YAML THEN returns {:error, :invalid_format}
      content = """
      ---
      name: [invalid yaml without closing bracket
      description: this won't parse
      ---

      Content
      """

      assert {:error, :invalid_format} = Loader.parse_skill_file(path, content)
    end

    @tag :r11
    test "returns error when required fields missing - no name", %{
      skills_path: path,
      base_name: _base_name
    } do
      # R11: WHEN parse_skill_file/2 called IF missing name or description THEN returns {:error, :invalid_format}
      content = """
      ---
      description: only description, no name
      ---

      Content
      """

      assert {:error, :invalid_format} = Loader.parse_skill_file(path, content)
    end

    @tag :r11
    test "returns error when required fields missing - no description", %{
      skills_path: path,
      base_name: _base_name
    } do
      # R11: Missing description
      content = """
      ---
      name: only-name
      ---

      Content
      """

      assert {:error, :invalid_format} = Loader.parse_skill_file(path, content)
    end

    @tag :r10
    test "returns error for missing frontmatter delimiters", %{
      skills_path: path,
      base_name: _base_name
    } do
      # Edge case: no frontmatter at all
      content = """
      # Just markdown

      No frontmatter here
      """

      assert {:error, :invalid_format} = Loader.parse_skill_file(path, content)
    end
  end

  # =============================================================================
  # R12: Name Validation Tests
  # =============================================================================

  describe "name validation" do
    @tag :r12
    test "validates name matches directory name", %{skills_path: path, base_name: base_name} do
      # R12: WHEN load_skill/2 called IF name field doesn't match directory name THEN returns {:error, :invalid_format}
      content = """
      ---
      name: different-name
      description: Name doesn't match directory
      ---

      Content
      """

      create_skill_raw(base_name, "actual-name", content)

      assert {:error, :invalid_format} = Loader.load_skill("actual-name", skills_path: path)
    end

    @tag :r12
    test "accepts skill when name matches directory name", %{
      skills_path: path,
      base_name: base_name
    } do
      # Positive case: name matches
      create_skill(base_name, "matching-name")

      {:ok, skill} = Loader.load_skill("matching-name", skills_path: path)
      assert skill.name == "matching-name"
    end
  end

  # =============================================================================
  # R13: Path Injection Tests
  # =============================================================================

  describe "skills_dir/1" do
    @tag :r13
    test "uses injected skills_path from opts", %{skills_path: path, base_name: base_name} do
      # R13: WHEN opts contains :skills_path THEN uses that path instead of default
      create_skill(base_name, "injected-test")

      {:ok, skills} = Loader.list_skills(skills_path: path)
      assert Enum.any?(skills, &(&1.name == "injected-test"))
    end

    @tag :r13
    test "returns default path when no opts provided" do
      # When no skills_path in opts, should use default ~/.quoracle/skills
      default_path = Loader.skills_dir([])
      assert default_path =~ ".quoracle/skills"
    end

    @tag :r13
    test "skills_dir returns injected path" do
      custom_path = "/custom/skills/path"
      assert Loader.skills_dir(skills_path: custom_path) == custom_path
    end
  end

  # =============================================================================
  # R14-R15: Metadata Tests
  # =============================================================================

  describe "metadata handling" do
    @tag :r14
    test "extracts all metadata fields", %{skills_path: path, base_name: base_name} do
      # R14: WHEN frontmatter contains metadata field THEN all metadata fields extracted
      create_skill(base_name, "with-meta",
        metadata: %{
          "complexity" => "high",
          "estimated_tokens" => 2000,
          "author" => "human",
          "version" => "1.0"
        }
      )

      {:ok, skill} = Loader.load_skill("with-meta", skills_path: path)

      assert skill.metadata["complexity"] == "high"
      assert skill.metadata["estimated_tokens"] == 2000
      assert skill.metadata["author"] == "human"
      assert skill.metadata["version"] == "1.0"
    end

    @tag :r15
    test "handles missing metadata field", %{skills_path: path, base_name: base_name} do
      # R15: WHEN frontmatter has no metadata field THEN returns empty metadata map
      content = """
      ---
      name: no-meta
      description: No metadata here
      ---

      Content without metadata
      """

      create_skill_raw(base_name, "no-meta", content)

      {:ok, skill} = Loader.load_skill("no-meta", skills_path: path)
      assert skill.metadata == %{}
    end

    @tag :r14
    test "preserves nested metadata structure", %{skills_path: path, base_name: base_name} do
      # Edge case: nested metadata
      content = """
      ---
      name: nested-meta
      description: Has nested metadata
      metadata:
        complexity: medium
        requirements:
          cpu: high
          memory: low
      ---

      Content
      """

      create_skill_raw(base_name, "nested-meta", content)

      {:ok, skill} = Loader.load_skill("nested-meta", skills_path: path)
      assert skill.metadata["complexity"] == "medium"
      assert skill.metadata["requirements"]["cpu"] == "high"
      assert skill.metadata["requirements"]["memory"] == "low"
    end
  end

  # =============================================================================
  # Property-Based Tests
  # =============================================================================

  describe "property-based tests" do
    @tag :property
    test "parsed skill name always matches frontmatter name", %{
      skills_path: path,
      base_name: base_name
    } do
      # Property: name in result always equals name in frontmatter (when valid)
      valid_names = ["skill-one", "my-skill", "a", "test123", "skill-with-numbers-123"]

      for name <- valid_names do
        create_skill(base_name, name)
        {:ok, skill} = Loader.load_skill(name, skills_path: path)
        assert skill.name == name, "Expected name #{name} but got #{skill.name}"
        # Cleanup for next iteration
        File.rm_rf!(Path.join([System.tmp_dir!(), base_name, name]))
      end
    end

    @tag :property
    test "list_skills returns subset of load_skills for same directory", %{
      skills_path: path,
      base_name: base_name
    } do
      # Property: every skill in list_skills can be loaded with load_skill
      create_skill(base_name, "prop-skill-a")
      create_skill(base_name, "prop-skill-b")

      {:ok, listed} = Loader.list_skills(skills_path: path)
      names = Enum.map(listed, & &1.name)

      {:ok, loaded} = Loader.load_skills(names, skills_path: path)

      assert length(listed) == length(loaded)

      for skill <- loaded do
        assert Enum.any?(listed, &(&1.name == skill.name))
      end
    end
  end

  # =============================================================================
  # Edge Cases and Error Handling
  # =============================================================================

  describe "edge cases" do
    test "handles skill directory without SKILL.md file", %{
      skills_path: path,
      base_name: base_name
    } do
      # Directory exists but no SKILL.md file
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "empty-skill"]))

      # Should not appear in list (no valid SKILL.md)
      {:ok, skills} = Loader.list_skills(skills_path: path)
      refute Enum.any?(skills, &(&1.name == "empty-skill"))

      # load_skill should return not_found
      assert {:error, :not_found} = Loader.load_skill("empty-skill", skills_path: path)
    end

    test "handles empty SKILL.md file", %{skills_path: path, base_name: base_name} do
      create_skill_raw(base_name, "empty-file", "")

      assert {:error, :invalid_format} = Loader.load_skill("empty-file", skills_path: path)
    end

    test "handles SKILL.md with only frontmatter, no body", %{
      skills_path: path,
      base_name: base_name
    } do
      content = """
      ---
      name: no-body
      description: Has frontmatter but no body
      ---
      """

      create_skill_raw(base_name, "no-body", content)

      {:ok, skill} = Loader.load_skill("no-body", skills_path: path)
      # Empty body should be acceptable
      assert skill.name == "no-body"
      assert skill.content == ""
    end

    test "handles special characters in description", %{skills_path: path, base_name: base_name} do
      content = """
      ---
      name: special-chars
      description: "Description with: colons, 'quotes', and #special chars"
      ---

      Content
      """

      create_skill_raw(base_name, "special-chars", content)

      {:ok, skill} = Loader.load_skill("special-chars", skills_path: path)
      assert skill.description =~ "colons"
    end

    test "ignores non-directory files in skills directory", %{
      skills_path: path,
      base_name: base_name
    } do
      # Create a regular file in skills directory (not a skill directory)
      File.write!(Path.join([System.tmp_dir!(), base_name, "not-a-skill.txt"]), "just a file")
      create_skill(base_name, "real-skill")

      {:ok, skills} = Loader.list_skills(skills_path: path)

      assert length(skills) == 1
      assert hd(skills).name == "real-skill"
    end
  end

  # =============================================================================
  # R21-R26: Grove-Local Skill Resolution (v3.0)
  # =============================================================================
  #
  # These tests verify the v3.0 contract: when a grove_skills_path is provided
  # in opts, skills are searched there FIRST before falling back to the global
  # skills directory. This enables groves to bundle their own skill definitions
  # that shadow global skills of the same name.
  #
  # The integration audit found:
  # (HIGH) SkillLoader resolves a single skills_path, so grove-local selection
  #        replaces global rather than grove-first with global fallback.
  # (HIGH) EventHandlers/TaskManager forward one path, so valid global skills
  #        fail when absent from grove-local scope.
  # (MEDIUM) No acceptance test for same-name grove skill shadowing global,
  #          and no test for fallback to global when grove-local skill is missing.

  # Helper to create a skill in a grove-local skills directory.
  # Creates a separate temp dir for grove skills (not under the global skills_path).
  # Inlines System.tmp_dir!() directly in File.* calls (for git hook static analysis)
  defp create_grove_skill(grove_base_name, name, opts) do
    File.mkdir_p!(Path.join([System.tmp_dir!(), grove_base_name, name]))

    description = Keyword.get(opts, :description, "Grove skill description for #{name}")
    content = Keyword.get(opts, :content, "# #{name}\n\nGrove-local content for #{name}")

    skill_content = """
    ---
    name: #{name}
    description: #{description}
    ---

    #{content}
    """

    File.write!(Path.join([System.tmp_dir!(), grove_base_name, name, "SKILL.md"]), skill_content)
    Path.join([System.tmp_dir!(), grove_base_name, name])
  end

  describe "grove-local skill resolution (v3.0)" do
    setup %{base_name: base_name} do
      # Create a separate grove-local skills directory (isolated from global)
      grove_base = "grove_skills_test/#{System.unique_integer([:positive])}"
      grove_skills_dir = Path.join(System.tmp_dir!(), grove_base)
      File.mkdir_p!(grove_skills_dir)

      on_exit(fn -> File.rm_rf!(grove_skills_dir) end)

      %{
        grove_skills_path: grove_skills_dir,
        grove_base: grove_base,
        global_base: base_name
      }
    end

    @tag :r21
    test "R21: load_skill finds skill in grove_skills_path first", %{
      skills_path: global_path,
      global_base: global_base,
      grove_skills_path: grove_path,
      grove_base: grove_base
    } do
      # R21: WHEN grove_skills_path provided AND skill exists in grove
      # THEN returns grove skill (not global)
      # Create the same skill in both grove and global with different content
      create_skill(global_base, "deploy", content: "# Deploy\n\nGlobal deployment skill")

      create_grove_skill(grove_base, "deploy",
        content: "# Deploy\n\nGrove-local deployment skill"
      )

      # When grove_skills_path is provided, should find grove version first
      {:ok, skill} =
        Loader.load_skill("deploy",
          skills_path: global_path,
          grove_skills_path: grove_path
        )

      assert skill.name == "deploy"
      assert skill.content =~ "Grove-local deployment skill"
      refute skill.content =~ "Global deployment skill"
    end

    @tag :r22
    test "R22: load_skill falls back to global when not in grove", %{
      skills_path: global_path,
      global_base: global_base,
      grove_skills_path: grove_path,
      grove_base: _grove_base
    } do
      # R22: WHEN grove_skills_path provided AND skill NOT in grove THEN returns global skill
      create_skill(global_base, "code-review",
        content: "# Code Review\n\nGlobal review checklist"
      )

      # Grove directory exists but does NOT contain "code-review"
      {:ok, skill} =
        Loader.load_skill("code-review",
          skills_path: global_path,
          grove_skills_path: grove_path
        )

      assert skill.name == "code-review"
      assert skill.content =~ "Global review checklist"
    end

    @tag :r23
    test "R23: load_skill without grove_skills_path uses global only", %{
      skills_path: global_path,
      global_base: global_base
    } do
      # R23: WHEN grove_skills_path not in opts THEN behavior identical to v2.0
      create_skill(global_base, "deploy", content: "# Deploy\n\nGlobal deploy content")

      {:ok, skill} = Loader.load_skill("deploy", skills_path: global_path)

      assert skill.name == "deploy"
      assert skill.content =~ "Global deploy content"
    end

    @tag :r25
    test "R25: non-existent grove_skills_path falls back to global", %{
      skills_path: global_path,
      global_base: global_base
    } do
      # R25: WHEN grove_skills_path points to non-existent directory THEN silently uses global only
      nonexistent_grove = "/nonexistent/grove/skills/#{System.unique_integer([:positive])}"

      create_skill(global_base, "deploy", content: "# Deploy\n\nGlobal deploy fallback")

      {:ok, skill} =
        Loader.load_skill("deploy",
          skills_path: global_path,
          grove_skills_path: nonexistent_grove
        )

      assert skill.name == "deploy"
      assert skill.content =~ "Global deploy fallback"

      # list_skills should also work with nonexistent grove path
      {:ok, skills} =
        Loader.list_skills(
          skills_path: global_path,
          grove_skills_path: nonexistent_grove
        )

      assert Enum.any?(skills, &(&1.name == "deploy"))
    end

    @tag :r24
    test "R24: list_skills merges grove and global with grove priority", %{
      skills_path: global_path,
      global_base: global_base,
      grove_skills_path: grove_path,
      grove_base: grove_base
    } do
      # R24: WHEN grove and global both have skills
      # THEN list returns union with grove taking precedence for same-name skills
      # Global has: deploy, code-review
      create_skill(global_base, "deploy", description: "Global deploy")

      create_skill(global_base, "code-review", description: "Global code review")

      # Grove has: deploy (shadows global), testing (new)
      create_grove_skill(grove_base, "deploy", description: "Grove deploy")

      create_grove_skill(grove_base, "testing", description: "Grove testing")

      {:ok, skills} =
        Loader.list_skills(
          skills_path: global_path,
          grove_skills_path: grove_path
        )

      skill_names = Enum.map(skills, & &1.name) |> Enum.sort()

      # Should have all 3 unique skills: code-review (global), deploy (grove), testing (grove)
      assert "code-review" in skill_names
      assert "deploy" in skill_names
      assert "testing" in skill_names
      assert length(skills) == 3

      # deploy should be grove version (description = "Grove deploy")
      deploy_skill = Enum.find(skills, &(&1.name == "deploy"))
      assert deploy_skill.description == "Grove deploy"
    end

    @tag :r26
    @tag :acceptance
    test "R26: grove skill shadows global skill of same name", %{
      skills_path: global_path,
      global_base: global_base,
      grove_skills_path: grove_path,
      grove_base: grove_base
    } do
      # R26 [SYSTEM]: WHEN grove and global both have a skill named "deploy"
      # with different content THEN load_skill returns grove version content
      # AND list_skills shows grove version for that name
      #
      # This is the acceptance test verifying the complete v3.0 contract:
      # grove-local skills shadow same-name globals, AND global skills
      # remain available as fallback when not present in grove-local scope.

      # Global has: deploy (v1) and code-review
      create_skill(global_base, "deploy",
        description: "Global deployment v1",
        content: "# Deploy\n\nGlobal deployment instructions v1"
      )

      create_skill(global_base, "code-review",
        description: "Global code review",
        content: "# Code Review\n\nGlobal review checklist"
      )

      # Grove has: deploy (v2) -- shadows global deploy
      create_grove_skill(grove_base, "deploy",
        description: "Grove deployment v2",
        content: "# Deploy\n\nGrove-specific deployment for this project"
      )

      opts = [skills_path: global_path, grove_skills_path: grove_path]

      # 1. load_skill("deploy") returns grove version (shadow)
      {:ok, deploy} = Loader.load_skill("deploy", opts)
      assert deploy.content =~ "Grove-specific deployment"
      refute deploy.content =~ "Global deployment instructions"

      # 2. load_skill("code-review") returns global version (fallback)
      {:ok, review} = Loader.load_skill("code-review", opts)
      assert review.content =~ "Global review checklist"

      # 3. list_skills returns merged set with grove priority
      {:ok, all_skills} = Loader.list_skills(opts)
      names = Enum.map(all_skills, & &1.name) |> Enum.sort()
      assert names == ["code-review", "deploy"]

      # 4. deploy in listing is grove version
      listed_deploy = Enum.find(all_skills, &(&1.name == "deploy"))
      assert listed_deploy.description == "Grove deployment v2"
      refute listed_deploy.description =~ "Global"

      # 5. code-review in listing is global version (no grove version exists)
      listed_review = Enum.find(all_skills, &(&1.name == "code-review"))
      assert listed_review.description == "Global code review"
    end

    test "load_skills resolves skills from both grove and global", %{
      skills_path: global_path,
      global_base: global_base,
      grove_skills_path: grove_path,
      grove_base: grove_base
    } do
      # Integration: load_skills/2 (multi-skill) should also respect grove priority
      create_skill(global_base, "deploy", content: "# Deploy\n\nGlobal deploy")

      create_skill(global_base, "code-review", content: "# Code Review\n\nGlobal review")

      create_grove_skill(grove_base, "deploy", content: "# Deploy\n\nGrove deploy")

      {:ok, skills} =
        Loader.load_skills(["deploy", "code-review"],
          skills_path: global_path,
          grove_skills_path: grove_path
        )

      assert length(skills) == 2

      deploy = Enum.find(skills, &(&1.name == "deploy"))
      review = Enum.find(skills, &(&1.name == "code-review"))

      assert deploy.content =~ "Grove deploy"
      assert review.content =~ "Global review"
    end
  end

  # =============================================================================
  # GAP-3: Bang File Operations - Permission Denied Handling (MEDIUM)
  # =============================================================================
  #
  # Integration audit found that:
  # - list_skills_in_dir/1 (line 168) uses File.ls!/1 which crashes on permission-denied
  # - load_skill_from_dir/1 (line 193) uses File.read!/1 which crashes on unreadable SKILL.md
  # - load_skill_metadata/2 (line 218) uses File.read!/1 which crashes on unreadable SKILL.md
  #
  # These should return {:error, _} tuples instead of crashing, enabling graceful
  # degradation when filesystem permissions are restrictive.
  #
  # NOTE: These tests use File.chmod to make files/directories unreadable. This
  # requires the test process to NOT be running as root (root ignores permissions).
  # The tests skip gracefully if running as root.

  describe "bang file operations - permission denied (GAP-3)" do
    @tag :gap3
    test "GAP-3a: list_skills graceful on unreadable directory",
         %{base_name: base_name} do
      # GAP-3a: WHEN list_skills/1 called with a directory that exists but has
      # no read permission THEN returns {:ok, []} instead of crashing.
      #
      # Current behavior: File.ls!/1 raises %File.Error{reason: :eacces}
      # Expected behavior: {:ok, []} graceful empty list

      # Uses System.tmp_dir!() inline for git hook static analysis
      sub = "#{base_name}/gap3a"
      dir = Path.join(System.tmp_dir!(), sub)
      File.mkdir_p!(Path.join([System.tmp_dir!(), sub, "some-skill"]))

      File.write!(Path.join([System.tmp_dir!(), sub, "some-skill", "SKILL.md"]), """
      ---
      name: some-skill
      description: A skill that should not be reachable
      ---
      Content
      """)

      # Remove read permission from the directory
      File.chmod!(Path.join(System.tmp_dir!(), sub), 0o000)

      on_exit(fn ->
        File.chmod!(Path.join(System.tmp_dir!(), sub), 0o755)
        File.rm_rf!(Path.join(System.tmp_dir!(), sub))
      end)

      if running_as_root?() do
        assert true
      else
        # Currently crashes with File.Error from File.ls!/1 (line 168)
        assert {:ok, _skills} = Loader.list_skills(skills_path: dir)
      end
    end

    @tag :gap3
    test "GAP-3b: load_skill graceful on unreadable SKILL.md",
         %{base_name: base_name} do
      # GAP-3b: WHEN load_skill/2 is called for a skill whose SKILL.md has no
      # read permission THEN returns {:error, _} instead of crashing.
      #
      # Current behavior: File.read!/1 raises %File.Error{reason: :eacces}

      sub = "#{base_name}/gap3b"
      dir = Path.join(System.tmp_dir!(), sub)
      File.mkdir_p!(Path.join([System.tmp_dir!(), sub, "locked-skill"]))

      File.write!(Path.join([System.tmp_dir!(), sub, "locked-skill", "SKILL.md"]), """
      ---
      name: locked-skill
      description: A skill with unreadable manifest
      ---
      Content that cannot be read
      """)

      File.chmod!(Path.join([System.tmp_dir!(), sub, "locked-skill", "SKILL.md"]), 0o000)

      on_exit(fn ->
        File.chmod!(Path.join([System.tmp_dir!(), sub, "locked-skill", "SKILL.md"]), 0o644)
        File.rm_rf!(Path.join(System.tmp_dir!(), sub))
      end)

      if running_as_root?() do
        assert true
      else
        result = Loader.load_skill("locked-skill", skills_path: dir)

        assert match?({:error, _}, result),
               "Expected {:error, _} when SKILL.md is unreadable, " <>
                 "got: #{inspect(result)}."
      end
    end

    @tag :gap3
    test "GAP-3c: list_skills skips unreadable individual SKILL.md",
         %{base_name: base_name} do
      # GAP-3c: WHEN one skill's SKILL.md is unreadable but others are fine
      # THEN returns the readable skills (graceful degradation).
      #
      # Current behavior: load_skill_metadata/2 calls File.read!/1 which raises

      sub = "#{base_name}/gap3c"
      dir = Path.join(System.tmp_dir!(), sub)

      # Create readable skill
      File.mkdir_p!(Path.join([System.tmp_dir!(), sub, "readable-skill"]))

      File.write!(Path.join([System.tmp_dir!(), sub, "readable-skill", "SKILL.md"]), """
      ---
      name: readable-skill
      description: This skill is readable
      ---
      Readable content
      """)

      # Create unreadable skill
      File.mkdir_p!(Path.join([System.tmp_dir!(), sub, "locked-skill"]))

      File.write!(Path.join([System.tmp_dir!(), sub, "locked-skill", "SKILL.md"]), """
      ---
      name: locked-skill
      description: This skill has no read permission
      ---
      Locked content
      """)

      File.chmod!(Path.join([System.tmp_dir!(), sub, "locked-skill", "SKILL.md"]), 0o000)

      on_exit(fn ->
        File.chmod!(Path.join([System.tmp_dir!(), sub, "locked-skill", "SKILL.md"]), 0o644)
        File.rm_rf!(Path.join(System.tmp_dir!(), sub))
      end)

      if running_as_root?() do
        assert true
      else
        # Currently crashes with File.Error from File.read!/1 (line 218)
        {:ok, skills} = Loader.list_skills(skills_path: dir)

        assert Enum.any?(skills, &(&1.name == "readable-skill")),
               "Expected readable-skill in results"

        refute Enum.any?(skills, &(&1.name == "locked-skill")),
               "Unreadable skill should be excluded"
      end
    end
  end

  # =============================================================================
  # GAP-4: Resilience Tests for Unreadable Skill Manifests (MEDIUM)
  # =============================================================================
  #
  # Extended resilience tests covering additional permission scenarios.
  # These tests verify graceful degradation rather than crashes.

  describe "resilience - unreadable skill manifests (GAP-4)" do
    @tag :gap4
    test "GAP-4a: list_skills with all-unreadable skills",
         %{base_name: base_name} do
      # GAP-4a: WHEN ALL skills have unreadable SKILL.md files
      # THEN returns {:ok, []} instead of crashing.

      sub = "#{base_name}/gap4a"
      dir = Path.join(System.tmp_dir!(), sub)

      for name <- ["locked-a", "locked-b"] do
        File.mkdir_p!(Path.join([System.tmp_dir!(), sub, name]))

        File.write!(Path.join([System.tmp_dir!(), sub, name, "SKILL.md"]), """
        ---
        name: #{name}
        description: #{name} description
        ---
        Content for #{name}
        """)

        File.chmod!(Path.join([System.tmp_dir!(), sub, name, "SKILL.md"]), 0o000)
      end

      on_exit(fn ->
        for name <- ["locked-a", "locked-b"] do
          File.chmod!(Path.join([System.tmp_dir!(), sub, name, "SKILL.md"]), 0o644)
        end

        File.rm_rf!(Path.join(System.tmp_dir!(), sub))
      end)

      if running_as_root?() do
        assert true
      else
        result = Loader.list_skills(skills_path: dir)

        assert match?({:ok, []}, result),
               "Expected {:ok, []} when all SKILL.md files are unreadable, " <>
                 "got: #{inspect(result)}."
      end
    end

    @tag :gap4
    test "GAP-4b: search/2 graceful on unreadable directory",
         %{base_name: base_name} do
      # GAP-4b: WHEN search/2 is called with an unreadable directory
      # THEN returns [] instead of crashing.

      sub = "#{base_name}/gap4b"
      dir = Path.join(System.tmp_dir!(), sub)
      File.mkdir_p!(Path.join([System.tmp_dir!(), sub, "some-skill"]))

      File.write!(Path.join([System.tmp_dir!(), sub, "some-skill", "SKILL.md"]), """
      ---
      name: some-skill
      description: Test skill
      ---
      Content
      """)

      File.chmod!(Path.join(System.tmp_dir!(), sub), 0o000)

      on_exit(fn ->
        File.chmod!(Path.join(System.tmp_dir!(), sub), 0o755)
        File.rm_rf!(Path.join(System.tmp_dir!(), sub))
      end)

      if running_as_root?() do
        assert true
      else
        result = Loader.search(["test"], skills_path: dir)

        assert result == [],
               "Expected empty search results for unreadable directory, " <>
                 "got: #{inspect(result)}"
      end
    end

    @tag :gap4
    test "GAP-4c: load_skills/2 graceful when one skill unreadable",
         %{base_name: base_name} do
      # GAP-4c: WHEN load_skills/2 has one unreadable SKILL.md
      # THEN returns {:error, _} instead of crashing.

      sub = "#{base_name}/gap4c"
      dir = Path.join(System.tmp_dir!(), sub)

      File.mkdir_p!(Path.join([System.tmp_dir!(), sub, "good-skill"]))

      File.write!(Path.join([System.tmp_dir!(), sub, "good-skill", "SKILL.md"]), """
      ---
      name: good-skill
      description: Readable skill
      ---
      Good content
      """)

      File.mkdir_p!(Path.join([System.tmp_dir!(), sub, "bad-skill"]))

      File.write!(Path.join([System.tmp_dir!(), sub, "bad-skill", "SKILL.md"]), """
      ---
      name: bad-skill
      description: Unreadable skill
      ---
      Bad content
      """)

      File.chmod!(Path.join([System.tmp_dir!(), sub, "bad-skill", "SKILL.md"]), 0o000)

      on_exit(fn ->
        File.chmod!(Path.join([System.tmp_dir!(), sub, "bad-skill", "SKILL.md"]), 0o644)
        File.rm_rf!(Path.join(System.tmp_dir!(), sub))
      end)

      if running_as_root?() do
        assert true
      else
        result = Loader.load_skills(["good-skill", "bad-skill"], skills_path: dir)

        assert match?({:error, _}, result),
               "Expected {:error, _} when one skill is unreadable, " <>
                 "got: #{inspect(result)}."
      end
    end
  end
end
