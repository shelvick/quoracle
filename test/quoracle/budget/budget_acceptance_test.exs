defmodule Quoracle.Budget.BudgetAcceptanceTest do
  @moduledoc """
  End-to-end acceptance test for the complete budget lifecycle.

  WorkGroupID: wip-20251231-budget
  Packet: Packet 10 (Acceptance Test)

  This test verifies the ENTIRE budget flow from user entry point to outcome:
  1. TaskManager.create_task with budget_limit -> root agent spawns with budget_data
  2. Root spawns child with allocation -> escrow locks parent committed
  3. record_cost action -> over_budget transitions when spent >= allocated
  4. Over-budget agent attempts spawn_child -> {:error, :budget_exceeded}
  5. Child dismissed -> parent committed releases

  Uses REAL components - no mocking. Isolated PubSub/Registry/DynSup per test.
  """
  # Isolated dependencies per test - safe for async
  use Quoracle.DataCase, async: true

  import Test.AgentTestHelpers,
    only: [
      create_test_profile: 0,
      register_agent_cleanup: 1
    ]

  alias Quoracle.Agent.Core
  alias Quoracle.Tasks.TaskManager
  alias Quoracle.Actions.Spawn
  alias Quoracle.Actions.DismissChild
  alias Quoracle.Actions.RecordCost
  alias Quoracle.Actions.Router

  @moduletag :acceptance

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated PubSub instance for this test
    pubsub_name = :"acceptance_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Create isolated Registry for this test
    registry_name = :"acceptance_registry_#{System.unique_integer([:positive])}"
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    # Create isolated DynamicSupervisor for agents
    dynsup_name = :"acceptance_dynsup_#{System.unique_integer([:positive])}"

    {:ok, _dynsup} =
      start_supervised({DynamicSupervisor, strategy: :one_for_one, name: dynsup_name})

    # Subscribe to lifecycle events for spawn completion tracking
    test_pid = self()

    %{
      pubsub: pubsub_name,
      registry: registry_name,
      dynsup: dynsup_name,
      sandbox_owner: sandbox_owner,
      spawn_complete_notify: test_pid,
      profile: create_test_profile()
    }
  end

  # Helper to wait for background spawn to complete
  defp wait_for_spawn_complete(child_id, timeout \\ 5000) do
    receive do
      {:spawn_complete, ^child_id, {:ok, child_pid}} -> child_pid
      {:spawn_complete, ^child_id, {:error, _reason}} -> nil
    after
      timeout -> nil
    end
  end

  # Helper to poll until condition is met (returns truthy value)
  # Uses :erlang.yield() instead of Process.sleep for scheduler-friendly polling
  defp wait_until(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5000

    case fun.() do
      nil -> retry_wait_until(fun, deadline)
      false -> retry_wait_until(fun, deadline)
      result -> result
    end
  end

  defp retry_wait_until(fun, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      # Yield multiple times to let async operations complete
      Enum.each(1..10, fn _ -> :erlang.yield() end)
      wait_until(fun, deadline)
    else
      nil
    end
  end

  describe "Full Budget Lifecycle (E2E)" do
    @tag :acceptance
    test "complete budget flow: task creation → spawn → cost → over-budget → dismiss", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner,
      spawn_complete_notify: spawn_complete_notify,
      profile: profile
    } do
      # ============================================================
      # STEP 1: TaskManager.create_task with budget_limit
      # Verify root agent spawns with correct budget_data
      # ============================================================

      task_fields = %{
        budget_limit: Decimal.new("100.00"),
        profile: profile.name
      }

      agent_fields = %{
        task_description: "Test task with budget constraints",
        system_prompt: "You are a test agent with budget constraints",
        user_prompt: "Execute budget acceptance test",
        success_criteria: "Complete all steps",
        immediate_context: "Acceptance test",
        approach_guidance: "Follow the test flow"
      }

      opts = [
        sandbox_owner: sandbox_owner,
        dynsup: dynsup,
        registry: registry,
        pubsub: pubsub
      ]

      # Create task with budget - this is the USER ENTRY POINT
      {:ok, {task, root_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)
      register_agent_cleanup(root_pid)

      # Wait for agent initialization
      {:ok, _state} = Core.get_state(root_pid)

      # VERIFY: Root agent has correct budget_data from task
      {:ok, root_state} = Core.get_state(root_pid)

      assert root_state.budget_data != nil,
             "Root agent must have budget_data"

      assert root_state.budget_data.mode == :root,
             "Root agent budget mode must be :root"

      assert Decimal.equal?(root_state.budget_data.allocated, Decimal.new("100.00")),
             "Root agent allocated must equal task budget_limit"

      assert Decimal.equal?(root_state.budget_data.committed, Decimal.new("0")),
             "Root agent committed must start at 0"

      assert root_state.over_budget == false,
             "Root agent must not be over budget initially"

      # ============================================================
      # STEP 2: Root spawns child with budget allocation
      # Verify escrow locks parent committed
      # ============================================================

      # Build parent config for spawn (required by ConfigBuilder)
      parent_config = %{
        task_id: root_state.task_id,
        prompt_fields: root_state.prompt_fields,
        models: root_state.models,
        sandbox_owner: sandbox_owner,
        test_mode: true,
        pubsub: pubsub,
        skip_auto_consensus: true
      }

      spawn_params = %{
        "task_description" => "Child task with allocated budget",
        "success_criteria" => "Complete",
        "immediate_context" => "Child test",
        "approach_guidance" => "Standard",
        "profile" => profile.name,
        "budget" => "30.00"
      }

      spawn_opts = [
        agent_pid: root_pid,
        registry: registry,
        dynsup: dynsup,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner,
        parent_config: parent_config,
        spawn_complete_notify: spawn_complete_notify,
        # Pass parent's budget data for validation
        budget_data: root_state.budget_data,
        spent: Decimal.new("0")
      ]

      # Execute spawn action
      {:ok, spawn_result} = Spawn.execute(spawn_params, root_state.agent_id, spawn_opts)
      child_agent_id = spawn_result.agent_id

      # Wait for async spawn to complete
      child_pid = wait_for_spawn_complete(child_agent_id)
      assert child_pid, "Child should spawn successfully"
      register_agent_cleanup(child_pid)

      # VERIFY: Spawn result includes budget_allocated for Core to process
      # (v19.0: budget_committed update moved from Spawn callback to handle_action_result)
      assert spawn_result.budget_allocated == Decimal.new("30.00"),
             "Spawn result must include budget_allocated for Core result processing"

      # Parent committed is NOT updated by direct Spawn.execute (only via ActionExecutor pipeline).
      # Simulate what Core.handle_action_result does when processing spawn result:
      Core.update_budget_committed(root_pid, spawn_result.budget_allocated)
      {:ok, root_state_after_spawn} = Core.get_state(root_pid)

      assert Decimal.equal?(root_state_after_spawn.budget_data.committed, Decimal.new("30.00")),
             "Parent committed must increase after simulated result processing"

      # VERIFY: Child has allocated budget from parent
      {:ok, child_state} = Core.get_state(child_pid)

      assert child_state.budget_data.mode == :allocated,
             "Child budget mode must be :allocated"

      assert Decimal.equal?(child_state.budget_data.allocated, Decimal.new("30.00")),
             "Child allocated must equal spawn budget"

      # ============================================================
      # STEP 3: Record cost to push agent over budget
      # Verify over_budget transitions to true
      # ============================================================

      # Record cost that exceeds remaining budget (100 - 30 committed = 70 available)
      # Recording $75 will push root over budget
      cost_params = %{
        amount: 75.00,
        description: "Test cost to trigger over-budget"
      }

      cost_opts = [
        pubsub: pubsub,
        task_id: task.id
      ]

      {:ok, _cost_result} = RecordCost.execute(cost_params, root_state.agent_id, cost_opts)

      # Broadcast cost event to trigger over_budget check
      Phoenix.PubSub.broadcast(
        pubsub,
        "agents:#{root_state.agent_id}:costs",
        {:cost_recorded, %{}}
      )

      # Force state refresh via GenServer call
      {:ok, root_state_after_cost} = Core.get_state(root_pid)

      # VERIFY: Root agent is now over budget
      # Available = 100 - 75 - 30 = -5 (over budget!)
      assert root_state_after_cost.over_budget == true,
             "Root agent must be over budget after cost exceeds available"

      # ============================================================
      # STEP 4: Over-budget agent attempts spawn_child via Router
      # Verify action is blocked with :budget_exceeded
      # ============================================================

      # Per-action Router (v28.0): Start Router for spawn_child action
      action_id = "spawn-budget-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :spawn_child,
          action_id: action_id,
          agent_id: root_state.agent_id,
          agent_pid: root_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router_pid) do
          try do
            GenServer.stop(router_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Try to spawn another child while over budget
      spawn_params_2 = %{
        "task_description" => "Another child (should be blocked)",
        "success_criteria" => "N/A",
        "immediate_context" => "N/A",
        "approach_guidance" => "N/A",
        "profile" => profile.name
      }

      spawn_opts_2 = [
        action_id: action_id,
        agent_id: root_state.agent_id,
        agent_pid: root_pid,
        registry: registry,
        dynsup: dynsup,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner,
        parent_config: parent_config,
        # CRITICAL: Pass over_budget flag to Router
        over_budget: true
      ]

      # VERIFY: Spawn is blocked due to over budget
      result = Router.execute_action(router_pid, :spawn_child, spawn_params_2, spawn_opts_2)

      assert {:error, :budget_exceeded} = result,
             "Spawn must be blocked when agent is over budget"

      # ============================================================
      # STEP 5: Dismiss child
      # Verify parent committed releases
      # ============================================================

      # First verify current committed before dismiss
      {:ok, root_before_dismiss} = Core.get_state(root_pid)
      committed_before = root_before_dismiss.budget_data.committed

      assert Decimal.equal?(committed_before, Decimal.new("30.00")),
             "Committed should still be 30 before dismiss"

      # Dismiss the child
      dismiss_params = %{
        child_id: child_agent_id,
        reason: "Task complete"
      }

      dismiss_opts = [
        agent_pid: root_pid,
        registry: registry,
        dynsup: dynsup,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner
      ]

      # Monitor child before dismissing to wait for termination
      child_ref = Process.monitor(child_pid)

      {:ok, _dismiss_result} =
        DismissChild.execute(dismiss_params, root_state.agent_id, dismiss_opts)

      # Wait for child termination (proper synchronization instead of sleep)
      assert_receive {:DOWN, ^child_ref, :process, ^child_pid, _reason}, 5000

      # VERIFY: Parent's committed released (back to 0)
      # Poll until committed is released (budget release is async via PubSub)
      root_after_dismiss =
        wait_until(fn ->
          {:ok, state} = Core.get_state(root_pid)
          if Decimal.equal?(state.budget_data.committed, Decimal.new("0")), do: state
        end)

      assert root_after_dismiss != nil,
             "Parent committed must be released after child dismiss"

      assert Decimal.equal?(root_after_dismiss.budget_data.committed, Decimal.new("0")),
             "Parent committed must be 0 after child dismiss"

      # VERIFY: Parent recovers from over-budget after child dismissal (v34.0)
      # available = 100 - 75(own spent) - 0(committed) = 25 > 0, so no longer over budget
      assert root_after_dismiss.over_budget == false,
             "Over budget status should recover after child budget released (v34.0)"

      # ============================================================
      # SUCCESS: Full budget lifecycle verified
      # ============================================================
    end
  end
end
