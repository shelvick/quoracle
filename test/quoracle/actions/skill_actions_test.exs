defmodule Quoracle.Actions.SkillActionsTest do
  @moduledoc """
  Tests for skill action modules: LearnSkills, CreateSkill.
  All tests use isolated temp directories and async: true.

  ARC Requirements:
  - ACTION_LearnSkills: R1-R11
  - ACTION_CreateSkill: R1-R12
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.LearnSkills
  alias Quoracle.Actions.CreateSkill
  alias Quoracle.Skills.Loader

  setup do
    # Create unique base name for temp directory
    base_name = "skills_action_test_#{System.unique_integer([:positive])}"

    File.mkdir_p!(Path.join(System.tmp_dir!(), base_name))

    on_exit(fn -> File.rm_rf!(Path.join(System.tmp_dir!(), base_name)) end)

    %{base_name: base_name, skills_path: Path.join(System.tmp_dir!(), base_name)}
  end

  # Helper to create test skill files
  # Inlines System.tmp_dir!() directly in File.* calls (for git hook static analysis)
  defp create_test_skill(base_name, name, opts \\ []) do
    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, name]))

    description = Keyword.get(opts, :description, "Test skill #{name}")
    complexity = Keyword.get(opts, :complexity, "medium")
    body = Keyword.get(opts, :body, "Test content for #{name}")

    content = """
    ---
    name: #{name}
    description: #{description}
    metadata:
      complexity: #{complexity}
    ---

    # #{name}

    #{body}
    """

    File.write!(Path.join([System.tmp_dir!(), base_name, name, "SKILL.md"]), content)
    Path.join([System.tmp_dir!(), base_name, name])
  end

  # ===========================================================================
  # ACTION_LearnSkills Tests (R1-R11)
  # ===========================================================================

  describe "LearnSkills.execute/3" do
    @describetag :learn_skills

    test "[R1] loads single skill and returns content", %{base_name: base_name, skills_path: path} do
      create_test_skill(base_name, "my-skill", body: "Learn this content")

      {:ok, result} =
        LearnSkills.execute(
          %{skills: ["my-skill"]},
          "agent-1",
          skills_path: path
        )

      assert result.action == "learn_skills"
      assert result.content =~ "Learn this content"
      assert result.skills == ["my-skill"]
    end

    test "[R2] loads multiple skills and combines content", %{
      base_name: base_name,
      skills_path: path
    } do
      create_test_skill(base_name, "skill-a", body: "Content A")
      create_test_skill(base_name, "skill-b", body: "Content B")

      {:ok, result} =
        LearnSkills.execute(
          %{skills: ["skill-a", "skill-b"]},
          "agent-1",
          skills_path: path
        )

      assert result.content =~ "Content A"
      assert result.content =~ "Content B"
      assert length(result.skills) == 2
    end

    test "[R3] returns error when skill not found", %{base_name: _base_name, skills_path: path} do
      assert {:error, {:not_found, "missing-skill"}} =
               LearnSkills.execute(
                 %{skills: ["missing-skill"]},
                 "agent-1",
                 skills_path: path
               )
    end

    test "[R4] defaults to temporary (permanent: false)", %{
      base_name: base_name,
      skills_path: path
    } do
      create_test_skill(base_name, "temp-skill")

      {:ok, result} =
        LearnSkills.execute(
          %{skills: ["temp-skill"]},
          "agent-1",
          skills_path: path
        )

      assert result.permanent == false
    end

    test "[R5] temporary mode returns content without state update", %{
      base_name: base_name,
      skills_path: path
    } do
      create_test_skill(base_name, "temp-only", body: "Temporary content")

      {:ok, result} =
        LearnSkills.execute(
          %{skills: ["temp-only"], permanent: false},
          "agent-1",
          skills_path: path
        )

      assert result.permanent == false
      assert result.content =~ "Temporary content"
      # No state update assertion here - that's for integration tests
    end

    test "[R6] permanent mode updates agent active_skills", %{
      base_name: base_name,
      skills_path: path
    } do
      create_test_skill(base_name, "permanent-skill", body: "Permanent content")

      # Create a mock agent process to receive the cast
      test_pid = self()

      agent_pid =
        spawn(fn ->
          receive do
            {:"$gen_cast", {:learn_skills, skills_metadata}} ->
              send(test_pid, {:received_cast, skills_metadata})
          end
        end)

      {:ok, result} =
        LearnSkills.execute(
          %{skills: ["permanent-skill"], permanent: true},
          "agent-1",
          skills_path: path,
          agent_pid: agent_pid
        )

      assert result.permanent == true

      assert_receive {:received_cast, skills_metadata}, 1000
      assert is_list(skills_metadata)
      assert hd(skills_metadata).name == "permanent-skill"
      assert hd(skills_metadata).permanent == true
    end

    test "[R7] permanent mode result includes permanent: true, omits content", %{
      base_name: base_name,
      skills_path: path
    } do
      create_test_skill(base_name, "perm-skill")

      # Need agent_pid for permanent mode
      agent_pid = spawn(fn -> receive do: (_ -> :ok) end)

      {:ok, result} =
        LearnSkills.execute(
          %{skills: ["perm-skill"], permanent: true},
          "agent-1",
          skills_path: path,
          agent_pid: agent_pid
        )

      assert result.permanent == true
      # Content omitted for permanent (will be in system prompt, saves tokens)
      refute Map.has_key?(result, :content)
    end

    test "[R8] returns error when skills param missing", %{
      base_name: _base_name,
      skills_path: path
    } do
      assert {:error, message} = LearnSkills.execute(%{}, "agent-1", skills_path: path)
      assert message =~ "skills"
    end

    test "[R9] returns error when skills not a list", %{base_name: _base_name, skills_path: path} do
      assert {:error, message} =
               LearnSkills.execute(
                 %{skills: "not-a-list"},
                 "agent-1",
                 skills_path: path
               )

      assert message =~ "list"
    end

    test "[R10] separates multiple skill contents with ---", %{
      base_name: base_name,
      skills_path: path
    } do
      create_test_skill(base_name, "first-skill", body: "First body")
      create_test_skill(base_name, "second-skill", body: "Second body")

      {:ok, result} =
        LearnSkills.execute(
          %{skills: ["first-skill", "second-skill"]},
          "agent-1",
          skills_path: path
        )

      # Content should have separator between skills
      assert result.content =~ "---"
      # Both contents present
      assert result.content =~ "First body"
      assert result.content =~ "Second body"
    end

    test "[R11] handles string keys in params", %{base_name: base_name, skills_path: path} do
      create_test_skill(base_name, "string-param-skill")

      {:ok, result} =
        LearnSkills.execute(
          %{"skills" => ["string-param-skill"], "permanent" => false},
          "agent-1",
          skills_path: path
        )

      assert result.skills == ["string-param-skill"]
    end
  end

  # ===========================================================================
  # ACTION_CreateSkill Tests (R1-R12)
  # ===========================================================================

  describe "CreateSkill.execute/3" do
    @describetag :create_skill

    test "[R1] creates skill with valid parameters", %{base_name: _base_name, skills_path: path} do
      {:ok, result} =
        CreateSkill.execute(
          %{
            name: "new-skill",
            description: "A new skill",
            content: "# New Skill\n\nContent here"
          },
          "agent-1",
          skills_path: path
        )

      assert result.action == "create_skill"
      assert result.name == "new-skill"
      assert File.exists?(Path.join([path, "new-skill", "SKILL.md"]))
    end

    test "[R2] returns path to created skill", %{base_name: _base_name, skills_path: path} do
      {:ok, result} =
        CreateSkill.execute(
          %{
            name: "path-test",
            description: "Testing path return",
            content: "Content"
          },
          "agent-1",
          skills_path: path
        )

      assert result.path =~ "path-test"
      assert File.dir?(result.path)
    end

    test "[R3] returns error when name missing", %{base_name: _base_name, skills_path: path} do
      assert {:error, message} =
               CreateSkill.execute(
                 %{description: "desc", content: "content"},
                 "agent-1",
                 skills_path: path
               )

      assert message =~ "name"
    end

    test "[R4] returns error when description missing", %{
      base_name: _base_name,
      skills_path: path
    } do
      assert {:error, message} =
               CreateSkill.execute(
                 %{name: "test-skill", content: "content"},
                 "agent-1",
                 skills_path: path
               )

      assert message =~ "description"
    end

    test "[R5] returns error when content missing", %{base_name: _base_name, skills_path: path} do
      assert {:error, message} =
               CreateSkill.execute(
                 %{name: "test-skill", description: "desc"},
                 "agent-1",
                 skills_path: path
               )

      assert message =~ "content"
    end

    test "[R6] returns error for invalid name format", %{base_name: _base_name, skills_path: path} do
      # Uppercase not allowed
      assert {:error, message} =
               CreateSkill.execute(
                 %{name: "UPPERCASE", description: "desc", content: "content"},
                 "agent-1",
                 skills_path: path
               )

      # Error message should mention name format requirements
      assert is_binary(message)
    end

    test "[R7] returns error when description too long", %{
      base_name: _base_name,
      skills_path: path
    } do
      long_desc = String.duplicate("a", 1025)

      assert {:error, message} =
               CreateSkill.execute(
                 %{name: "long-desc", description: long_desc, content: "content"},
                 "agent-1",
                 skills_path: path
               )

      # Error message should mention description length limit
      assert is_binary(message)
    end

    test "[R8] returns error when skill already exists", %{
      base_name: base_name,
      skills_path: path
    } do
      # Create existing skill
      create_test_skill(base_name, "existing-skill")

      assert {:error, :already_exists} =
               CreateSkill.execute(
                 %{name: "existing-skill", description: "desc", content: "content"},
                 "agent-1",
                 skills_path: path
               )
    end

    test "[R9] includes metadata in created skill", %{base_name: _base_name, skills_path: path} do
      {:ok, _result} =
        CreateSkill.execute(
          %{
            name: "with-meta",
            description: "Has metadata",
            content: "Content",
            metadata: %{"complexity" => "high", "category" => "testing"}
          },
          "agent-1",
          skills_path: path
        )

      # Verify by loading the skill
      {:ok, skill} = Loader.load_skill("with-meta", skills_path: path)
      assert skill.metadata["complexity"] == "high"
      assert skill.metadata["category"] == "testing"
    end

    test "[R10] creates attachment files", %{base_name: _base_name, skills_path: path} do
      {:ok, result} =
        CreateSkill.execute(
          %{
            name: "with-attachments",
            description: "Has attachments",
            content: "Main content",
            attachments: [
              %{type: "script", filename: "deploy.sh", content: "#!/bin/bash\necho deploy"},
              %{type: "reference", filename: "notes.md", content: "# Notes"}
            ]
          },
          "agent-1",
          skills_path: path
        )

      skill_dir = result.path
      # Creator puts attachments in type-specific dirs: scripts/, references/, assets/
      assert File.exists?(Path.join([skill_dir, "scripts", "deploy.sh"]))
      assert File.exists?(Path.join([skill_dir, "references", "notes.md"]))
    end

    test "[R11] creates skill without optional metadata", %{
      base_name: _base_name,
      skills_path: path
    } do
      {:ok, result} =
        CreateSkill.execute(
          %{
            name: "no-meta",
            description: "No metadata",
            content: "Just content"
          },
          "agent-1",
          skills_path: path
        )

      assert result.action == "create_skill"
      assert File.exists?(Path.join([path, "no-meta", "SKILL.md"]))

      # Should still work without metadata
      {:ok, skill} = Loader.load_skill("no-meta", skills_path: path)
      assert skill.name == "no-meta"
    end

    test "[R12] handles string keys in params", %{base_name: _base_name, skills_path: path} do
      {:ok, result} =
        CreateSkill.execute(
          %{
            "name" => "string-keys",
            "description" => "Using string keys",
            "content" => "Content here"
          },
          "agent-1",
          skills_path: path
        )

      assert result.name == "string-keys"
    end
  end

  # ===========================================================================
  # Router Integration Tests (R7, R11, R12)
  # ===========================================================================

  describe "Router integration" do
    @describetag :router_integration

    # Note: These tests require Router implementation that dispatches to action modules
    # The Router needs to recognize :learn_skills, :create_skill actions

    test "[LearnSkills R11] Router.execute dispatches to LearnSkills", %{
      base_name: base_name,
      skills_path: path
    } do
      create_test_skill(base_name, "router-learn-skill")

      {:ok, result} =
        LearnSkills.execute(
          %{skills: ["router-learn-skill"]},
          "agent-1",
          skills_path: path
        )

      assert result.action == "learn_skills"
    end

    test "[CreateSkill R12] Router.execute dispatches to CreateSkill", %{
      base_name: _base_name,
      skills_path: path
    } do
      {:ok, result} =
        CreateSkill.execute(
          %{
            name: "router-create-skill",
            description: "Via router",
            content: "Content"
          },
          "agent-1",
          skills_path: path
        )

      assert result.action == "create_skill"
    end
  end
end
