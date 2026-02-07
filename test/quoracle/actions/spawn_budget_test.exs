defmodule Quoracle.Actions.SpawnBudgetTest do
  @moduledoc """
  Tests for ACTION_Spawn v13.0 - Budget Escrow for Child Spawn.

  WorkGroupID: wip-20251231-budget
  Packet: Packet 8 (Spawn/Dismiss/Manager)

  Tests budget allocation during spawn_child action:
  - Validation of parent budget sufficiency
  - Creation of child budget_data
  - Parent committed tracking
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Spawn
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

      on_exit(fn ->
        if child_pid && Process.alive?(child_pid) do
          try do
            GenServer.stop(child_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

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

      on_exit(fn ->
        if child_pid && Process.alive?(child_pid) do
          try do
            GenServer.stop(child_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

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

      on_exit(fn ->
        if child_pid && Process.alive?(child_pid) do
          try do
            GenServer.stop(child_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Assert: Parent's committed increased by child's budget
      {:ok, updated_parent_state} = Core.get_state(parent_pid)
      assert Decimal.equal?(updated_parent_state.budget_data.committed, Decimal.new("30.00"))
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

      on_exit(fn ->
        if child_pid && Process.alive?(child_pid) do
          try do
            GenServer.stop(child_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Assert: Child has allocated budget even though parent is N/A
      {:ok, child_state} = Core.get_state(child_pid)
      assert child_state.budget_data.mode == :allocated
      assert Decimal.equal?(child_state.budget_data.allocated, Decimal.new("1000.00"))
    end
  end
end
