defmodule Quoracle.Actions.AdjustBudgetTimeoutTest do
  @moduledoc """
  Tests for FIX_AdjustBudgetTimeout - Cast-Based Budget Update (v3.0).

  WorkGroupID: fix-20260217-adjust-budget-timeout
  Packet: Packet 1 (Budget Fix)

  v3.0 changes being tested:
  - R1: Unified code path (always Core.adjust_child_budget, no adjust_child_directly)
  - R2: No GenServer.call to child (eliminates timeout when child is busy)
  - R3: Child allocation sourced from parent's children[].budget_allocated
  - R4: Cast to child {:set_budget_allocated, new_budget} (fire-and-forget)
  - R5: Core handles set_budget_allocated cast (updates allocated + over_budget)
  - R8: Decrease validation uses spent-only (not spent+committed), new error atom
  - R15: No-change case returns {:ok, parent_budget} unchanged
  - R17: [ACCEPTANCE] Busy child does not cause timeout

  Tests that verify continuity of existing behavior (R6, R7, R9-R14, R16)
  remain in adjust_budget_test.exs.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.AdjustBudget
  alias Quoracle.Agent.Core
  alias Quoracle.Costs.AgentCost
  alias Quoracle.Tasks.Task, as: TaskSchema
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

  # Helper to record a cost for a child agent
  defp record_child_spending(agent_id, amount) do
    {:ok, db_task} =
      Repo.insert(TaskSchema.changeset(%TaskSchema{}, %{prompt: "Test", status: "running"}))

    %AgentCost{}
    |> AgentCost.changeset(%{
      agent_id: agent_id,
      task_id: db_task.id,
      cost_type: "llm_consensus",
      cost_usd: amount
    })
    |> Repo.insert!()
  end

  # ============================================================================
  # R1: Unified Code Path [UNIT]
  # WHEN AdjustBudget.execute/3 called with parent_config in opts
  # THEN always routes through Core.adjust_child_budget (never adjust_child_directly)
  #
  # v2.0 bug: when parent_config in opts, takes Path A (adjust_child_directly)
  # which only updates child directly, doesn't update parent state atomically.
  # v3.0 fix: always uses Core.adjust_child_budget regardless of parent_config.
  # ============================================================================
  describe "R1: Unified Code Path" do
    @tag :r1
    @tag :unit
    test "execute/3 with parent_config routes through Core (atomic parent update)", %{deps: deps} do
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

      # Execute WITH parent_config in opts
      # v2.0: takes adjust_child_directly path (only updates child, not parent)
      # v3.0: always goes through Core.adjust_child_budget (updates both)
      params = %{child_id: child_state.agent_id, new_budget: "30.00"}

      opts = [
        registry: deps.registry,
        pubsub: deps.pubsub,
        parent_config: parent_state
      ]

      result = AdjustBudget.execute(params, parent_state.agent_id, opts)

      # Assert: Should succeed
      assert {:ok, response} = result
      assert response.action == "adjust_budget"
      assert response.new_budget == "30.00"

      # KEY ASSERTION: Parent's committed MUST be updated atomically
      # v2.0 fails here because adjust_child_directly doesn't update parent state
      {:ok, updated_parent} = Core.get_state(parent_pid)
      assert Decimal.equal?(updated_parent.budget_data.committed, Decimal.new("30.00"))
    end
  end

  # ============================================================================
  # R2: No GenServer.call to Child [UNIT]
  # WHEN BudgetHandler.adjust_child_budget/4 executes
  # THEN never calls Core.get_state(child_pid) - reads allocation from parent state
  #
  # Proven by suspending child: if impl calls child, it will timeout.
  # v3.0 should succeed because it never calls child GenServer.
  # ============================================================================
  describe "R2: No GenServer.call to Child" do
    @tag :r2
    @tag :unit
    test "succeeds with suspended child (proves no GenServer.call to child)", %{deps: deps} do
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

      # Suspend the child GenServer - any GenServer.call to it will timeout
      :sys.suspend(child_pid)

      params = %{child_id: child_state.agent_id, new_budget: "30.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      # Act: v3.0 should succeed because it never calls child GenServer
      # v2.0 calls Core.get_state(child_pid) which will timeout on suspended process
      result = AdjustBudget.execute(params, parent_state.agent_id, opts)

      # Resume child for cleanup
      :sys.resume(child_pid)

      # Assert: Should succeed without calling child
      assert {:ok, response} = result
      assert response.action == "adjust_budget"
      assert response.new_budget == "30.00"
    end
  end

  # ============================================================================
  # R3: Child Allocation from Parent State [UNIT]
  # WHEN BudgetHandler.adjust_child_budget/4 needs current child allocation
  # THEN reads from state.children[].budget_allocated (NOT child's state)
  #
  # Proven by having different values in parent's children list vs child's state.
  # If impl reads from child state, the delta calculation will be wrong.
  # ============================================================================
  describe "R3: Child Allocation from Parent State" do
    @tag :r3
    @tag :unit
    test "uses budget_allocated from parent's children list for delta", %{deps: deps} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("30.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      child_budget = %{
        mode: :child,
        allocated: Decimal.new("30.00"),
        committed: Decimal.new("0")
      }

      {:ok, child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Now artificially change child's budget_data.allocated directly
      # to create divergence between parent's children list and child's state.
      # Parent's children[].budget_allocated = 30.00
      # Child's budget_data.allocated = 10.00 (we change it directly)
      Core.update_budget_data(child_pid, %{
        child_state.budget_data
        | allocated: Decimal.new("10.00")
      })

      # Verify divergence exists
      {:ok, diverged_child} = Core.get_state(child_pid)
      assert Decimal.equal?(diverged_child.budget_data.allocated, Decimal.new("10.00"))
      {:ok, parent_with_child} = Core.get_state(parent_pid)
      child_entry = Enum.find(parent_with_child.children, &(&1.agent_id == child_state.agent_id))
      assert Decimal.equal?(child_entry.budget_allocated, Decimal.new("30.00"))

      # Now adjust to 40.00
      # If reading from parent state: delta = 40 - 30 = 10 (increase)
      # If reading from child state: delta = 40 - 10 = 30 (larger increase)
      params = %{child_id: child_state.agent_id, new_budget: "40.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      {:ok, _response} = AdjustBudget.execute(params, parent_state.agent_id, opts)

      # Assert: Parent committed should reflect delta from parent's children list (10)
      # not delta from child state (30)
      {:ok, updated_parent} = Core.get_state(parent_pid)
      # Starting committed was 30.00, delta should be 10.00 (from 30->40)
      assert Decimal.equal?(updated_parent.budget_data.committed, Decimal.new("40.00"))
    end
  end

  # ============================================================================
  # R4: Cast to Child [UNIT]
  # WHEN budget adjustment succeeds
  # THEN sends {:set_budget_allocated, new_budget} cast to child (fire-and-forget)
  #
  # v2.0: Uses Core.update_budget_data(child_pid, ...) which is GenServer.call
  # v3.0: Sends {:set_budget_allocated, new_budget} cast (non-blocking)
  #
  # Proven by suspending child, executing adjustment, then resuming.
  # v2.0 will timeout on the call; v3.0 returns immediately (cast is fire-and-forget).
  # After resume, child should have the updated allocated value.
  # ============================================================================
  describe "R4: Cast to Child" do
    @tag :r4
    @tag :unit
    test "sends cast to child with new budget (fire-and-forget)", %{deps: deps} do
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

      # Suspend child to prove the update is via cast (fire-and-forget), not call
      :sys.suspend(child_pid)

      params = %{child_id: child_state.agent_id, new_budget: "35.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      # Act: v3.0 should return immediately because cast doesn't block
      # v2.0 will timeout because it calls Core.get_state(child_pid) and
      # Core.update_budget_data(child_pid, ...) which are GenServer.calls
      result = AdjustBudget.execute(params, parent_state.agent_id, opts)

      # Resume child so it processes the queued cast
      :sys.resume(child_pid)

      # Assert: Parent returned successfully (cast didn't block)
      assert {:ok, response} = result
      assert response.action == "adjust_budget"
      assert response.new_budget == "35.00"

      # Assert: Child received the cast and updated its allocated
      {:ok, updated_child} = Core.get_state(child_pid)
      assert Decimal.equal?(updated_child.budget_data.allocated, Decimal.new("35.00"))
    end
  end

  # ============================================================================
  # R5: Core Handles set_budget_allocated Cast [UNIT]
  # WHEN Core receives {:set_budget_allocated, new_budget} cast
  # THEN updates budget_data.allocated and re-evaluates over_budget
  #
  # This cast handler doesn't exist yet in Core.
  # ============================================================================
  describe "R5: Core Handles set_budget_allocated Cast" do
    @tag :r5
    @tag :unit
    test "Core processes set_budget_allocated cast", %{deps: deps} do
      agent_budget = %{
        mode: :child,
        allocated: Decimal.new("10.00"),
        committed: Decimal.new("0")
      }

      {:ok, agent_pid} = spawn_parent_with_budget(deps, agent_budget)
      {:ok, agent_state} = Core.get_state(agent_pid)
      # Initially not over budget
      refute agent_state.over_budget

      # Act: Send set_budget_allocated cast (v3.0 new handler)
      GenServer.cast(agent_pid, {:set_budget_allocated, Decimal.new("50.00")})

      # Sync to ensure cast processed
      {:ok, updated_state} = Core.get_state(agent_pid)

      # Assert: allocated updated via cast handler
      assert Decimal.equal?(updated_state.budget_data.allocated, Decimal.new("50.00"))
    end

    @tag :r5
    @tag :unit
    test "set_budget_allocated re-evaluates over_budget status", %{deps: deps} do
      # Agent with small budget that is currently over budget
      agent_budget = %{
        mode: :child,
        allocated: Decimal.new("1.00"),
        committed: Decimal.new("0")
      }

      {:ok, agent_pid} = spawn_parent_with_budget(deps, agent_budget)

      # Record spending that exceeds current allocation
      {:ok, agent_state} = Core.get_state(agent_pid)
      record_child_spending(agent_state.agent_id, Decimal.new("5.00"))

      # Trigger over_budget recalc (cost_recorded notification)
      send(agent_pid, {:cost_recorded, nil})
      {:ok, over_state} = Core.get_state(agent_pid)
      assert over_state.over_budget

      # Act: Increase allocation to cover spending
      GenServer.cast(agent_pid, {:set_budget_allocated, Decimal.new("100.00")})
      {:ok, recovered_state} = Core.get_state(agent_pid)

      # Assert: over_budget should be recalculated to false
      refute recovered_state.over_budget
      assert Decimal.equal?(recovered_state.budget_data.allocated, Decimal.new("100.00"))
    end
  end

  # ============================================================================
  # R8: Decrease Validation Uses Spent-Only [UNIT]
  # WHEN new_budget < child spent (from DB)
  # THEN returns {:error, %{reason: :would_exceed_spent, ...}}
  #
  # v2.0: validates against spent+committed, returns :would_violate_escrow
  # v3.0: validates against spent-only (from DB), returns :would_exceed_spent
  # ============================================================================
  describe "R8: Decrease Validation Uses Spent-Only" do
    @tag :r8
    @tag :unit
    test "decrease fails with :would_exceed_spent when below child spent", %{deps: deps} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("50.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      child_budget = %{
        mode: :child,
        allocated: Decimal.new("50.00"),
        committed: Decimal.new("0")
      }

      {:ok, _child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Record spending for child in DB
      record_child_spending(child_state.agent_id, Decimal.new("40.00"))

      # Try to decrease to 20.00 when child has 40.00 spent
      params = %{child_id: child_state.agent_id, new_budget: "20.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      result = AdjustBudget.execute(params, parent_state.agent_id, opts)

      # Assert: v3.0 returns :would_exceed_spent (not :would_violate_escrow)
      assert {:error, error_info} = result
      assert error_info.reason == :would_exceed_spent
      assert Map.has_key?(error_info, :child_spent)
      assert Map.has_key?(error_info, :requested)
      assert Map.has_key?(error_info, :minimum)
    end

    @tag :r8
    @tag :unit
    test "decrease succeeds when above spent but below spent+committed", %{deps: deps} do
      # v3.0 change: committed is no longer part of decrease validation
      # Only spent from DB matters. If child has committed=30 but spent=5,
      # decreasing to 10 should succeed (10 > 5) even though 10 < 5+30=35.
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("50.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      # Child has committed=30 but no actual spending in DB
      child_budget = %{
        mode: :child,
        allocated: Decimal.new("50.00"),
        committed: Decimal.new("30.00")
      }

      {:ok, _child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Record modest spending (5.00) in DB
      record_child_spending(child_state.agent_id, Decimal.new("5.00"))

      # Decrease to 10.00
      # v2.0: would fail (10 < 5+30 = 35, :would_violate_escrow)
      # v3.0: should succeed (10 > 5, only spent matters)
      params = %{child_id: child_state.agent_id, new_budget: "10.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      result = AdjustBudget.execute(params, parent_state.agent_id, opts)

      # Assert: v3.0 succeeds because only DB spent is checked
      assert {:ok, response} = result
      assert response.new_budget == "10.00"
    end
  end

  # ============================================================================
  # R15: No Change (Same Budget) [UNIT]
  # WHEN new_budget == current allocation (from parent's children list)
  # THEN returns {:ok, response} with no parent state changes
  #
  # v3.0: reads current from parent's children list, so the no-op path
  # must work with children[].budget_allocated as source of truth.
  # ============================================================================
  describe "R15: No Change (Same Budget)" do
    @tag :r15
    @tag :unit
    test "no-op when budget unchanged, uses parent children list", %{deps: deps} do
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

      # Change child's actual allocated to something different
      # to prove delta is computed from parent's children list
      Core.update_budget_data(child_pid, %{
        child_state.budget_data
        | allocated: Decimal.new("999.00")
      })

      # Set new_budget to same as parent's children[].budget_allocated (25.00)
      params = %{child_id: child_state.agent_id, new_budget: "25.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      result = AdjustBudget.execute(params, parent_state.agent_id, opts)

      # Assert: Should succeed with no change
      assert {:ok, response} = result
      assert response.new_budget == "25.00"

      # Parent state unchanged
      {:ok, unchanged_parent} = Core.get_state(parent_pid)
      assert Decimal.equal?(unchanged_parent.budget_data.committed, Decimal.new("25.00"))
    end
  end

  # ============================================================================
  # R17: System Test - Busy Child [SYSTEM/ACCEPTANCE]
  # WHEN parent adjusts budget of child that is mid-consensus (blocked)
  # THEN succeeds without timeout (cast, not call)
  #
  # This is the acceptance test proving the original bug is fixed.
  # The bug: Core.get_state(child_pid) during adjust_child_budget times out
  # when child is blocked in a long LLM consensus call.
  # ============================================================================
  describe "R17: System Test - Busy Child" do
    @tag :r17
    @tag :system
    @tag :acceptance
    test "adjust_budget succeeds when child GenServer is blocked", %{deps: deps} do
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
        committed: Decimal.new("0")
      }

      {:ok, child_pid, child_state} =
        spawn_child_with_budget(deps, parent_pid, parent_state, child_budget)

      # Simulate child being busy (mid-consensus LLM call)
      # Suspending the GenServer means any GenServer.call to it will hang indefinitely
      :sys.suspend(child_pid)

      # Act: Parent adjusts child's budget while child is "busy"
      params = %{child_id: child_state.agent_id, new_budget: "75.00"}
      opts = [registry: deps.registry, pubsub: deps.pubsub]

      result = AdjustBudget.execute(params, parent_state.agent_id, opts)

      # Resume child for cleanup and to verify cast was queued
      :sys.resume(child_pid)

      # Assert: Budget adjustment succeeded despite child being busy
      assert {:ok, response} = result
      assert response.action == "adjust_budget"
      assert response.child_id == child_state.agent_id
      assert response.new_budget == "75.00"

      # Negative assertions: No timeout, no error
      refute match?({:error, :timeout}, result)
      refute match?({:error, _}, result)

      # Verify parent state updated correctly
      {:ok, updated_parent} = Core.get_state(parent_pid)
      assert Decimal.equal?(updated_parent.budget_data.committed, Decimal.new("75.00"))

      # Verify child received the budget update cast after resume
      {:ok, updated_child} = Core.get_state(child_pid)
      assert Decimal.equal?(updated_child.budget_data.allocated, Decimal.new("75.00"))
    end
  end
end
