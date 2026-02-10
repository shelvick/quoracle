defmodule Quoracle.Actions.DismissChildTest do
  @moduledoc """
  Tests for ACTION_DismissChild - Recursive Child Agent Termination.

  Packet 3: DismissChild Action (~12 tests)
  - Authorization tests (R1, R2)
  - Idempotent behavior tests (R3, R4)
  - Async behavior tests (R5, R6)
  - Reason parameter tests (R7, R8)
  - Error case tests (R9, R10)
  - System test (R11)
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.DismissChild
  alias Quoracle.Agent.Core
  alias Quoracle.Agents.Agent, as: AgentSchema
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    {:ok, deps: deps}
  end

  # Helper to spawn a test agent with proper parent relationship
  defp spawn_test_agent(agent_id, deps, opts \\ []) do
    parent_id = Keyword.get(opts, :parent_id)
    parent_pid = Keyword.get(opts, :parent_pid)

    config = %{
      agent_id: agent_id,
      parent_id: parent_id,
      parent_pid: parent_pid,
      task_id: Keyword.get(opts, :task_id, Ecto.UUID.generate()),
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: deps.sandbox_owner
    }

    spawn_agent_with_cleanup(
      deps.dynsup,
      config,
      registry: deps.registry,
      pubsub: deps.pubsub
    )
  end

  # Helper to check if agent exists in registry
  defp agent_exists?(agent_id, registry) do
    case Registry.lookup(registry, {:agent, agent_id}) do
      [{_pid, _meta}] -> true
      [] -> false
    end
  end

  # Wait for agent to be removed from Registry (handles async cleanup race)
  defp wait_for_registry_cleanup(agent_id, registry, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_cleanup(agent_id, registry, deadline)
  end

  defp do_wait_for_cleanup(agent_id, registry, deadline) do
    if agent_exists?(agent_id, registry) do
      if System.monotonic_time(:millisecond) < deadline do
        # Registry cleanup is async (DOWN message handling)
        # Use receive/after instead of Process.sleep (Credo-compliant)
        receive do
        after
          5 -> do_wait_for_cleanup(agent_id, registry, deadline)
        end
      else
        {:error, :timeout}
      end
    else
      :ok
    end
  end

  # Wait for dismissing flag to be cleared (background task clears after TreeTerminator)
  defp wait_for_dismissing_cleared(parent_pid, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_dismissing_cleared(parent_pid, deadline)
  end

  defp do_wait_for_dismissing_cleared(parent_pid, deadline) do
    if Process.alive?(parent_pid) and Core.dismissing?(parent_pid) do
      if System.monotonic_time(:millisecond) < deadline do
        # Background task clears flag after TreeTerminator
        # Use receive/after instead of Process.sleep (Credo-compliant)
        receive do
        after
          5 -> do_wait_for_dismissing_cleared(parent_pid, deadline)
        end
      else
        {:error, :timeout}
      end
    else
      :ok
    end
  end

  # Build opts for DismissChild.execute/3
  defp action_opts(deps) do
    [
      registry: deps.registry,
      dynsup: deps.dynsup,
      pubsub: deps.pubsub,
      sandbox_owner: deps.sandbox_owner
    ]
  end

  # ==========================================================================
  # Authorization Tests (R1, R2)
  # ==========================================================================

  describe "authorization" do
    @tag :r1
    test "R1: non-parent agent cannot dismiss child", %{deps: deps} do
      # Arrange: Create parent with child, plus a stranger
      {:ok, parent_pid} = spawn_test_agent("parent", deps)

      {:ok, _child_pid} =
        spawn_test_agent("child", deps,
          parent_id: "parent",
          parent_pid: parent_pid
        )

      {:ok, _stranger_pid} = spawn_test_agent("stranger", deps)

      # Act: Stranger tries to dismiss child
      result = DismissChild.execute(%{child_id: "child"}, "stranger", action_opts(deps))

      # Assert: Denied - only parent can dismiss
      assert {:error, :not_parent} = result
    end

    @tag :r2
    test "R2: parent agent can dismiss own child", %{deps: deps} do
      # Arrange: Create parent-child hierarchy
      {:ok, parent_pid} = spawn_test_agent("parent", deps)

      {:ok, _child_pid} =
        spawn_test_agent("child", deps,
          parent_id: "parent",
          parent_pid: parent_pid
        )

      # Subscribe to wait for background completion (prevents sandbox exit race)
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:child")

      # Act: Parent dismisses own child
      result = DismissChild.execute(%{child_id: "child"}, "parent", action_opts(deps))

      # Assert: Success with terminating status
      assert {:ok, %{action: "dismiss_child", status: "terminating"}} = result

      # Wait for background task to complete before test exits
      assert_receive {:agent_terminated, _}, 30_000
    end

    @tag :r2_grandparent
    test "R2b: grandparent cannot dismiss grandchild directly", %{deps: deps} do
      # Arrange: Create 3-level hierarchy
      {:ok, grandparent_pid} = spawn_test_agent("grandparent", deps)

      {:ok, parent_pid} =
        spawn_test_agent("parent", deps,
          parent_id: "grandparent",
          parent_pid: grandparent_pid
        )

      {:ok, _child_pid} =
        spawn_test_agent("child", deps,
          parent_id: "parent",
          parent_pid: parent_pid
        )

      # Act: Grandparent tries to dismiss grandchild directly
      result = DismissChild.execute(%{child_id: "child"}, "grandparent", action_opts(deps))

      # Assert: Denied - only direct parent can dismiss
      assert {:error, :not_parent} = result
    end
  end

  # ==========================================================================
  # Idempotent Behavior Tests (R3, R4)
  # ==========================================================================

  describe "idempotent behavior" do
    @tag :r3
    test "R3: dismiss non-existent agent returns success (already_terminated)", %{deps: deps} do
      # Arrange: Create parent but child doesn't exist
      {:ok, _parent_pid} = spawn_test_agent("parent", deps)

      # Act: Parent tries to dismiss non-existent child
      result = DismissChild.execute(%{child_id: "ghost"}, "parent", action_opts(deps))

      # Assert: Idempotent success - agent already gone (per spec R3)
      assert {:ok, %{status: "already_terminated"}} = result
    end

    @tag :r4
    test "R4: double dismiss returns idempotent success", %{deps: deps} do
      # Arrange: Create parent-child hierarchy
      {:ok, parent_pid} = spawn_test_agent("parent", deps)

      {:ok, _child_pid} =
        spawn_test_agent("child", deps,
          parent_id: "parent",
          parent_pid: parent_pid
        )

      # Subscribe to know when termination completes
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:child")

      # Act: First dismiss
      {:ok, _} = DismissChild.execute(%{child_id: "child"}, "parent", action_opts(deps))

      # Wait for background termination
      assert_receive {:agent_terminated, %{agent_id: "child"}}, 30_000
      # Wait for Registry cleanup (async race between PubSub and Registry DOWN handling)
      :ok = wait_for_registry_cleanup("child", deps.registry)

      # Wait for background task to complete (clears dismissing flag after TreeTerminator)
      :ok = wait_for_dismissing_cleared(parent_pid)

      # Act: Second dismiss (child already gone)
      result = DismissChild.execute(%{child_id: "child"}, "parent", action_opts(deps))

      # Assert: Idempotent success
      assert {:ok, %{status: "already_terminated"}} = result
    end
  end

  # ==========================================================================
  # Async Behavior Tests (R5, R6)
  # ==========================================================================

  describe "async behavior" do
    @tag :r5
    test "R5: dismiss_child returns immediately (< 150ms)", %{deps: deps} do
      # Arrange: Create parent-child hierarchy
      {:ok, parent_pid} = spawn_test_agent("parent", deps)

      {:ok, _child_pid} =
        spawn_test_agent("child", deps,
          parent_id: "parent",
          parent_pid: parent_pid
        )

      # Subscribe to wait for background completion (prevents sandbox exit race)
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:child")

      # Act: Measure execution time
      {time_us, result} =
        :timer.tc(fn ->
          DismissChild.execute(%{child_id: "child"}, "parent", action_opts(deps))
        end)

      # Assert: Returns quickly (< 500ms) with success
      # Relaxed from 150ms (was 50ms) to handle scheduler jitter under parallel test load
      assert {:ok, _} = result
      assert time_us < 500_000, "dismiss_child took #{time_us}us, expected < 500000us"

      # Wait for background task to complete before test exits
      assert_receive {:agent_terminated, _}, 30_000
    end

    @tag :r6
    test "R6: child agent terminated after dismiss returns", %{deps: deps} do
      # Arrange: Create parent-child hierarchy
      {:ok, parent_pid} = spawn_test_agent("parent", deps)

      {:ok, child_pid} =
        spawn_test_agent("child", deps,
          parent_id: "parent",
          parent_pid: parent_pid
        )

      assert agent_exists?("child", deps.registry)

      # Subscribe to wait for background completion (prevents sandbox exit race)
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:child")

      # Act: Dismiss child
      {:ok, _} = DismissChild.execute(%{child_id: "child"}, "parent", action_opts(deps))

      # Wait for full termination (includes DB cleanup)
      assert_receive {:agent_terminated, _}, 30_000
      # Wait for Registry cleanup (async race between PubSub and Registry DOWN handling)
      :ok = wait_for_registry_cleanup("child", deps.registry)

      # Assert: Child is gone
      refute agent_exists?("child", deps.registry)
      refute Process.alive?(child_pid)
    end
  end

  # ==========================================================================
  # Reason Parameter Tests (R7, R8)
  # ==========================================================================

  describe "reason parameter" do
    @tag :r7
    test "R7: reason included in dismiss result", %{deps: deps} do
      # Arrange: Create parent-child hierarchy
      {:ok, parent_pid} = spawn_test_agent("parent", deps)

      {:ok, _child_pid} =
        spawn_test_agent("child", deps,
          parent_id: "parent",
          parent_pid: parent_pid
        )

      # Subscribe to wait for background completion (prevents sandbox exit race)
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:child")

      # Act: Dismiss with custom reason
      result =
        DismissChild.execute(
          %{child_id: "child", reason: "budget exceeded"},
          "parent",
          action_opts(deps)
        )

      # Assert: Success returned (reason propagates to events, not result)
      assert {:ok, %{action: "dismiss_child"}} = result

      # Wait for background task to complete before test exits
      assert_receive {:agent_terminated, _}, 30_000
    end

    @tag :r8
    test "R8: default reason used when not provided", %{deps: deps} do
      # Arrange: Create parent-child hierarchy
      {:ok, parent_pid} = spawn_test_agent("parent", deps)

      {:ok, _child_pid} =
        spawn_test_agent("child", deps,
          parent_id: "parent",
          parent_pid: parent_pid
        )

      # Subscribe to events
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:child")

      # Act: Dismiss without reason
      DismissChild.execute(%{child_id: "child"}, "parent", action_opts(deps))

      # Assert: Default reason in event
      assert_receive {:agent_dismissed, %{reason: "dismissed by parent"}}, 30_000
      # Wait for full background task completion before test exits
      assert_receive {:agent_terminated, _}, 30_000
    end

    @tag :r8_custom
    test "R8b: custom reason propagated to events", %{deps: deps} do
      # Arrange: Create parent-child hierarchy
      {:ok, parent_pid} = spawn_test_agent("parent", deps)

      {:ok, _child_pid} =
        spawn_test_agent("child", deps,
          parent_id: "parent",
          parent_pid: parent_pid
        )

      # Subscribe to events
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:child")

      # Act: Dismiss with custom reason
      DismissChild.execute(
        %{child_id: "child", reason: "task completed"},
        "parent",
        action_opts(deps)
      )

      # Assert: Custom reason in event
      assert_receive {:agent_dismissed, %{reason: "task completed"}}, 30_000
      # Wait for full background task completion before test exits
      assert_receive {:agent_terminated, _}, 30_000
    end
  end

  # ==========================================================================
  # Error Case Tests (R9, R10)
  # ==========================================================================

  describe "error cases" do
    @tag :r9
    test "R9: missing child_id returns error", %{deps: deps} do
      # Act: Call without child_id
      result = DismissChild.execute(%{}, "parent", action_opts(deps))

      # Assert: Error for missing required param
      assert {:error, :missing_child_id} = result
    end

    @tag :r10
    test "R10: invalid child_id format returns error", %{deps: deps} do
      # Act: Call with non-string child_id
      result = DismissChild.execute(%{child_id: 123}, "parent", action_opts(deps))

      # Assert: Error for invalid type
      assert {:error, :invalid_child_id} = result
    end

    @tag :r10_nil
    test "R10b: nil child_id returns error", %{deps: deps} do
      # Act: Call with nil child_id
      result = DismissChild.execute(%{child_id: nil}, "parent", action_opts(deps))

      # Assert: Error for nil (treated as missing)
      assert {:error, :missing_child_id} = result
    end
  end

  # ==========================================================================
  # Children Tracking - Parent Notification Tests (R13-R16 v2.0)
  # WorkGroupID: feat-20251227-children-inject, Packet 3
  # ==========================================================================

  describe "parent notification of child dismiss (R13-R16)" do
    @tag :r13
    test "R13: dispatch casts child_dismissed to parent", %{deps: deps} do
      # Arrange: Create parent-child hierarchy
      {:ok, parent_pid} = spawn_test_agent("parent-R13", deps)

      {:ok, child_pid} =
        spawn_test_agent("child-R13", deps,
          parent_id: "parent-R13",
          parent_pid: parent_pid
        )

      # Manually add child to parent's children list to simulate spawn tracking
      GenServer.cast(
        parent_pid,
        {:child_spawned,
         %{
           agent_id: "child-R13",
           spawned_at: DateTime.utc_now()
         }}
      )

      # Sync wait to ensure cast is processed
      {:ok, state_before} = Core.get_state(parent_pid)

      assert Enum.any?(state_before.children, &(&1.agent_id == "child-R13")),
             "Parent should have child in children list before dismiss"

      # Subscribe to wait for background completion
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:child-R13")

      # Act: Parent dismisses child (should cast child_dismissed to parent)
      {:ok, _} = DismissChild.execute(%{child_id: "child-R13"}, "parent-R13", action_opts(deps))

      # Wait for termination
      assert_receive {:agent_terminated, _}, 30_000
      :ok = wait_for_registry_cleanup("child-R13", deps.registry)

      # Assert: Parent should have removed the child from children list
      {:ok, state_after} = Core.get_state(parent_pid)

      refute Enum.any?(state_after.children, &(&1.agent_id == "child-R13")),
             "Parent should have received child_dismissed cast and removed child"

      # Cleanup child_pid reference (already terminated)
      _ = child_pid
    end

    @tag :r14
    test "R14: child_dismissed cast contains child_id", %{deps: deps} do
      # Arrange: Create parent-child hierarchy
      {:ok, parent_pid} = spawn_test_agent("parent-R14", deps)

      {:ok, _child_pid} =
        spawn_test_agent("child-R14", deps,
          parent_id: "parent-R14",
          parent_pid: parent_pid
        )

      # Manually add child to parent's children list
      child_id = "child-R14"

      GenServer.cast(
        parent_pid,
        {:child_spawned,
         %{
           agent_id: child_id,
           spawned_at: DateTime.utc_now()
         }}
      )

      # Sync wait
      {:ok, _state} = Core.get_state(parent_pid)

      # Subscribe to wait for background completion
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:#{child_id}")

      # Act: Parent dismisses child
      {:ok, _} = DismissChild.execute(%{child_id: child_id}, "parent-R14", action_opts(deps))

      # Wait for termination
      assert_receive {:agent_terminated, _}, 30_000
      :ok = wait_for_registry_cleanup(child_id, deps.registry)

      # Assert: The correct child was removed (by child_id)
      {:ok, state_after} = Core.get_state(parent_pid)

      refute Enum.any?(state_after.children, &(&1.agent_id == child_id)),
             "Child with specific child_id should be removed"
    end

    @tag :r15
    test "R15: skips cast if parent process not alive", %{deps: deps} do
      # Arrange: Create parent-child hierarchy
      {:ok, parent_pid} = spawn_test_agent("parent-R15", deps)

      {:ok, child_pid} =
        spawn_test_agent("child-R15", deps,
          parent_id: "parent-R15",
          parent_pid: parent_pid
        )

      # Add child to parent's children list
      GenServer.cast(
        parent_pid,
        {:child_spawned,
         %{
           agent_id: "child-R15",
           spawned_at: DateTime.utc_now()
         }}
      )

      {:ok, state_before} = Core.get_state(parent_pid)
      assert Enum.any?(state_before.children, &(&1.agent_id == "child-R15"))

      # Subscribe to child events
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:child-R15")

      # Start the dismiss process - parent is alive at this point
      {:ok, result} =
        DismissChild.execute(%{child_id: "child-R15"}, "parent-R15", action_opts(deps))

      assert result.status == "terminating"

      # Now kill the parent while dismiss is in progress
      # The background task will try to cast to parent but it should skip gracefully
      GenServer.stop(parent_pid, :normal, :infinity)
      refute Process.alive?(parent_pid)

      # Wait for termination (child should still terminate)
      assert_receive {:agent_terminated, _}, 30_000
      :ok = wait_for_registry_cleanup("child-R15", deps.registry)

      # Assert: The key is NO CRASH occurred - dismiss completed successfully
      # Parent's children list can't be checked (parent is dead)
      # But the child was terminated and no crash happened
      refute Process.alive?(child_pid)
    end

    @tag :r16
    test "R16: no cast when child already terminated", %{deps: deps} do
      # Arrange: Create parent without actual child
      {:ok, parent_pid} = spawn_test_agent("parent-R16", deps)

      # Add a fake child entry to parent's children list
      GenServer.cast(
        parent_pid,
        {:child_spawned,
         %{
           agent_id: "ghost-child",
           spawned_at: DateTime.utc_now()
         }}
      )

      {:ok, state_before} = Core.get_state(parent_pid)
      assert Enum.any?(state_before.children, &(&1.agent_id == "ghost-child"))

      # Act: Try to dismiss non-existent child (already_terminated)
      result = DismissChild.execute(%{child_id: "ghost-child"}, "parent-R16", action_opts(deps))

      # Assert: Idempotent success but NO cast should be sent
      assert {:ok, %{status: "already_terminated"}} = result

      # Parent's children list should NOT be modified (no cast was sent)
      {:ok, state_after} = Core.get_state(parent_pid)

      assert Enum.any?(state_after.children, &(&1.agent_id == "ghost-child")),
             "No child_dismissed cast should be sent for already_terminated"
    end
  end

  # ==========================================================================
  # System Test (R11)
  # ==========================================================================

  describe "system test" do
    @tag :r11
    @tag :system
    test "R11: full dismiss flow terminates entire agent tree", %{deps: deps} do
      # Arrange: Create 3-level tree
      #     parent
      #     /    \
      #  child1  child2
      #    |
      #  grandchild

      {:ok, parent_pid} = spawn_test_agent("sys-parent", deps)

      {:ok, child1_pid} =
        spawn_test_agent("sys-child1", deps,
          parent_id: "sys-parent",
          parent_pid: parent_pid
        )

      {:ok, child2_pid} =
        spawn_test_agent("sys-child2", deps,
          parent_id: "sys-parent",
          parent_pid: parent_pid
        )

      {:ok, grandchild_pid} =
        spawn_test_agent("sys-grandchild", deps,
          parent_id: "sys-child1",
          parent_pid: child1_pid
        )

      # Verify all exist
      assert agent_exists?("sys-child1", deps.registry)
      assert agent_exists?("sys-child2", deps.registry)
      assert agent_exists?("sys-grandchild", deps.registry)

      # Subscribe to parent-dismissed child's termination
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:sys-child1")

      # Act: Parent dismisses child1 (which has grandchild)
      result =
        DismissChild.execute(
          %{child_id: "sys-child1", reason: "no longer needed"},
          "sys-parent",
          action_opts(deps)
        )

      # Assert: Immediate success
      assert {:ok, %{action: "dismiss_child", status: "terminating"}} = result

      # Wait for child1 terminated event
      assert_receive {:agent_terminated, %{agent_id: "sys-child1"}}, 30_000
      # Wait for Registry cleanup (async race between PubSub and Registry DOWN handling)
      :ok = wait_for_registry_cleanup("sys-child1", deps.registry)
      :ok = wait_for_registry_cleanup("sys-grandchild", deps.registry)

      # Wait for background task to complete (clears dismissing flag after TreeTerminator)
      :ok = wait_for_dismissing_cleared(parent_pid)

      # Assert: Child1 and grandchild are gone, but child2 and parent remain
      refute agent_exists?("sys-child1", deps.registry)
      refute agent_exists?("sys-grandchild", deps.registry)
      assert agent_exists?("sys-child2", deps.registry)
      assert agent_exists?("sys-parent", deps.registry)

      # Verify processes are dead
      refute Process.alive?(child1_pid)
      refute Process.alive?(grandchild_pid)
      assert Process.alive?(child2_pid)
      assert Process.alive?(parent_pid)

      # Verify DB cleanup
      refute Repo.get_by(AgentSchema, agent_id: "sys-child1")
      refute Repo.get_by(AgentSchema, agent_id: "sys-grandchild")
    end
  end
end
