defmodule Quoracle.Agent.Core.ChildrenTrackerTest do
  @moduledoc """
  Unit tests for ChildrenTracker handler module.

  Tests the handler functions in isolation without going through Core GenServer.

  WorkGroupID: feat-20251227-children-inject
  v2.0 Budget additions: wip-20251231-budget (Packet 3)
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.Core.ChildrenTracker

  defp make_state(children) do
    %{children: children}
  end

  # Helper for creating child entries with budget (v2.0)
  defp child_entry(agent_id, opts) do
    %{
      agent_id: agent_id,
      spawned_at: Keyword.get(opts, :spawned_at, DateTime.utc_now()),
      budget_allocated: Keyword.get(opts, :budget_allocated)
    }
  end

  describe "handle_child_spawned/2" do
    test "R1: adds child to front of children list" do
      state = make_state([])
      spawned_at = DateTime.utc_now()
      data = %{agent_id: "child-1", spawned_at: spawned_at}

      {:noreply, new_state} = ChildrenTracker.handle_child_spawned(data, state)

      assert length(new_state.children) == 1
      assert hd(new_state.children).agent_id == "child-1"
      assert hd(new_state.children).spawned_at == spawned_at
    end

    test "R4: newest children appear first in list" do
      t1 = DateTime.utc_now()
      t2 = DateTime.add(t1, 1, :second)
      t3 = DateTime.add(t2, 1, :second)

      state = make_state([])

      {:noreply, state1} =
        ChildrenTracker.handle_child_spawned(%{agent_id: "child-1", spawned_at: t1}, state)

      {:noreply, state2} =
        ChildrenTracker.handle_child_spawned(%{agent_id: "child-2", spawned_at: t2}, state1)

      {:noreply, state3} =
        ChildrenTracker.handle_child_spawned(%{agent_id: "child-3", spawned_at: t3}, state2)

      # Newest first (prepend behavior)
      assert length(state3.children) == 3
      assert Enum.at(state3.children, 0).agent_id == "child-3"
      assert Enum.at(state3.children, 1).agent_id == "child-2"
      assert Enum.at(state3.children, 2).agent_id == "child-1"
    end

    test "returns {:noreply, new_state} tuple" do
      state = make_state([])
      spawned_at = DateTime.utc_now()
      data = %{agent_id: "child-1", spawned_at: spawned_at}

      result = ChildrenTracker.handle_child_spawned(data, state)

      assert {:noreply, _new_state} = result
    end
  end

  describe "handle_child_dismissed/2" do
    test "R2: removes child from children list by agent_id" do
      spawned_at = DateTime.utc_now()

      state =
        make_state([
          %{agent_id: "child-1", spawned_at: spawned_at},
          %{agent_id: "child-2", spawned_at: spawned_at}
        ])

      {:noreply, new_state} = ChildrenTracker.handle_child_dismissed("child-1", state)

      assert length(new_state.children) == 1
      assert hd(new_state.children).agent_id == "child-2"
    end

    test "R3: dismissing non-existent child leaves state unchanged" do
      spawned_at = DateTime.utc_now()
      state = make_state([%{agent_id: "child-1", spawned_at: spawned_at}])

      {:noreply, new_state} = ChildrenTracker.handle_child_dismissed("non-existent", state)

      assert new_state.children == state.children
    end

    test "handles empty children list gracefully" do
      state = make_state([])

      {:noreply, new_state} = ChildrenTracker.handle_child_dismissed("any-id", state)

      assert new_state.children == []
    end

    test "removes only the matching child" do
      spawned_at = DateTime.utc_now()

      state =
        make_state([
          %{agent_id: "child-3", spawned_at: spawned_at},
          %{agent_id: "child-2", spawned_at: spawned_at},
          %{agent_id: "child-1", spawned_at: spawned_at}
        ])

      {:noreply, new_state} = ChildrenTracker.handle_child_dismissed("child-2", state)

      assert length(new_state.children) == 2
      agent_ids = Enum.map(new_state.children, & &1.agent_id)
      assert "child-1" in agent_ids
      assert "child-3" in agent_ids
      refute "child-2" in agent_ids
    end

    test "returns {:noreply, new_state} tuple" do
      state = make_state([])

      result = ChildrenTracker.handle_child_dismissed("any-id", state)

      assert {:noreply, _new_state} = result
    end
  end

  # ==========================================================================
  # v2.0 Budget Tracking Tests (wip-20251231-budget)
  # ==========================================================================

  describe "R6-R7: budget_allocated in child entries" do
    test "R6: child entry includes budget_allocated field" do
      state = make_state([])
      spawned_at = DateTime.utc_now()
      budget = Decimal.new("50.00")

      data = %{agent_id: "child-1", spawned_at: spawned_at, budget_allocated: budget}

      {:noreply, new_state} = ChildrenTracker.handle_child_spawned(data, state)

      child = hd(new_state.children)
      assert child.agent_id == "child-1"
      assert child.spawned_at == spawned_at
      assert Decimal.equal?(child.budget_allocated, Decimal.new("50.00"))
    end

    test "R7: budget_allocated is nil for N/A children" do
      state = make_state([])
      spawned_at = DateTime.utc_now()

      # No budget_allocated in data (N/A child)
      data = %{agent_id: "child-1", spawned_at: spawned_at}

      {:noreply, new_state} = ChildrenTracker.handle_child_spawned(data, state)

      child = hd(new_state.children)
      assert child.budget_allocated == nil
    end

    test "R7: explicit nil budget_allocated preserved" do
      state = make_state([])
      spawned_at = DateTime.utc_now()

      data = %{agent_id: "child-1", spawned_at: spawned_at, budget_allocated: nil}

      {:noreply, new_state} = ChildrenTracker.handle_child_spawned(data, state)

      child = hd(new_state.children)
      assert child.budget_allocated == nil
    end

    test "mixed budgeted and N/A children maintain correct fields" do
      state = make_state([])
      t1 = DateTime.utc_now()
      t2 = DateTime.add(t1, 1, :second)

      # First child with budget
      data1 = %{agent_id: "child-1", spawned_at: t1, budget_allocated: Decimal.new("100.00")}
      {:noreply, state1} = ChildrenTracker.handle_child_spawned(data1, state)

      # Second child without budget (N/A)
      data2 = %{agent_id: "child-2", spawned_at: t2}
      {:noreply, state2} = ChildrenTracker.handle_child_spawned(data2, state1)

      # Newest first
      [child2, child1] = state2.children
      assert child1.agent_id == "child-1"
      assert Decimal.equal?(child1.budget_allocated, Decimal.new("100.00"))
      assert child2.agent_id == "child-2"
      assert child2.budget_allocated == nil
    end
  end

  describe "R8-R9: total_children_budget/1" do
    test "R8: sums all non-nil budget_allocated amounts" do
      children = [
        child_entry("child-1", budget_allocated: Decimal.new("50.00")),
        child_entry("child-2", budget_allocated: Decimal.new("30.00")),
        child_entry("child-3", budget_allocated: Decimal.new("20.00"))
      ]

      total = ChildrenTracker.total_children_budget(children)

      assert Decimal.equal?(total, Decimal.new("100.00"))
    end

    test "R8: returns zero for empty children list" do
      total = ChildrenTracker.total_children_budget([])

      assert Decimal.equal?(total, Decimal.new("0"))
    end

    test "R9: ignores N/A children (nil budget_allocated)" do
      children = [
        child_entry("child-1", budget_allocated: Decimal.new("50.00")),
        child_entry("child-2", budget_allocated: nil),
        child_entry("child-3", budget_allocated: Decimal.new("30.00")),
        child_entry("child-4", budget_allocated: nil)
      ]

      total = ChildrenTracker.total_children_budget(children)

      # Only child-1 and child-3 counted: 50 + 30 = 80
      assert Decimal.equal?(total, Decimal.new("80.00"))
    end

    test "R9: returns zero when all children are N/A" do
      children = [
        child_entry("child-1", budget_allocated: nil),
        child_entry("child-2", budget_allocated: nil)
      ]

      total = ChildrenTracker.total_children_budget(children)

      assert Decimal.equal?(total, Decimal.new("0"))
    end

    test "handles single budgeted child" do
      children = [
        child_entry("child-1", budget_allocated: Decimal.new("75.50"))
      ]

      total = ChildrenTracker.total_children_budget(children)

      assert Decimal.equal?(total, Decimal.new("75.50"))
    end

    test "preserves decimal precision" do
      children = [
        child_entry("child-1", budget_allocated: Decimal.new("0.01")),
        child_entry("child-2", budget_allocated: Decimal.new("0.02")),
        child_entry("child-3", budget_allocated: Decimal.new("0.03"))
      ]

      total = ChildrenTracker.total_children_budget(children)

      assert Decimal.equal?(total, Decimal.new("0.06"))
    end
  end

  # ==========================================================================
  # v2.1 Children Restoration Tests (fix-20260104-children-restore)
  # ==========================================================================

  describe "handle_child_restored/2 (v2.1)" do
    test "R10: handle_child_restored adds child to children list" do
      state = make_state([])
      spawned_at = DateTime.utc_now()
      data = %{agent_id: "restored-child-1", spawned_at: spawned_at}

      {:noreply, new_state} = ChildrenTracker.handle_child_restored(data, state)

      assert length(new_state.children) == 1
      assert hd(new_state.children).agent_id == "restored-child-1"
      assert hd(new_state.children).spawned_at == spawned_at
    end

    test "R11: handle_child_restored preserves budget_allocated" do
      state = make_state([])
      spawned_at = DateTime.utc_now()
      budget = Decimal.new("75.00")

      data = %{agent_id: "restored-child-1", spawned_at: spawned_at, budget_allocated: budget}

      {:noreply, new_state} = ChildrenTracker.handle_child_restored(data, state)

      child = hd(new_state.children)
      assert child.agent_id == "restored-child-1"
      assert Decimal.equal?(child.budget_allocated, Decimal.new("75.00"))
    end

    test "R11: handle_child_restored sets nil budget for N/A children" do
      state = make_state([])
      spawned_at = DateTime.utc_now()

      # No budget_allocated in data (N/A child)
      data = %{agent_id: "restored-child-1", spawned_at: spawned_at}

      {:noreply, new_state} = ChildrenTracker.handle_child_restored(data, state)

      child = hd(new_state.children)
      assert child.budget_allocated == nil
    end

    test "handle_child_restored prepends to existing children" do
      existing_child = %{
        agent_id: "existing-child",
        spawned_at: DateTime.add(DateTime.utc_now(), -100, :second),
        budget_allocated: nil
      }

      state = make_state([existing_child])
      spawned_at = DateTime.utc_now()
      data = %{agent_id: "restored-child-1", spawned_at: spawned_at}

      {:noreply, new_state} = ChildrenTracker.handle_child_restored(data, state)

      assert length(new_state.children) == 2
      # New child prepended (first in list)
      assert hd(new_state.children).agent_id == "restored-child-1"
      # Existing child still present
      assert Enum.at(new_state.children, 1).agent_id == "existing-child"
    end

    test "handle_child_restored returns {:noreply, new_state} tuple" do
      state = make_state([])
      spawned_at = DateTime.utc_now()
      data = %{agent_id: "restored-child-1", spawned_at: spawned_at}

      result = ChildrenTracker.handle_child_restored(data, state)

      assert {:noreply, _new_state} = result
    end
  end
end
