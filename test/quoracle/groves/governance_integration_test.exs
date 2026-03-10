defmodule Quoracle.Groves.GovernanceIntegrationTest do
  @moduledoc """
  Integration tests for TEST_GroveGovernance packets 3-5.

  ARC Criteria covered in this file:
  - R23-R24: Core.State governance field defaults
  - R25-R26: ConfigManager governance config threading
  - R27-R28: Consensus/system prompt governance integration
  - R30-R32: Task creation governance threading
  - R33-R36: Spawn governance propagation
  """

  use Quoracle.DataCase, async: true

  import Test.AgentTestHelpers,
    only: [create_test_profile: 0, spawn_agent_with_cleanup: 3, stop_agent_tree: 2]

  alias Quoracle.Actions.Spawn
  alias Quoracle.Agent.ConfigManager
  alias Quoracle.Agent.Core
  alias Quoracle.Agent.Core.State
  alias Quoracle.Groves.{GovernanceResolver, Loader}
  alias Quoracle.Tasks.TaskManager

  @moduletag :feat_grove_system
  @moduletag :packet_3
  @moduletag :packet_4
  @moduletag :packet_5

  describe "agent state governance threading" do
    test "R23: governance_rules field exists in agent state with default nil" do
      state =
        State.new(%{
          agent_id: "r23-state-agent",
          registry: :test_registry,
          dynsup: self(),
          pubsub: :test_pubsub
        })

      assert Map.has_key?(state, :governance_rules)
      assert Map.get(state, :governance_rules) == nil
    end

    test "R24: governance_config field exists in agent state with default nil" do
      state =
        State.new(%{
          agent_id: "r24-state-agent",
          registry: :test_registry,
          dynsup: self(),
          pubsub: :test_pubsub
        })

      assert Map.has_key?(state, :governance_config)
      assert Map.get(state, :governance_config) == nil
    end

    test "R25: ConfigManager preserves governance_rules from config" do
      config = %{
        agent_id: "r25-config-agent",
        test_mode: true,
        model_pool: ["test-model-1"],
        governance_rules: "## Governance Rules\n\nTest governance text"
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.governance_rules == "## Governance Rules\n\nTest governance text"
    end

    test "R26: ConfigManager preserves governance_config from config" do
      injections = [
        %{content: "Rule A", priority: :high, inject_into: ["venture-management"]},
        %{content: "Rule B", priority: :normal, inject_into: ["factory-oversight"]}
      ]

      config = %{
        agent_id: "r26-config-agent",
        test_mode: true,
        model_pool: ["test-model-1"],
        governance_config: injections
      }

      normalized = ConfigManager.normalize_config(config)

      assert normalized.governance_config == injections
    end

    test "grove_hard_rules field exists in agent state with default nil" do
      state =
        State.new(%{
          agent_id: "state-hard-rules-agent",
          registry: :test_registry,
          dynsup: self(),
          pubsub: :test_pubsub
        })

      assert Map.has_key?(state, :grove_hard_rules)
      assert Map.get(state, :grove_hard_rules) == nil
    end

    test "ConfigManager preserves grove_hard_rules from config" do
      grove_hard_rules = [
        %{
          "type" => "shell_pattern_block",
          "pattern" => "rm\\s+-rf|pkill|killall",
          "message" => "Never execute destructive commands without explicit user approval.",
          "scope" => "all"
        }
      ]

      config = %{
        agent_id: "config-hard-rules-agent",
        test_mode: true,
        model_pool: ["test-model-1"],
        grove_hard_rules: grove_hard_rules
      }

      normalized = ConfigManager.normalize_config(config)

      assert Map.get(normalized, :grove_hard_rules) == grove_hard_rules
    end
  end

  describe "consensus handler governance integration" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      _profile = create_test_profile()

      {:ok, deps: deps, sandbox_owner: sandbox_owner}
    end

    test "R27: agent system prompt contains governance rules from grove", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      governance_text = "## Governance Rules\n\nNever use pkill."

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          agent_config(deps,
            governance_rules: governance_text,
            test_pid: self()
          ),
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {_messages, captured_prompt} = trigger_consensus_and_capture_prompt(agent_pid)

      assert captured_prompt =~ "Governance Rules"
      assert captured_prompt =~ "Never use pkill."
    end

    test "R28: governance_rules included in cached system prompt", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      governance_text = "## Governance Rules\n\nFollow the doctrine."

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          agent_config(deps,
            governance_rules: governance_text,
            test_pid: self()
          ),
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      _ = trigger_consensus_and_capture_prompt(agent_pid)
      {:ok, state} = Core.get_state(agent_pid)

      assert is_binary(state.cached_system_prompt)
      assert state.cached_system_prompt =~ "Follow the doctrine."
    end
  end

  describe "task creation governance integration" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      profile = create_test_profile()

      fixture = create_governed_grove_fixture(profile.name)
      on_exit(fn -> File.rm_rf!(fixture.groves_path) end)

      {:ok, deps: deps, profile: profile, fixture: fixture, sandbox_owner: sandbox_owner}
    end

    @tag :acceptance
    test "R30: task from grove sends system prompt containing governance rules", %{
      deps: deps,
      profile: profile,
      fixture: fixture,
      sandbox_owner: sandbox_owner
    } do
      %{governance_rules: governance_rules, governance_config: governance_config} =
        resolve_governance_from_fixture(fixture)

      assert is_binary(governance_rules)
      assert governance_rules =~ "Never bypass governance review."

      task_fields = %{profile: profile.name, skills: ["venture-management"]}
      agent_fields = %{task_description: "R30 governed task"}

      assert {:ok, {_task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: sandbox_owner,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 pubsub: deps.pubsub,
                 grove_skills_path: fixture.grove_skills_path,
                 governance_rules: governance_rules,
                 governance_config: governance_config,
                 test_opts: [model_query_fn: capturing_model_query_fn(self())]
               )

      on_exit(fn -> stop_agent_tree(root_pid, deps.registry) end)

      {_messages, captured_prompt} = trigger_consensus_and_capture_prompt(root_pid)
      assert {:ok, root_state} = Core.get_state(root_pid)

      assert is_binary(captured_prompt)
      assert captured_prompt =~ "## Governance Rules"
      assert captured_prompt =~ "Never bypass governance review."
      assert captured_prompt =~ "SYSTEM RULE:"
      refute is_nil(root_state.governance_rules)
      refute root_state.governance_rules == ""
    end

    test "R31: task from grove provides governance_config for child spawning path", %{
      deps: deps,
      profile: profile,
      fixture: fixture,
      sandbox_owner: sandbox_owner
    } do
      %{governance_rules: governance_rules, governance_config: governance_config} =
        resolve_governance_from_fixture(fixture)

      task_fields = %{profile: profile.name, skills: ["venture-management"]}
      agent_fields = %{task_description: "R31 governed task"}

      assert {:ok, {_task, root_pid}} =
               TaskManager.create_task(task_fields, agent_fields,
                 sandbox_owner: sandbox_owner,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 pubsub: deps.pubsub,
                 grove_skills_path: fixture.grove_skills_path,
                 governance_rules: governance_rules,
                 governance_config: governance_config
               )

      on_exit(fn -> stop_agent_tree(root_pid, deps.registry) end)

      spawn_action = %{
        action: "spawn_child",
        params: %{
          task_description: "R31 child task",
          success_criteria: "Validate governance config threading",
          immediate_context: "Governance integration test",
          approach_guidance: "Follow parent governance",
          profile: profile.name
        }
      }

      action_id = "r31-spawn-#{System.unique_integer([:positive])}"

      assert {:ok, %{pid: child_pid}} =
               GenServer.call(root_pid, {:process_action, spawn_action, action_id}, 15_000)

      assert {:ok, child_state} = Core.get_state(child_pid)

      assert is_list(child_state.governance_config)
      refute child_state.governance_config == []

      assert Enum.any?(
               child_state.governance_config,
               &(&1.content =~ "Never bypass governance review.")
             )
    end

    @tag :acceptance
    test "R32: task without grove sends system prompt without governance section", %{
      deps: deps,
      profile: profile,
      fixture: fixture,
      sandbox_owner: sandbox_owner
    } do
      %{governance_rules: governance_rules, governance_config: governance_config} =
        resolve_governance_from_fixture(fixture)

      governed_task_fields = %{profile: profile.name, skills: ["venture-management"]}
      governed_agent_fields = %{task_description: "R32 governed baseline task"}

      assert {:ok, {_task, governed_root_pid}} =
               TaskManager.create_task(governed_task_fields, governed_agent_fields,
                 sandbox_owner: sandbox_owner,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 pubsub: deps.pubsub,
                 grove_skills_path: fixture.grove_skills_path,
                 governance_rules: governance_rules,
                 governance_config: governance_config,
                 test_opts: [model_query_fn: capturing_model_query_fn(self())]
               )

      on_exit(fn -> stop_agent_tree(governed_root_pid, deps.registry) end)

      {_governed_messages, governed_prompt} =
        trigger_consensus_and_capture_prompt(governed_root_pid)

      assert governed_prompt =~ "Governance Rules"

      plain_task_fields = %{profile: profile.name}
      plain_agent_fields = %{task_description: "R32 plain task"}

      assert {:ok, {_task, plain_root_pid}} =
               TaskManager.create_task(plain_task_fields, plain_agent_fields,
                 sandbox_owner: sandbox_owner,
                 registry: deps.registry,
                 dynsup: deps.dynsup,
                 pubsub: deps.pubsub,
                 test_opts: [model_query_fn: capturing_model_query_fn(self())]
               )

      on_exit(fn -> stop_agent_tree(plain_root_pid, deps.registry) end)

      {_plain_messages, plain_prompt} = trigger_consensus_and_capture_prompt(plain_root_pid)

      assert is_binary(plain_prompt)
      refute plain_prompt =~ "Governance Rules"
      refute plain_prompt =~ "Never bypass governance review."
    end
  end

  describe "spawn governance propagation" do
    # Packet 2 work extends Packet 1 by validating spawn contract context
    # is threaded through TaskManager -> root agent -> spawn execution path.
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      profile = create_test_profile()

      skills_base_name = "governance_spawn_skills_#{System.unique_integer([:positive])}"
      skills_path = Path.join(System.tmp_dir!(), skills_base_name)

      File.mkdir_p!(Path.join(System.tmp_dir!(), skills_base_name))

      create_skill_manifest(skills_base_name, "venture-management")
      create_skill_manifest(skills_base_name, "factory-oversight")
      create_skill_manifest(skills_base_name, "unrelated-skill")

      on_exit(fn -> File.rm_rf!(Path.join(System.tmp_dir!(), skills_base_name)) end)

      governance_config = [
        %{
          content: "venture-management governance",
          priority: :high,
          inject_into: ["venture-management"]
        },
        %{
          content: "factory-oversight governance",
          priority: :normal,
          inject_into: ["factory-oversight"]
        }
      ]

      governance_rules =
        GovernanceResolver.build_agent_governance(
          governance_config,
          ["venture-management", "factory-oversight"],
          nil
        )

      {:ok,
       deps: deps,
       profile: profile,
       sandbox_owner: sandbox_owner,
       skills_path: skills_path,
       governance_config: governance_config,
       governance_rules: governance_rules}
    end

    test "R33: child agent receives governance_rules filtered to its skills", ctx do
      {:ok, root_pid} =
        create_root_agent_with_governance(ctx,
          governance_rules: ctx.governance_rules,
          governance_config: ctx.governance_config
        )

      {:ok, child_pid} = spawn_child_and_wait(root_pid, ctx, ["venture-management"])
      assert {:ok, child_state} = Core.get_state(child_pid)

      assert is_binary(child_state.governance_rules)
      assert child_state.governance_rules =~ "venture-management governance"
      refute child_state.governance_rules =~ "factory-oversight governance"
    end

    test "R34: child inherits full governance_config for further spawning", ctx do
      {:ok, root_pid} =
        create_root_agent_with_governance(ctx,
          governance_rules: ctx.governance_rules,
          governance_config: ctx.governance_config
        )

      {:ok, child_pid} = spawn_child_and_wait(root_pid, ctx, ["factory-oversight"])
      assert {:ok, child_state} = Core.get_state(child_pid)

      assert child_state.governance_config == ctx.governance_config
      assert is_binary(child_state.governance_rules)
      assert child_state.governance_rules =~ "factory-oversight governance"
      refute child_state.governance_rules =~ "venture-management governance"
    end

    test "R35: child with no matching governance gets nil governance_rules", ctx do
      {:ok, root_pid} =
        create_root_agent_with_governance(ctx,
          governance_rules: ctx.governance_rules,
          governance_config: ctx.governance_config
        )

      {:ok, child_pid} = spawn_child_and_wait(root_pid, ctx, ["unrelated-skill"])
      assert {:ok, child_state} = Core.get_state(child_pid)

      assert is_nil(child_state.governance_rules)
      assert child_state.governance_config == ctx.governance_config
    end

    test "R36: child spawned without grove context has nil governance", ctx do
      stale_parent_rules = "## Governance Rules\n\nstale parent governance text"

      {:ok, root_pid} =
        create_root_agent_with_governance(ctx,
          governance_rules: stale_parent_rules,
          governance_config: nil
        )

      {:ok, child_pid} = spawn_child_and_wait(root_pid, ctx, ["venture-management"])
      assert {:ok, child_state} = Core.get_state(child_pid)

      assert is_nil(child_state.governance_rules)
      assert is_nil(child_state.governance_config)
    end

    test "R46: spawn_child forwards grove_topology from root state to child state", ctx do
      grove_topology = %{
        "edges" => [
          %{
            "from" => ["venture-orchestrator"],
            "to" => ["factory-oversight"],
            "auto_inject" => %{"skills" => ["venture-management"]}
          }
        ]
      }

      {:ok, root_pid} =
        create_root_agent_with_governance(ctx,
          governance_rules: ctx.governance_rules,
          governance_config: ctx.governance_config,
          grove_topology: grove_topology
        )

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_topology)
      assert Map.get(root_state, :grove_topology) == grove_topology

      {:ok, child_pid} = spawn_child_and_wait(root_pid, ctx, ["venture-management"])
      assert {:ok, child_state} = Core.get_state(child_pid)

      assert Map.has_key?(child_state, :grove_topology)
      assert Map.get(child_state, :grove_topology) == grove_topology
      assert is_binary(child_state.governance_rules)
      assert child_state.governance_rules =~ "venture-management governance"
    end

    test "R47: spawn_child forwards grove_path from root state to child state", ctx do
      grove_path =
        Path.join(System.tmp_dir!(), "spawn_contract_path_#{System.unique_integer([:positive])}")

      {:ok, root_pid} =
        create_root_agent_with_governance(ctx,
          governance_rules: ctx.governance_rules,
          governance_config: ctx.governance_config,
          grove_path: grove_path
        )

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_path)
      assert Map.get(root_state, :grove_path) == grove_path

      {:ok, child_pid} = spawn_child_and_wait(root_pid, ctx, ["venture-management"])
      assert {:ok, child_state} = Core.get_state(child_pid)

      assert Map.has_key?(child_state, :grove_path)
      assert Map.get(child_state, :grove_path) == grove_path
      assert is_binary(child_state.governance_rules)
      assert child_state.governance_rules =~ "venture-management governance"
    end

    test "R48: spawn_child without grove context keeps topology fields nil", ctx do
      {:ok, root_pid} =
        create_root_agent_with_governance(ctx,
          governance_rules: ctx.governance_rules,
          governance_config: ctx.governance_config
        )

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert is_nil(Map.get(root_state, :grove_topology))
      assert is_nil(Map.get(root_state, :grove_path))

      {:ok, child_pid} = spawn_child_and_wait(root_pid, ctx, ["venture-management"])
      assert {:ok, child_state} = Core.get_state(child_pid)

      assert is_nil(Map.get(child_state, :grove_topology))
      assert is_nil(Map.get(child_state, :grove_path))
      assert is_binary(child_state.governance_rules)
      assert child_state.governance_rules =~ "venture-management governance"
    end

    test "R403: root state includes schema fields when provided", ctx do
      grove_schemas = [
        %{
          "name" => "output-schema",
          "definition" => "schemas/output.json",
          "validate_on" => "file_write",
          "path_pattern" => "data/**/*.json"
        }
      ]

      grove_workspace =
        Path.join(
          System.tmp_dir!(),
          "core_schema_workspace_#{System.unique_integer([:positive])}"
        )

      {:ok, root_pid} =
        create_root_agent_with_governance(ctx,
          governance_rules: ctx.governance_rules,
          governance_config: ctx.governance_config,
          grove_schemas: grove_schemas,
          grove_workspace: grove_workspace
        )

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_schemas)
      assert Map.has_key?(root_state, :grove_workspace)
      assert Map.get(root_state, :grove_schemas) == grove_schemas
      assert Map.get(root_state, :grove_workspace) == grove_workspace
    end

    test "R404: child inherits grove_schemas and grove_workspace from parent", ctx do
      grove_schemas = [
        %{
          "name" => "output-schema",
          "definition" => "schemas/output.json",
          "validate_on" => "file_write",
          "path_pattern" => "data/**/*.json"
        }
      ]

      grove_workspace =
        Path.join(
          System.tmp_dir!(),
          "child_schema_workspace_#{System.unique_integer([:positive])}"
        )

      {:ok, root_pid} =
        create_root_agent_with_governance(ctx,
          governance_rules: ctx.governance_rules,
          governance_config: ctx.governance_config,
          grove_schemas: grove_schemas,
          grove_workspace: grove_workspace
        )

      {:ok, child_pid} = spawn_child_and_wait(root_pid, ctx, ["venture-management"])
      assert {:ok, child_state} = Core.get_state(child_pid)

      assert Map.has_key?(child_state, :grove_schemas)
      assert Map.has_key?(child_state, :grove_workspace)
      assert Map.get(child_state, :grove_schemas) == grove_schemas
      assert Map.get(child_state, :grove_workspace) == grove_workspace
    end
  end

  describe "spawn hard-rule propagation" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      profile = create_test_profile()

      skills_base_name = "governance_hard_rules_skills_#{System.unique_integer([:positive])}"
      skills_path = Path.join(System.tmp_dir!(), skills_base_name)

      File.mkdir_p!(Path.join(System.tmp_dir!(), skills_base_name))

      create_skill_manifest(skills_base_name, "venture-management")

      on_exit(fn -> File.rm_rf!(Path.join(System.tmp_dir!(), skills_base_name)) end)

      governance_config = [
        %{
          content: "venture-management governance",
          priority: :high,
          inject_into: ["venture-management"]
        }
      ]

      grove_hard_rules = [
        %{
          "type" => "shell_pattern_block",
          "pattern" => "rm\\s+-rf|pkill|killall",
          "message" => "Never execute destructive commands without explicit user approval.",
          "scope" => "all"
        }
      ]

      governance_rules =
        GovernanceResolver.build_agent_governance(
          governance_config,
          ["venture-management"],
          grove_hard_rules
        )

      {:ok,
       deps: deps,
       profile: profile,
       sandbox_owner: sandbox_owner,
       skills_path: skills_path,
       governance_config: governance_config,
       governance_rules: governance_rules,
       grove_hard_rules: grove_hard_rules}
    end

    test "child agent receives hard_rules in governance text via spawn path", ctx do
      {:ok, root_pid} =
        create_root_agent_with_governance(ctx,
          governance_rules: ctx.governance_rules,
          governance_config: ctx.governance_config,
          grove_hard_rules: ctx.grove_hard_rules
        )

      {:ok, child_pid} = spawn_child_and_wait(root_pid, ctx, ["venture-management"])
      assert {:ok, child_state} = Core.get_state(child_pid)

      assert is_binary(child_state.governance_rules)

      assert child_state.governance_rules =~
               "SYSTEM RULE: Never execute destructive commands without explicit user approval."
    end

    test "grandchild receives hard_rules in 3-generation spawn chain", ctx do
      {:ok, root_pid} =
        create_root_agent_with_governance(ctx,
          governance_rules: ctx.governance_rules,
          governance_config: ctx.governance_config,
          grove_hard_rules: ctx.grove_hard_rules
        )

      {:ok, child_pid} = spawn_child_and_wait(root_pid, ctx, ["venture-management"])
      {:ok, grandchild_pid} = spawn_child_and_wait(child_pid, ctx, ["venture-management"])

      assert {:ok, grandchild_state} = Core.get_state(grandchild_pid)
      assert is_binary(grandchild_state.governance_rules)

      assert grandchild_state.governance_rules =~
               "SYSTEM RULE: Never execute destructive commands without explicit user approval."
    end
  end

  defp create_root_agent_with_governance(ctx, opts) do
    model_pool = ["test-model-1"]

    spawn_agent_with_cleanup(
      ctx.deps.dynsup,
      %{
        agent_id: "packet5-root-#{System.unique_integer([:positive])}",
        task_id: Ecto.UUID.generate(),
        test_mode: true,
        model_pool: model_pool,
        model_histories: Map.new(model_pool, fn model -> {model, []} end),
        registry: ctx.deps.registry,
        dynsup: ctx.deps.dynsup,
        pubsub: ctx.deps.pubsub,
        skip_auto_consensus: true,
        governance_rules: Keyword.get(opts, :governance_rules),
        governance_config: Keyword.get(opts, :governance_config),
        grove_hard_rules: Keyword.get(opts, :grove_hard_rules),
        grove_topology: Keyword.get(opts, :grove_topology),
        grove_path: Keyword.get(opts, :grove_path),
        grove_schemas: Keyword.get(opts, :grove_schemas),
        grove_workspace: Keyword.get(opts, :grove_workspace)
      },
      registry: ctx.deps.registry,
      pubsub: ctx.deps.pubsub,
      sandbox_owner: ctx.sandbox_owner
    )
  end

  defp spawn_child_and_wait(root_pid, ctx, skills) do
    assert {:ok, parent_state} = Core.get_state(root_pid)

    params = %{
      "task_description" => "Packet 5 child task",
      "success_criteria" => "Verify governance propagation",
      "immediate_context" => "Spawn integration test",
      "approach_guidance" => "Use spawn path",
      "profile" => ctx.profile.name,
      "skills" => skills
    }

    opts = [
      agent_pid: root_pid,
      dynsup: ctx.deps.dynsup,
      registry: ctx.deps.registry,
      pubsub: ctx.deps.pubsub,
      sandbox_owner: ctx.sandbox_owner,
      skills_path: ctx.skills_path,
      spawn_complete_notify: self(),
      parent_config: parent_state,
      dismissing: false
    ]

    assert {:ok, %{action: "spawn", agent_id: child_id}} =
             Spawn.execute(params, parent_state.agent_id, opts)

    assert_receive {:spawn_complete, ^child_id, {:ok, child_pid}}, 10_000

    on_exit(fn -> stop_agent_tree(child_pid, ctx.deps.registry) end)
    {:ok, child_pid}
  end

  defp create_skill_manifest(skills_base_name, name) do
    File.mkdir_p!(Path.join(System.tmp_dir!(), Path.join([skills_base_name, name])))

    File.write!(Path.join(System.tmp_dir!(), Path.join([skills_base_name, name, "SKILL.md"])), """
    ---
    name: #{name}
    description: Skill #{name} for packet 5
    ---
    # #{name}

    Packet 5 skill content.
    """)
  end

  defp agent_config(deps, opts) do
    test_pid = Keyword.get(opts, :test_pid, self())
    model_pool = Keyword.get(opts, :model_pool, ["test-model-1"])

    %{
      agent_id: "gov-integration-agent-#{System.unique_integer([:positive])}",
      test_mode: true,
      model_pool: model_pool,
      model_histories: Map.new(model_pool, fn model -> {model, []} end),
      registry: deps.registry,
      dynsup: deps.dynsup,
      pubsub: deps.pubsub,
      active_skills: Keyword.get(opts, :active_skills, []),
      governance_rules: Keyword.get(opts, :governance_rules),
      governance_config: Keyword.get(opts, :governance_config),
      test_opts: [model_query_fn: capturing_model_query_fn(test_pid)]
    }
  end

  defp trigger_consensus_and_capture_prompt(agent_pid) do
    Core.handle_message(agent_pid, "Trigger governance consensus")

    assert_receive {:query_messages, ^agent_pid, _model_id, messages}, 10_000

    system_prompt =
      messages
      |> Enum.find(&(&1.role == "system"))
      |> case do
        nil -> nil
        message -> message.content
      end

    {messages, system_prompt}
  end

  defp capturing_model_query_fn(test_pid) do
    fn messages, [model_id], _opts ->
      send(test_pid, {:query_messages, self(), model_id, messages})

      {:ok,
       %{
         successful_responses: [%{model: model_id, content: orient_response()}],
         failed_models: []
       }}
    end
  end

  defp create_governed_grove_fixture(profile_name) do
    base_name = "test_governance_packet4/#{System.unique_integer([:positive])}"
    groves_path = Path.join(System.tmp_dir!(), base_name)
    File.mkdir_p!(groves_path)

    grove_name = "governed-grove"
    grove_dir = Path.join(System.tmp_dir!(), Path.join(base_name, grove_name))

    governance_dir =
      Path.join(System.tmp_dir!(), Path.join([base_name, grove_name, "governance"]))

    skills_dir =
      Path.join(
        System.tmp_dir!(),
        Path.join([base_name, grove_name, "skills", "venture-management"])
      )

    doctrine_file = Path.join(governance_dir, "doctrine.md")
    skill_file = Path.join(skills_dir, "SKILL.md")
    grove_file = Path.join(System.tmp_dir!(), Path.join([base_name, grove_name, "GROVE.md"]))

    File.mkdir_p!(governance_dir)
    File.mkdir_p!(skills_dir)
    File.write!(doctrine_file, "Never bypass governance review.")

    File.write!(skill_file, """
    ---
    name: venture-management
    description: Venture management skill for governance tests
    ---
    Execute venture-management tasks.
    """)

    File.write!(grove_file, """
    ---
    name: governed-grove
    description: Packet 4 governed grove fixture
    version: "1.0"
    bootstrap:
      profile: #{profile_name}
      skills:
        - venture-management
    governance:
      injections:
        - source: governance/doctrine.md
          priority: high
          inject_into:
            - venture-management
      hard_rules:
        - type: shell_pattern_block
          pattern: "rm\\s+-rf|pkill|killall"
          message: "Always obtain explicit approval before destructive actions."
          scope: all
    ---
    """)

    %{
      groves_path: groves_path,
      grove_name: grove_name,
      grove_skills_path: Path.join(grove_dir, "skills")
    }
  end

  defp resolve_governance_from_fixture(fixture) do
    {:ok, grove} = Loader.load_grove(fixture.grove_name, groves_path: fixture.groves_path)
    {:ok, injections} = GovernanceResolver.resolve_all(grove)

    governance_rules =
      GovernanceResolver.build_agent_governance(
        injections,
        grove.bootstrap.skills || [],
        Map.get(grove.governance || %{}, "hard_rules")
      )

    %{governance_rules: governance_rules, governance_config: injections}
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
      "reasoning" => "Governance integration test orient response",
      "wait" => true
    })
  end
end
