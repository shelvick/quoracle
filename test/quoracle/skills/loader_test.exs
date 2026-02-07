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
end
