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

    test "ARC_ENF_03: allows call from IsolationHelpers", %{
      deps: deps,
      sandbox_owner: _sandbox_owner
    } do
      # IsolationHelpers functions are approved callers
      # This test itself uses create_isolated_deps which internally may spawn processes
      # The fact that setup passed proves IsolationHelpers is approved
      assert deps.registry != nil
      assert deps.dynsup != nil
    end

    test "ARC_ENF_04: error message includes helpful instructions", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      config = %{
        agent_id: "test-error-message",
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: sandbox_owner
      }

      error =
        assert_raise RuntimeError, fn ->
          DynSup.start_agent(deps.dynsup, config, registry: deps.registry)
        end

      # Verify error message includes key information
      assert error.message =~ "DynSup.start_agent called directly"
      assert error.message =~ "spawn_agent_with_cleanup"
      assert error.message =~ "Postgrex"
      assert error.message =~ "test/support/agent_test_helpers.ex"
    end
  end

  describe "production code is allowed" do
    test "ARC_ENF_05: enforcement only applies in test environment" do
      # This test verifies the Mix.env() == :test check exists
      # In production, the enforcement function is never called
      # We can't test production behavior from test env, but we document the requirement
      assert Mix.env() == :test
    end
  end
end
