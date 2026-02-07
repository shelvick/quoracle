defmodule Quoracle.Agent.TokenManagerMessagesToCondenseTest do
  @moduledoc """
  Tests for TokenManager.messages_to_condense/2 function.

  This function splits history by message count (exactly N oldest messages),
  unlike tokens_to_condense/2 which splits by token count (>80% of tokens).

  WorkGroupID: wip-20260104-condense-param
  Packet: 1 (Foundation)
  Requirements: R13-R23 from AGENT_TokenManager v6.0 spec

  ## v7.0 Bug Fix Tests (fix-20260106-condense-ordering)
  R24-R28: Tests for newest-first history ordering fix.
  The bug was that messages_to_condense removed NEWEST instead of OLDEST
  because history is stored newest-first but Enum.split takes first N.
  """

  use ExUnit.Case, async: true
  alias Quoracle.Agent.TokenManager

  # Helper to create test message entries with sequential IDs
  defp create_entry(id) do
    %{
      id: id,
      role: if(rem(id, 2) == 1, do: "user", else: "assistant"),
      content: "Message #{id} content",
      timestamp: DateTime.utc_now()
    }
  end

  # Helper to create history in NEWEST-FIRST order (matching production storage)
  # History is stored via [entry | history] prepend, so newest is at index 0
  # Example: create_history_newest_first(5) => [%{id: 5}, %{id: 4}, %{id: 3}, %{id: 2}, %{id: 1}]
  defp create_history_newest_first(count) when count >= 0 do
    count..1//-1
    |> Enum.map(&create_entry/1)
  end

  describe "R13: Correct N Messages Split" do
    test "splits exactly N oldest messages" do
      # Create 10-entry history (newest-first, matching production storage)
      history = create_history_newest_first(10)

      {to_remove, _to_keep} = TokenManager.messages_to_condense(history, 3)

      # to_remove should have exactly 3 entries
      assert length(to_remove) == 3
    end

    test "splits 5 messages from 10-entry history" do
      history = create_history_newest_first(10)

      {to_remove, _to_keep} = TokenManager.messages_to_condense(history, 5)

      assert length(to_remove) == 5
    end

    test "splits 1 message from 5-entry history" do
      history = create_history_newest_first(5)

      {to_remove, _to_keep} = TokenManager.messages_to_condense(history, 1)

      assert length(to_remove) == 1
    end
  end

  describe "R14: Remaining Messages in to_keep" do
    test "to_keep contains remaining messages" do
      # Create 10-entry history (newest-first), remove 3 oldest
      history = create_history_newest_first(10)

      {_to_remove, to_keep} = TokenManager.messages_to_condense(history, 3)

      # to_keep should have 7 entries (10 - 3)
      assert length(to_keep) == 7
    end

    test "to_keep has 5 entries when removing 5 from 10" do
      history = create_history_newest_first(10)

      {_to_remove, to_keep} = TokenManager.messages_to_condense(history, 5)

      assert length(to_keep) == 5
    end
  end

  describe "R15: Order Preserved in to_remove" do
    test "to_remove preserves message order" do
      history = create_history_newest_first(10)

      {to_remove, _to_keep} = TokenManager.messages_to_condense(history, 4)

      # Extract IDs from to_remove
      removed_ids = Enum.map(to_remove, & &1.id)

      # Should be oldest 4 in chronological order: [1, 2, 3, 4]
      assert removed_ids == [1, 2, 3, 4]
    end

    test "to_remove maintains chronological order for large split" do
      history = create_history_newest_first(20)

      {to_remove, _to_keep} = TokenManager.messages_to_condense(history, 15)

      removed_ids = Enum.map(to_remove, & &1.id)

      # Should be 1..15 in chronological order (oldest-first for Reflector)
      assert removed_ids == Enum.to_list(1..15)
    end
  end

  describe "R16: Order Preserved in to_keep" do
    test "to_keep preserves message order" do
      history = create_history_newest_first(10)

      {_to_remove, to_keep} = TokenManager.messages_to_condense(history, 4)

      # Extract IDs from to_keep
      kept_ids = Enum.map(to_keep, & &1.id)

      # Should be remaining 6 in newest-first order: [10, 9, 8, 7, 6, 5]
      assert kept_ids == [10, 9, 8, 7, 6, 5]
    end

    test "to_keep maintains newest-first order for small split" do
      history = create_history_newest_first(20)

      {_to_remove, to_keep} = TokenManager.messages_to_condense(history, 5)

      kept_ids = Enum.map(to_keep, & &1.id)

      # Should be 6..20 in newest-first order: [20, 19, 18, ..., 6]
      assert kept_ids == Enum.to_list(20..6//-1)
    end
  end

  describe "R17: N Equals History Length" do
    test "N equals length returns all in to_remove" do
      history = create_history_newest_first(5)

      {to_remove, to_keep} = TokenManager.messages_to_condense(history, 5)

      # All messages removed (oldest-first order)
      assert length(to_remove) == 5
      removed_ids = Enum.map(to_remove, & &1.id)
      assert removed_ids == [1, 2, 3, 4, 5]

      # Nothing kept
      assert to_keep == []
    end

    test "N equals length for single-entry history" do
      history = create_history_newest_first(1)

      {to_remove, to_keep} = TokenManager.messages_to_condense(history, 1)

      assert length(to_remove) == 1
      assert to_keep == []
    end
  end

  describe "R18: N Greater Than History Length" do
    test "N exceeds length returns all in to_remove" do
      history = create_history_newest_first(5)

      # Request 10 but only 5 exist
      {to_remove, to_keep} = TokenManager.messages_to_condense(history, 10)

      # All messages removed (oldest-first order)
      removed_ids = Enum.map(to_remove, & &1.id)
      assert removed_ids == [1, 2, 3, 4, 5]
      assert length(to_remove) == 5

      # Nothing kept
      assert to_keep == []
    end

    test "N greatly exceeds length" do
      history = create_history_newest_first(3)

      {to_remove, to_keep} = TokenManager.messages_to_condense(history, 100)

      removed_ids = Enum.map(to_remove, & &1.id)
      assert removed_ids == [1, 2, 3]
      assert to_keep == []
    end
  end

  describe "R19: N = 1" do
    test "N=1 removes only oldest message" do
      history = create_history_newest_first(5)

      {to_remove, to_keep} = TokenManager.messages_to_condense(history, 1)

      # Only oldest message (id=1) removed
      assert length(to_remove) == 1
      assert hd(to_remove).id == 1

      # Remaining 4 kept (newest-first order)
      assert length(to_keep) == 4
      kept_ids = Enum.map(to_keep, & &1.id)
      assert kept_ids == [5, 4, 3, 2]
    end

    test "N=1 from large history" do
      history = create_history_newest_first(100)

      {to_remove, to_keep} = TokenManager.messages_to_condense(history, 1)

      assert length(to_remove) == 1
      assert hd(to_remove).id == 1
      assert length(to_keep) == 99
    end
  end

  describe "R20: Empty History" do
    test "empty history returns empty tuples" do
      {to_remove, to_keep} = TokenManager.messages_to_condense([], 5)

      assert to_remove == []
      assert to_keep == []
    end

    test "empty history with N=1" do
      {to_remove, to_keep} = TokenManager.messages_to_condense([], 1)

      assert to_remove == []
      assert to_keep == []
    end
  end

  describe "R21: Invalid N (Zero)" do
    test "N=0 returns empty to_remove" do
      history = create_history_newest_first(5)

      {to_remove, to_keep} = TokenManager.messages_to_condense(history, 0)

      # Nothing removed
      assert to_remove == []

      # All kept (unchanged)
      assert to_keep == history
    end

    test "N=0 with empty history" do
      {to_remove, to_keep} = TokenManager.messages_to_condense([], 0)

      assert to_remove == []
      assert to_keep == []
    end
  end

  describe "R22: Invalid N (Negative)" do
    test "negative N returns empty to_remove" do
      history = create_history_newest_first(5)

      {to_remove, to_keep} = TokenManager.messages_to_condense(history, -1)

      # Nothing removed
      assert to_remove == []

      # All kept (unchanged)
      assert to_keep == history
    end

    test "large negative N returns empty to_remove" do
      history = create_history_newest_first(10)

      {to_remove, to_keep} = TokenManager.messages_to_condense(history, -100)

      assert to_remove == []
      assert to_keep == history
    end
  end

  describe "R23: Non-List History" do
    test "non-list history returns empty to_remove" do
      # Pass a map instead of list
      {to_remove, to_keep} = TokenManager.messages_to_condense(%{foo: "bar"}, 5)

      assert to_remove == []
      assert to_keep == %{foo: "bar"}
    end

    test "nil history returns empty to_remove" do
      {to_remove, to_keep} = TokenManager.messages_to_condense(nil, 5)

      assert to_remove == []
      assert to_keep == nil
    end

    test "string history returns empty to_remove" do
      {to_remove, to_keep} = TokenManager.messages_to_condense("not a list", 3)

      assert to_remove == []
      assert to_keep == "not a list"
    end

    test "tuple history returns empty to_remove" do
      tuple_history = {:a, :b, :c}

      {to_remove, to_keep} = TokenManager.messages_to_condense(tuple_history, 2)

      assert to_remove == []
      assert to_keep == tuple_history
    end
  end

  # ========== v7.0 Bug Fix Tests (fix-20260106-condense-ordering) ==========
  # These tests use NEWEST-FIRST history (matching production storage).
  # The bug: Enum.split(history, n) takes FIRST n elements, but history
  # is stored newest-first, so it removed NEWEST instead of OLDEST.

  describe "R24: Oldest Messages Removed" do
    test "removes oldest N messages from newest-first history" do
      # History stored newest-first: [id:10, id:9, ..., id:1]
      # id:10 is NEWEST (index 0), id:1 is OLDEST (index 9)
      history = create_history_newest_first(10)

      # Remove 3 oldest messages
      {to_remove, _to_keep} = TokenManager.messages_to_condense(history, 3)

      # to_remove should contain the 3 OLDEST messages (id:1, id:2, id:3)
      removed_ids = Enum.map(to_remove, & &1.id)

      assert removed_ids == [1, 2, 3],
             "Expected oldest messages [1,2,3], got #{inspect(removed_ids)}"
    end

    test "removes oldest 5 from 10-message newest-first history" do
      history = create_history_newest_first(10)

      {to_remove, _to_keep} = TokenManager.messages_to_condense(history, 5)

      removed_ids = Enum.map(to_remove, & &1.id)
      assert removed_ids == [1, 2, 3, 4, 5], "Expected oldest [1-5], got #{inspect(removed_ids)}"
    end
  end

  describe "R25: Newest Messages Kept" do
    test "keeps newest messages after removing oldest" do
      # History: [id:10, id:9, ..., id:1] (newest-first)
      history = create_history_newest_first(10)

      # Remove 3 oldest, keep 7 newest
      {_to_remove, to_keep} = TokenManager.messages_to_condense(history, 3)

      # to_keep should have the 7 NEWEST messages (id:10, id:9, ..., id:4)
      kept_ids = Enum.map(to_keep, & &1.id)
      assert length(to_keep) == 7
      # Verify we kept the newest, not the oldest
      assert 10 in kept_ids, "Expected newest message (id:10) to be kept"
      assert 9 in kept_ids, "Expected id:9 to be kept"
      refute 1 in kept_ids, "Expected oldest message (id:1) to be removed"
      refute 2 in kept_ids, "Expected id:2 to be removed"
      refute 3 in kept_ids, "Expected id:3 to be removed"
    end
  end

  describe "R26: to_remove Oldest-First Order" do
    test "to_remove is in oldest-first order for Reflector" do
      # Reflector needs messages in chronological order (oldest first)
      # to extract lessons from the conversation flow
      history = create_history_newest_first(10)

      {to_remove, _to_keep} = TokenManager.messages_to_condense(history, 4)

      removed_ids = Enum.map(to_remove, & &1.id)
      # Should be in chronological order: [1, 2, 3, 4] (oldest first)
      assert removed_ids == [1, 2, 3, 4], "to_remove should be oldest-first for Reflector"
    end

    test "to_remove chronological order preserved for large split" do
      history = create_history_newest_first(20)

      {to_remove, _to_keep} = TokenManager.messages_to_condense(history, 10)

      removed_ids = Enum.map(to_remove, & &1.id)
      # Should be [1, 2, 3, ..., 10] in chronological order
      assert removed_ids == Enum.to_list(1..10)
    end
  end

  describe "R27: to_keep Newest-First Order" do
    test "to_keep maintains newest-first storage order" do
      # to_keep should preserve the storage convention (newest-first)
      # so it can be stored back without re-ordering
      history = create_history_newest_first(10)

      {_to_remove, to_keep} = TokenManager.messages_to_condense(history, 3)

      kept_ids = Enum.map(to_keep, & &1.id)
      # Should be [10, 9, 8, 7, 6, 5, 4] - newest first
      assert kept_ids == [10, 9, 8, 7, 6, 5, 4], "to_keep should be newest-first"
    end

    test "to_keep newest-first order for small split" do
      history = create_history_newest_first(8)

      {_to_remove, to_keep} = TokenManager.messages_to_condense(history, 2)

      kept_ids = Enum.map(to_keep, & &1.id)
      # Keep 6 newest: [8, 7, 6, 5, 4, 3]
      assert kept_ids == [8, 7, 6, 5, 4, 3]
    end
  end

  describe "R28: Acceptance - Full Condense Flow" do
    @tag :acceptance
    test "full condense flow removes oldest messages not newest" do
      # This acceptance test verifies the user-observable behavior:
      # When model requests condense=N, the N OLDEST messages are removed,
      # preserving the most recent context (newest messages).

      # Simulate production storage: newest-first
      # Messages represent a conversation where id correlates with time
      history = create_history_newest_first(10)

      # User expectation: "condense 5" removes the 5 OLDEST messages
      {to_remove, to_keep} = TokenManager.messages_to_condense(history, 5)

      # POSITIVE: Oldest 5 should be removed (for Reflector to extract lessons)
      removed_ids = Enum.map(to_remove, & &1.id)
      assert removed_ids == [1, 2, 3, 4, 5], "Should remove oldest 5, got #{inspect(removed_ids)}"

      # POSITIVE: Newest 5 should be kept (preserving recent context)
      kept_ids = Enum.map(to_keep, & &1.id)
      assert 10 in kept_ids, "Newest message (id:10) should be kept"
      assert 6 in kept_ids, "Message id:6 should be kept"

      # NEGATIVE: Removed messages should not be in to_keep
      refute 1 in kept_ids, "Oldest (id:1) should NOT be kept"
      refute 5 in kept_ids, "Message id:5 should NOT be kept"

      # POSITIVE: to_remove in chronological order for Reflector
      assert to_remove == Enum.sort_by(to_remove, & &1.id)

      # POSITIVE: to_keep in newest-first order for storage
      assert kept_ids == Enum.sort(kept_ids, :desc)
    end
  end
end
