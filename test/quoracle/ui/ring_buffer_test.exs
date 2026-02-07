defmodule Quoracle.UI.RingBufferTest do
  @moduledoc """
  Unit tests for the RingBuffer pure functional data structure.
  Tests all public API functions and edge cases.

  All tests are async: true since RingBuffer is pure functional
  with no shared state or side effects.
  """

  use ExUnit.Case, async: true

  alias Quoracle.UI.RingBuffer

  describe "new/1" do
    # R1: Buffer Creation
    test "new/1 creates empty buffer with specified max_size" do
      buffer = RingBuffer.new(50)

      assert RingBuffer.size(buffer) == 0
      assert RingBuffer.empty?(buffer)
      assert RingBuffer.to_list(buffer) == []
    end

    # R2: Buffer Creation Invalid Size
    test "new/1 raises ArgumentError for invalid max_size" do
      assert_raise ArgumentError, fn -> RingBuffer.new(0) end
      assert_raise ArgumentError, fn -> RingBuffer.new(-1) end
      assert_raise ArgumentError, fn -> RingBuffer.new(-100) end
    end
  end

  describe "insert/2" do
    # R3: Insert Below Capacity
    test "insert/2 adds item when below capacity" do
      buffer =
        RingBuffer.new(5)
        |> RingBuffer.insert(:a)
        |> RingBuffer.insert(:b)
        |> RingBuffer.insert(:c)

      assert RingBuffer.size(buffer) == 3
      assert RingBuffer.to_list(buffer) == [:a, :b, :c]
    end

    # R4: Insert At Capacity
    test "insert/2 evicts oldest when at capacity" do
      buffer = RingBuffer.new(3)

      # Insert 5 items into buffer of size 3
      buffer =
        Enum.reduce(1..5, buffer, fn item, acc ->
          RingBuffer.insert(acc, item)
        end)

      # Should have [3, 4, 5] - oldest (1, 2) evicted
      assert RingBuffer.size(buffer) == 3
      assert RingBuffer.to_list(buffer) == [3, 4, 5]
    end

    # R5: FIFO Eviction Order
    test "eviction follows FIFO order across multiple overflows" do
      buffer = RingBuffer.new(2)

      # Insert items one by one and verify FIFO eviction
      buffer = RingBuffer.insert(buffer, :first)
      assert RingBuffer.to_list(buffer) == [:first]

      buffer = RingBuffer.insert(buffer, :second)
      assert RingBuffer.to_list(buffer) == [:first, :second]

      # At capacity, next insert evicts :first
      buffer = RingBuffer.insert(buffer, :third)
      assert RingBuffer.to_list(buffer) == [:second, :third]

      # Next insert evicts :second
      buffer = RingBuffer.insert(buffer, :fourth)
      assert RingBuffer.to_list(buffer) == [:third, :fourth]

      # Next insert evicts :third
      buffer = RingBuffer.insert(buffer, :fifth)
      assert RingBuffer.to_list(buffer) == [:fourth, :fifth]
    end

    # R12: Immutability
    test "insert/2 does not mutate original buffer" do
      original = RingBuffer.new(5) |> RingBuffer.insert(:a)
      _modified = RingBuffer.insert(original, :b)

      # Original should still have only :a
      assert RingBuffer.to_list(original) == [:a]
      assert RingBuffer.size(original) == 1
    end
  end

  describe "to_list/1" do
    # R6: Chronological to_list
    test "to_list/1 returns items in chronological order" do
      buffer =
        RingBuffer.new(10)
        |> RingBuffer.insert(:oldest)
        |> RingBuffer.insert(:middle)
        |> RingBuffer.insert(:newest)

      # Oldest first (chronological order)
      assert RingBuffer.to_list(buffer) == [:oldest, :middle, :newest]
    end

    test "to_list/1 returns empty list for new buffer" do
      buffer = RingBuffer.new(5)
      assert RingBuffer.to_list(buffer) == []
    end
  end

  describe "size/1" do
    # R7: Size Accuracy
    test "size/1 accurately tracks item count" do
      buffer = RingBuffer.new(10)
      assert RingBuffer.size(buffer) == 0

      buffer = RingBuffer.insert(buffer, :a)
      assert RingBuffer.size(buffer) == 1

      buffer = RingBuffer.insert(buffer, :b)
      assert RingBuffer.size(buffer) == 2

      buffer = RingBuffer.insert(buffer, :c)
      assert RingBuffer.size(buffer) == 3
    end

    test "size/1 does not exceed max_size after eviction" do
      buffer = RingBuffer.new(3)

      # Insert 10 items
      buffer =
        Enum.reduce(1..10, buffer, fn item, acc ->
          RingBuffer.insert(acc, item)
        end)

      # Size should still be 3
      assert RingBuffer.size(buffer) == 3
    end
  end

  describe "empty?/1" do
    # R8: Empty Buffer
    test "empty?/1 returns true for new buffer" do
      buffer = RingBuffer.new(100)
      assert RingBuffer.empty?(buffer) == true
    end

    test "empty?/1 returns false after insert" do
      buffer = RingBuffer.new(5) |> RingBuffer.insert(:item)
      assert RingBuffer.empty?(buffer) == false
    end
  end

  describe "clear/1" do
    # R9: Clear Preserves Capacity
    test "clear/1 resets buffer but preserves max_size" do
      buffer =
        RingBuffer.new(42)
        |> RingBuffer.insert(:a)
        |> RingBuffer.insert(:b)
        |> RingBuffer.insert(:c)

      cleared = RingBuffer.clear(buffer)

      assert RingBuffer.empty?(cleared)
      assert RingBuffer.size(cleared) == 0
      assert RingBuffer.to_list(cleared) == []

      # Verify max_size preserved by inserting 42 items (should all fit)
      filled =
        Enum.reduce(1..42, cleared, fn i, acc ->
          RingBuffer.insert(acc, i)
        end)

      assert RingBuffer.size(filled) == 42

      # 43rd item should trigger eviction (proving max_size is 42)
      overflowed = RingBuffer.insert(filled, :overflow)
      assert RingBuffer.size(overflowed) == 42
      assert hd(RingBuffer.to_list(overflowed)) == 2
    end
  end

  describe "edge cases" do
    # R10: Single Item Buffer
    test "buffer with max_size 1 behaves correctly" do
      buffer = RingBuffer.new(1)

      buffer = RingBuffer.insert(buffer, :first)
      assert RingBuffer.to_list(buffer) == [:first]
      assert RingBuffer.size(buffer) == 1

      # Each insert evicts the previous item
      buffer = RingBuffer.insert(buffer, :second)
      assert RingBuffer.to_list(buffer) == [:second]
      assert RingBuffer.size(buffer) == 1

      buffer = RingBuffer.insert(buffer, :third)
      assert RingBuffer.to_list(buffer) == [:third]
      assert RingBuffer.size(buffer) == 1
    end

    # R11: Large Capacity
    test "large buffer operations are performant" do
      # Create buffer with 10000 capacity
      buffer = RingBuffer.new(10_000)

      # Insert 10000 items - should complete quickly
      {time_us, buffer} =
        :timer.tc(fn ->
          Enum.reduce(1..10_000, buffer, fn i, acc ->
            RingBuffer.insert(acc, i)
          end)
        end)

      # Should complete in under 100ms (100_000 microseconds)
      assert time_us < 100_000, "Insert 10000 items took #{time_us}us, expected < 100000us"
      assert RingBuffer.size(buffer) == 10_000

      # to_list should also be fast
      {list_time_us, list} =
        :timer.tc(fn ->
          RingBuffer.to_list(buffer)
        end)

      assert list_time_us < 100_000, "to_list took #{list_time_us}us, expected < 100000us"
      assert length(list) == 10_000
      assert hd(list) == 1
      assert List.last(list) == 10_000
    end

    test "handles nil values correctly" do
      buffer =
        RingBuffer.new(3)
        |> RingBuffer.insert(nil)
        |> RingBuffer.insert(:value)
        |> RingBuffer.insert(nil)

      assert RingBuffer.to_list(buffer) == [nil, :value, nil]
      assert RingBuffer.size(buffer) == 3
    end

    test "handles complex data structures" do
      log1 = %{id: "log-1", level: :info, message: "First"}
      log2 = %{id: "log-2", level: :error, message: "Second"}
      log3 = %{id: "log-3", level: :debug, message: "Third"}

      buffer =
        RingBuffer.new(2)
        |> RingBuffer.insert(log1)
        |> RingBuffer.insert(log2)
        |> RingBuffer.insert(log3)

      # log1 should be evicted
      assert RingBuffer.to_list(buffer) == [log2, log3]
    end
  end
end
