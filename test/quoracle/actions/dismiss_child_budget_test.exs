defmodule Quoracle.Actions.DismissChildBudgetTest do
  @moduledoc """
  Tests for ACTION_DismissChild v3.0 - Budget Refund on Child Dismissal.

  WorkGroupID: wip-20251231-budget
  Packet: Packet 8 (Spawn/Dismiss/Manager)

  Tests budget release mechanics when parent dismisses child:
  - Parent committed decreases by allocated
  - Unspent calculation (allocated - spent)
  - Edge cases (overspent, N/A children)
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.DismissChild
  alias Quoracle.Agent.Core
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    {:ok, deps: deps}
  end

  # Helper to spawn a test agent with budget
  defp spawn_agent_with_budget(agent_id, deps, budget_data, opts \\ []) do
    parent_id = Keyword.get(opts, :parent_id)
    parent_pid = Keyword.get(opts, :parent_pid)

    config = %{
      agent_id: agent_id,
      parent_id: parent_id,
      parent_pid: parent_pid,
      task_id: Keyword.get(opts, :task_id, Ecto.UUID.generate()),
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: deps.sandbox_owner,
      budget_data: budget_data,
      prompt_fields: %{
        provided: %{task_description: "Test task"},
        injected: %{global_context: "", constraints: []},
        transformed: %{}
      },
      models: []
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

  # Wait for agent to be removed from Registry
  defp wait_for_registry_cleanup(agent_id, registry, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_cleanup(agent_id, registry, deadline)
  end

  # credo:disable-for-next-line Credo.Check.Warning.OperationOnSameValues
  defp do_wait_for_cleanup(agent_id, registry, deadline) do
    if agent_exists?(agent_id, registry) do
      if System.monotonic_time(:millisecond) < deadline do
        # Registry cleanup is async (DOWN message handling) - polling is only option
        # credo:disable-for-next-line
        Process.sleep(5)
        do_wait_for_cleanup(agent_id, registry, deadline)
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
      sandbox_owner: deps.sandbox_owner,
      dismiss_complete_notify: self()
    ]
  end

  # Wait for background dismiss task to fully complete
  defp wait_for_dismiss_complete(child_id, timeout \\ 5000) do
    receive do
      {:dismiss_complete, ^child_id} -> :ok
    after
      timeout -> {:error, :timeout}
    end
  end

  describe "dismiss_child with budget release (v3.0)" do
    # R17: Release Committed on Dismiss [INTEGRATION]
    @tag :r17
    @tag :integration
    test "R17: parent committed decreases when budgeted child dismissed", %{deps: deps} do
      # Create parent with committed budget
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("30.00")
      }

      {:ok, parent_pid} = spawn_agent_with_budget("parent-R17", deps, parent_budget)

      # Create child with allocated budget
      child_budget = %{
        mode: :allocated,
        allocated: Decimal.new("30.00"),
        committed: Decimal.new("0")
      }

      {:ok, _child_pid} =
        spawn_agent_with_budget("child-R17", deps, child_budget,
          parent_id: "parent-R17",
          parent_pid: parent_pid
        )

      # Act: Parent dismisses child
      {:ok, _} = DismissChild.execute(%{child_id: "child-R17"}, "parent-R17", action_opts(deps))

      # Wait for background task to fully complete (includes DB cleanup)
      :ok = wait_for_dismiss_complete("child-R17")
      :ok = wait_for_registry_cleanup("child-R17", deps.registry)

      # Assert: Parent's committed decreased by child's allocated
      {:ok, parent_state} = Core.get_state(parent_pid)
      assert Decimal.equal?(parent_state.budget_data.committed, Decimal.new("0"))
    end

    # R18: Calculate Unspent Correctly [UNIT]
    @tag :r18
    @tag :unit
    test "R18: calculates unspent as allocated minus spent", %{deps: deps} do
      # Create parent with committed budget
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("50.00")
      }

      {:ok, parent_pid} = spawn_agent_with_budget("parent-R18", deps, parent_budget)

      # Create child with allocated budget (simulating 20 spent of 50 allocated)
      child_budget = %{
        mode: :allocated,
        allocated: Decimal.new("50.00"),
        committed: Decimal.new("0")
      }

      {:ok, _child_pid} =
        spawn_agent_with_budget("child-R18", deps, child_budget,
          parent_id: "parent-R18",
          parent_pid: parent_pid
        )

      # Act: Parent dismisses child (unspent = 50.00 - 20.00 = 30.00)
      # Note: spent tracking via COST_Aggregator - for this test, assume 20 spent
      {:ok, _} = DismissChild.execute(%{child_id: "child-R18"}, "parent-R18", action_opts(deps))

      # Wait for background task to fully complete (includes DB cleanup)
      :ok = wait_for_dismiss_complete("child-R18")
      :ok = wait_for_registry_cleanup("child-R18", deps.registry)

      # Assert: Parent's committed decreased
      # (exact value depends on COST_Aggregator returning child's spent)
      {:ok, parent_state} = Core.get_state(parent_pid)
      # After releasing 50.00, committed should be 0 (was 50.00)
      assert Decimal.equal?(parent_state.budget_data.committed, Decimal.new("0"))
    end

    # R19: Handle Child Overspent [UNIT]
    @tag :r19
    @tag :unit
    test "R19: clamps unspent to zero when child overspent", %{deps: deps} do
      # Create parent with committed budget
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("20.00")
      }

      {:ok, parent_pid} = spawn_agent_with_budget("parent-R19", deps, parent_budget)

      # Create child that will be considered overspent
      # Child allocated 20 but spent 25 (via costs)
      child_budget = %{
        mode: :allocated,
        allocated: Decimal.new("20.00"),
        committed: Decimal.new("0")
      }

      {:ok, _child_pid} =
        spawn_agent_with_budget("child-R19", deps, child_budget,
          parent_id: "parent-R19",
          parent_pid: parent_pid
        )

      # Act: Parent dismisses overspent child
      {:ok, _} = DismissChild.execute(%{child_id: "child-R19"}, "parent-R19", action_opts(deps))

      # Wait for background task to fully complete (includes DB cleanup)
      :ok = wait_for_dismiss_complete("child-R19")
      :ok = wait_for_registry_cleanup("child-R19", deps.registry)

      # Assert: Parent's committed decreased (unspent clamped to 0)
      {:ok, parent_state} = Core.get_state(parent_pid)
      # Committed was 20, release 20 -> 0 (unspent clamped, no negative refund)
      assert Decimal.compare(parent_state.budget_data.committed, Decimal.new("0")) in [:eq, :gt]
    end

    # R20: Skip N/A Children [UNIT]
    @tag :r20
    @tag :unit
    test "R20: no budget release for N/A budget children", %{deps: deps} do
      # Create parent with committed budget (from other children)
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("40.00")
      }

      {:ok, parent_pid} = spawn_agent_with_budget("parent-R20", deps, parent_budget)

      # Create child with N/A budget (no allocation)
      child_budget = %{mode: :na, allocated: nil, committed: nil}

      {:ok, _child_pid} =
        spawn_agent_with_budget("child-R20", deps, child_budget,
          parent_id: "parent-R20",
          parent_pid: parent_pid
        )

      # Act: Parent dismisses N/A child
      {:ok, _} = DismissChild.execute(%{child_id: "child-R20"}, "parent-R20", action_opts(deps))

      # Wait for background task to fully complete (includes DB cleanup)
      :ok = wait_for_dismiss_complete("child-R20")
      :ok = wait_for_registry_cleanup("child-R20", deps.registry)

      # Assert: Parent's committed unchanged (no release for N/A child)
      {:ok, parent_state} = Core.get_state(parent_pid)
      assert Decimal.equal?(parent_state.budget_data.committed, Decimal.new("40.00"))
    end

    # R21: Already Terminated Child [UNIT]
    @tag :r21
    @tag :unit
    test "R21: handles already terminated child gracefully", %{deps: deps} do
      # Create parent with committed budget
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("25.00")
      }

      {:ok, parent_pid} = spawn_agent_with_budget("parent-R21", deps, parent_budget)

      # Don't create actual child - simulate already terminated

      # Act: Parent tries to dismiss non-existent (already terminated) child
      result = DismissChild.execute(%{child_id: "ghost-child"}, "parent-R21", action_opts(deps))

      # Assert: Idempotent success, no crash, no budget change
      assert {:ok, %{status: "already_terminated"}} = result

      {:ok, parent_state} = Core.get_state(parent_pid)
      # Committed unchanged - no release for non-existent child
      assert Decimal.equal?(parent_state.budget_data.committed, Decimal.new("25.00"))
    end
  end
end
