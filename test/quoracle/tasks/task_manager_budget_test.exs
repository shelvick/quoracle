defmodule Quoracle.Tasks.TaskManagerBudgetTest do
  @moduledoc """
  Tests for TASK_Manager v4.0 - Budget Initialization for Root Agent.

  WorkGroupID: wip-20251231-budget
  Packet: Packet 8 (Spawn/Dismiss/Manager)

  Tests budget_data creation from task.budget_limit during root agent creation.
  """
  use Quoracle.DataCase, async: true

  import Test.AgentTestHelpers

  alias Quoracle.Tasks.TaskManager
  alias Quoracle.Agent.Core

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated PubSub for test isolation
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    # Create isolated Registry
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})

    # Create isolated DynSup with :infinity shutdown
    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
      shutdown: :infinity
    }

    {:ok, dynsup} = start_supervised(dynsup_spec)

    # Ensure test profile exists - use unique name to avoid ON CONFLICT contention
    profile = create_test_profile()

    deps = %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner,
      profile: profile
    }

    %{deps: deps}
  end

  describe "create_task/3 with budget_limit (v4.0)" do
    # R15: Budget Data Created from Task Limit [INTEGRATION]
    @tag :r15
    @tag :integration
    test "R15: creates root agent with budget_data from task.budget_limit", %{deps: deps} do
      task_fields = %{profile: deps.profile.name, budget_limit: Decimal.new("100.00")}
      agent_fields = %{task_description: "Build feature with budget"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      # Verify task has budget_limit persisted
      assert task.budget_limit == Decimal.new("100.00")

      # Verify agent has budget_data with :root mode
      {:ok, state} = Core.get_state(agent_pid)
      assert state.budget_data.mode == :root
      assert state.budget_data.allocated == Decimal.new("100.00")
      assert state.budget_data.committed == Decimal.new("0")

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # R16: Nil Budget Creates N/A Mode [INTEGRATION]
    @tag :r16
    @tag :integration
    test "R16: nil budget_limit creates N/A budget_data", %{deps: deps} do
      task_fields = %{profile: deps.profile.name}
      agent_fields = %{task_description: "No budget task"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      # Verify task has nil budget_limit
      assert task.budget_limit == nil

      # Verify agent has budget_data with :na mode
      {:ok, state} = Core.get_state(agent_pid)
      assert state.budget_data.mode == :na
      assert state.budget_data.allocated == nil
      assert state.budget_data.committed == nil

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # R17: Budget Data Structure [UNIT]
    @tag :r17
    @tag :unit
    test "R17: budget_data has correct structure", %{deps: deps} do
      task_fields = %{profile: deps.profile.name, budget_limit: Decimal.new("50.00")}
      agent_fields = %{task_description: "Verify structure"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {_task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      {:ok, state} = Core.get_state(agent_pid)

      # Verify budget_data has required fields
      assert Map.has_key?(state.budget_data, :allocated)
      assert Map.has_key?(state.budget_data, :committed)
      assert Map.has_key?(state.budget_data, :mode)

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # R18: Decimal Precision Preserved [INTEGRATION]
    @tag :r18
    @tag :integration
    test "R18: budget Decimal precision preserved through creation", %{deps: deps} do
      # Test with precise decimal value
      precise_budget = Decimal.new("99.99")
      task_fields = %{profile: deps.profile.name, budget_limit: precise_budget}
      agent_fields = %{task_description: "Precision test"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      # Verify exact Decimal preservation
      assert Decimal.equal?(task.budget_limit, precise_budget)

      {:ok, state} = Core.get_state(agent_pid)
      assert Decimal.equal?(state.budget_data.allocated, precise_budget)

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    # Additional edge case: Large budget value
    @tag :r18_large
    @tag :integration
    test "R18b: large budget values preserved correctly", %{deps: deps} do
      large_budget = Decimal.new("999999.99")
      task_fields = %{profile: deps.profile.name, budget_limit: large_budget}
      agent_fields = %{task_description: "Large budget test"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      assert Decimal.equal?(task.budget_limit, large_budget)

      {:ok, state} = Core.get_state(agent_pid)
      assert Decimal.equal?(state.budget_data.allocated, large_budget)

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end
  end
end
