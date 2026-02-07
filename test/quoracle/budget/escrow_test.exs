defmodule Quoracle.Budget.EscrowTest do
  @moduledoc """
  Unit tests for BUDGET_Escrow module.

  Tests escrow operations for parent-child budget allocations.
  Pure functional module - no GenServer or database interaction.

  WorkGroupID: wip-20251231-budget
  Packet: 3 (Escrow System)
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Quoracle.Budget.Escrow
  alias Quoracle.Budget.Schema

  # Helper to create budget data with specific values
  defp budget_with(allocated, committed) do
    %{
      allocated: allocated,
      committed: committed,
      mode: if(is_nil(allocated), do: :na, else: :root)
    }
  end

  describe "R1-R3: validate_allocation/3" do
    test "R1: succeeds with sufficient budget" do
      # Budget: 100 allocated, 20 committed, 30 spent = 50 available
      budget = budget_with(Decimal.new("100.00"), Decimal.new("20.00"))
      spent = Decimal.new("30.00")
      amount = Decimal.new("50.00")

      assert Escrow.validate_allocation(budget, spent, amount) == :ok
    end

    test "R1: succeeds when exactly at available limit" do
      # Budget: 100 allocated, 0 committed, 50 spent = 50 available
      budget = budget_with(Decimal.new("100.00"), Decimal.new("0"))
      spent = Decimal.new("50.00")
      amount = Decimal.new("50.00")

      assert Escrow.validate_allocation(budget, spent, amount) == :ok
    end

    test "R2: fails with insufficient budget" do
      # Budget: 100 allocated, 20 committed, 30 spent = 50 available
      budget = budget_with(Decimal.new("100.00"), Decimal.new("20.00"))
      spent = Decimal.new("30.00")
      amount = Decimal.new("50.01")

      assert Escrow.validate_allocation(budget, spent, amount) == {:error, :insufficient_budget}
    end

    test "R2: fails when budget already exhausted" do
      # Budget: 100 allocated, 50 committed, 50 spent = 0 available
      budget = budget_with(Decimal.new("100.00"), Decimal.new("50.00"))
      spent = Decimal.new("50.00")
      amount = Decimal.new("0.01")

      assert Escrow.validate_allocation(budget, spent, amount) == {:error, :insufficient_budget}
    end

    test "R3: always succeeds for N/A budget" do
      budget = Schema.new_na()
      spent = Decimal.new("0")
      # Large amount should still succeed
      amount = Decimal.new("1000000.00")

      assert Escrow.validate_allocation(budget, spent, amount) == :ok
    end

    test "R3: N/A budget allows any amount regardless of spent" do
      budget = Schema.new_na()
      spent = Decimal.new("999999.99")
      amount = Decimal.new("999999.99")

      assert Escrow.validate_allocation(budget, spent, amount) == :ok
    end
  end

  describe "R4-R6: lock_allocation/3" do
    test "R4: increases committed on success" do
      budget = budget_with(Decimal.new("100.00"), Decimal.new("10.00"))
      spent = Decimal.new("20.00")
      amount = Decimal.new("30.00")

      assert {:ok, updated} = Escrow.lock_allocation(budget, spent, amount)

      # Committed should increase from 10 to 40
      assert Decimal.equal?(updated.committed, Decimal.new("40.00"))
      # Allocated should remain unchanged
      assert Decimal.equal?(updated.allocated, Decimal.new("100.00"))
    end

    test "R4: multiple locks accumulate committed" do
      budget = budget_with(Decimal.new("100.00"), Decimal.new("0"))
      spent = Decimal.new("0")

      {:ok, budget1} = Escrow.lock_allocation(budget, spent, Decimal.new("20.00"))
      {:ok, budget2} = Escrow.lock_allocation(budget1, spent, Decimal.new("15.00"))
      {:ok, budget3} = Escrow.lock_allocation(budget2, spent, Decimal.new("25.00"))

      assert Decimal.equal?(budget3.committed, Decimal.new("60.00"))
    end

    test "R5: returns error when insufficient budget" do
      budget = budget_with(Decimal.new("100.00"), Decimal.new("50.00"))
      spent = Decimal.new("40.00")
      # Available = 100 - 50 - 40 = 10, requesting 20
      amount = Decimal.new("20.00")

      assert Escrow.lock_allocation(budget, spent, amount) == {:error, :insufficient_budget}
    end

    test "R5: state unchanged on lock failure" do
      original = budget_with(Decimal.new("100.00"), Decimal.new("50.00"))
      spent = Decimal.new("60.00")
      amount = Decimal.new("20.00")

      result = Escrow.lock_allocation(original, spent, amount)

      assert result == {:error, :insufficient_budget}
      # Original budget unchanged (functional, no mutation)
      assert Decimal.equal?(original.committed, Decimal.new("50.00"))
    end

    test "R6: passes through N/A budget unchanged" do
      budget = Schema.new_na()
      spent = Decimal.new("0")
      amount = Decimal.new("500.00")

      assert {:ok, updated} = Escrow.lock_allocation(budget, spent, amount)

      # N/A budget should remain unchanged
      assert updated.allocated == nil
      assert Decimal.equal?(updated.committed, Decimal.new("0"))
      assert updated.mode == :na
    end

    test "R6: N/A budget allows any lock amount" do
      budget = Schema.new_na()
      spent = Decimal.new("1000000.00")
      amount = Decimal.new("9999999.99")

      assert {:ok, _updated} = Escrow.lock_allocation(budget, spent, amount)
    end
  end

  describe "R7-R9: release_allocation/3" do
    test "R7: decreases committed by child_allocated" do
      budget = budget_with(Decimal.new("100.00"), Decimal.new("50.00"))
      child_allocated = Decimal.new("30.00")
      child_spent = Decimal.new("20.00")

      assert {:ok, updated, _unspent} =
               Escrow.release_allocation(budget, child_allocated, child_spent)

      # Committed should decrease from 50 to 20
      assert Decimal.equal?(updated.committed, Decimal.new("20.00"))
    end

    test "R7: release fully clears committed when single child" do
      budget = budget_with(Decimal.new("100.00"), Decimal.new("30.00"))
      child_allocated = Decimal.new("30.00")
      child_spent = Decimal.new("25.00")

      assert {:ok, updated, _unspent} =
               Escrow.release_allocation(budget, child_allocated, child_spent)

      assert Decimal.equal?(updated.committed, Decimal.new("0"))
    end

    test "R8: returns correct unspent amount" do
      budget = budget_with(Decimal.new("100.00"), Decimal.new("50.00"))
      child_allocated = Decimal.new("40.00")
      child_spent = Decimal.new("25.00")

      assert {:ok, _updated, unspent} =
               Escrow.release_allocation(budget, child_allocated, child_spent)

      # Unspent = 40 - 25 = 15
      assert Decimal.equal?(unspent, Decimal.new("15.00"))
    end

    test "R8: returns zero unspent when child spent exactly allocated" do
      budget = budget_with(Decimal.new("100.00"), Decimal.new("50.00"))
      child_allocated = Decimal.new("50.00")
      child_spent = Decimal.new("50.00")

      assert {:ok, _updated, unspent} =
               Escrow.release_allocation(budget, child_allocated, child_spent)

      assert Decimal.equal?(unspent, Decimal.new("0"))
    end

    test "R9: clamps negative unspent to zero" do
      budget = budget_with(Decimal.new("100.00"), Decimal.new("50.00"))
      child_allocated = Decimal.new("30.00")
      # Child overspent
      child_spent = Decimal.new("40.00")

      assert {:ok, _updated, unspent} =
               Escrow.release_allocation(budget, child_allocated, child_spent)

      # Unspent should be clamped to 0, not -10
      assert Decimal.equal?(unspent, Decimal.new("0"))
    end

    test "R9: committed still decreases even when child overspent" do
      budget = budget_with(Decimal.new("100.00"), Decimal.new("50.00"))
      child_allocated = Decimal.new("30.00")
      child_spent = Decimal.new("50.00")

      assert {:ok, updated, _unspent} =
               Escrow.release_allocation(budget, child_allocated, child_spent)

      # Committed should still decrease by child_allocated
      assert Decimal.equal?(updated.committed, Decimal.new("20.00"))
    end

    test "release always succeeds (never errors)" do
      budget = budget_with(Decimal.new("100.00"), Decimal.new("0"))
      # Even with committed at 0, release should work (clamps to 0)
      child_allocated = Decimal.new("50.00")
      child_spent = Decimal.new("25.00")

      assert {:ok, _updated, _unspent} =
               Escrow.release_allocation(budget, child_allocated, child_spent)
    end
  end

  # ============================================================================
  # MODIFICATION: adjust_child_allocation/4 (feat-20251231-191717)
  # Packet 2 (Budget Logic Extensions)
  # ============================================================================

  describe "R10-R14: adjust_child_allocation/4" do
    # R10: WHEN increase AND parent has available THEN committed increases by delta
    test "R10: increases committed on valid increase" do
      parent_budget = budget_with(Decimal.new("100.00"), Decimal.new("20.00"))
      parent_spent = Decimal.new("10.00")
      # Available = 100 - 10 - 20 = 70
      current_child_allocated = Decimal.new("20.00")
      new_child_allocated = Decimal.new("40.00")
      # Delta = 40 - 20 = 20 (increase)

      assert {:ok, updated} =
               Escrow.adjust_child_allocation(
                 parent_budget,
                 current_child_allocated,
                 new_child_allocated,
                 parent_spent
               )

      # Committed should increase from 20 to 40
      assert Decimal.equal?(updated.committed, Decimal.new("40.00"))
    end

    # R11: WHEN increase AND parent lacks funds THEN returns :insufficient_parent_budget
    test "R11: rejects increase without funds" do
      parent_budget = budget_with(Decimal.new("100.00"), Decimal.new("50.00"))
      parent_spent = Decimal.new("40.00")
      # Available = 100 - 40 - 50 = 10
      current_child_allocated = Decimal.new("30.00")
      new_child_allocated = Decimal.new("50.00")
      # Delta = 20 (increase), but only 10 available

      result =
        Escrow.adjust_child_allocation(
          parent_budget,
          current_child_allocated,
          new_child_allocated,
          parent_spent
        )

      assert result == {:error, :insufficient_parent_budget}
    end

    # R12: WHEN decrease THEN committed decreases by abs(delta)
    test "R12: releases committed on decrease" do
      parent_budget = budget_with(Decimal.new("100.00"), Decimal.new("50.00"))
      parent_spent = Decimal.new("20.00")
      current_child_allocated = Decimal.new("40.00")
      new_child_allocated = Decimal.new("25.00")
      # Delta = 25 - 40 = -15 (decrease)

      assert {:ok, updated} =
               Escrow.adjust_child_allocation(
                 parent_budget,
                 current_child_allocated,
                 new_child_allocated,
                 parent_spent
               )

      # Committed should decrease from 50 to 35
      assert Decimal.equal?(updated.committed, Decimal.new("35.00"))
    end

    # R13: WHEN new = current THEN returns unchanged budget_data
    test "R13: returns unchanged for zero delta" do
      parent_budget = budget_with(Decimal.new("100.00"), Decimal.new("30.00"))
      parent_spent = Decimal.new("20.00")
      current_child_allocated = Decimal.new("30.00")
      new_child_allocated = Decimal.new("30.00")
      # Delta = 0

      assert {:ok, updated} =
               Escrow.adjust_child_allocation(
                 parent_budget,
                 current_child_allocated,
                 new_child_allocated,
                 parent_spent
               )

      assert Decimal.equal?(updated.committed, parent_budget.committed)
      assert Decimal.equal?(updated.allocated, parent_budget.allocated)
    end

    # R14: WHEN parent allocated is nil THEN any increase allowed
    test "R14: allows increase for N/A parent" do
      parent_budget = Schema.new_na()
      parent_spent = Decimal.new("1000.00")
      current_child_allocated = Decimal.new("500.00")
      new_child_allocated = Decimal.new("999999.00")
      # Large increase, but N/A parent allows any

      assert {:ok, updated} =
               Escrow.adjust_child_allocation(
                 parent_budget,
                 current_child_allocated,
                 new_child_allocated,
                 parent_spent
               )

      # N/A budget should remain N/A
      assert updated.allocated == nil
      assert updated.mode == :na
    end
  end

  describe "P2: committed delta matches child delta" do
    property "committed change equals child allocation change" do
      check all(
              current_child <- positive_decimal(),
              extra_committed <- integer(0..1000),
              delta <- integer(-1000..1000)
            ) do
        # Ensure positive new_child
        new_child =
          Decimal.add(current_child, Decimal.new(delta))
          |> Decimal.max(Decimal.new("0.01"))

        # Parent's committed must be >= current_child (valid budget state)
        # Plus optional extra committed for other children
        initial_committed = Decimal.add(current_child, Decimal.new(extra_committed))

        # Ensure parent has enough for any increase
        parent_allocated =
          Decimal.add(initial_committed, Decimal.new("10000.00"))

        parent_budget = budget_with(parent_allocated, initial_committed)
        parent_spent = Decimal.new("0")

        case Escrow.adjust_child_allocation(
               parent_budget,
               current_child,
               new_child,
               parent_spent
             ) do
          {:ok, updated} ->
            # The change in committed should equal the change in child allocation
            committed_change = Decimal.sub(updated.committed, initial_committed)
            child_change = Decimal.sub(new_child, current_child)

            assert Decimal.equal?(committed_change, child_change)

          {:error, :insufficient_parent_budget} ->
            # This is expected when delta exceeds available - skip this case
            :ok
        end
      end
    end
  end

  describe "P1: lock/release symmetry property" do
    # Generator for positive decimals
    defp positive_decimal do
      gen all(
            int <- integer(1..100_000),
            cents <- integer(0..99)
          ) do
        Decimal.new("#{int}.#{String.pad_leading("#{cents}", 2, "0")}")
      end
    end

    property "lock followed by release restores committed" do
      check all(
              initial_committed <- positive_decimal(),
              lock_amount <- positive_decimal(),
              child_spent <- positive_decimal()
            ) do
        # Ensure allocated is large enough to cover initial + lock
        total_needed = Decimal.add(initial_committed, lock_amount)
        actual_allocated = Decimal.add(total_needed, Decimal.new("100.00"))

        budget = budget_with(actual_allocated, initial_committed)
        spent = Decimal.new("0")

        # Lock the amount
        {:ok, locked_budget} = Escrow.lock_allocation(budget, spent, lock_amount)

        # Committed should have increased
        expected_committed = Decimal.add(initial_committed, lock_amount)
        assert Decimal.equal?(locked_budget.committed, expected_committed)

        # Release with child spending some amount
        child_allocated = lock_amount
        actual_child_spent = Decimal.min(child_spent, lock_amount)

        {:ok, released_budget, _unspent} =
          Escrow.release_allocation(locked_budget, child_allocated, actual_child_spent)

        # Committed should be back to initial
        assert Decimal.equal?(released_budget.committed, initial_committed)
      end
    end
  end
end
