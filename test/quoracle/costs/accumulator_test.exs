defmodule Quoracle.Costs.AccumulatorTest do
  @moduledoc """
  Tests for COST_Accumulator module - in-memory cost batching.

  WorkGroupID: feat-20260203-194408
  Packet: 1 (Foundation)

  Requirements:
  - R1: Create Empty Accumulator [UNIT]
  - R2: Add Single Entry [UNIT]
  - R3: Add Multiple Entries [UNIT]
  - R4: to_list Returns Insertion Order [UNIT]
  - R5: Count Entries [UNIT]
  - R6: Empty Check - Empty [UNIT]
  - R7: Empty Check - Non-Empty [UNIT]
  - R8: Nil Cost Handling [UNIT]
  - R9: Metadata Preservation [UNIT]
  - R10: Immutability [UNIT]
  """

  use ExUnit.Case, async: true

  alias Quoracle.Costs.Accumulator

  # ============================================================
  # R1: Create Empty Accumulator [UNIT]
  # ============================================================

  describe "new/0" do
    test "creates empty accumulator" do
      acc = Accumulator.new()

      assert acc.entries == []
      assert Accumulator.empty?(acc)
    end
  end

  # ============================================================
  # R2: Add Single Entry [UNIT]
  # ============================================================

  describe "add/2 - single entry" do
    test "accumulates single entry" do
      entry = build_cost_entry()
      acc = Accumulator.new() |> Accumulator.add(entry)

      assert Accumulator.count(acc) == 1
      assert [^entry] = Accumulator.to_list(acc)
    end
  end

  # ============================================================
  # R3: Add Multiple Entries [UNIT]
  # ============================================================

  describe "add/2 - multiple entries" do
    test "accumulates multiple entries in order" do
      entry1 = build_cost_entry(cost_type: "llm_embedding")
      entry2 = build_cost_entry(cost_type: "llm_consensus")
      entry3 = build_cost_entry(cost_type: "llm_answer")

      acc =
        Accumulator.new()
        |> Accumulator.add(entry1)
        |> Accumulator.add(entry2)
        |> Accumulator.add(entry3)

      assert Accumulator.to_list(acc) == [entry1, entry2, entry3]
    end
  end

  # ============================================================
  # R4: to_list Returns Insertion Order [UNIT]
  # ============================================================

  describe "to_list/1" do
    test "returns entries in insertion order" do
      entries = Enum.map(1..5, fn i -> build_cost_entry(cost_type: "type_#{i}") end)

      acc = Enum.reduce(entries, Accumulator.new(), &Accumulator.add(&2, &1))

      assert Accumulator.to_list(acc) == entries
    end

    test "returns empty list for new accumulator" do
      acc = Accumulator.new()
      assert Accumulator.to_list(acc) == []
    end
  end

  # ============================================================
  # R5: Count Entries [UNIT]
  # ============================================================

  describe "count/1" do
    test "returns entry count" do
      acc =
        Accumulator.new()
        |> Accumulator.add(build_cost_entry())
        |> Accumulator.add(build_cost_entry())
        |> Accumulator.add(build_cost_entry())

      assert Accumulator.count(acc) == 3
    end

    test "returns 0 for new accumulator" do
      assert Accumulator.count(Accumulator.new()) == 0
    end
  end

  # ============================================================
  # R6: Empty Check - Empty [UNIT]
  # ============================================================

  describe "empty?/1 - empty" do
    test "returns true for new accumulator" do
      assert Accumulator.empty?(Accumulator.new())
    end
  end

  # ============================================================
  # R7: Empty Check - Non-Empty [UNIT]
  # ============================================================

  describe "empty?/1 - non-empty" do
    test "returns false after add" do
      acc = Accumulator.new() |> Accumulator.add(build_cost_entry())
      refute Accumulator.empty?(acc)
    end
  end

  # ============================================================
  # R8: Nil Cost Handling [UNIT]
  # ============================================================

  describe "nil cost handling" do
    test "handles nil cost_usd in entry" do
      entry = build_cost_entry(cost_usd: nil)
      acc = Accumulator.new() |> Accumulator.add(entry)

      [stored] = Accumulator.to_list(acc)
      assert stored.cost_usd == nil
    end
  end

  # ============================================================
  # R9: Metadata Preservation [UNIT]
  # ============================================================

  describe "metadata preservation" do
    test "preserves metadata in entries" do
      metadata = %{"model_spec" => "azure:gpt-4", "tokens" => 100}
      entry = build_cost_entry(metadata: metadata)
      acc = Accumulator.new() |> Accumulator.add(entry)

      [stored] = Accumulator.to_list(acc)
      assert stored.metadata == metadata
    end
  end

  # ============================================================
  # R10: Immutability [UNIT]
  # ============================================================

  describe "immutability" do
    test "add/2 returns new accumulator without mutating original" do
      entry = build_cost_entry()
      original = Accumulator.new()
      updated = Accumulator.add(original, entry)

      assert Accumulator.empty?(original)
      refute Accumulator.empty?(updated)
    end
  end

  # ============================================================
  # Test Helpers
  # ============================================================

  defp build_cost_entry(overrides \\ []) do
    defaults = %{
      agent_id: "agent_#{System.unique_integer([:positive])}",
      task_id: Ecto.UUID.generate(),
      cost_type: "llm_embedding",
      cost_usd: Decimal.new("0.0001"),
      metadata: %{"model_spec" => "azure:text-embedding-3-large"}
    }

    Map.merge(defaults, Map.new(overrides))
  end
end
