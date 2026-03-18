defmodule Quoracle.Groves.SpawnContractIntegrationTest do
  @moduledoc """
  Acceptance/integration coverage for Grove spawn contract packets 2 and 3.

  ARC criteria covered in this file:
  - R27: Spawn succeeds on unmatched topology warning path
  - R30: Full grove to spawn flow auto-injects edge configuration into child
  - R64: Child confinement templates resolved via grove_vars
  - R65: Child confinement unresolved without grove_vars
  - R66: grove_vars ignored when no topology edge matches
  """

  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog

  import Test.AgentTestHelpers,
    only: [create_test_profile: 0, register_agent_cleanup: 1, register_agent_cleanup: 2]

  alias Quoracle.Agent.Core
  alias Quoracle.Groves.Loader
  alias Quoracle.Tasks.TaskManager

  @moduletag :feat_grove_system
  @moduletag :packet_2
  @moduletag :packet_3

  describe "spawn contract integration" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      profile = create_test_profile()

      fixture = create_spawn_contract_fixture(profile.name)

      on_exit(fn ->
        File.rm_rf!(fixture.base_dir)
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

  describe "template variable resolution in spawn" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      profile = create_test_profile()

      fixture = create_grove_vars_fixture(profile.name)

      on_exit(fn ->
        File.rm_rf!(fixture.base_dir)
      end)

      {:ok, grove} = Loader.load_grove(fixture.grove_name, groves_path: fixture.groves_path)

      {:ok,
       deps: deps,
       profile: profile,
       sandbox_owner: sandbox_owner,
       grove: grove,
       topology: grove.topology,
       grove_path: grove.path,
       grove_confinement: grove.confinement,
       grove_confinement_mode: grove.confinement_mode,
       grove_skills_path: grove.skills_path}
    end

    @tag :r64
    test "R64: child confinement templates resolved via grove_vars", ctx do
      task_fields = %{profile: ctx.profile.name, skills: ["factory-oversight"]}
      agent_fields = %{task_description: "Root task for grove_vars template resolution"}

      assert {:ok, {_task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: ctx.sandbox_owner,
                 registry: ctx.deps.registry,
                 dynsup: ctx.deps.dynsup,
                 pubsub: ctx.deps.pubsub,
                 grove_skills_path: ctx.grove_skills_path,
                 grove_topology: ctx.topology,
                 grove_path: ctx.grove_path,
                 grove_confinement: ctx.grove_confinement,
                 grove_confinement_mode: ctx.grove_confinement_mode,
                 test_opts: [model_query_fn: simple_orient_fn()]
               )

      register_agent_cleanup(root_pid, cleanup_tree: true, registry: ctx.deps.registry)

      action_id = "spawn-grove-vars-r64-1"

      assert {:ok, %{pid: child_pid}} =
               GenServer.call(
                 root_pid,
                 {
                   :process_action,
                   %{
                     action: "spawn_child",
                     params: %{
                       task_description: "Child with template grove_vars",
                       success_criteria: "Confinement paths are resolved",
                       immediate_context: "grove_vars integration",
                       approach_guidance: "Use resolved paths",
                       skills: ["operations-observer"],
                       profile: ctx.profile.name,
                       grove_vars: %{"child_workspace" => "venture-alpha"}
                     }
                   },
                   action_id
                 },
                 30_000
               )

      register_agent_cleanup(child_pid)

      assert {:ok, child_state} = Core.get_state(child_pid)
      assert child_state.grove_confinement_mode == "strict"

      child_skill_names = Enum.map(child_state.active_skills || [], & &1.name)
      assert "operations-observer" in child_skill_names
      assert "venture-management" in child_skill_names

      all_paths = confinement_paths(child_state.grove_confinement)

      assert Enum.any?(all_paths, &String.contains?(&1, "venture-alpha"))
      refute Enum.any?(all_paths, &String.contains?(&1, "{child_workspace}"))
    end

    @tag :r65
    test "R65: child confinement unresolved without grove_vars", ctx do
      capture_log(fn ->
        task_fields = %{profile: ctx.profile.name, skills: ["factory-oversight"]}
        agent_fields = %{task_description: "Root task for unresolved template path"}

        assert {:ok, {_task, root_pid}} =
                 TaskManager.create_task(task_fields, agent_fields,
                   sandbox_owner: ctx.sandbox_owner,
                   registry: ctx.deps.registry,
                   dynsup: ctx.deps.dynsup,
                   pubsub: ctx.deps.pubsub,
                   grove_skills_path: ctx.grove_skills_path,
                   grove_topology: ctx.topology,
                   grove_path: ctx.grove_path,
                   grove_confinement: ctx.grove_confinement,
                   grove_confinement_mode: ctx.grove_confinement_mode,
                   test_opts: [model_query_fn: simple_orient_fn()]
                 )

        register_agent_cleanup(root_pid, cleanup_tree: true, registry: ctx.deps.registry)

        action_id = "spawn-grove-vars-r65-1"

        assert {:ok, %{pid: child_pid}} =
                 GenServer.call(
                   root_pid,
                   {
                     :process_action,
                     %{
                       action: "spawn_child",
                       params: %{
                         task_description: "Child without grove_vars",
                         success_criteria: "Confinement paths remain as templates",
                         immediate_context: "No grove_vars provided",
                         approach_guidance: "Proceed without variable resolution",
                         skills: ["operations-observer"],
                         profile: ctx.profile.name
                       }
                     },
                     action_id
                   },
                   30_000
                 )

        register_agent_cleanup(child_pid)

        assert {:ok, child_state} = Core.get_state(child_pid)
        assert child_state.grove_confinement_mode == "strict"

        all_paths = confinement_paths(child_state.grove_confinement)
        assert Enum.any?(all_paths, &String.contains?(&1, "{child_workspace}"))
        refute Enum.any?(all_paths, &String.contains?(&1, "venture-alpha"))
      end)
    end

    @tag :r66
    test "R66: grove_vars ignored when no topology edge matches", ctx do
      task_fields = %{profile: ctx.profile.name, skills: ["factory-oversight"]}
      agent_fields = %{task_description: "Root task for unmatched edge grove_vars"}

      assert {:ok, {_task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: ctx.sandbox_owner,
                 registry: ctx.deps.registry,
                 dynsup: ctx.deps.dynsup,
                 pubsub: ctx.deps.pubsub,
                 grove_skills_path: ctx.grove_skills_path,
                 grove_topology: ctx.topology,
                 grove_path: ctx.grove_path,
                 grove_confinement: ctx.grove_confinement,
                 grove_confinement_mode: ctx.grove_confinement_mode,
                 test_opts: [model_query_fn: simple_orient_fn()]
               )

      register_agent_cleanup(root_pid, cleanup_tree: true, registry: ctx.deps.registry)

      action_id = "spawn-grove-vars-r66-1"

      assert {:ok, %{pid: child_pid}} =
               GenServer.call(
                 root_pid,
                 {
                   :process_action,
                   %{
                     action: "spawn_child",
                     params: %{
                       task_description: "Child with grove_vars on unmatched edge",
                       success_criteria: "Spawn succeeds; grove_vars discarded",
                       immediate_context: "No edge match",
                       approach_guidance: "Proceed normally",
                       skills: ["factory-oversight"],
                       profile: ctx.profile.name,
                       grove_vars: %{"child_workspace" => "venture-beta"}
                     }
                   },
                   action_id
                 },
                 30_000
               )

      register_agent_cleanup(child_pid)

      assert {:ok, child_state} = Core.get_state(child_pid)
      assert child_state.grove_confinement_mode == "strict"

      child_skill_names = Enum.map(child_state.active_skills || [], & &1.name)
      assert "factory-oversight" in child_skill_names
      refute "venture-management" in child_skill_names

      all_paths = confinement_paths(child_state.grove_confinement)
      assert Enum.any?(all_paths, &String.contains?(&1, "{child_workspace}"))
      refute Enum.any?(all_paths, &String.contains?(&1, "venture-beta"))
    end
  end

  defp create_spawn_contract_fixture(profile_name) do
    base_name = "test_spawn_contract_packet2/#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), base_name)
    grove_name = "spawn-contract-grove"
    constraints_dir = Path.join(System.tmp_dir!(), "#{base_name}/#{grove_name}/constraints")
    edge_file = Path.join(constraints_dir, "edge.md")

    File.mkdir_p!(constraints_dir)

    write_skill_manifest(base_name, grove_name, "factory-oversight")
    write_skill_manifest(base_name, grove_name, "venture-management")
    write_skill_manifest(base_name, grove_name, "operations-observer")

    File.write!(edge_file, "Edge-mandated constraint from topology.\n")

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

    grove_file = Path.join(System.tmp_dir!(), "#{base_name}/#{grove_name}/GROVE.md")
    File.write!(grove_file, grove_yaml)

    %{
      base_name: base_name,
      base_dir: tmp_dir,
      groves_path: tmp_dir,
      grove_name: grove_name
    }
  end

  defp create_grove_vars_fixture(profile_name) do
    base_name = "test_spawn_contract_packet3/#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), base_name)
    grove_name = "spawn-contract-grove-vars"
    template_root = Path.join(tmp_dir, "template-workspaces")

    write_skill_manifest(base_name, grove_name, "factory-oversight")
    write_skill_manifest(base_name, grove_name, "venture-management")
    write_skill_manifest(base_name, grove_name, "operations-observer")

    grove_yaml =
      """
      ---
      name: #{grove_name}
      description: Spawn contract grove_vars integration fixture
      version: "1.0"
      bootstrap:
        profile: #{profile_name}
        skills:
          - factory-oversight
      topology:
        edges:
          - parent: factory-oversight
            child: operations-observer
            required_context:
              - child_workspace
            auto_inject:
              skills:
                - venture-management
      confinement_mode: strict
      confinement:
        venture-management:
          paths:
            - "#{template_root}/{child_workspace}/**"
          read_only_paths:
            - "#{template_root}/shared/**"
      ---
      """

    grove_dir = Path.join(System.tmp_dir!(), "#{base_name}/#{grove_name}")
    grove_file = Path.join(grove_dir, "GROVE.md")

    File.mkdir_p!(grove_dir)
    File.write!(grove_file, grove_yaml)

    %{
      base_name: base_name,
      base_dir: tmp_dir,
      groves_path: tmp_dir,
      grove_name: grove_name
    }
  end

  defp write_skill_manifest(base_name, grove_name, skill_name) do
    skill_dir = Path.join(System.tmp_dir!(), "#{base_name}/#{grove_name}/skills/#{skill_name}")
    skill_file = Path.join(skill_dir, "SKILL.md")

    File.mkdir_p!(skill_dir)

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

  defp simple_orient_fn do
    fn _messages, [model_id], _opts ->
      {:ok,
       %{
         successful_responses: [%{model: model_id, content: orient_response()}],
         failed_models: []
       }}
    end
  end

  defp confinement_paths(confinement) when is_map(confinement) do
    confinement
    |> Map.values()
    |> Enum.flat_map(fn cfg -> (cfg["paths"] || []) ++ (cfg["read_only_paths"] || []) end)
  end

  defp confinement_paths(_confinement), do: []

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
