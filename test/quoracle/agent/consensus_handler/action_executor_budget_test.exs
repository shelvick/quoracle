defmodule Quoracle.Agent.ConsensusHandler.ActionExecutorBudgetTest do
  @moduledoc """
  Tests for budget_data and spent propagation through ActionExecutor.build_execute_opts/4.

  WorkGroupID: fix-20260211-budget-enforcement
  Packet: Packet 1 (Integration Gap - ActionExecutor Budget Propagation)

  The primary integration gap: ActionExecutor.build_execute_opts/4 must extract
  budget_data and spent from the parent agent's state and pass them as top-level
  keywords in opts to the Router/Spawn pipeline. Without this, BudgetValidation
  cannot see the parent's budget mode and thus cannot enforce budget requirements.

  Tests:
  - R59: build_execute_opts includes budget_data from state [UNIT]
  - R60: build_execute_opts includes spent from Tracker [UNIT]
  - R63: Budget enforcement works through real pipeline (budgeted parent, no budget param) [INTEGRATION]
  - R64: Acceptance - budgeted parent spawn through real pipeline [SYSTEM]

  Deferred to IMPLEMENT phase as TEST-FIXes (pass without fix, regression tests):
  - R61: build_execute_opts with nil budget_data omits key [UNIT]
  - R62: ActionExecutor -> Router -> Spawn pipeline propagates budget_data [INTEGRATION]
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core
  alias Quoracle.Budget.Tracker
  alias Quoracle.Costs.AgentCost
  alias Quoracle.Profiles.CapabilityGroups
  alias Quoracle.Tasks.Task, as: TaskSchema
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers
  import Test.IsolationHelpers, only: [poll_until: 2]

  # All capability groups (allows all actions including :spawn_child)
  @all_capability_groups CapabilityGroups.groups()

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    # Create shared task for cost records
    {:ok, task} =
      Repo.insert(%TaskSchema{
        id: Ecto.UUID.generate(),
        prompt: "action executor budget test",
        status: "running"
      })

    # Create test profile for spawn_child (required since v24.0)
    profile = create_test_profile()

    # Subscribe to lifecycle events for spawn tracking
    Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

    # Notify test pid for async spawn completion
    test_pid = self()
    deps = Map.put(deps, :spawn_complete_notify, test_pid)

    {:ok, deps: deps, task: task, profile: profile, test_pid: test_pid}
  end

  # Helper to spawn a parent agent with budget and capability_groups for spawn
  defp spawn_parent_with_budget(deps, task, budget_data) do
    agent_id = "parent-ae-#{System.unique_integer([:positive])}"

    config = %{
      agent_id: agent_id,
      task_id: task.id,
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: deps.sandbox_owner,
      pubsub: deps.pubsub,
      budget_data: budget_data,
      # Must include :hierarchy for spawn_child to pass ActionGate
      capability_groups: @all_capability_groups,
      # Pass spawn_complete_notify for async spawn synchronization
      spawn_complete_notify: Map.get(deps, :spawn_complete_notify),
      prompt_fields: %{
        provided: %{task_description: "Parent task"},
        injected: %{global_context: "", constraints: []},
        transformed: %{}
      },
      models: []
    }

    spawn_agent_with_cleanup(deps.dynsup, config,
      registry: deps.registry,
      pubsub: deps.pubsub,
      sandbox_owner: deps.sandbox_owner
    )
  end

  # Helper to insert a cost record for an agent
  defp insert_cost(agent_id, task_id, cost_usd) do
    {:ok, cost} =
      Repo.insert(
        AgentCost.changeset(%AgentCost{}, %{
          agent_id: agent_id,
          task_id: task_id,
          cost_type: "llm_consensus",
          cost_usd: cost_usd
        })
      )

    cost
  end

  # Helper to extract result entries from model histories
  # History entries use :type field (not :role)
  defp extract_result_entries(model_histories) do
    model_histories
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(fn entry ->
      Map.get(entry, :type) == :result
    end)
  end

  # Helper to look up child pid from registry by agent_id
  defp find_child_pid(child_id, registry) do
    case Registry.lookup(registry, child_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  # ============================================================================
  # R59: build_execute_opts includes budget_data from state [UNIT]
  #
  # Verifies that when a budgeted parent (:root mode) executes spawn_child
  # without a budget param through the ActionExecutor pipeline, the spawn
  # action receives the parent's budget_data and returns :budget_required.
  #
  # Currently fails because build_execute_opts does NOT extract budget_data.
  # ============================================================================

  describe "build_execute_opts budget_data propagation (R59)" do
    @tag :r59
    @tag :unit
    @tag capture_log: true
    test "R59: build_execute_opts extracts budget_data from state", %{
      deps: deps,
      task: task,
      profile: profile
    } do
      import Quoracle.Agent.ConsensusTestHelpers, only: [execute_and_collect_result: 2]

      # Arrange: Create parent with :root budget
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("20.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, task, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      # Verify parent has budget_data in state
      assert parent_state.budget_data.mode == :root

      # Act: Spawn child WITHOUT budget param through the real pipeline.
      # If budget_data IS propagated: BudgetValidation sees :root + no param -> :budget_required
      # If budget_data NOT propagated: BudgetValidation sees nil -> N/A child created (BUG)
      action_response = %{
        action: :spawn_child,
        params: %{
          task_description: "Test child from budgeted parent",
          success_criteria: "Complete",
          immediate_context: "Test",
          approach_guidance: "Standard",
          profile: profile.name
          # NOTE: No budget param - triggers budget_required if budget_data propagated
        },
        wait: false,
        reasoning: "Testing budget propagation"
      }

      test_state = %{
        parent_state
        | pending_actions: %{},
          action_counter: 0
      }

      # v35.0: Use async helper with self() as agent_pid (default).
      # Cast arrives at test process for collection. Budget error path doesn't
      # interact with real agent, so self() is safe.
      result = execute_and_collect_result(test_state, action_response)

      # Assert: The result history should contain a budget-related error
      result_entries = extract_result_entries(result.model_histories)

      assert result_entries != [],
             "Should have at least one result entry from spawn attempt"

      last_result = List.last(result_entries)

      assert match?({:error, _}, last_result.result),
             "Spawn should return {:error, reason} when " <>
               "budget_data is propagated. Got result: #{inspect(last_result.result)}. " <>
               "This indicates budget_data is NOT being propagated through build_execute_opts."

      {:error, error_reason} = last_result.result

      assert is_binary(error_reason) and error_reason =~ "Budget is required",
             "Error message should contain 'Budget is required'. Got: #{inspect(error_reason)}"
    end
  end

  # ============================================================================
  # R60: build_execute_opts includes spent from Tracker [UNIT]
  #
  # Verifies that when a budgeted parent with recorded costs attempts to spawn
  # a child requesting more budget than available (considering spent), the
  # spawn fails with :insufficient_budget.
  #
  # Currently fails because build_execute_opts does NOT query/pass spent.
  # ============================================================================

  describe "build_execute_opts spent propagation (R60)" do
    @tag :r60
    @tag :unit
    @tag capture_log: true
    test "R60: build_execute_opts includes spent amount from Tracker", %{
      deps: deps,
      task: task,
      profile: profile
    } do
      import Quoracle.Agent.ConsensusTestHelpers, only: [execute_and_collect_result: 2]

      # Arrange: Parent with $50 allocated and $40 spent -> $10 available
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("50.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, task, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      # Record costs so spent > 0
      _cost = insert_cost(parent_state.agent_id, task.id, Decimal.new("40.00"))

      # Verify spent is recorded in DB
      spent = Tracker.get_spent(parent_state.agent_id)
      assert Decimal.compare(spent, Decimal.new("0")) == :gt, "Costs should be recorded"

      # Act: Spawn child with budget=$20 (exceeds available = 50 - 40 - 0 = 10)
      action_response = %{
        action: :spawn_child,
        params: %{
          task_description: "Test child with budget",
          success_criteria: "Complete",
          immediate_context: "Test",
          approach_guidance: "Standard",
          profile: profile.name,
          budget: "20.00"
        },
        wait: false,
        reasoning: "Testing spent propagation"
      }

      test_state = %{
        parent_state
        | pending_actions: %{},
          action_counter: 0
      }

      # v35.0: Use async helper with self() as agent_pid (default).
      # Budget error path doesn't interact with real agent.
      result = execute_and_collect_result(test_state, action_response)

      # Assert: Should fail with :insufficient_budget
      result_entries = extract_result_entries(result.model_histories)
      assert result_entries != [], "Should have at least one result entry"

      last_result = List.last(result_entries)

      assert match?({:error, :insufficient_budget}, last_result.result),
             "Spawn should fail with {:error, :insufficient_budget} when spent ($40) " <>
               "is propagated. Available should be $10 (50-40-0), but requested $20. " <>
               "Got result: #{inspect(last_result.result)}. " <>
               "This indicates spent is NOT being propagated through build_execute_opts."
    end
  end

  # NOTE: R61 (nil budget_data graceful handling) and R62 (valid budgeted spawn succeeds)
  # are deferred to IMPLEMENT phase as TEST-FIXes. They test existing behavior that
  # passes without the fix (regression tests), violating the TEST phase rule that
  # ALL new tests must fail.

  # ============================================================================
  # R63: Budget enforcement through real pipeline [INTEGRATION]
  #
  # The key integration test: budgeted parent, no budget param.
  # If budget_data is propagated: :budget_required error
  # If budget_data NOT propagated: spawn succeeds with N/A child (BUG)
  #
  # Currently FAILS because build_execute_opts does NOT include budget_data.
  # ============================================================================

  describe "budget enforcement through pipeline (R63)" do
    @tag :r63
    @tag :integration
    @tag capture_log: true
    test "R63: budgeted parent without budget param fails through ActionExecutor pipeline", %{
      deps: deps,
      task: task,
      profile: profile
    } do
      import Quoracle.Agent.ConsensusTestHelpers, only: [execute_and_collect_result: 2]

      # Arrange: Parent with :root budget
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, task, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      # Act: Attempt spawn WITHOUT budget param through real pipeline
      action_response = %{
        action: :spawn_child,
        params: %{
          task_description: "Child without budget from budgeted parent",
          success_criteria: "Complete",
          immediate_context: "Test",
          approach_guidance: "Standard",
          profile: profile.name
          # NOTE: No budget param - this is the key scenario
        },
        wait: false,
        reasoning: "Testing budget enforcement through pipeline"
      }

      test_state = %{
        parent_state
        | pending_actions: %{},
          action_counter: 0
      }

      # v35.0: Use async helper with self() as agent_pid (default).
      # Budget error path doesn't interact with real agent.
      result_state = execute_and_collect_result(test_state, action_response)

      # Assert: Should contain budget-related error
      result_entries = extract_result_entries(result_state.model_histories)
      assert result_entries != [], "Should have result entry from spawn attempt"

      last_result = List.last(result_entries)

      assert match?({:error, _}, last_result.result),
             "Budgeted parent spawning without budget param should get {:error, reason} " <>
               "through the real ActionExecutor pipeline. " <>
               "Got result: #{inspect(last_result.result)}. " <>
               "This proves budget_data is NOT being propagated through build_execute_opts."

      {:error, error_reason} = last_result.result

      assert is_binary(error_reason) and error_reason =~ "Budget is required",
             "Error message should contain 'Budget is required'. Got: #{inspect(error_reason)}"
    end
  end

  # ============================================================================
  # R64: Acceptance - budgeted parent spawn through real pipeline [SYSTEM]
  #
  # Full end-to-end test exercising ActionExecutor -> Router -> Spawn pipeline
  # (not calling Spawn.execute directly with hand-crafted opts).
  #
  # Steps:
  # 1. Create budgeted parent agent
  # 2. Spawn child WITH budget through ActionExecutor pipeline
  # 3. Verify child has correct budget
  # 4. Verify parent's committed increased
  # 5. Verify insufficient budget enforcement (spent considered)
  #
  # Steps 3-5 FAIL because budget_data and spent are not propagated.
  # ============================================================================

  describe "acceptance test - real pipeline (R64)" do
    @tag :r64
    @tag :acceptance
    @tag :system
    @tag capture_log: true
    test "R64: end-to-end budgeted parent spawns child through ActionExecutor pipeline", %{
      deps: deps,
      task: task,
      profile: profile
    } do
      alias Quoracle.Agent.ConsensusHandler.ActionExecutor

      # STEP 1: Create budgeted parent agent
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, task, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      # Record some parent costs (to verify spent is also propagated)
      _cost = insert_cost(parent_state.agent_id, task.id, Decimal.new("15.00"))

      # STEP 2: Spawn child WITH budget through ActionExecutor pipeline
      # v35.0: Must use real parent_pid as agent_pid because Spawn.execute uses
      # opts[:agent_pid] for parent_pid → GenServer.call(parent_pid, :update_budget_committed).
      # Cannot use execute_and_collect_result here; dispatch directly and observe outcomes.
      action_response = %{
        action: :spawn_child,
        params: %{
          task_description: "Acceptance test child with budget",
          success_criteria: "Complete acceptance test",
          immediate_context: "Testing real pipeline",
          approach_guidance: "Standard approach",
          profile: profile.name,
          budget: "30.00"
        },
        wait: false,
        reasoning: "Acceptance test for budget propagation through ActionExecutor"
      }

      test_state = %{
        parent_state
        | pending_actions: %{},
          action_counter: 0
      }

      # v35.0: Dispatch with real parent_pid so budget escrow works through the
      # real agent GenServer. The cast goes to parent_pid; we observe via spawn_complete.
      # v36.0: Register pending_action on parent BEFORE dispatch completes, so that
      # {:action_result, ...} cast is recognized by handle_action_result (not rejected as unknown).
      # In production, execute_consensus_action runs inside the GenServer callback, so the
      # pending_action is part of the state. In this test, we simulate that.
      action_id = "action_#{parent_state.agent_id}_1"
      Core.add_pending_action(parent_pid, action_id, :spawn_child, action_response.params)

      _dispatched =
        ActionExecutor.execute_consensus_action(test_state, action_response, parent_pid)

      # Wait for spawn_complete notification (fires AFTER background spawn)
      assert_receive {:spawn_complete, child_agent_id, {:ok, _child_pid}}, 10_000

      # Look up child pid from registry and register cleanup
      child_pid = find_child_pid(child_agent_id, deps.registry)
      if child_pid, do: register_agent_cleanup(child_pid)

      # STEP 3: Verify parent's committed increased after child spawn with budget.
      # RACE CONDITION FIX: spawn_complete fires BEFORE the Task.Supervisor child
      # sends {:action_result, ...} cast to Core. The action_result cast triggers
      # maybe_update_budget_committed which updates budget_data.committed. A single
      # Core.get_state call after spawn_complete may return before the cast is processed.
      # Poll until committed updates (event-based sync via GenServer.call serialization).
      assert :ok =
               poll_until(
                 fn ->
                   {:ok, s} = Core.get_state(parent_pid)
                   not Decimal.equal?(s.budget_data.committed, Decimal.new("0"))
                 end,
                 10_000
               ),
             "Parent committed should NOT remain at $0 after spawning child with $30 budget. " <>
               "Committed=$0 means escrow (lock_allocation) never happened, which means " <>
               "budget_data was not propagated through build_execute_opts."

      {:ok, updated_parent_state} = Core.get_state(parent_pid)

      assert Decimal.equal?(updated_parent_state.budget_data.committed, Decimal.new("30.00")),
             "Parent committed should increase by $30.00 after child spawn. " <>
               "Got committed=#{updated_parent_state.budget_data.committed}. " <>
               "This fails because budget_data is not propagated through build_execute_opts, " <>
               "so escrow (lock_allocation) never happens."

      # STEP 4: Verify insufficient budget enforcement through pipeline
      # With committed=$30 and spent=$15: available = 100 - 15 - 30 = 55
      # Request $60 -> should fail with :insufficient_budget if spent is propagated
      action_response_2 = %{
        action: :spawn_child,
        params: %{
          task_description: "Second child exceeding budget",
          success_criteria: "Complete",
          immediate_context: "Test",
          approach_guidance: "Standard",
          profile: profile.name,
          budget: "60.00"
        },
        wait: false,
        reasoning: "Testing insufficient budget through pipeline"
      }

      test_state_2 = %{
        updated_parent_state
        | pending_actions: %{},
          action_counter: test_state.action_counter + 1
      }

      # v36.0: Dispatch second spawn and directly receive the result cast.
      # Using direct receive instead of execute_and_collect_result because
      # the helper processes inherited model_histories which masks the actual result.
      _dispatched_state_2 =
        ActionExecutor.execute_consensus_action(test_state_2, action_response_2, self())

      assert_receive {:"$gen_cast", {:action_result, _action_id_2, result_2, _opts_2}}, 10_000

      assert match?({:error, :insufficient_budget}, result_2),
             "Second spawn should fail with {:error, :insufficient_budget} when spent ($15) " <>
               "is considered. Available should be $55 (100-15-30), but requested $60. " <>
               "Got result: #{inspect(result_2)}"
    end
  end
end
