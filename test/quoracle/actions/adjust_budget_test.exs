defmodule Quoracle.Actions.AdjustBudgetTest do
  @moduledoc """
  Tests for ACTION_AdjustBudget v1.0 - Adjust Child Budget Action.

  WorkGroupID: feat-20251231-191717
  Packet: Packet 3 (Agent Core Integration)

  Tests budget adjustment from parent to direct child:
  - Increase with sufficient parent budget
  - Decrease with child having sufficient available
  - Validation of direct child relationship
  - Atomic escrow updates
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.AdjustBudget
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

  # Helper to spawn a parent agent with budget and children tracking
  defp spawn_parent_with_budget(deps, budget_data) do
    task_id = Ecto.UUID.generate()

    parent_config = %{
      agent_id: "parent-adjust-#{System.unique_integer([:positive])}",
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
      models: [],
      capability_groups: [:hierarchy]
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
      agent_id: "child-adjust-#{System.unique_integer([:positive])}",
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

  describe "R1-R7: execute/3 UNIT tests" do
    # R1: Increase with Sufficient Parent Budget [UNIT]
    @tag :r1
    @tag :unit
    test "R1: increases child budget when parent has funds", %{deps: deps} do
      # Arrange: Parent with available budget
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("20.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      # Child with current allocation of 20.00
      child_budget = %{
        mode: :child,
        allocated: Decimal.new("20.00"),
        committed: Decimal.new("0")
      }

      {:ok, _child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      params = %{child_id: child_state.agent_id, new_budget: "40.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      # Act
      result = AdjustBudget.execute(params, parent_state.agent_id, opts)

      # Assert: Should succeed (increase of 20.00, parent has 60.00 available)
      assert {:ok, response} = result
      assert response.action == "adjust_budget"
      assert response.child_id == child_state.agent_id
      assert response.new_budget == "40.00"
    end

    # R2: Increase with Insufficient Parent Budget [UNIT]
    @tag :r2
    @tag :unit
    test "R2: fails increase when parent lacks funds", %{deps: deps} do
      # Arrange: Parent with limited available budget
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("50.00"),
        committed: Decimal.new("40.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      child_budget = %{
        mode: :child,
        allocated: Decimal.new("40.00"),
        committed: Decimal.new("0")
      }

      {:ok, _child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Try to increase by 20.00 when parent only has 10.00 available
      params = %{child_id: child_state.agent_id, new_budget: "60.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      # Act
      result = AdjustBudget.execute(params, parent_state.agent_id, opts)

      # Assert
      assert {:error, :insufficient_parent_budget} = result
    end

    # R3: Decrease with Sufficient Child Available [UNIT]
    @tag :r3
    @tag :unit
    test "R3: decreases child budget when above minimum", %{deps: deps} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("50.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      # Child with allocation of 50.00, no spent/committed
      child_budget = %{
        mode: :child,
        allocated: Decimal.new("50.00"),
        committed: Decimal.new("0")
      }

      {:ok, _child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Decrease to 30.00 (should succeed since child has no spent/committed)
      params = %{child_id: child_state.agent_id, new_budget: "30.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      # Act
      result = AdjustBudget.execute(params, parent_state.agent_id, opts)

      # Assert
      assert {:ok, response} = result
      assert response.new_budget == "30.00"
    end

    # R4: Decrease Below Minimum [UNIT]
    @tag :r4
    @tag :unit
    test "R4: fails decrease below spent+committed", %{deps: deps} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("50.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      # Child with allocation of 50.00, committed of 30.00
      child_budget = %{
        mode: :child,
        allocated: Decimal.new("50.00"),
        committed: Decimal.new("30.00")
      }

      {:ok, _child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Try to decrease to 20.00 (below committed of 30.00)
      params = %{child_id: child_state.agent_id, new_budget: "20.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      # Act
      result = AdjustBudget.execute(params, parent_state.agent_id, opts)

      # Assert: Should return structured error with details
      assert {:error, error_map} = result
      assert error_map.reason == :would_violate_escrow
      assert Map.has_key?(error_map, :spent)
      assert Map.has_key?(error_map, :committed)
      assert Map.has_key?(error_map, :minimum)
    end

    # R5: Non-Direct Child [UNIT]
    @tag :r5
    @tag :unit
    test "R5: rejects adjustment to non-direct child", %{deps: deps} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("20.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      # First spawn a REAL child to ensure direct child check works
      child_budget = %{mode: :child, allocated: Decimal.new("20.00"), committed: Decimal.new("0")}

      {:ok, _child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Spawn another agent that is NOT a child of parent
      other_budget = %{mode: :root, allocated: Decimal.new("50.00"), committed: Decimal.new("0")}
      {:ok, other_pid} = spawn_parent_with_budget(deps, other_budget)
      {:ok, other_state} = Core.get_state(other_pid)

      opts = [registry: deps.registry, pubsub: deps.pubsub]

      # First verify real child CAN be adjusted (requires full impl)
      child_params = %{child_id: child_state.agent_id, new_budget: "25.00"}
      child_result = AdjustBudget.execute(child_params, parent_state.agent_id, opts)
      assert {:ok, _} = child_result

      # Then verify non-child is rejected
      other_params = %{child_id: other_state.agent_id, new_budget: "30.00"}
      other_result = AdjustBudget.execute(other_params, parent_state.agent_id, opts)
      assert {:error, :not_direct_child} = other_result
    end

    # R6: Invalid Amount [UNIT]
    @tag :r6
    @tag :unit
    test "R6: rejects non-positive amount", %{deps: deps} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("20.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      child_budget = %{mode: :child, allocated: Decimal.new("20.00"), committed: Decimal.new("0")}

      {:ok, _child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Try negative amount
      params = %{child_id: child_state.agent_id, new_budget: "-10.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      result = AdjustBudget.execute(params, parent_state.agent_id, opts)

      assert {:error, :invalid_amount} = result

      # Try zero
      params_zero = %{child_id: child_state.agent_id, new_budget: "0"}
      result_zero = AdjustBudget.execute(params_zero, parent_state.agent_id, opts)

      assert {:error, :invalid_amount} = result_zero
    end

    # R7: N/A Parent Budget [UNIT]
    @tag :r7
    @tag :unit
    test "R7: allows any increase for N/A parent", %{deps: deps} do
      # Parent with N/A (unlimited) budget
      parent_budget = %{
        mode: :na,
        allocated: nil,
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      child_budget = %{
        mode: :child,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, _child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Large increase should be allowed for N/A parent
      params = %{child_id: child_state.agent_id, new_budget: "999999.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      result = AdjustBudget.execute(params, parent_state.agent_id, opts)

      assert {:ok, response} = result
      assert response.new_budget == "999999.00"
    end
  end

  describe "R8-R10: execute/3 INTEGRATION tests" do
    # R8: Atomic Escrow Update [INTEGRATION]
    @tag :r8
    @tag :integration
    test "R8: updates escrow atomically", %{deps: deps} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("20.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      child_budget = %{
        mode: :child,
        allocated: Decimal.new("20.00"),
        committed: Decimal.new("0")
      }

      {:ok, child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Increase child budget by 10.00
      params = %{child_id: child_state.agent_id, new_budget: "30.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      {:ok, _response} = AdjustBudget.execute(params, parent_state.agent_id, opts)

      # Verify parent committed increased by 10.00 (delta)
      {:ok, updated_parent} = Core.get_state(parent_pid)
      assert Decimal.equal?(updated_parent.budget_data.committed, Decimal.new("30.00"))

      # Verify child allocated updated to 30.00
      {:ok, updated_child} = Core.get_state(child_pid)
      assert Decimal.equal?(updated_child.budget_data.allocated, Decimal.new("30.00"))
    end

    # R10: Router Integration [INTEGRATION]
    @tag :r10
    @tag :integration
    test "R10: Router executes adjust_budget action", %{deps: deps} do
      alias Quoracle.Actions.Router

      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("20.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      child_budget = %{
        mode: :child,
        allocated: Decimal.new("20.00"),
        committed: Decimal.new("0")
      }

      {:ok, _child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Per-action Router (v28.0): Spawn Router for adjust_budget action
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :adjust_budget,
          action_id: action_id,
          agent_id: parent_state.agent_id,
          agent_pid: parent_pid,
          pubsub: deps.pubsub,
          sandbox_owner: deps.sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router_pid) do
          try do
            GenServer.stop(router_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute via Router
      params = %{child_id: child_state.agent_id, new_budget: "45.00"}

      action_opts = [
        action_id: action_id,
        agent_id: parent_state.agent_id,
        capability_groups: [:hierarchy],
        registry: deps.registry,
        pubsub: deps.pubsub
      ]

      result = Router.execute_action(router_pid, :adjust_budget, params, action_opts)

      assert {:ok, response} = result
      assert response.action == "adjust_budget"
      assert response.new_budget == "45.00"
    end
  end
end
