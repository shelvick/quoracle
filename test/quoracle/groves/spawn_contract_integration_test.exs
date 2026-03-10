defmodule Quoracle.Groves.SpawnContractIntegrationTest do
  @moduledoc """
  Acceptance/integration coverage for Grove spawn contract packet 2.

  ARC criteria covered in this file:
  - R27: Spawn succeeds on unmatched topology warning path
  - R30: Full grove to spawn flow auto-injects edge configuration into child
  """

  use Quoracle.DataCase, async: true

  import Test.AgentTestHelpers,
    only: [create_test_profile: 0, register_agent_cleanup: 1, register_agent_cleanup: 2]

  alias Quoracle.Agent.Core
  alias Quoracle.Groves.Loader
  alias Quoracle.Tasks.TaskManager

  @moduletag :feat_grove_system
  @moduletag :packet_2

  describe "spawn contract integration" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      profile = create_test_profile()

      fixture = create_spawn_contract_fixture(profile.name)

      on_exit(fn ->
        File.rm_rf!(Path.join(System.tmp_dir!(), fixture.base_name))
      end)

      {:ok, grove} = Loader.load_grove(fixture.grove_name, groves_path: fixture.groves_path)

      {:ok,
       deps: deps,
       profile: profile,
       sandbox_owner: sandbox_owner,
       topology: grove.topology,
       grove_path: grove.path,
       grove_skills_path: grove.skills_path}
    end

    test "R27: spawn succeeds on unmatched topology warning path", ctx do
      task_fields = %{profile: ctx.profile.name, skills: ["factory-oversight"]}
      agent_fields = %{task_description: "Root task for unmatched edge path"}

      assert {:ok, {_task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: ctx.sandbox_owner,
                 registry: ctx.deps.registry,
                 dynsup: ctx.deps.dynsup,
                 pubsub: ctx.deps.pubsub,
                 grove_skills_path: ctx.grove_skills_path,
                 grove_topology: ctx.topology,
                 grove_path: ctx.grove_path,
                 test_opts: [model_query_fn: capturing_model_query_fn(self())]
               )

      register_agent_cleanup(root_pid, cleanup_tree: true, registry: ctx.deps.registry)

      # Use child skills that do not match the only configured edge child (operations-observer).
      action_id = "spawn-contract-unmatched-action-1"

      assert {:ok, %{pid: child_pid, agent_id: child_id}} =
               GenServer.call(
                 root_pid,
                 {
                   :process_action,
                   %{
                     action: "spawn_child",
                     params: %{
                       task_description: "Child task unmatched edge",
                       success_criteria: "Unmatched edge path still succeeds",
                       immediate_context: "Integration flow",
                       approach_guidance: "Follow parent",
                       skills: ["factory-oversight"],
                       profile: ctx.profile.name
                     }
                   },
                   action_id
                 },
                 30_000
               )

      register_agent_cleanup(child_pid)
      _ = child_id

      assert {:ok, child_state} = Core.get_state(child_pid)
      child_skill_names = Enum.map(child_state.active_skills || [], & &1.name)

      # Positive: spawn succeeds and keeps explicitly requested child shape.
      assert "factory-oversight" in child_skill_names
      assert child_state.profile_name == ctx.profile.name

      transformed = child_state.prompt_fields[:transformed] || %{}
      constraints = Map.get(transformed, :constraints, [])

      # Negative: unmatched edge does not inject edge-specific values.
      refute "venture-management" in child_skill_names
      refute child_state.profile_name == "edge-quality"
      refute Enum.any?(constraints, &(&1 =~ "Edge-mandated constraint from topology."))
    end

    @tag :acceptance
    test "R30: full grove to spawn flow auto-injects edge configuration into child", ctx do
      # User entry point: create a task using grove-derived topology context.
      task_fields = %{profile: ctx.profile.name, skills: ["factory-oversight"]}
      agent_fields = %{task_description: "Root task from grove"}

      assert {:ok, {_task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: ctx.sandbox_owner,
                 registry: ctx.deps.registry,
                 dynsup: ctx.deps.dynsup,
                 pubsub: ctx.deps.pubsub,
                 grove_skills_path: ctx.grove_skills_path,
                 grove_topology: ctx.topology,
                 grove_path: ctx.grove_path,
                 test_opts: [model_query_fn: capturing_model_query_fn(self())]
               )

      register_agent_cleanup(root_pid, cleanup_tree: true, registry: ctx.deps.registry)

      # Full-flow prerequisite: root must carry grove topology for spawn path.
      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.get(root_state, :grove_topology) == ctx.topology
      assert Map.get(root_state, :grove_path) == ctx.grove_path

      # System boundary: drive spawn through the agent's :process_action GenServer call,
      # the same public interface the LLM uses at runtime (not the internal Spawn module).
      # LLM omits profile — edge auto_inject provides it as a fallback.
      action_id = "spawn-contract-action-1"

      assert {:ok, %{pid: child_pid, agent_id: child_id}} =
               GenServer.call(
                 root_pid,
                 {
                   :process_action,
                   %{
                     action: "spawn_child",
                     params: %{
                       task_description: "Child task from spawn contract",
                       success_criteria: "Validate edge auto inject",
                       immediate_context: "Acceptance flow",
                       approach_guidance: "Follow parent",
                       skills: ["operations-observer"]
                     }
                   },
                   action_id
                 },
                 30_000
               )

      register_agent_cleanup(child_pid)
      _ = child_id

      assert {:ok, child_state} = Core.get_state(child_pid)
      child_skill_names = Enum.map(child_state.active_skills || [], & &1.name)

      # Positive: edge injects skills/profile/constraints as defaults (LLM omitted profile).
      assert "venture-management" in child_skill_names
      assert "operations-observer" in child_skill_names
      assert child_state.profile_name == "edge-quality"

      transformed = child_state.prompt_fields[:transformed] || %{}
      constraints = Map.get(transformed, :constraints, [])
      assert Enum.any?(constraints, &(&1 =~ "Edge-mandated constraint from topology."))

      # Negative: edge-injected values are not sourced from parent prompt defaults.
      refute child_state.profile_name == ctx.profile.name
      refute Enum.any?(constraints, &(&1 =~ "LLM supplied downstream constraint"))
    end

    @tag :acceptance
    test "regression: explicit LLM profile overrides edge auto_inject profile", ctx do
      task_fields = %{profile: ctx.profile.name, skills: ["factory-oversight"]}
      agent_fields = %{task_description: "Root task for explicit profile precedence"}

      assert {:ok, {_task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: ctx.sandbox_owner,
                 registry: ctx.deps.registry,
                 dynsup: ctx.deps.dynsup,
                 pubsub: ctx.deps.pubsub,
                 grove_skills_path: ctx.grove_skills_path,
                 grove_topology: ctx.topology,
                 grove_path: ctx.grove_path,
                 test_opts: [model_query_fn: capturing_model_query_fn(self())]
               )

      register_agent_cleanup(root_pid, cleanup_tree: true, registry: ctx.deps.registry)

      action_id = "spawn-contract-profile-precedence-action-1"

      assert {:ok, %{pid: child_pid, agent_id: child_id}} =
               GenServer.call(
                 root_pid,
                 {
                   :process_action,
                   %{
                     action: "spawn_child",
                     params: %{
                       task_description: "Child task with explicit profile",
                       success_criteria: "Explicit profile wins over edge default",
                       immediate_context: "Profile precedence regression",
                       approach_guidance: "Preserve explicit LLM intent",
                       skills: ["operations-observer"],
                       profile: ctx.profile.name
                     }
                   },
                   action_id
                 },
                 30_000
               )

      register_agent_cleanup(child_pid)
      _ = child_id

      assert {:ok, child_state} = Core.get_state(child_pid)
      child_skill_names = Enum.map(child_state.active_skills || [], & &1.name)

      # Positive: edge still injects matching skills and constraints.
      assert "venture-management" in child_skill_names
      assert "operations-observer" in child_skill_names

      transformed = child_state.prompt_fields[:transformed] || %{}
      constraints = Map.get(transformed, :constraints, [])
      assert Enum.any?(constraints, &(&1 =~ "Edge-mandated constraint from topology."))

      # Negative: edge profile must not override explicit LLM profile.
      assert child_state.profile_name == ctx.profile.name
      refute child_state.profile_name == "edge-quality"
    end
  end

  defp create_spawn_contract_fixture(profile_name) do
    base_name = "test_spawn_contract_packet2/#{System.unique_integer([:positive])}"
    grove_name = "spawn-contract-grove"

    constraints_dir = Path.join([System.tmp_dir!(), base_name, grove_name, "constraints"])
    File.mkdir_p!(constraints_dir)

    write_skill_manifest(base_name, grove_name, "factory-oversight")
    write_skill_manifest(base_name, grove_name, "venture-management")
    write_skill_manifest(base_name, grove_name, "operations-observer")

    edge_constraint_file = Path.join(constraints_dir, "edge.md")
    File.write!(edge_constraint_file, "Edge-mandated constraint from topology.\n")

    grove_yaml =
      """
      ---
      name: spawn-contract-grove
      description: Spawn contract integration fixture
      version: "1.0"
      bootstrap:
        profile: #{profile_name}
        skills:
          - factory-oversight
      topology:
        edges:
          - parent: factory-oversight
            child: operations-observer
            auto_inject:
              skills:
                - venture-management
              profile: edge-quality
              constraints: constraints/edge.md
      ---
      """

    grove_file = Path.join([System.tmp_dir!(), base_name, grove_name, "GROVE.md"])
    File.write!(grove_file, grove_yaml)

    %{
      base_name: base_name,
      groves_path: Path.join([System.tmp_dir!(), base_name]),
      grove_name: grove_name
    }
  end

  defp write_skill_manifest(base_name, grove_name, skill_name) do
    skill_dir = Path.join([System.tmp_dir!(), base_name, grove_name, "skills", skill_name])
    File.mkdir_p!(skill_dir)

    skill_file = Path.join(skill_dir, "SKILL.md")

    File.write!(skill_file, """
    ---
    name: #{skill_name}
    description: #{skill_name} skill for spawn contract integration
    ---
    ## #{skill_name}

    Skill content for #{skill_name}.
    """)
  end

  defp capturing_model_query_fn(_test_pid) do
    fn _messages, [model_id], _opts ->
      {:ok,
       %{
         successful_responses: [%{model: model_id, content: orient_response()}],
         failed_models: []
       }}
    end
  end

  defp orient_response do
    Jason.encode!(%{
      "action" => "orient",
      "params" => %{
        "current_situation" => "Processing",
        "goal_clarity" => "Clear",
        "available_resources" => "Available",
        "key_challenges" => "None",
        "delegation_consideration" => "none"
      },
      "reasoning" => "Spawn contract integration orient response",
      "wait" => true
    })
  end
end
