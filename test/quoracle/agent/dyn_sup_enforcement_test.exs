defmodule Quoracle.Agent.DynSupEnforcementTest do
  @moduledoc """
  Tests for runtime enforcement that prevents direct DynSup.start_agent calls in tests.
  This enforcement prevents orphaned processes that cause DB connection leaks.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.DynSup
  import Test.IsolationHelpers
  import Test.AgentTestHelpers

  describe "runtime enforcement in test environment" do
    setup do
      deps = create_isolated_deps()
      %{deps: deps}
    end

    test "ARC_ENF_01: raises when called directly from test without helper", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      config = %{
        agent_id: "test-direct-call",
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: sandbox_owner
      }

      # Direct call should raise
      assert_raise RuntimeError, ~r/DynSup.start_agent called directly from test module/, fn ->
        DynSup.start_agent(deps.dynsup, config, registry: deps.registry)
      end
    end

    test "ARC_ENF_02: allows call from spawn_agent_with_cleanup", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      config = %{
        agent_id: "test-with-helper",
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: sandbox_owner
      }

      # Call through approved helper should work
      assert {:ok, _pid} = spawn_agent_with_cleanup(deps.dynsup, config, registry: deps.registry)
    end
  end
end
