defmodule Quoracle.Actions.SpawnBudgetTest do
  @moduledoc """
  Tests for ACTION_Spawn budget system.

  v13.0 (WorkGroupID: wip-20251231-budget):
  - Validation of parent budget sufficiency
  - Creation of child budget_data
  - Parent committed tracking

  v17.0 (WorkGroupID: fix-20260211-budget-enforcement, Packet 1):
  - Budget enforcement: budgeted parents MUST specify budget when spawning
  - R52-R58: Budget required validation and error guidance
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Spawn
  alias Quoracle.Actions.Spawn.BudgetValidation
  alias Quoracle.Agent.Core
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    # Subscribe to lifecycle events
    Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

    # Add spawn_complete_notify for async spawn completion tracking
    test_pid = self()
    deps = Map.put(deps, :spawn_complete_notify, test_pid)

    # Create test profile for spawn_child (required since v24.0)
    profile = create_test_profile()

    {:ok, deps: deps, profile: profile}
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

  # Helper to spawn a parent agent with budget
  defp spawn_parent_with_budget(deps, budget_data) do
    task_id = Ecto.UUID.generate()

    parent_config = %{
      agent_id: "parent-budget-#{System.unique_integer([:positive])}",
      task_id: task_id,
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: deps.sandbox_owner,
      pubsub: deps.pubsub,
      budget_data: budget_data,
      prompt_fields: %{
        provided: %{task_description: "Parent task"},
        injected: %{global_context: "", constraints: []},
        transformed: %{}
      },
      models: []
    }

    spawn_agent_with_cleanup(deps.dynsup, parent_config,
      registry: deps.registry,
      pubsub: deps.pubsub,
      sandbox_owner: deps.sandbox_owner
    )
  end

  # Helper to build spawn_opts with parent_config (prevents ConfigBuilder deadlock)
  # NOTE: Caller must add agent_pid separately to avoid Keyword.get returning wrong value
  defp build_spawn_opts(deps, parent_state) do
    parent_config = %{
      task_id: parent_state.task_id,
      prompt_fields: parent_state.prompt_fields,
      models: parent_state.models,
      sandbox_owner: deps.sandbox_owner,
      test_mode: true,
      pubsub: deps.pubsub,
      skip_auto_consensus: true
    }

    Map.to_list(deps) ++ [parent_config: parent_config]
  end

  describe "spawn_child with budget (v13.0)" do
    # R25: Spawn Without Budget Creates N/A Child [INTEGRATION]
    @tag :r25
    @tag :integration
    test "R25: child gets N/A budget when no budget specified", %{deps: deps, profile: profile} do
      # Create parent with budget
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      params = %{
        "task_description" => "Child without budget",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      spawn_opts = build_spawn_opts(deps, parent_state) ++ [agent_pid: parent_pid]

      # Act: Spawn child without budget parameter
      {:ok, result} = Spawn.execute(params, parent_state.agent_id, spawn_opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      assert child_pid, "Child should spawn"
      register_agent_cleanup(child_pid)

      # Assert: Child has N/A budget
      {:ok, child_state} = Core.get_state(child_pid)
      assert child_state.budget_data.mode == :na
      assert child_state.budget_data.allocated == nil
    end

    # R26: Spawn With Budget Creates Allocated Child [INTEGRATION]
    @tag :r26
    @tag :integration
    test "R26: child gets allocated budget from spawn param", %{deps: deps, profile: profile} do
      # Create parent with sufficient budget
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      params = %{
        "task_description" => "Child with budget",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "budget" => "50.00",
        "profile" => profile.name
      }

      spawn_opts = build_spawn_opts(deps, parent_state) ++ [agent_pid: parent_pid]

      # Act: Spawn child with budget
      {:ok, result} = Spawn.execute(params, parent_state.agent_id, spawn_opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      assert child_pid, "Child should spawn"
      register_agent_cleanup(child_pid)

      # Assert: Child has allocated budget
      {:ok, child_state} = Core.get_state(child_pid)
      assert child_state.budget_data.mode == :allocated
      assert Decimal.equal?(child_state.budget_data.allocated, Decimal.new("50.00"))
    end

    # R27: Insufficient Parent Budget Blocks Spawn [UNIT]
    @tag :r27
    @tag :unit
    test "R27: spawn fails when parent has insufficient budget", %{deps: deps, profile: profile} do
      # Create parent with limited budget
      parent_budget = %{mode: :root, allocated: Decimal.new("10.00"), committed: Decimal.new("0")}
      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      params = %{
        "task_description" => "Child needs more budget",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "budget" => "50.00",
        "profile" => profile.name
      }

      spawn_opts =
        build_spawn_opts(deps, parent_state) ++
          [
            agent_pid: parent_pid,
            budget_data: parent_budget,
            spent: Decimal.new("0")
          ]

      # Act: Attempt spawn with more budget than available
      result = Spawn.execute(params, parent_state.agent_id, spawn_opts)

      # Assert: Spawn blocked due to insufficient budget
      assert {:error, :insufficient_budget} = result
    end

    # R28: Parent Committed Increases on Spawn [INTEGRATION]
    @tag :r28
    @tag :integration
    test "R28: parent committed increases when child spawned with budget", %{
      deps: deps,
      profile: profile
    } do
      # Create parent with budget
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      # Verify initial committed is 0
      assert Decimal.equal?(parent_state.budget_data.committed, Decimal.new("0"))

      params = %{
        "task_description" => "Child with budget",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "budget" => "30.00",
        "profile" => profile.name
      }

      spawn_opts = build_spawn_opts(deps, parent_state) ++ [agent_pid: parent_pid]

      # Act: Spawn child with budget
      {:ok, result} = Spawn.execute(params, parent_state.agent_id, spawn_opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      assert child_pid, "Child should spawn"
      register_agent_cleanup(child_pid)

      # Assert: Parent committed is NOT updated by direct Spawn.execute
      # (v19.0: budget_committed update moved to handle_action_result in ActionExecutor pipeline)
      # Spawn returns budget_allocated in result so Core can update committed when processing result
      {:ok, updated_parent_state} = Core.get_state(parent_pid)
      assert Decimal.equal?(updated_parent_state.budget_data.committed, Decimal.new("0"))

      # Assert: Spawn result includes budget_allocated for Core to use
      assert result.budget_allocated == Decimal.new("30.00")
    end

    # R29: Invalid Budget Format Rejected [UNIT]
    @tag :r29
    @tag :unit
    test "R29: rejects invalid budget format", %{deps: deps, profile: profile} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      params = %{
        "task_description" => "Child with bad budget",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "budget" => "not-a-number",
        "profile" => profile.name
      }

      spawn_opts = build_spawn_opts(deps, parent_state) ++ [agent_pid: parent_pid]

      # Act: Attempt spawn with invalid budget format
      result = Spawn.execute(params, parent_state.agent_id, spawn_opts)

      # Assert: Rejected with error
      assert {:error, :invalid_budget_format} = result
    end

    # R30: Zero Budget Rejected [UNIT]
    @tag :r30
    @tag :unit
    test "R30: rejects zero or negative budget", %{deps: deps, profile: profile} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      # Test zero budget
      params_zero = %{
        "task_description" => "Child with zero budget",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "budget" => "0",
        "profile" => profile.name
      }

      spawn_opts = build_spawn_opts(deps, parent_state) ++ [agent_pid: parent_pid]

      result_zero = Spawn.execute(params_zero, parent_state.agent_id, spawn_opts)
      assert {:error, :invalid_budget_format} = result_zero

      # Test negative budget
      params_negative = %{
        "task_description" => "Child with negative budget",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "budget" => "-10.00",
        "profile" => profile.name
      }

      result_negative = Spawn.execute(params_negative, parent_state.agent_id, spawn_opts)
      assert {:error, :invalid_budget_format} = result_negative
    end

    # R31: N/A Parent Can Spawn With Budget [INTEGRATION]
    @tag :r31
    @tag :integration
    test "R31: N/A parent can spawn child with budget", %{deps: deps, profile: profile} do
      # Create parent with N/A budget (unlimited)
      parent_budget = %{mode: :na, allocated: nil, committed: nil}
      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      params = %{
        "task_description" => "Child from unlimited parent",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "budget" => "1000.00",
        "profile" => profile.name
      }

      spawn_opts = build_spawn_opts(deps, parent_state) ++ [agent_pid: parent_pid]

      # Act: N/A parent spawns child with any budget amount
      {:ok, result} = Spawn.execute(params, parent_state.agent_id, spawn_opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      assert child_pid, "Child should spawn from N/A parent"
      register_agent_cleanup(child_pid)

      # Assert: Child has allocated budget even though parent is N/A
      {:ok, child_state} = Core.get_state(child_pid)
      assert child_state.budget_data.mode == :allocated
      assert Decimal.equal?(child_state.budget_data.allocated, Decimal.new("1000.00"))
    end
  end

  describe "budget enforcement for budgeted parents (v17.0)" do
    # R52: Budgeted Parent Must Specify Budget [UNIT]
    # Tests BudgetValidation.validate_and_check_budget/2 directly.
    # A parent with :root or :allocated budget mode MUST provide a budget param.
    @tag :r52
    @tag :unit
    test "R52: budgeted parent cannot spawn child without budget" do
      # Arrange: no budget in params, parent has :root budget in deps
      params_no_budget = %{}

      root_deps = %{
        budget_data: %{mode: :root, allocated: Decimal.new("100.00"), committed: Decimal.new("0")}
      }

      # Act & Assert: :root parent without budget param returns :budget_required
      assert {:error, :budget_required} =
               BudgetValidation.validate_and_check_budget(params_no_budget, root_deps)

      # Also test :allocated mode
      allocated_deps = %{
        budget_data: %{
          mode: :allocated,
          allocated: Decimal.new("50.00"),
          committed: Decimal.new("0")
        }
      }

      assert {:error, :budget_required} =
               BudgetValidation.validate_and_check_budget(params_no_budget, allocated_deps)
    end

    # R57: Error Message Contains Guidance [INTEGRATION]
    # The :budget_required error, when surfaced through Spawn.execute, should
    # return a descriptive string message (not just the atom) that guides the
    # LLM on what to do: include "budget" param and use "get_budget" to check funds.
    @tag :r57
    @tag :integration
    test "R57: budget_required error message guides LLM", %{deps: deps, profile: profile} do
      # Create parent with root budget (budgeted parent)
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      params = %{
        "task_description" => "Child without budget from budgeted parent",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
        # NOTE: No "budget" param - this is the bug scenario
      }

      # Include budget_data in opts so BudgetValidation can see parent's budget mode
      spawn_opts =
        build_spawn_opts(deps, parent_state) ++
          [
            agent_pid: parent_pid,
            budget_data: parent_budget
          ]

      # Act: Attempt spawn without budget from budgeted parent
      result = Spawn.execute(params, parent_state.agent_id, spawn_opts)

      # Assert: Error contains guidance for the LLM agent
      # The error should be a string message (not just atom) that mentions:
      # 1. "budget" - what's required
      # 2. "get_budget" - how to check available funds
      assert {:error, message} = result
      assert is_binary(message), "Error should be a descriptive string, got: #{inspect(message)}"
      assert message =~ "budget", "Error message should mention 'budget'"
      assert message =~ "get_budget", "Error message should mention 'get_budget' action"
    end

    # NOTE: R53 (N/A parent unchanged), R54 (nil budget unchanged), R55 (root + budget OK),
    # R56 (allocated + budget OK), R58 (acceptance) test existing behavior that already passes.
    # These will be added as regression tests during IMPLEMENT phase.
  end
end
