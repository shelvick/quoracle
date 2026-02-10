defmodule Quoracle.Tasks.TaskManagerSkillsTest do
  @moduledoc """
  Tests for TASK_Manager v7.0 - Skill resolution for root agents.

  ARC Requirements (v7.0 - feat-20260205-root-skills):
  - R29: Skills resolved before spawn
  - R30: Active skills in agent config
  - R31: Empty skills valid
  - R32: Skill not found error
  - R33: Fail-fast on first invalid
  - R34: Skills path injection
  - R35: Skill content available to agent

  WorkGroupID: feat-20260205-root-skills
  """

  use Quoracle.DataCase, async: true

  import Test.AgentTestHelpers

  alias Quoracle.Tasks.TaskManager
  alias Quoracle.Agent.Core

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated PubSub for test isolation
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    # Create isolated Registry
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})

    # Create isolated DynSup with :infinity shutdown
    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
      shutdown: :infinity
    }

    {:ok, dynsup} = start_supervised(dynsup_spec)

    # Create temp skills directory base name (passed to create_skill_file)
    base_name = "task_skills_test_#{System.unique_integer([:positive])}"
    skills_path = Path.join(System.tmp_dir!(), base_name)
    File.mkdir_p!(skills_path)

    on_exit(fn -> File.rm_rf!(Path.join(System.tmp_dir!(), base_name)) end)

    # Ensure test profile exists
    profile = create_test_profile()

    deps = %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner,
      profile: profile,
      skills_path: skills_path
    }

    %{deps: deps, skills_path: skills_path, profile: profile, base_name: base_name}
  end

  # Helper to create skill files in temp directory
  # Uses base_name and System.tmp_dir!() directly for pre-commit hook compliance
  defp create_skill_file(base_name, name, content \\ nil) do
    content =
      content ||
        """
        ---
        name: #{name}
        description: Test skill #{name}
        metadata:
          complexity: low
        ---
        # #{name} Skill

        This is the content for #{name}.
        """

    skill_dir = Path.join([System.tmp_dir!(), base_name, name])
    skill_file = Path.join(skill_dir, "SKILL.md")
    File.mkdir_p!(skill_dir)
    File.write!(skill_file, content)
  end

  # ===========================================================================
  # R29-R30: Skills Resolution
  # ===========================================================================

  describe "skill resolution (R29-R30)" do
    # R29: Skills Resolved Before Spawn
    @tag :integration
    test "resolves each skill via SkillLoader", %{
      deps: deps,
      skills_path: skills_path,
      base_name: base_name
    } do
      # Create test skills
      create_skill_file(base_name, "deployment")
      create_skill_file(base_name, "code-review")

      task_fields = %{
        profile: deps.profile.name,
        skills: ["deployment", "code-review"]
      }

      agent_fields = %{task_description: "Test task with skills"}

      assert {:ok, {task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 skills_path: skills_path
               )

      # Wait for agent initialization
      assert {:ok, state} = Core.get_state(root_pid)

      # Cleanup agent
      register_agent_cleanup(root_pid, cleanup_tree: true, registry: deps.registry)

      assert task.id != nil

      # Verify skills were actually resolved (fails before implementation)
      assert length(state.active_skills) == 2
      skill_names = Enum.map(state.active_skills, & &1.name)
      assert "deployment" in skill_names
      assert "code-review" in skill_names
    end

    # R30: Active Skills in Agent Config
    @tag :integration
    test "agent config includes active_skills from resolved skills", %{
      deps: deps,
      skills_path: skills_path,
      base_name: base_name
    } do
      # Create test skill
      create_skill_file(base_name, "deployment")

      task_fields = %{
        profile: deps.profile.name,
        skills: ["deployment"]
      }

      agent_fields = %{task_description: "Test task with skills"}

      assert {:ok, {_task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 skills_path: skills_path
               )

      # Get agent state to verify active_skills
      assert {:ok, state} = Core.get_state(root_pid)

      # Cleanup agent
      register_agent_cleanup(root_pid, cleanup_tree: true, registry: deps.registry)

      # Agent should have active_skills with resolved content
      assert is_list(state.active_skills)
      assert length(state.active_skills) == 1

      [skill] = state.active_skills
      assert skill.name == "deployment"
      assert skill.content =~ "This is the content for deployment"
    end
  end

  # ===========================================================================
  # R31: Empty Skills Valid
  # ===========================================================================

  describe "empty skills (R31)" do
    @tag :integration
    test "empty skills creates task with empty active_skills", %{
      deps: deps,
      skills_path: skills_path,
      base_name: base_name
    } do
      # First verify skills ARE processed when provided (fails before implementation)
      create_skill_file(base_name, "precondition-skill")

      task_fields_with = %{
        profile: deps.profile.name,
        skills: ["precondition-skill"]
      }

      assert {:ok, {_task, pid_with}} =
               TaskManager.create_task(task_fields_with, %{task_description: "Precondition test"},
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 skills_path: skills_path
               )

      assert {:ok, state_with} = Core.get_state(pid_with)
      register_agent_cleanup(pid_with, cleanup_tree: true, registry: deps.registry)

      # This assertion fails before implementation - proves skill resolution works
      assert length(state_with.active_skills) == 1,
             "precondition: skills must be resolved when provided"

      # Now test empty case
      task_fields = %{
        profile: deps.profile.name,
        skills: []
      }

      agent_fields = %{task_description: "Test task without skills"}

      assert {:ok, {task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup
               )

      # Get agent state
      assert {:ok, state} = Core.get_state(root_pid)

      # Cleanup agent
      register_agent_cleanup(root_pid, cleanup_tree: true, registry: deps.registry)

      assert task.id != nil
      # Empty skills should result in empty active_skills
      assert state.active_skills == []
    end

    @tag :integration
    test "nil skills creates task with empty active_skills", %{
      deps: deps,
      skills_path: skills_path,
      base_name: base_name
    } do
      # First verify skills ARE processed when provided (fails before implementation)
      create_skill_file(base_name, "precondition-skill-nil")

      task_fields_with = %{
        profile: deps.profile.name,
        skills: ["precondition-skill-nil"]
      }

      assert {:ok, {_task, pid_with}} =
               TaskManager.create_task(
                 task_fields_with,
                 %{task_description: "Precondition test nil"},
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 skills_path: skills_path
               )

      assert {:ok, state_with} = Core.get_state(pid_with)
      register_agent_cleanup(pid_with, cleanup_tree: true, registry: deps.registry)

      # This assertion fails before implementation - proves skill resolution works
      assert length(state_with.active_skills) == 1,
             "precondition: skills must be resolved when provided"

      # Now test nil case
      task_fields = %{
        profile: deps.profile.name
        # skills not provided (nil)
      }

      agent_fields = %{task_description: "Test task without skills"}

      assert {:ok, {task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup
               )

      # Get agent state
      assert {:ok, state} = Core.get_state(root_pid)

      # Cleanup agent
      register_agent_cleanup(root_pid, cleanup_tree: true, registry: deps.registry)

      assert task.id != nil
      # Nil skills should result in empty active_skills
      assert state.active_skills == []
    end
  end

  # ===========================================================================
  # R32-R33: Error Handling
  # ===========================================================================

  describe "skill not found errors (R32-R33)" do
    # R32: Skill Not Found Error
    @tag :integration
    test "returns error for non-existent skill", %{
      deps: deps,
      skills_path: skills_path,
      base_name: _base_name
    } do
      task_fields = %{
        profile: deps.profile.name,
        skills: ["nonexistent-skill"]
      }

      agent_fields = %{task_description: "Test task with invalid skill"}

      assert {:error, {:skill_not_found, "nonexistent-skill"}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 skills_path: skills_path
               )
    end

    # R33: Fail-Fast on First Invalid
    @tag :integration
    test "fails on first invalid skill without creating task", %{
      deps: deps,
      skills_path: skills_path,
      base_name: base_name
    } do
      # Create only the first skill
      create_skill_file(base_name, "valid-skill")

      task_fields = %{
        profile: deps.profile.name,
        skills: ["valid-skill", "invalid-skill"]
      }

      agent_fields = %{task_description: "Test task with mixed skills"}

      # Should fail on the second (invalid) skill
      assert {:error, {:skill_not_found, "invalid-skill"}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 skills_path: skills_path
               )

      # Verify no task was created (fail-fast before DB)
      tasks = Quoracle.Tasks.TaskManager.list_tasks()
      task_prompts = Enum.map(tasks, & &1.prompt)
      refute "Test task with mixed skills" in task_prompts
    end
  end

  # ===========================================================================
  # R34: Skills Path Injection
  # ===========================================================================

  describe "skills path injection (R34)" do
    @tag :unit
    test "respects skills_path option for test isolation", %{
      deps: deps,
      skills_path: skills_path,
      base_name: base_name
    } do
      # Create skill only in test-specific path
      create_skill_file(base_name, "isolated-skill")

      task_fields = %{
        profile: deps.profile.name,
        skills: ["isolated-skill"]
      }

      agent_fields = %{task_description: "Test with isolated skill"}

      # Should find skill in custom path
      assert {:ok, {_task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 skills_path: skills_path
               )

      # Verify skill was loaded from custom path (fails before implementation)
      assert {:ok, state} = Core.get_state(root_pid)

      # Cleanup
      register_agent_cleanup(root_pid, cleanup_tree: true, registry: deps.registry)

      # Verify the skill was resolved via the custom skills_path
      assert length(state.active_skills) == 1
      [skill] = state.active_skills
      assert skill.name == "isolated-skill"
    end
  end

  # ===========================================================================
  # R35: Skill Content Available to Agent (System Test)
  # ===========================================================================

  describe "skill content in agent (R35)" do
    @tag :system
    test "root agent receives skill content in active_skills", %{
      deps: deps,
      skills_path: skills_path,
      base_name: base_name
    } do
      # Create skill with specific content
      custom_content = """
      ---
      name: custom-skill
      description: A custom test skill with specific content
      metadata:
        complexity: high
        estimated_tokens: 500
      ---
      # Custom Skill

      ## Instructions

      Follow these specific instructions for the custom skill.

      1. First step
      2. Second step
      3. Third step
      """

      create_skill_file(base_name, "custom-skill", custom_content)

      task_fields = %{
        profile: deps.profile.name,
        skills: ["custom-skill"]
      }

      agent_fields = %{task_description: "Test with custom skill content"}

      assert {:ok, {_task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 skills_path: skills_path
               )

      # Get agent state to verify skill content
      assert {:ok, state} = Core.get_state(root_pid)

      # Cleanup
      register_agent_cleanup(root_pid, cleanup_tree: true, registry: deps.registry)

      # Verify skill metadata and content available
      assert length(state.active_skills) == 1

      [skill] = state.active_skills
      assert skill.name == "custom-skill"
      assert skill.description == "A custom test skill with specific content"
      assert skill.content =~ "Follow these specific instructions"
      assert skill.metadata["complexity"] == "high"
    end
  end
end
