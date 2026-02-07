defmodule Quoracle.Agent.ConfigManagerTest do
  @moduledoc """
  Tests for ConfigManager atomic Registry registration.
  Verifies the race condition fix and atomic parent-child relationships.
  """
  use ExUnit.Case, async: true
  import Test.IsolationHelpers

  alias Quoracle.Agent.ConfigManager

  setup do
    # Create isolated Registry and DynSup for this test
    deps = create_isolated_deps()
    {:ok, deps: deps}
  end

  describe "normalize_config/1" do
    test "converts keyword list to map" do
      # test_mode: true avoids DB query for model_pool
      config = [agent_id: "test-1", parent_pid: self(), test_mode: true]
      normalized = ConfigManager.normalize_config(config)

      assert is_map(normalized)
      assert normalized.agent_id == "test-1"
      assert normalized.parent_pid == self()
    end

    test "preserves map config" do
      # test_mode: true avoids DB query for model_pool
      config = %{agent_id: "test-2", parent_pid: self(), test_mode: true}
      normalized = ConfigManager.normalize_config(config)

      assert is_map(normalized)
      assert normalized.agent_id == "test-2"
      assert normalized.parent_pid == self()
      assert is_integer(normalized.started_at)
    end

    test "generates agent_id when missing" do
      # test_mode: true avoids DB query for model_pool
      config = %{parent_pid: self(), test_mode: true}
      normalized = ConfigManager.normalize_config(config)

      assert normalized.agent_id =~ ~r/^agent-\d+$/
    end

    test "adds started_at timestamp" do
      # test_mode: true avoids DB query for model_pool
      config = %{agent_id: "test-3", test_mode: true}
      normalized = ConfigManager.normalize_config(config)

      assert is_integer(normalized.started_at)
    end
  end

  describe "register_agent/1 - atomic registration" do
    test "registers agent with composite value in single operation", %{deps: deps} do
      config = %{agent_id: "atomic-test-1", parent_pid: self()}

      assert :ok = ConfigManager.register_agent(config, deps.registry)

      # Verify composite value structure
      [{_pid, value}] = Registry.lookup(deps.registry, {:agent, "atomic-test-1"})
      assert value.pid == self()
      assert value.parent_pid == self()
      assert is_integer(value.registered_at)
    end

    test "registration is atomic - no partial state visible", %{deps: deps} do
      config = %{agent_id: "atomic-test-2", parent_pid: self()}

      # Start registration in background
      task =
        Task.async(fn ->
          ConfigManager.register_agent(config, deps.registry)
        end)

      # Try to catch partial state (should never happen)
      for _ <- 1..100 do
        case Registry.lookup(deps.registry, {:agent, "atomic-test-2"}) do
          [] ->
            :not_registered

          [{_pid, %{pid: _, parent_pid: _}}] ->
            :fully_registered

          [{_pid, partial}] ->
            flunk("Caught partial registration state: #{inspect(partial)}")
        end
      end

      Task.await(task)
    end

    test "raises on duplicate agent_id (BEAM philosophy - let it crash)", %{deps: deps} do
      config = %{agent_id: "duplicate-test", parent_pid: self()}

      assert :ok = ConfigManager.register_agent(config, deps.registry)

      # Second registration should crash
      assert_raise RuntimeError, ~r/Duplicate agent ID: duplicate-test/, fn ->
        ConfigManager.register_agent(config, deps.registry)
      end
    end

    test "no orphaned entries on registration failure", %{deps: deps} do
      config = %{agent_id: "orphan-test", parent_pid: self()}

      # First registration succeeds
      assert :ok = ConfigManager.register_agent(config, deps.registry)

      # Count entries for this specific agent_id (not all Registry entries)
      before_entries = Registry.lookup(deps.registry, {:agent, "orphan-test"})
      assert length(before_entries) == 1

      # Second registration fails
      assert_raise RuntimeError, ~r/Duplicate agent ID/, fn ->
        ConfigManager.register_agent(config, deps.registry)
      end

      # Verify no additional entries created for this agent_id
      after_entries = Registry.lookup(deps.registry, {:agent, "orphan-test"})
      assert length(after_entries) == 1
      assert after_entries == before_entries
    end

    test "parent_pid is included in atomic registration", %{deps: deps} do
      parent = self()
      config = %{agent_id: "parent-test", parent_pid: parent}

      assert :ok = ConfigManager.register_agent(config, deps.registry)

      [{_pid, value}] = Registry.lookup(deps.registry, {:agent, "parent-test"})
      assert value.parent_pid == parent
    end

    test "works without parent_pid", %{deps: deps} do
      config = %{agent_id: "no-parent-test"}

      assert :ok = ConfigManager.register_agent(config, deps.registry)

      [{_pid, value}] = Registry.lookup(deps.registry, {:agent, "no-parent-test"})
      assert value.parent_pid == nil
    end
  end

  describe "query patterns with composite value" do
    test "can find agent by ID and extract parent", %{deps: deps} do
      parent = self()
      config = %{agent_id: "query-test-1", parent_pid: parent}

      ConfigManager.register_agent(config, deps.registry)

      # Query pattern that components will use
      case Registry.lookup(deps.registry, {:agent, "query-test-1"}) do
        [{_pid, %{pid: agent_pid, parent_pid: found_parent}}] ->
          assert agent_pid == self()
          assert found_parent == parent

        _ ->
          flunk("Agent not found")
      end
    end

    test "can find all children of a parent using Registry.select", %{deps: deps} do
      parent = self()

      # Register multiple children
      for i <- 1..3 do
        config = %{agent_id: "child-#{i}", parent_pid: parent}
        ConfigManager.register_agent(config, deps.registry)
      end

      # Query for all children of parent using Registry.select
      children =
        Registry.select(deps.registry, [
          {{:"$1", :"$2", :"$3"}, [{:==, {:map_get, :parent_pid, :"$3"}, parent}], [:"$3"]}
        ])

      assert length(children) == 3
      assert Enum.all?(children, &(&1.parent_pid == parent))
    end
  end
end
