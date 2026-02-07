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

  alias Quoracle.Actions.Spawn.ConfigBuilder

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

  describe "[UNIT] cost context in transform_opts (R49-R51)" do
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
