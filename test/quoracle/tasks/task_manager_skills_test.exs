defmodule Quoracle.Tasks.TaskManagerSkillsTest do
  @moduledoc """
  Tests for TASK_Manager v7.0 & v8.0 - Skill resolution for root agents.

  ARC Requirements (v7.0 - feat-20260205-root-skills):
  - R29: Skills resolved before spawn
  - R30: Active skills in agent config
  - R31: Empty skills valid
  - R32: Skill not found error
  - R33: Fail-fast on first invalid
  - R34: Skills path injection
  - R35: Skill content available to agent

  ARC Requirements (v8.0 - wip-20260222-grove-bootstrap):
  - R36: create_task forwards grove_skills_path to skill loader
  - R37: create_task without grove_skills_path uses global skills only
  - R38: Grove skill resolved in task (grove-local version loaded)
  - R39: End-to-end grove skill in task config

  WorkGroupID: feat-20260205-root-skills, wip-20260222-grove-bootstrap
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

  # ===========================================================================
  # R36-R39: Grove Skills Path Forwarding (v8.0 - wip-20260222-grove-bootstrap)
  # ===========================================================================

  describe "grove_skills_path forwarding (R36-R39)" do
    # Helper to create a grove skills directory with a skill file
    # Uses grove_base_name and System.tmp_dir!() directly for pre-commit hook compliance
    defp create_grove_skill_file(grove_base_name, name, content \\ nil) do
      content =
        content ||
          """
          ---
          name: #{name}
          description: Grove-local skill #{name}
          metadata:
            source: grove
          ---
          # #{name} (Grove Version)

          This is the GROVE-LOCAL content for #{name}.
          """

      skill_dir = Path.join([System.tmp_dir!(), grove_base_name, name])
      skill_file = Path.join(skill_dir, "SKILL.md")
      File.mkdir_p!(skill_dir)
      File.write!(skill_file, content)
    end

    # R36: create_task forwards grove_skills_path to skill loader
    @tag :integration
    test "create_task forwards grove_skills_path to skill loader", %{
      deps: deps,
      skills_path: skills_path
    } do
      # Create a grove skills directory with a skill that only exists there
      grove_base = "grove_skills_r36_#{System.unique_integer([:positive])}"
      grove_dir = Path.join(System.tmp_dir!(), grove_base)
      File.mkdir_p!(grove_dir)
      on_exit(fn -> File.rm_rf!(Path.join(System.tmp_dir!(), grove_base)) end)

      create_grove_skill_file(grove_base, "grove-only-skill")

      task_fields = %{
        profile: deps.profile.name,
        skills: ["grove-only-skill"]
      }

      agent_fields = %{task_description: "Test grove_skills_path forwarding"}

      # The skill only exists in grove_dir, not in skills_path.
      # If grove_skills_path is forwarded correctly, SkillLoader will find it.
      # If NOT forwarded (current bug), this will fail with {:error, {:skill_not_found, ...}}
      assert {:ok, {_task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 skills_path: skills_path,
                 grove_skills_path: grove_dir
               )

      assert {:ok, state} = Core.get_state(root_pid)
      register_agent_cleanup(root_pid, cleanup_tree: true, registry: deps.registry)

      # Verify the grove-only skill was resolved
      assert length(state.active_skills) == 1
      [skill] = state.active_skills
      assert skill.name == "grove-only-skill"
      assert skill.content =~ "GROVE-LOCAL content"
    end

    # R37: create_task without grove_skills_path uses global skills only
    @tag :unit
    test "create_task without grove_skills_path uses global skills only", %{
      deps: deps,
      skills_path: skills_path,
      base_name: base_name
    } do
      # Create a grove skills directory with a grove-only skill
      grove_base = "grove_skills_r37_#{System.unique_integer([:positive])}"
      grove_dir = Path.join(System.tmp_dir!(), grove_base)
      File.mkdir_p!(grove_dir)
      on_exit(fn -> File.rm_rf!(Path.join(System.tmp_dir!(), grove_base)) end)

      create_grove_skill_file(grove_base, "grove-exclusive-skill")

      # Also create a skill in the global skills_path
      create_skill_file(base_name, "global-only-skill")

      # Part 1: WITHOUT grove_skills_path, grove-exclusive skill should NOT be found
      task_fields_grove = %{
        profile: deps.profile.name,
        skills: ["grove-exclusive-skill"]
      }

      assert {:error, {:skill_not_found, "grove-exclusive-skill"}} =
               TaskManager.create_task(task_fields_grove, %{task_description: "Should fail"},
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 skills_path: skills_path
               )

      # Part 2: WITH grove_skills_path, the same skill should be found
      # This assertion fails before implementation (grove_skills_path not forwarded)
      assert {:ok, {_task, root_pid}} =
               TaskManager.create_task(task_fields_grove, %{task_description: "Should succeed"},
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 skills_path: skills_path,
                 grove_skills_path: grove_dir
               )

      assert {:ok, state} = Core.get_state(root_pid)
      register_agent_cleanup(root_pid, cleanup_tree: true, registry: deps.registry)

      # Confirms grove_skills_path was the difference
      assert length(state.active_skills) == 1
      [skill] = state.active_skills
      assert skill.name == "grove-exclusive-skill"
    end

    # R38: Grove skill resolved in task (grove-local version loaded)
    @tag :integration
    test "task creation resolves grove-local skills", %{
      deps: deps,
      skills_path: skills_path,
      base_name: base_name
    } do
      # Create same-named skill in BOTH global and grove directories
      # Global version
      create_skill_file(base_name, "shared-skill", """
      ---
      name: shared-skill
      description: Global version of shared skill
      metadata:
        source: global
      ---
      # shared-skill (Global)

      This is the GLOBAL content for shared-skill.
      """)

      # Grove version (different content)
      grove_base = "grove_skills_r38_#{System.unique_integer([:positive])}"
      grove_dir = Path.join(System.tmp_dir!(), grove_base)
      File.mkdir_p!(grove_dir)
      on_exit(fn -> File.rm_rf!(Path.join(System.tmp_dir!(), grove_base)) end)

      create_grove_skill_file(grove_base, "shared-skill", """
      ---
      name: shared-skill
      description: Grove-local version of shared skill
      metadata:
        source: grove
      ---
      # shared-skill (Grove)

      This is the GROVE-LOCAL content for shared-skill.
      """)

      task_fields = %{
        profile: deps.profile.name,
        skills: ["shared-skill"]
      }

      agent_fields = %{task_description: "Test grove skill shadowing"}

      # With grove_skills_path, grove version should take precedence
      assert {:ok, {_task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 skills_path: skills_path,
                 grove_skills_path: grove_dir
               )

      assert {:ok, state} = Core.get_state(root_pid)
      register_agent_cleanup(root_pid, cleanup_tree: true, registry: deps.registry)

      # Verify the grove-local version was loaded (not global)
      assert length(state.active_skills) == 1
      [skill] = state.active_skills
      assert skill.name == "shared-skill"
      assert skill.description == "Grove-local version of shared skill"
      assert skill.content =~ "GROVE-LOCAL content"
      refute skill.content =~ "GLOBAL content"
    end

    # R39: End-to-end grove skill in task config
    @tag :system
    test "task from grove uses grove-local skill content in agent config", %{
      deps: deps,
      skills_path: skills_path,
      base_name: base_name
    } do
      # Simulate a grove with its own skills/ directory
      grove_base = "grove_skills_r39_#{System.unique_integer([:positive])}"
      grove_dir = Path.join(System.tmp_dir!(), grove_base)
      File.mkdir_p!(grove_dir)
      on_exit(fn -> File.rm_rf!(Path.join(System.tmp_dir!(), grove_base)) end)

      # Create a grove-local skill with detailed content
      grove_skill_content = """
      ---
      name: deploy
      description: Grove-specific deployment procedure
      metadata:
        source: grove
        complexity: high
        estimated_tokens: 2000
      ---
      # Deploy (Grove-Specific)

      ## Grove Deployment Instructions

      1. Run grove-specific pre-checks
      2. Deploy using grove configuration
      3. Verify grove endpoints

      This deployment process is specific to this grove's infrastructure.
      """

      create_grove_skill_file(grove_base, "deploy", grove_skill_content)

      # Also create a global version with different content
      create_skill_file(base_name, "deploy", """
      ---
      name: deploy
      description: Generic global deployment
      metadata:
        source: global
        complexity: low
      ---
      # Deploy (Global)

      Generic global deployment instructions.
      """)

      task_fields = %{
        profile: deps.profile.name,
        skills: ["deploy"]
      }

      agent_fields = %{task_description: "Deploy using grove configuration"}

      # Create task as if from a grove (with grove_skills_path)
      assert {:ok, {task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: deps.sandbox_owner,
                 pubsub: deps.pubsub,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 skills_path: skills_path,
                 grove_skills_path: grove_dir
               )

      assert {:ok, state} = Core.get_state(root_pid)
      register_agent_cleanup(root_pid, cleanup_tree: true, registry: deps.registry)

      # Verify end-to-end: task was created
      assert task.id != nil
      assert task.status == "running"

      # Verify agent has grove-local skill content (not global version)
      assert length(state.active_skills) == 1
      [skill] = state.active_skills

      # Positive assertions: grove-specific content present
      assert skill.name == "deploy"
      assert skill.description == "Grove-specific deployment procedure"
      assert skill.content =~ "Grove Deployment Instructions"
      assert skill.content =~ "grove-specific pre-checks"
      assert skill.metadata["source"] == "grove"

      # Negative assertions: global content absent
      refute skill.content =~ "Generic global deployment"
      refute skill.description =~ "Generic global"
    end
  end
end
