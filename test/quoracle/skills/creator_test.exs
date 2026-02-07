defmodule Quoracle.Skills.CreatorTest do
  @moduledoc """
  Unit tests for SKILL_Creator module.
  Tests skill creation, name validation, and attachment handling.

  ARC Criteria: R1-R15 from SKILL_Creator spec
  """
  use ExUnit.Case, async: true

  @moduletag :feat_skills_system

  alias Quoracle.Skills.Creator
  alias Quoracle.Skills.Loader

  setup do
    # Create unique temp directory per test for isolation
    base_name = "skills_creator_test/#{System.unique_integer([:positive])}"
    temp_dir = Path.join(System.tmp_dir!(), base_name)

    # Don't create the directory - let tests verify auto-creation behavior
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    %{skills_path: temp_dir, base_name: base_name}
  end

  # Helper to create existing skill for testing (inlines System.tmp_dir!() for git hook)
  defp create_existing_skill(base_name, name, content) do
    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, name]))
    File.write!(Path.join([System.tmp_dir!(), base_name, name, "SKILL.md"]), content)
  end

  # =============================================================================
  # R1: Create Basic Skill
  # =============================================================================

  describe "create/2 - basic skill creation" do
    @tag :r1
    test "creates skill directory and SKILL.md file", %{
      skills_path: path,
      base_name: _base_name
    } do
      # R1: WHEN create/2 called with valid params THEN creates SKILL.md in correct directory
      params = %{
        name: "my-skill",
        description: "A test skill",
        content: "# My Skill\n\nThis is the skill content."
      }

      {:ok, skill_path} = Creator.create(params, skills_path: path)

      assert File.dir?(skill_path)
      skill_file = Path.join(skill_path, "SKILL.md")
      assert File.exists?(skill_file)
    end
  end

  # =============================================================================
  # R2-R6: Name Validation Tests
  # =============================================================================

  describe "validate_name/1 - valid names" do
    @tag :r2
    test "accepts valid skill names" do
      # R2: WHEN validate_name/1 called IF valid format THEN returns :ok
      assert :ok = Creator.validate_name("deployment")
      assert :ok = Creator.validate_name("code-review")
      assert :ok = Creator.validate_name("api-v2")
      assert :ok = Creator.validate_name("test123")
      assert :ok = Creator.validate_name("a")
      assert :ok = Creator.validate_name("ab-cd-ef")
    end
  end

  describe "validate_name/1 - invalid names" do
    @tag :r3
    test "rejects uppercase in name" do
      # R3: WHEN validate_name/1 called IF contains uppercase THEN returns error
      assert {:error, message} = Creator.validate_name("Deployment")
      assert is_binary(message)

      assert {:error, _} = Creator.validate_name("CODE-REVIEW")
      assert {:error, _} = Creator.validate_name("mySkill")
    end

    @tag :r4
    test "rejects consecutive hyphens" do
      # R4: WHEN validate_name/1 called IF consecutive hyphens THEN returns error
      assert {:error, message} = Creator.validate_name("my--skill")
      assert is_binary(message)

      assert {:error, _} = Creator.validate_name("code---review")
      assert {:error, _} = Creator.validate_name("a--b--c")
    end

    @tag :r5
    test "rejects names starting with number" do
      # R5: WHEN validate_name/1 called IF starts with number THEN returns error
      assert {:error, message} = Creator.validate_name("123skill")
      assert is_binary(message)

      assert {:error, _} = Creator.validate_name("1-deployment")
      assert {:error, _} = Creator.validate_name("0test")
    end

    @tag :r6
    test "rejects names over 64 characters" do
      # R6: WHEN validate_name/1 called IF over 64 chars THEN returns error
      long_name = String.duplicate("a", 65)
      assert {:error, message} = Creator.validate_name(long_name)
      assert message =~ "64"

      # Exactly 64 should be ok
      exactly_64 = String.duplicate("a", 64)
      assert :ok = Creator.validate_name(exactly_64)
    end

    test "rejects names with special characters" do
      assert {:error, _} = Creator.validate_name("my_skill")
      assert {:error, _} = Creator.validate_name("my.skill")
      assert {:error, _} = Creator.validate_name("my skill")
      assert {:error, _} = Creator.validate_name("my@skill")
    end

    test "rejects names ending with hyphen" do
      assert {:error, _} = Creator.validate_name("skill-")
      assert {:error, _} = Creator.validate_name("deployment-")
    end

    test "rejects names starting with hyphen" do
      assert {:error, _} = Creator.validate_name("-skill")
      assert {:error, _} = Creator.validate_name("-deployment")
    end

    test "rejects empty name" do
      assert {:error, _} = Creator.validate_name("")
    end
  end

  # =============================================================================
  # R7: Skill Already Exists
  # =============================================================================

  describe "create/2 - existing skill" do
    @tag :r7
    test "returns error when skill already exists", %{
      skills_path: path,
      base_name: base_name
    } do
      # R7: WHEN create/2 called IF skill already exists THEN returns error
      # First, create a skill manually
      create_existing_skill(
        base_name,
        "existing-skill",
        "---\nname: existing-skill\ndescription: Already exists\n---\n"
      )

      params = %{
        name: "existing-skill",
        description: "Try to create again",
        content: "Content"
      }

      assert {:error, :already_exists} = Creator.create(params, skills_path: path)
    end
  end

  # =============================================================================
  # R8: Auto-Create Skills Directory
  # =============================================================================

  describe "create/2 - auto-create directory" do
    @tag :r8
    test "auto-creates skills directory if missing", %{
      skills_path: path,
      base_name: _base_name
    } do
      # R8: WHEN create/2 called IF ~/.quoracle/skills/ doesn't exist THEN creates it
      # path doesn't exist yet (we didn't create it in setup)
      refute File.dir?(path)

      params = %{
        name: "new-skill",
        description: "Test description",
        content: "Content"
      }

      {:ok, _skill_path} = Creator.create(params, skills_path: path)

      assert File.dir?(path)
    end
  end

  # =============================================================================
  # R9-R11: Attachment Tests
  # =============================================================================

  describe "create/2 - attachments" do
    @tag :r9
    test "creates script attachments in scripts/ directory", %{
      skills_path: path,
      base_name: _base_name
    } do
      # R9: WHEN create/2 called with script attachment THEN creates scripts/ subdirectory
      params = %{
        name: "with-script",
        description: "Skill with script",
        content: "Content",
        attachments: [
          %{type: "script", filename: "deploy.sh", content: "#!/bin/bash\necho 'deploy'"}
        ]
      }

      {:ok, skill_path} = Creator.create(params, skills_path: path)

      script_path = Path.join([skill_path, "scripts", "deploy.sh"])
      assert File.exists?(script_path)
      assert File.read!(script_path) =~ "deploy"
    end

    @tag :r10
    test "creates reference attachments in references/ directory", %{
      skills_path: path,
      base_name: _base_name
    } do
      # R10: WHEN create/2 called with reference attachment THEN creates references/ subdirectory
      params = %{
        name: "with-reference",
        description: "Skill with reference",
        content: "Content",
        attachments: [
          %{type: "reference", filename: "docs.md", content: "# Documentation\n\nReference docs"}
        ]
      }

      {:ok, skill_path} = Creator.create(params, skills_path: path)

      ref_path = Path.join([skill_path, "references", "docs.md"])
      assert File.exists?(ref_path)
      assert File.read!(ref_path) =~ "Documentation"
    end

    @tag :r11
    test "creates asset attachments in assets/ directory", %{
      skills_path: path,
      base_name: _base_name
    } do
      # R11: WHEN create/2 called with asset attachment THEN creates assets/ subdirectory
      params = %{
        name: "with-asset",
        description: "Skill with asset",
        content: "Content",
        attachments: [
          %{type: "asset", filename: "config.json", content: "{\"key\": \"value\"}"}
        ]
      }

      {:ok, skill_path} = Creator.create(params, skills_path: path)

      asset_path = Path.join([skill_path, "assets", "config.json"])
      assert File.exists?(asset_path)
      assert File.read!(asset_path) =~ "key"
    end

    test "creates multiple attachments of different types", %{
      skills_path: path,
      base_name: _base_name
    } do
      params = %{
        name: "multi-attach",
        description: "Multiple attachments",
        content: "Content",
        attachments: [
          %{type: "script", filename: "run.sh", content: "#!/bin/bash"},
          %{type: "reference", filename: "readme.md", content: "# README"},
          %{type: "asset", filename: "data.json", content: "{}"}
        ]
      }

      {:ok, skill_path} = Creator.create(params, skills_path: path)

      assert File.exists?(Path.join([skill_path, "scripts", "run.sh"]))
      assert File.exists?(Path.join([skill_path, "references", "readme.md"]))
      assert File.exists?(Path.join([skill_path, "assets", "data.json"]))
    end
  end

  # =============================================================================
  # R12-R14: Frontmatter and Content Tests
  # =============================================================================

  describe "create/2 - frontmatter generation" do
    @tag :r12
    test "generates valid YAML frontmatter", %{skills_path: path, base_name: _base_name} do
      # R12: WHEN create/2 called THEN generated SKILL.md has valid YAML frontmatter
      params = %{
        name: "yaml-test",
        description: "Testing YAML generation",
        content: "Content body"
      }

      {:ok, _skill_path} = Creator.create(params, skills_path: path)

      # Verify we can load the skill back (validates YAML)
      {:ok, skill} = Loader.load_skill("yaml-test", skills_path: path)
      assert skill.name == "yaml-test"
      assert skill.description == "Testing YAML generation"
    end

    @tag :r13
    test "includes metadata in frontmatter", %{skills_path: path, base_name: _base_name} do
      # R13: WHEN create/2 called with metadata THEN metadata included in frontmatter
      params = %{
        name: "with-metadata",
        description: "Has metadata",
        content: "Content",
        metadata: %{
          "complexity" => "high",
          "author" => "test-user",
          "version" => "1.0"
        }
      }

      {:ok, _skill_path} = Creator.create(params, skills_path: path)

      {:ok, skill} = Loader.load_skill("with-metadata", skills_path: path)
      assert skill.metadata["complexity"] == "high"
      assert skill.metadata["author"] == "test-user"
      assert skill.metadata["version"] == "1.0"
    end

    @tag :r14
    test "includes content body after frontmatter", %{skills_path: path, base_name: _base_name} do
      # R14: WHEN create/2 called THEN content appears after frontmatter
      params = %{
        name: "with-content",
        description: "Has content",
        content: "# Main Heading\n\nThis is the skill content body.\n\n- Item 1\n- Item 2"
      }

      {:ok, _skill_path} = Creator.create(params, skills_path: path)

      {:ok, skill} = Loader.load_skill("with-content", skills_path: path)
      assert skill.content =~ "Main Heading"
      assert skill.content =~ "skill content body"
      assert skill.content =~ "Item 1"
    end
  end

  # =============================================================================
  # R15: Return Path
  # =============================================================================

  describe "create/2 - return value" do
    @tag :r15
    test "returns path to created skill directory", %{skills_path: path, base_name: _base_name} do
      # R15: WHEN create/2 succeeds THEN returns {:ok, path} with full skill path
      params = %{
        name: "path-test",
        description: "Test return path",
        content: "Content"
      }

      {:ok, skill_path} = Creator.create(params, skills_path: path)

      assert is_binary(skill_path)
      assert String.ends_with?(skill_path, "path-test")
      assert File.dir?(skill_path)
    end
  end

  # =============================================================================
  # Additional Edge Cases
  # =============================================================================

  describe "create/2 - edge cases" do
    test "validates name before creating", %{skills_path: path, base_name: _base_name} do
      params = %{
        name: "Invalid--Name",
        description: "Bad name",
        content: "Content"
      }

      assert {:error, _reason} = Creator.create(params, skills_path: path)
    end

    test "handles empty content", %{skills_path: path, base_name: _base_name} do
      params = %{
        name: "empty-content",
        description: "Has no content",
        content: ""
      }

      {:ok, skill_path} = Creator.create(params, skills_path: path)
      assert File.exists?(Path.join(skill_path, "SKILL.md"))
    end

    test "handles missing metadata", %{skills_path: path, base_name: _base_name} do
      params = %{
        name: "no-metadata",
        description: "No metadata provided",
        content: "Content"
      }

      {:ok, _skill_path} = Creator.create(params, skills_path: path)

      {:ok, skill} = Loader.load_skill("no-metadata", skills_path: path)
      assert skill.metadata == %{}
    end

    test "handles empty attachments list", %{skills_path: path, base_name: _base_name} do
      params = %{
        name: "no-attachments",
        description: "No attachments",
        content: "Content",
        attachments: []
      }

      {:ok, skill_path} = Creator.create(params, skills_path: path)
      assert File.exists?(Path.join(skill_path, "SKILL.md"))
      refute File.exists?(Path.join(skill_path, "scripts"))
      refute File.exists?(Path.join(skill_path, "references"))
      refute File.exists?(Path.join(skill_path, "assets"))
    end
  end
end
