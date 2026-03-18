defmodule Quoracle.Actions.Spawn.ConfigBuilderCostContextTest do
  @moduledoc """
  Tests for ACTION_Spawn v16.0 - cost context in ConfigBuilder transform_opts.
  WorkGroupID: fix-costs-20260129
  Packet: 1 (Single Packet — All Cost Fixes)

  Requirements:
  - R49: Cost Context in transform_opts [INTEGRATION]
  - R51: Backward Compatible Without Cost Context [UNIT]

  Note: R50 (Summarization Cost Recorded) is tested at the spawn integration
  level, not in ConfigBuilder unit tests.
  """

  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog

  require Logger

  alias Quoracle.Actions.Spawn.{ConfigBuilder, TopologyResolver}

  # Minimal deps map for build_config (parent_config required)
  defp base_deps(overrides \\ %{}) do
    Map.merge(
      %{
        parent_config: %{
          prompt_fields: %{},
          task_id: "task-123"
        },
        task_id: "task-123",
        sandbox_owner: nil
      },
      overrides
    )
  end

  defp capture_warning_log(fun) do
    previous_level = Logger.get_process_level(self())
    Logger.put_process_level(self(), :warning)

    try do
      capture_log(fun)
    after
      case previous_level do
        nil -> Logger.delete_process_level(self())
        level -> Logger.put_process_level(self(), level)
      end
    end
  end

  describe "[UNIT] cost context in transform_opts (R49-R51)" do
    # R2117: Config stores initial_message for child initial send_user_message
    test "build_config includes initial_message in config" do
      deps = base_deps()

      {:ok, config} =
        ConfigBuilder.build_config(
          {:field_based, "Audit stream offsets"},
          %{
            task_description: "Audit stream offsets",
            success_criteria: "Detect every gap",
            immediate_context: "Broker replay in progress",
            approach_guidance: "Prefer deterministic checkpoints"
          },
          "parent-agent-id",
          self(),
          deps,
          "child-id-r2117"
        )

      assert is_binary(config.initial_message)
      assert config.initial_message =~ "<task>Audit stream offsets</task>"
      assert config.initial_message =~ "<success_criteria>Detect every gap</success_criteria>"
    end

    # R-CB5: grove_confinement_mode Inherited
    test "child inherits grove_confinement_mode from parent config" do
      deps =
        base_deps(%{
          parent_config: %{
            prompt_fields: %{},
            task_id: "task-123",
            grove_confinement_mode: "strict"
          }
        })

      {:ok, config} =
        ConfigBuilder.build_config(
          {:field_based, "Test child task"},
          %{task: "Test child task"},
          "parent-agent-id",
          self(),
          deps,
          "child-id-cb5"
        )

      assert Map.has_key?(config, :grove_confinement_mode)
      assert config.grove_confinement_mode == "strict"
    end

    # R-TR1: validate_required_context Called
    test "apply_spawn_contract calls validate_required_context with grove_vars" do
      params = %{
        skills: ["child-skill"],
        grove_vars: %{"provided_key" => "value"}
      }

      deps =
        base_deps(%{
          parent_config: %{
            prompt_fields: %{},
            task_id: "task-tr1",
            active_skills: [%{name: "parent-skill"}]
          },
          grove_topology: %{
            "edges" => [
              %{
                "parent" => "parent-skill",
                "child" => "child-skill",
                "required_context" => ["missing_key"]
              }
            ]
          }
        })

      log =
        capture_warning_log(fn ->
          assert {:ok, resolved_params} = TopologyResolver.apply_spawn_contract(params, deps)
          assert resolved_params.grove_vars == %{"provided_key" => "value"}
        end)

      assert log =~ "missing grove_vars required_context keys"
      assert log =~ "missing_key"
    end

    # R-CB1: Template Resolution with Matching Key
    test "resolve_grove_templates replaces {key} with grove_vars value" do
      confinement = %{
        "agentic-coding" => %{
          "paths" => ["/tmp/workspaces/{venture_id}/**"],
          "read_only_paths" => ["/tmp/shared/{venture_id}/docs/**"]
        }
      }

      deps =
        base_deps(%{
          parent_config: %{
            prompt_fields: %{},
            task_id: "task-cb1",
            grove_confinement: confinement
          }
        })

      {:ok, config} =
        ConfigBuilder.build_config(
          {:field_based, "Child task with template confinement"},
          %{
            task_description: "Template resolution child",
            success_criteria: "Paths resolved",
            immediate_context: "Template test",
            approach_guidance: "Check paths",
            grove_vars: %{"venture_id" => "acme-corp"}
          },
          "parent-agent-id",
          self(),
          deps,
          "child-id-cb1"
        )

      all_paths =
        config.grove_confinement
        |> Map.values()
        |> Enum.flat_map(fn cfg ->
          (cfg["paths"] || []) ++ (cfg["read_only_paths"] || [])
        end)

      assert Enum.any?(all_paths, &String.contains?(&1, "acme-corp"))
      refute Enum.any?(all_paths, &String.contains?(&1, "{venture_id}"))
    end

    # R-CB2: Nil grove_vars Passes Through
    test "resolve_grove_templates passes through when grove_vars is nil" do
      confinement = %{
        "agentic-coding" => %{
          "paths" => ["/tmp/workspaces/{venture_id}/**"],
          "read_only_paths" => []
        }
      }

      deps =
        base_deps(%{
          parent_config: %{
            prompt_fields: %{},
            task_id: "task-cb2",
            grove_confinement: confinement
          }
        })

      {:ok, config} =
        ConfigBuilder.build_config(
          {:field_based, "Child task no grove_vars"},
          %{
            task_description: "No grove_vars child",
            success_criteria: "Templates unchanged",
            immediate_context: "Template passthrough",
            approach_guidance: "Do not resolve"
          },
          "parent-agent-id",
          self(),
          deps,
          "child-id-cb2"
        )

      all_paths =
        config.grove_confinement
        |> Map.values()
        |> Enum.flat_map(fn cfg ->
          (cfg["paths"] || []) ++ (cfg["read_only_paths"] || [])
        end)

      assert Enum.any?(all_paths, &String.contains?(&1, "{venture_id}"))
      refute Enum.any?(all_paths, &String.contains?(&1, "acme-corp"))
    end

    # R-CB3: Partial grove_vars Resolves Only Matching
    test "resolve_grove_templates resolves only matching keys" do
      confinement = %{
        "agentic-coding" => %{
          "paths" => ["/tmp/{venture_id}/{workspace_name}/**"],
          "read_only_paths" => []
        }
      }

      deps =
        base_deps(%{
          parent_config: %{
            prompt_fields: %{},
            task_id: "task-cb3",
            grove_confinement: confinement
          }
        })

      {:ok, config} =
        ConfigBuilder.build_config(
          {:field_based, "Child task partial grove_vars"},
          %{
            task_description: "Partial grove_vars child",
            success_criteria: "Only matching template resolved",
            immediate_context: "Partial resolution",
            approach_guidance: "Resolve only known keys",
            grove_vars: %{"venture_id" => "acme-corp"}
          },
          "parent-agent-id",
          self(),
          deps,
          "child-id-cb3"
        )

      all_paths =
        config.grove_confinement
        |> Map.values()
        |> Enum.flat_map(fn cfg ->
          (cfg["paths"] || []) ++ (cfg["read_only_paths"] || [])
        end)

      assert Enum.any?(all_paths, &String.contains?(&1, "acme-corp"))
      assert Enum.any?(all_paths, &String.contains?(&1, "{workspace_name}"))
      refute Enum.any?(all_paths, &String.contains?(&1, "{venture_id}"))
    end

    # R-CB4: Nil Confinement Returns Config Unchanged
    test "resolve_grove_templates returns config unchanged when no confinement" do
      deps =
        base_deps(%{
          parent_config: %{
            prompt_fields: %{},
            task_id: "task-cb4"
          }
        })

      {:ok, config} =
        ConfigBuilder.build_config(
          {:field_based, "Child task nil confinement"},
          %{
            task_description: "No confinement child",
            success_criteria: "Config returned unchanged",
            immediate_context: "Nil confinement",
            approach_guidance: "Proceed normally",
            grove_vars: %{"venture_id" => "acme-corp"}
          },
          "parent-agent-id",
          self(),
          deps,
          "child-id-cb4"
        )

      refute Map.has_key?(config, :grove_confinement)
    end

    # R51: Backward Compatible Without Cost Context
    test "build_config works without cost context in deps" do
      # deps lacks agent_id/task_id/pubsub — should not crash
      deps = base_deps()

      # build_config should succeed — transform_opts will have nil cost context values
      {:ok, config} =
        ConfigBuilder.build_config(
          {:field_based, "Test child task"},
          %{task: "Test child task"},
          "parent-agent-id",
          self(),
          deps,
          "child-id-123"
        )

      assert config != nil
      assert is_map(config)
    end

    # R49: Cost Context flows through transform_opts, NOT as dead config field
    test "build_config does not add dead cost_context field to config" do
      # The spec (ACTION_Spawn v16.0) requires cost context to flow through
      # transform_opts to FieldTransformer.maybe_add_cost_context/2 — NOT
      # as a config[:cost_context] map that nothing downstream consumes.
      pubsub_name = :"test_pubsub_cb_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      deps =
        base_deps(%{
          agent_id: "parent-agent",
          task_id: "task-456",
          pubsub: pubsub_name
        })

      {:ok, config} =
        ConfigBuilder.build_config(
          {:field_based, "Test child task"},
          %{task: "Test child task"},
          "parent-agent-id",
          self(),
          deps,
          "child-id-456"
        )

      # config[:cost_context] is dead code — nothing reads it.
      # Cost context should flow via transform_opts, not config.
      refute Map.has_key?(config, :cost_context)
    end
  end
end
