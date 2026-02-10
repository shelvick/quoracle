defmodule Quoracle.Agent.CoreAdjustBudgetTest do
  @moduledoc """
  Tests for AGENT_Core v23.0 - adjust_child_budget Handler.

  WorkGroupID: feat-20251231-191717
  Packet: Packet 3 (Agent Core Integration)

  Tests the Core.adjust_child_budget/4 GenServer handler:
  - Atomic budget updates (parent committed + child allocated)
  - Direct child validation
  - Registry lookup failures
  - Child notification
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    # Subscribe to lifecycle events
    Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

    {:ok, deps: deps}
  end

  # Helper to spawn a parent agent with budget
  defp spawn_parent_with_budget(deps, budget_data) do
    task_id = Ecto.UUID.generate()

    parent_config = %{
      agent_id: "parent-core-#{System.unique_integer([:positive])}",
      task_id: task_id,
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: deps.sandbox_owner,
      pubsub: deps.pubsub,
      budget_data: budget_data,
      prompt_fields: %{
        provided: %{task_description: "Parent task"},
        injected: %{global_context: "", constraints: []},
        transformed: %{}
      },
      models: []
    }

    spawn_agent_with_cleanup(deps.dynsup, parent_config,
      registry: deps.registry,
      pubsub: deps.pubsub,
      sandbox_owner: deps.sandbox_owner
    )
  end

  # Helper to spawn a child agent with budget under a parent
  defp spawn_child_with_budget(deps, parent_pid, parent_state, child_budget_data) do
    child_config = %{
      agent_id: "child-core-#{System.unique_integer([:positive])}",
      task_id: parent_state.task_id,
      parent_id: parent_state.agent_id,
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: deps.sandbox_owner,
      pubsub: deps.pubsub,
      budget_data: child_budget_data,
      prompt_fields: %{
        provided: %{task_description: "Child task"},
        injected: %{global_context: "", constraints: []},
        transformed: %{}
      },
      models: []
    }

    {:ok, child_pid} =
      spawn_agent_with_cleanup(deps.dynsup, child_config,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      )

    # Register child with parent (simulate post-spawn state)
    {:ok, child_state} = Core.get_state(child_pid)

    child_info = %{
      agent_id: child_state.agent_id,
      spawned_at: DateTime.utc_now(),
      budget_allocated: child_budget_data.allocated
    }

    GenServer.cast(parent_pid, {:child_spawned, child_info})
    # Allow cast to process
    _ = Core.get_state(parent_pid)

    {:ok, child_pid, child_state}
  end

  describe "R40-R45: Core.adjust_child_budget/4" do
    # R40: Adjust Child Budget Success [INTEGRATION]
    @tag :r40
    @tag :integration
    test "R40: updates child and parent budget_data", %{deps: deps} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("25.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      child_budget = %{
        mode: :child,
        allocated: Decimal.new("25.00"),
        committed: Decimal.new("0")
      }

      {:ok, child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Increase child budget by 15.00 (25 -> 40)
      new_budget = Decimal.new("40.00")
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      result =
        Core.adjust_child_budget(parent_state.agent_id, child_state.agent_id, new_budget, opts)

      assert :ok = result

      # Verify parent committed increased (25 + 15 = 40)
      {:ok, updated_parent} = Core.get_state(parent_pid)
      assert Decimal.equal?(updated_parent.budget_data.committed, Decimal.new("40.00"))

      # Verify child allocated updated
      {:ok, updated_child} = Core.get_state(child_pid)
      assert Decimal.equal?(updated_child.budget_data.allocated, Decimal.new("40.00"))
    end

    # R41: Direct Child Validation [UNIT]
    @tag :r41
    @tag :unit
    test "R41: rejects non-direct child", %{deps: deps} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      # Spawn another agent that is NOT a child of parent
      other_budget = %{mode: :root, allocated: Decimal.new("50.00"), committed: Decimal.new("0")}
      {:ok, other_pid} = spawn_parent_with_budget(deps, other_budget)
      {:ok, other_state} = Core.get_state(other_pid)

      new_budget = Decimal.new("30.00")
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      result =
        Core.adjust_child_budget(parent_state.agent_id, other_state.agent_id, new_budget, opts)

      assert {:error, :not_direct_child} = result
    end

    # R42: Child Not Found [INTEGRATION]
    @tag :r42
    @tag :integration
    test "R42: returns error for missing child", %{deps: deps} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      # Try to adjust a non-existent child
      new_budget = Decimal.new("30.00")
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      result =
        Core.adjust_child_budget(parent_state.agent_id, "nonexistent-child-id", new_budget, opts)

      assert {:error, :child_not_found} = result
    end

    # R43: Parent Not Found [INTEGRATION]
    @tag :r43
    @tag :integration
    test "R43: returns error for missing parent", %{deps: deps} do
      new_budget = Decimal.new("30.00")
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      result =
        Core.adjust_child_budget("nonexistent-parent-id", "some-child-id", new_budget, opts)

      assert {:error, :parent_not_found} = result
    end

    # R44: Atomic Update [INTEGRATION]
    @tag :r44
    @tag :integration
    test "R44: updates parent committed and child allocated together", %{deps: deps} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("200.00"),
        committed: Decimal.new("50.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      child_budget = %{
        mode: :child,
        allocated: Decimal.new("50.00"),
        committed: Decimal.new("10.00")
      }

      {:ok, child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Record initial values
      {:ok, initial_parent} = Core.get_state(parent_pid)
      {:ok, initial_child} = Core.get_state(child_pid)

      initial_parent_committed = initial_parent.budget_data.committed
      initial_child_allocated = initial_child.budget_data.allocated

      # Increase child by 30.00 (50 -> 80)
      new_budget = Decimal.new("80.00")
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      :ok =
        Core.adjust_child_budget(parent_state.agent_id, child_state.agent_id, new_budget, opts)

      # Verify both updated atomically
      {:ok, final_parent} = Core.get_state(parent_pid)
      {:ok, final_child} = Core.get_state(child_pid)

      # Parent committed should increase by delta (30.00)
      expected_parent_committed = Decimal.add(initial_parent_committed, Decimal.new("30.00"))
      assert Decimal.equal?(final_parent.budget_data.committed, expected_parent_committed)

      # Child allocated should be new value
      assert Decimal.equal?(final_child.budget_data.allocated, new_budget)

      # Deltas should match
      parent_delta = Decimal.sub(final_parent.budget_data.committed, initial_parent_committed)
      child_delta = Decimal.sub(final_child.budget_data.allocated, initial_child_allocated)
      assert Decimal.equal?(parent_delta, child_delta)
    end
  end
end
