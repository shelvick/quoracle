defmodule Quoracle.Agent.CoreChildrenTest do
  @moduledoc """
  Tests for children state management in Core GenServer.

  Verifies that Core properly tracks spawned and dismissed children
  as part of agent state management (Packet 1 - Foundation).

  WorkGroupID: feat-20251227-children-inject

  Tests cover:
  - R23: Children field initializes as empty list
  - R24: Child spawned cast delegation
  - R25: Child dismissed cast delegation
  - R1-R5: ChildrenTracker handler behavior
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.Core

  setup do
    # Create isolated dependencies
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    dynsup = :"test_dynsup_#{System.unique_integer([:positive])}"

    start_supervised!({Phoenix.PubSub, name: pubsub})
    start_supervised!({Registry, keys: :duplicate, name: registry})

    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: dynsup]]},
      shutdown: :infinity
    }

    start_supervised!(dynsup_spec)

    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    {:ok, core_pid} =
      Core.start_link(
        agent_id: agent_id,
        parent_agent_id: nil,
        dynsup: dynsup,
        registry: registry,
        pubsub: pubsub,
        test_mode: true,
        skip_auto_consensus: true
      )

    on_exit(fn ->
      if Process.alive?(core_pid) do
        try do
          GenServer.stop(core_pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{
      core_pid: core_pid,
      agent_id: agent_id,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup
    }
  end

  describe "R23: children field initialization" do
    test "children field initializes as empty list", %{core_pid: core_pid} do
      {:ok, state} = GenServer.call(core_pid, :get_state)
      assert Map.has_key?(state, :children)
      assert state.children == []
    end
  end

  describe "R1: handle_child_spawned/2 - add child to list" do
    test "adds child to front of children list", %{core_pid: core_pid} do
      spawned_at = DateTime.utc_now()

      GenServer.cast(core_pid, {:child_spawned, %{agent_id: "child-1", spawned_at: spawned_at}})
      # Sync point
      {:ok, state} = GenServer.call(core_pid, :get_state)

      assert length(state.children) == 1
      assert hd(state.children).agent_id == "child-1"
      assert hd(state.children).spawned_at == spawned_at
    end
  end

  describe "R2: handle_child_dismissed/2 - remove child from list" do
    test "removes child from children list by agent_id", %{core_pid: core_pid} do
      spawned_at = DateTime.utc_now()

      # Add a child
      GenServer.cast(core_pid, {:child_spawned, %{agent_id: "child-1", spawned_at: spawned_at}})
      {:ok, state1} = GenServer.call(core_pid, :get_state)
      assert length(state1.children) == 1

      # Remove the child
      GenServer.cast(core_pid, {:child_dismissed, "child-1"})
      {:ok, state2} = GenServer.call(core_pid, :get_state)

      assert state2.children == []
    end
  end

  describe "R3: dismiss non-existent child (idempotent)" do
    test "dismissing non-existent child leaves state unchanged", %{core_pid: core_pid} do
      spawned_at = DateTime.utc_now()

      # Add a child
      GenServer.cast(core_pid, {:child_spawned, %{agent_id: "child-1", spawned_at: spawned_at}})
      {:ok, state1} = GenServer.call(core_pid, :get_state)
      original_children = state1.children

      # Try to dismiss non-existent child
      GenServer.cast(core_pid, {:child_dismissed, "non-existent-child"})
      {:ok, state2} = GenServer.call(core_pid, :get_state)

      assert state2.children == original_children
    end
  end

  describe "R4: multiple children ordering" do
    test "newest children appear first in list", %{core_pid: core_pid} do
      t1 = DateTime.utc_now()
      t2 = DateTime.add(t1, 1, :second)
      t3 = DateTime.add(t2, 1, :second)

      GenServer.cast(core_pid, {:child_spawned, %{agent_id: "child-1", spawned_at: t1}})
      {:ok, _} = GenServer.call(core_pid, :get_state)

      GenServer.cast(core_pid, {:child_spawned, %{agent_id: "child-2", spawned_at: t2}})
      {:ok, _} = GenServer.call(core_pid, :get_state)

      GenServer.cast(core_pid, {:child_spawned, %{agent_id: "child-3", spawned_at: t3}})
      {:ok, state} = GenServer.call(core_pid, :get_state)

      # Newest first (prepend behavior)
      assert length(state.children) == 3
      assert Enum.at(state.children, 0).agent_id == "child-3"
      assert Enum.at(state.children, 1).agent_id == "child-2"
      assert Enum.at(state.children, 2).agent_id == "child-1"
    end
  end

  describe "R24: child_spawned delegation" do
    test "delegates child_spawned cast to ChildrenTracker", %{core_pid: core_pid} do
      spawned_at = DateTime.utc_now()
      data = %{agent_id: "child-delegated", spawned_at: spawned_at}

      GenServer.cast(core_pid, {:child_spawned, data})
      {:ok, state} = GenServer.call(core_pid, :get_state)

      # Verify child was added (proves delegation worked)
      assert length(state.children) == 1
      assert hd(state.children).agent_id == "child-delegated"
    end
  end

  describe "R25: child_dismissed delegation" do
    test "delegates child_dismissed cast to ChildrenTracker", %{core_pid: core_pid} do
      spawned_at = DateTime.utc_now()

      # Add a child first
      GenServer.cast(
        core_pid,
        {:child_spawned, %{agent_id: "child-to-dismiss", spawned_at: spawned_at}}
      )

      {:ok, state1} = GenServer.call(core_pid, :get_state)
      assert length(state1.children) == 1

      # Dismiss via Core (delegates to ChildrenTracker)
      GenServer.cast(core_pid, {:child_dismissed, "child-to-dismiss"})
      {:ok, state2} = GenServer.call(core_pid, :get_state)

      assert state2.children == []
    end
  end

  # ==========================================================================
  # v2.1 Children Restoration Tests (fix-20260104-children-restore)
  # ==========================================================================

  describe "R12: child_restored delegation (v2.1)" do
    test "R12: Core delegates child_restored cast to ChildrenTracker", %{core_pid: core_pid} do
      spawned_at = DateTime.utc_now()
      data = %{agent_id: "restored-child", spawned_at: spawned_at, budget_allocated: nil}

      # Send child_restored cast to Core
      GenServer.cast(core_pid, {:child_restored, data})

      # Sync point to ensure cast is processed
      {:ok, state} = GenServer.call(core_pid, :get_state)

      # Verify child was added (proves delegation worked)
      assert length(state.children) == 1
      assert hd(state.children).agent_id == "restored-child"
      assert hd(state.children).spawned_at == spawned_at
    end

    test "R12: child_restored with budget_allocated", %{core_pid: core_pid} do
      spawned_at = DateTime.utc_now()
      budget = Decimal.new("50.00")

      data = %{
        agent_id: "restored-child-budget",
        spawned_at: spawned_at,
        budget_allocated: budget
      }

      GenServer.cast(core_pid, {:child_restored, data})
      {:ok, state} = GenServer.call(core_pid, :get_state)

      assert length(state.children) == 1
      child = hd(state.children)
      assert child.agent_id == "restored-child-budget"
      assert Decimal.equal?(child.budget_allocated, Decimal.new("50.00"))
    end
  end

  describe "children state persistence" do
    test "children survive message processing", %{core_pid: core_pid} do
      spawned_at = DateTime.utc_now()

      GenServer.cast(
        core_pid,
        {:child_spawned, %{agent_id: "persistent-child", spawned_at: spawned_at}}
      )

      {:ok, _} = GenServer.call(core_pid, :get_state)

      # Process some other messages
      GenServer.call(core_pid, :get_state)
      send(core_pid, :trigger_consensus)
      GenServer.call(core_pid, :get_state)

      # Children should still be there
      {:ok, state} = GenServer.call(core_pid, :get_state)
      assert length(state.children) == 1
      assert hd(state.children).agent_id == "persistent-child"
    end
  end

  describe "concurrent operations" do
    test "handles concurrent child spawn operations", %{core_pid: core_pid} do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            spawned_at = DateTime.utc_now()

            GenServer.cast(
              core_pid,
              {:child_spawned, %{agent_id: "child-#{i}", spawned_at: spawned_at}}
            )
          end)
        end

      Enum.each(tasks, &Task.await/1)
      {:ok, state} = GenServer.call(core_pid, :get_state)

      # Should have all 10 children
      assert length(state.children) == 10
      agent_ids = Enum.map(state.children, & &1.agent_id)
      for i <- 1..10, do: assert("child-#{i}" in agent_ids)
    end

    test "handles interleaved spawn and dismiss", %{core_pid: core_pid} do
      spawned_at = DateTime.utc_now()

      # Spawn child-1 and child-2
      GenServer.cast(core_pid, {:child_spawned, %{agent_id: "child-1", spawned_at: spawned_at}})
      GenServer.cast(core_pid, {:child_spawned, %{agent_id: "child-2", spawned_at: spawned_at}})
      {:ok, _} = GenServer.call(core_pid, :get_state)

      # Dismiss child-1, spawn child-3
      GenServer.cast(core_pid, {:child_dismissed, "child-1"})
      GenServer.cast(core_pid, {:child_spawned, %{agent_id: "child-3", spawned_at: spawned_at}})
      {:ok, state} = GenServer.call(core_pid, :get_state)

      # Should have child-2 and child-3
      assert length(state.children) == 2
      agent_ids = Enum.map(state.children, & &1.agent_id)
      assert "child-2" in agent_ids
      assert "child-3" in agent_ids
      refute "child-1" in agent_ids
    end
  end
end
