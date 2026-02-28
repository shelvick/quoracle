defmodule Quoracle.Agent.ConsensusForceReflectionTest do
  @moduledoc """
  Tests for forced refinement logic in Consensus (ARC R1-R4, R5).
  WorkGroupID: feat-20260225-forced-reflection
  """
  use Quoracle.DataCase, async: true
  alias Quoracle.Agent.Consensus
  alias Quoracle.Agent.ConfigManager
  import Test.IsolationHelpers

  describe "Core Consensus Logic" do
    @tag :unit
    test "R1: forces refinement in round 1 for single model when flag enabled" do
      deps = create_isolated_deps()
      state = build_state(deps, force_reflection: true, model_pool: ["model-1"])

      opts = build_opts(deps, model_pool: ["model-1"])

      {:ok, {type, _action, meta}, _updated_state} =
        Consensus.get_consensus_with_state(state, opts)

      assert type == :consensus
      assert Keyword.get(meta, :forced_reflection_applied) == true
    end

    @tag :unit
    test "R2: allows majority exit in round 2 even with forced reflection" do
      deps = create_isolated_deps()
      state = build_state(deps, force_reflection: true, model_pool: ["model-1"])

      opts = build_opts(deps, model_pool: ["model-1"], round: 2)

      {:ok, {type, _action, meta}, _updated_state} =
        Consensus.get_consensus_with_state(state, opts)

      assert type == :consensus
      refute Keyword.get(meta, :forced_reflection_applied)
    end

    @tag :unit
    test "R3: ignored for multi-model pools" do
      deps = create_isolated_deps()

      state =
        build_state(deps, force_reflection: true, model_pool: ["model-1", "model-2"])

      opts = build_opts(deps, model_pool: ["model-1", "model-2"])

      {:ok, {_type, _action, meta}, _updated_state} =
        Consensus.get_consensus_with_state(state, opts)

      refute Keyword.get(meta, :forced_reflection_applied)
    end

    @tag :unit
    test "R4: standard behavior when force_reflection is false" do
      deps = create_isolated_deps()
      state = build_state(deps, force_reflection: false, model_pool: ["model-1"])

      opts = build_opts(deps, model_pool: ["model-1"])

      {:ok, {type, _action, meta}, _updated_state} =
        Consensus.get_consensus_with_state(state, opts)

      assert type == :consensus
      refute Keyword.get(meta, :forced_reflection_applied)
    end
  end

  describe "Config-to-Consensus Integration" do
    @tag :integration
    test "R5: force_reflection flows from setup_agent to consensus" do
      deps = create_isolated_deps()

      config = %{
        agent_id: "fr_integration_#{System.unique_integer([:positive])}",
        parent_pid: self(),
        test_mode: true,
        force_reflection: true,
        model_pool: ["model-1"],
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub
      }

      # Use the real production initialization path
      state =
        ConfigManager.setup_agent(config,
          pubsub: deps.pubsub,
          registry: deps.registry,
          dynsup: deps.dynsup
        )

      # Verify the field survived the real initialization chain
      assert state.force_reflection == true

      # Now run consensus with the production-initialized state
      opts = build_opts(deps, model_pool: ["model-1"])

      {:ok, {_type, _action, meta}, _updated_state} =
        Consensus.get_consensus_with_state(state, opts)

      assert Keyword.get(meta, :forced_reflection_applied) == true
    end

    @tag :integration
    test "R5b: force_reflection=false produces no forced reflection" do
      deps = create_isolated_deps()

      config = %{
        agent_id: "fr_integration_#{System.unique_integer([:positive])}",
        parent_pid: self(),
        test_mode: true,
        force_reflection: false,
        model_pool: ["model-1"],
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub
      }

      state =
        ConfigManager.setup_agent(config,
          pubsub: deps.pubsub,
          registry: deps.registry,
          dynsup: deps.dynsup
        )

      assert state.force_reflection == false

      opts = build_opts(deps, model_pool: ["model-1"])

      {:ok, {_type, _action, meta}, _updated_state} =
        Consensus.get_consensus_with_state(state, opts)

      refute Keyword.get(meta, :forced_reflection_applied)
    end
  end

  # Build state through ConfigManager.setup_agent (production path)
  defp build_state(deps, overrides) do
    config = %{
      agent_id: "fr_test_#{System.unique_integer([:positive])}",
      parent_pid: self(),
      test_mode: true,
      force_reflection: Keyword.get(overrides, :force_reflection, false),
      model_pool: Keyword.get(overrides, :model_pool, ["model-1"]),
      registry: deps.registry,
      dynsup: deps.dynsup,
      pubsub: deps.pubsub
    }

    ConfigManager.setup_agent(config,
      pubsub: deps.pubsub,
      registry: deps.registry,
      dynsup: deps.dynsup
    )
  end

  defp build_opts(deps, overrides) do
    [
      model_pool: Keyword.get(overrides, :model_pool, ["model-1"]),
      round: Keyword.get(overrides, :round, 1),
      test_mode: true,
      force_persist: true,
      sandbox_owner: self(),
      pubsub: deps.pubsub,
      registry: deps.registry
    ]
  end
end
