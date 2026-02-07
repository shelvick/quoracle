defmodule Quoracle.Actions.RouterSkillsTest do
  @moduledoc """
  Tests for ACTION_Router v25.0 - Skills System action routing.

  ARC Requirements (v25.0):
  - R20-R21: ActionMapper entries for skill actions
  - R22: No access control for skill actions
  - R23: skills_path passed in opts
  - R25-R26: End-to-end routing for skill actions

  WorkGroupID: feat-20260112-skills-system
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Router
  alias Quoracle.Actions.Router.ActionMapper

  # ==========================================================================
  # R20-R21: ActionMapper Entries
  # ==========================================================================

  describe "ActionMapper skill action mappings (R20-R21)" do
    # R20: ActionMapper Includes learn_skills
    test "ActionMapper routes learn_skills to LearnSkills module" do
      result = ActionMapper.get_action_module(:learn_skills)
      assert {:ok, Quoracle.Actions.LearnSkills} = result
    end

    # R21: ActionMapper Includes create_skill
    test "ActionMapper routes create_skill to CreateSkill module" do
      result = ActionMapper.get_action_module(:create_skill)
      assert {:ok, Quoracle.Actions.CreateSkill} = result
    end
  end

  # ==========================================================================
  # R22: No Access Control
  # ==========================================================================

  describe "skill actions access control (R22)" do
    setup do
      # Create isolated test environment
      pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
      registry = :"test_registry_#{System.unique_integer([:positive])}"

      start_supervised!({Phoenix.PubSub, name: pubsub})
      start_supervised!({Registry, keys: :duplicate, name: registry})

      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      # Per-action Router (v28.0)
      {:ok, router} =
        Router.start_link(
          action_type: :learn_skills,
          action_id: "action-#{System.unique_integer([:positive])}",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub
        )

      # Create temp skills directory for test isolation
      base_name = "router_skills_test_#{System.unique_integer([:positive])}"
      File.mkdir_p!(Path.join(System.tmp_dir!(), base_name))

      on_exit(fn ->
        File.rm_rf!(Path.join(System.tmp_dir!(), base_name))

        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{
        pubsub: pubsub,
        registry: registry,
        router: router,
        base_name: base_name,
        agent_id: agent_id
      }
    end

    # R22: No Access Control for Skill Actions
    test "skill actions accessible to all agents", %{
      router: router,
      pubsub: pubsub,
      base_name: base_name
    } do
      skills_path = Path.join(System.tmp_dir!(), base_name)

      # Skill actions are available to any agent
      opts = [
        skills_path: skills_path,
        pubsub: pubsub
      ]

      # learn_skills should work for any agent
      params = %{"skills" => ["test"]}

      # This test verifies no :unauthorized error is returned
      # The action may fail for other reasons (skill not found), but not access control
      result = Router.execute(router, :learn_skills, params, "test-agent-1", opts)

      case result do
        {:error, :unauthorized} ->
          flunk("learn_skills should be available to any agent")

        {:error, :action_not_allowed} ->
          flunk("learn_skills should be allowed for all agents")

        _ ->
          # Any other result (success or other error) is acceptable
          :ok
      end
    end
  end

  # ==========================================================================
  # R23: skills_path Passthrough
  # ==========================================================================

  describe "skills_path passthrough (R23)" do
    setup do
      pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})

      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      # Per-action Router (v28.0)
      {:ok, router} =
        Router.start_link(
          action_type: :learn_skills,
          action_id: "action-#{System.unique_integer([:positive])}",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub
        )

      base_name = "router_skills_path_test_#{System.unique_integer([:positive])}"
      File.mkdir_p!(Path.join(System.tmp_dir!(), base_name))

      # Create a test skill directory with SKILL.md
      skill_dir = Path.join([System.tmp_dir!(), base_name, "test-skill"])
      File.mkdir_p!(skill_dir)

      skill_content = """
      ---
      name: test-skill
      description: A test skill for router testing
      ---
      # Test Skill Content
      """

      skill_file = Path.join(skill_dir, "SKILL.md")
      File.write!(skill_file, skill_content)

      on_exit(fn ->
        File.rm_rf!(Path.join(System.tmp_dir!(), base_name))

        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{base_name: base_name, router: router, pubsub: pubsub, agent_id: agent_id}
    end

    # R23: skills_path Passed in Opts
    test "Router passes skills_path in opts to skill actions", %{
      router: router,
      pubsub: pubsub,
      base_name: base_name
    } do
      skills_path = Path.join(System.tmp_dir!(), base_name)
      opts = [skills_path: skills_path, pubsub: pubsub]
      params = %{"skills" => ["test-skill"]}

      # The Router should pass skills_path to the action module
      # If skills_path is not passed, the action would use default path
      result = Router.execute(router, :learn_skills, params, "test-agent-2", opts)

      # Verify the action received the skills_path
      # A successful load from the custom path proves skills_path was passed
      assert {:ok, %{action: "learn_skills"}} = result
    end
  end

  # ==========================================================================
  # R25-R26: End-to-End Routing
  # ==========================================================================

  describe "skill action end-to-end routing (R25-R26)" do
    setup do
      pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})

      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      # Per-action Router (v28.0)
      {:ok, router} =
        Router.start_link(
          action_type: :learn_skills,
          action_id: "action-#{System.unique_integer([:positive])}",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub
        )

      base_name = "router_e2e_test_#{System.unique_integer([:positive])}"
      File.mkdir_p!(Path.join(System.tmp_dir!(), base_name))

      # Create test skill directory with SKILL.md
      skill_dir = Path.join([System.tmp_dir!(), base_name, "e2e-skill"])
      File.mkdir_p!(skill_dir)

      skill_content = """
      ---
      name: e2e-skill
      description: E2E test skill
      ---
      # E2E Skill Content
      """

      skill_file = Path.join(skill_dir, "SKILL.md")
      File.write!(skill_file, skill_content)

      on_exit(fn ->
        File.rm_rf!(Path.join(System.tmp_dir!(), base_name))

        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{base_name: base_name, router: router, pubsub: pubsub, agent_id: agent_id}
    end

    # R25: learn_skills End-to-End
    test "Router correctly routes learn_skills action", %{
      router: router,
      pubsub: pubsub,
      base_name: base_name
    } do
      skills_path = Path.join(System.tmp_dir!(), base_name)
      opts = [skills_path: skills_path, pubsub: pubsub]
      params = %{"skills" => ["e2e-skill"]}

      result = Router.execute(router, :learn_skills, params, "test-agent-4", opts)

      assert {:ok, response} = result
      assert response.action == "learn_skills"
    end

    # R26: create_skill End-to-End
    test "Router correctly routes create_skill action", %{
      router: router,
      pubsub: pubsub,
      base_name: base_name
    } do
      skills_path = Path.join(System.tmp_dir!(), base_name)
      opts = [skills_path: skills_path, pubsub: pubsub]

      params = %{
        "name" => "new-test-skill",
        "description" => "A newly created skill",
        "content" => "# New Skill\n\nThis is a new skill."
      }

      result = Router.execute(router, :create_skill, params, "test-agent-5", opts)

      assert {:ok, response} = result
      assert response.action == "create_skill"
    end
  end
end
