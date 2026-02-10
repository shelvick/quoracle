defmodule Quoracle.Budget.SchemaTest do
  @moduledoc """
  Tests for BUDGET_Schema - budget data type definitions and helpers.

  WorkGroupID: wip-20251231-budget
  Packet: 1 (Foundation - Data Model)

  ARC Verification Criteria:
  - R1: Root Budget Creation - new_root with Decimal returns :root mode
  - R2: N/A Budget Creation - new_root with nil returns :na mode
  - R3: Serialization Round-Trip - serialize then deserialize preserves data
  - R4: Decimal Precision in Serialization - 10 decimal places preserved
  - R5: Add Committed - committed increases by amount
  - R6: Release Committed - committed decreases by amount
  - R7: Release Committed Clamping - clamps to zero when would go negative
  - R8: Nil Deserialization - deserialize(nil) returns N/A budget
  """

  use ExUnit.Case, async: true

  alias Quoracle.Budget.Schema

  describe "R1: root budget creation" do
    # R1: WHEN new_root called with Decimal THEN returns budget with :root mode and zero committed
    test "new_root/1 creates root budget with correct structure" do
      budget = Schema.new_root(Decimal.new("100.00"))

      assert budget.mode == :root
      assert Decimal.equal?(budget.allocated, Decimal.new("100.00"))
      assert Decimal.equal?(budget.committed, Decimal.new(0))
    end

    test "new_root/1 with various decimal values" do
      # Small budget
      small = Schema.new_root(Decimal.new("0.01"))
      assert small.mode == :root
      assert Decimal.equal?(small.allocated, Decimal.new("0.01"))

      # Large budget
      large = Schema.new_root(Decimal.new("999999999.99"))
      assert large.mode == :root
      assert Decimal.equal?(large.allocated, Decimal.new("999999999.99"))
    end
  end

  describe "R2: N/A budget creation" do
    # R2: WHEN new_root called with nil THEN returns budget with :na mode and nil allocated
    test "new_root/1 with nil creates N/A budget" do
      budget = Schema.new_root(nil)

      assert budget.mode == :na
      assert budget.allocated == nil
      assert Decimal.equal?(budget.committed, Decimal.new(0))
    end

    test "new_na/0 creates N/A budget" do
      budget = Schema.new_na()

      assert budget.mode == :na
      assert budget.allocated == nil
      assert Decimal.equal?(budget.committed, Decimal.new(0))
    end
  end

  describe "R3: serialization round-trip" do
    # R3: WHEN budget serialized then deserialized THEN original values preserved
    test "serialize/deserialize round-trip preserves data" do
      original = %{
        allocated: Decimal.new("250.50"),
        committed: Decimal.new("75.25"),
        mode: :root
      }

      serialized = Schema.serialize(original)
      deserialized = Schema.deserialize(serialized)

      assert deserialized.mode == original.mode
      assert Decimal.equal?(deserialized.allocated, original.allocated)
      assert Decimal.equal?(deserialized.committed, original.committed)
    end

    test "serialize/deserialize round-trip for :allocated mode" do
      original = Schema.new_allocated(Decimal.new("50.00"))

      serialized = Schema.serialize(original)
      deserialized = Schema.deserialize(serialized)

      assert deserialized.mode == :allocated
      assert Decimal.equal?(deserialized.allocated, Decimal.new("50.00"))
    end

    test "serialize/deserialize round-trip for :na mode" do
      original = Schema.new_na()

      serialized = Schema.serialize(original)
      deserialized = Schema.deserialize(serialized)

      assert deserialized.mode == :na
      assert deserialized.allocated == nil
    end
  end

  describe "R4: decimal precision in serialization" do
    # R4: WHEN Decimal with 10 decimal places serialized THEN full precision preserved
    test "serialization preserves Decimal precision" do
      # High precision decimal (10 decimal places)
      precise_value = Decimal.new("123.1234567890")

      original = %{
        allocated: precise_value,
        committed: Decimal.new("0"),
        mode: :root
      }

      serialized = Schema.serialize(original)
      deserialized = Schema.deserialize(serialized)

      # Full precision must be preserved
      assert Decimal.equal?(deserialized.allocated, precise_value)
    end

    test "serialization stores decimals as strings" do
      budget = Schema.new_root(Decimal.new("100.00"))

      serialized = Schema.serialize(budget)

      # Should be string keys and string values for JSONB
      assert is_map(serialized)
      assert is_binary(serialized["allocated"])
      assert is_binary(serialized["committed"])
      assert is_binary(serialized["mode"])
    end
  end

  describe "R5: add committed" do
    # R5: WHEN add_committed called THEN committed increases by amount
    test "add_committed/2 increases committed amount" do
      budget = Schema.new_root(Decimal.new("100.00"))
      assert Decimal.equal?(budget.committed, Decimal.new(0))

      updated = Schema.add_committed(budget, Decimal.new("25.00"))

      assert Decimal.equal?(updated.committed, Decimal.new("25.00"))
      # Allocated unchanged
      assert Decimal.equal?(updated.allocated, Decimal.new("100.00"))
    end

    test "add_committed/2 accumulates multiple additions" do
      budget = Schema.new_root(Decimal.new("100.00"))

      updated =
        budget
        |> Schema.add_committed(Decimal.new("10.00"))
        |> Schema.add_committed(Decimal.new("15.00"))
        |> Schema.add_committed(Decimal.new("5.00"))

      assert Decimal.equal?(updated.committed, Decimal.new("30.00"))
    end
  end

  describe "R6: release committed" do
    # R6: WHEN release_committed called THEN committed decreases by amount
    test "release_committed/2 decreases committed amount" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("50.00"),
        mode: :root
      }

      updated = Schema.release_committed(budget, Decimal.new("20.00"))

      assert Decimal.equal?(updated.committed, Decimal.new("30.00"))
    end

    test "release_committed/2 can release full amount" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("50.00"),
        mode: :root
      }

      updated = Schema.release_committed(budget, Decimal.new("50.00"))

      assert Decimal.equal?(updated.committed, Decimal.new(0))
    end
  end

  describe "R7: release committed clamping" do
    # R7: WHEN release_committed would go negative THEN clamps to zero
    test "release_committed/2 clamps to zero" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("10.00"),
        mode: :root
      }

      # Try to release more than committed
      updated = Schema.release_committed(budget, Decimal.new("50.00"))

      # Should clamp to zero, not go negative
      assert Decimal.equal?(updated.committed, Decimal.new(0))
    end

    test "release_committed/2 clamps edge case (exact over)" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0.01"),
        mode: :root
      }

      updated = Schema.release_committed(budget, Decimal.new("0.02"))

      assert Decimal.equal?(updated.committed, Decimal.new(0))
    end
  end

  describe "R8: nil deserialization" do
    # R8: WHEN deserialize called with nil THEN returns N/A budget
    test "deserialize/1 with nil returns N/A budget" do
      budget = Schema.deserialize(nil)

      assert budget.mode == :na
      assert budget.allocated == nil
      assert Decimal.equal?(budget.committed, Decimal.new(0))
    end
  end

  describe "new_allocated/1" do
    test "creates budget with :allocated mode" do
      budget = Schema.new_allocated(Decimal.new("50.00"))

      assert budget.mode == :allocated
      assert Decimal.equal?(budget.allocated, Decimal.new("50.00"))
      assert Decimal.equal?(budget.committed, Decimal.new(0))
    end
  end
end
