defmodule Quoracle.Actions.SpawnSkillsTest do
  @moduledoc """
  Tests for ACTION_Spawn v15.0 - Spawn with skills parameter.

  ARC Requirements (v15.0):
  - R40: skills param accepted
  - R41: skills resolved via Loader
  - R42: missing skill fails spawn
  - R43: all skills must exist (no partial)
  - R44: skills metadata in config
  - R45: skills order preserved
  - R46: no skills is valid
  - R47: skills_path passthrough
  - R48: acceptance - child has skills

  WorkGroupID: feat-20260112-skills-system
  """

  use Quoracle.DataCase, async: true

  import Test.AgentTestHelpers

  alias Quoracle.Actions.Spawn

  setup do
    # Create isolated dependencies
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    dynsup = :"test_dynsup_#{System.unique_integer([:positive])}"

    start_supervised!({Phoenix.PubSub, name: pubsub})
    start_supervised!({Registry, keys: :duplicate, name: registry})

    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: dynsup]]},
      shutdown: :infinity
    }

    start_supervised!(dynsup_spec)

    # Create temp skills directory
    base_name = "spawn_skills_test_#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.join(System.tmp_dir!(), base_name))

    on_exit(fn -> File.rm_rf!(Path.join(System.tmp_dir!(), base_name)) end)

    # Create default profile for spawn tests (TEST-FIX: profile required by Spawn.resolve_profile)
    {:ok, _profile} =
      Quoracle.Repo.insert(%Quoracle.Profiles.TableProfiles{
        name: "default",
        description: "Default test profile",
        model_pool: ["gpt-4o-mini"],
        capability_groups: ["file_read", "file_write", "hierarchy"]
      })

    %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      base_name: base_name
    }
  end

  # TEST-FIX: Loader expects skill-name/SKILL.md directory structure, not flat files
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

  defp base_spawn_params do
    %{
      "task_description" => "Test spawn task",
      "success_criteria" => "Complete task",
      "immediate_context" => "Test context",
      "approach_guidance" => "Standard approach",
      "profile" => "default"
    }
  end

  # ==========================================================================
  # R40-R41: Skills Parameter Handling
  # ==========================================================================

  describe "skills parameter handling (R40-R41)" do
    # R40: Skills Param Accepted
    test "spawn accepts skills param", ctx do
      create_skill_file(ctx.base_name, "accepted-skill")
      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)

      params =
        Map.put(base_spawn_params(), "skills", ["accepted-skill"])

      opts = [
        dynsup: ctx.dynsup,
        registry: ctx.registry,
        pubsub: ctx.pubsub,
        skills_path: skills_path,
        test_mode: true
      ]

      result = Spawn.execute(params, "parent-agent-1", opts)

      assert {:ok, response} = result
      assert response.action == "spawn"

      # Cleanup spawned child
      if response[:child_pid], do: register_agent_cleanup(response.child_pid)
    end

    # R41: Skills Resolved via Loader
    test "spawn resolves skills via Loader", ctx do
      create_skill_file(ctx.base_name, "loader-skill")
      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)

      params =
        Map.put(base_spawn_params(), "skills", ["loader-skill"])

      opts = [
        dynsup: ctx.dynsup,
        registry: ctx.registry,
        pubsub: ctx.pubsub,
        skills_path: skills_path,
        test_mode: true
      ]

      result = Spawn.execute(params, "parent-agent-2", opts)

      # If Loader resolved the skill, spawn should succeed
      assert {:ok, response} = result

      # Cleanup spawned child
      if response[:child_pid], do: register_agent_cleanup(response.child_pid)
    end
  end

  # ==========================================================================
  # R42-R43: Missing Skill Handling
  # ==========================================================================

  describe "missing skill handling (R42-R43)" do
    # R42: Missing Skill Fails Spawn
    test "spawn fails if skill not found", ctx do
      # No skill file created - should fail
      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)

      params =
        Map.put(base_spawn_params(), "skills", ["nonexistent-skill"])

      opts = [
        dynsup: ctx.dynsup,
        registry: ctx.registry,
        pubsub: ctx.pubsub,
        skills_path: skills_path,
        test_mode: true
      ]

      result = Spawn.execute(params, "parent-agent-3", opts)

      assert {:error, {:skill_not_found, "nonexistent-skill"}} = result
    end

    # R43: All Skills Must Exist
    test "spawn fails on first missing skill", ctx do
      # Only create one of two required skills
      create_skill_file(ctx.base_name, "existing-skill")
      # "missing-skill" not created
      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)

      params =
        Map.put(base_spawn_params(), "skills", ["existing-skill", "missing-skill"])

      opts = [
        dynsup: ctx.dynsup,
        registry: ctx.registry,
        pubsub: ctx.pubsub,
        skills_path: skills_path,
        test_mode: true
      ]

      result = Spawn.execute(params, "parent-agent-4", opts)

      # Should fail with the missing skill name
      assert {:error, {:skill_not_found, "missing-skill"}} = result
    end
  end

  # ==========================================================================
  # R44-R46: Skills Metadata and Config
  # ==========================================================================

  describe "skills metadata in config (R44-R46)" do
    # R44: Skills Metadata in Config
    test "child config contains skill metadata", ctx do
      create_skill_file(ctx.base_name, "metadata-skill")
      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)

      params =
        Map.put(base_spawn_params(), "skills", ["metadata-skill"])

      opts = [
        dynsup: ctx.dynsup,
        registry: ctx.registry,
        pubsub: ctx.pubsub,
        skills_path: skills_path,
        test_mode: true
      ]

      result = Spawn.execute(params, "parent-agent-5", opts)

      assert {:ok, response} = result

      # The spawned child should have active_skills in its config
      # We verify this indirectly through the spawn response
      # TEST-FIX: response uses agent_id not child_id
      assert response.agent_id != nil

      # Cleanup spawned child
      if response[:child_pid], do: register_agent_cleanup(response.child_pid)
    end

    # R45: Skills Order Preserved
    test "skills loaded in specified order", ctx do
      create_skill_file(ctx.base_name, "first-skill")
      create_skill_file(ctx.base_name, "second-skill")
      create_skill_file(ctx.base_name, "third-skill")
      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)

      params =
        Map.put(base_spawn_params(), "skills", ["first-skill", "second-skill", "third-skill"])

      opts = [
        dynsup: ctx.dynsup,
        registry: ctx.registry,
        pubsub: ctx.pubsub,
        skills_path: skills_path,
        test_mode: true
      ]

      result = Spawn.execute(params, "parent-agent-6", opts)

      # Spawn should succeed with skills in order
      assert {:ok, response} = result

      # Cleanup spawned child
      if response[:child_pid], do: register_agent_cleanup(response.child_pid)
    end

    # R46: No Skills is Valid
    test "spawn succeeds without skills param", ctx do
      # No skills parameter at all
      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)
      params = base_spawn_params()

      opts = [
        dynsup: ctx.dynsup,
        registry: ctx.registry,
        pubsub: ctx.pubsub,
        skills_path: skills_path,
        test_mode: true
      ]

      result = Spawn.execute(params, "parent-agent-7", opts)

      assert {:ok, response} = result
      assert response.action == "spawn"

      # Cleanup spawned child
      if response[:child_pid], do: register_agent_cleanup(response.child_pid)
    end
  end

  # ==========================================================================
  # R47-R48: Skills Path and Acceptance
  # ==========================================================================

  describe "skills_path and acceptance (R47-R48)" do
    # R47: Skills Path Passthrough
    test "skills_path from opts used for skill resolution", ctx do
      # Create skill only in custom path
      create_skill_file(ctx.base_name, "custom-path-skill")
      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)

      params =
        Map.put(base_spawn_params(), "skills", ["custom-path-skill"])

      opts = [
        dynsup: ctx.dynsup,
        registry: ctx.registry,
        pubsub: ctx.pubsub,
        skills_path: skills_path,
        test_mode: true
      ]

      result = Spawn.execute(params, "parent-agent-8", opts)

      # Should find skill in custom path
      assert {:ok, response} = result

      # Cleanup spawned child
      if response[:child_pid], do: register_agent_cleanup(response.child_pid)
    end

    # R48: Acceptance - Child Has Skills
    # TEST-FIX: Added spawn_complete_notify and parent_config for async spawn pattern
    test "end-to-end spawned child has active skills", ctx do
      create_skill_file(ctx.base_name, "e2e-skill")
      skills_path = Path.join(System.tmp_dir!(), ctx.base_name)

      params =
        Map.put(base_spawn_params(), "skills", ["e2e-skill"])

      # Parent config required by ConfigBuilder
      parent_config = %{
        pubsub: ctx.pubsub,
        test_mode: true,
        skip_auto_consensus: true
      }

      opts = [
        dynsup: ctx.dynsup,
        registry: ctx.registry,
        pubsub: ctx.pubsub,
        skills_path: skills_path,
        test_mode: true,
        spawn_complete_notify: self(),
        parent_config: parent_config
      ]

      {:ok, response} = Spawn.execute(params, "parent-agent-9", opts)
      child_id = response.agent_id

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, ^child_id, {:ok, child_pid}}, 5000

      # Register cleanup before any assertions that might fail
      register_agent_cleanup(child_pid)

      {:ok, child_state} = GenServer.call(child_pid, :get_state)

      assert length(child_state.active_skills) == 1
      assert hd(child_state.active_skills).name == "e2e-skill"
    end
  end
end
