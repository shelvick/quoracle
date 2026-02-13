defmodule Quoracle.Agent.Packet2SafetyTest do
  @moduledoc """
  Tests for Packet 2 (Safety) of WorkGroupID: fix-20260212-action-deadlock.

  This packet eliminates deadlock-causing callbacks from the action execution
  pipeline:

  1. FIX_SpawnFailedHandler (R1-R5): Handle {:spawn_failed, ...} in Core
  2. FIX_BudgetCallbackElimination (R1-R6): Remove Core.update_budget_committed
     callback from Spawn, update budget_committed via result processing,
     use opts[:parent_config] in AdjustBudget
  3. ACTION_Spawn v19.0 (R65-R67): Remove blocking callback from spawn
  4. ACTION_AdjustBudget v2.0 (R11-R12): Use opts[:parent_config] for parent state

  ARC Verification Criteria covered:
  - FIX_SpawnFailedHandler: R1-R5
  - FIX_BudgetCallbackElimination: R1-R6
  - ACTION_Spawn v19.0: R65-R67
  - ACTION_AdjustBudget v2.0: R11-R12
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core
  alias Quoracle.Agent.Core.MessageInfoHandler
  alias Quoracle.Agent.MessageHandler
  alias Quoracle.Actions.AdjustBudget
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers

  # ============================================================================
  # Setup
  # ============================================================================

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    # Subscribe to lifecycle events
    Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

    base_state = %{
      agent_id: "agent-p2-#{System.unique_integer([:positive])}",
      task_id: "task-#{System.unique_integer([:positive])}",
      pending_actions: %{},
      model_histories: %{"test-model" => []},
      children: [],
      wait_timer: nil,
      timer_generation: 0,
      action_counter: 0,
      state: :processing,
      context_summary: nil,
      context_limit: 4000,
      context_limits_loaded: true,
      additional_context: [],
      test_mode: true,
      skip_auto_consensus: true,
      skip_consensus: true,
      pubsub: deps.pubsub,
      registry: deps.registry,
      dynsup: deps.dynsup,
      sandbox_owner: sandbox_owner,
      queued_messages: [],
      consensus_scheduled: false,
      budget_data: %{mode: :root, allocated: Decimal.new("100.00"), committed: Decimal.new("0")},
      over_budget: false,
      dismissing: false,
      capability_groups: [],
      consensus_retry_count: 0,
      prompt_fields: nil,
      system_prompt: nil,
      active_skills: [],
      todos: [],
      parent_pid: nil
    }

    %{state: base_state, deps: deps, sandbox_owner: sandbox_owner}
  end

  # ============================================================================
  # FIX_SpawnFailedHandler - R1: Handler Exists
  # [UNIT] WHEN Core receives {:spawn_failed, data} THEN does not crash
  #
  # FAILS: No handle_info({:spawn_failed, ...}) clause in Core, and no
  # handle_spawn_failed function in MessageInfoHandler.
  # ============================================================================

  describe "R1: spawn_failed handler exists" do
    test "handle_info spawn_failed does not crash agent",
         %{state: state} do
      data = %{
        child_id: "child-failed-1",
        reason: :timeout,
        task: "Do something important"
      }

      # This should not crash. Currently there is no handle_spawn_failed
      # function in MessageInfoHandler, so this will fail.
      {:noreply, _new_state} = MessageInfoHandler.handle_spawn_failed(data, state)
    end
  end

  # ============================================================================
  # FIX_SpawnFailedHandler - R2: Failure Recorded in History
  # [UNIT] WHEN spawn_failed received THEN failure message added to history
  #
  # FAILS: handle_spawn_failed does not exist yet.
  # ============================================================================

  describe "R2: spawn_failed records history" do
    test "spawn_failed adds failure to history",
         %{state: state} do
      data = %{
        child_id: "child-failed-2",
        reason: :budget_required,
        task: "Research something"
      }

      {:noreply, new_state} = MessageInfoHandler.handle_spawn_failed(data, state)

      # Check that the failure was recorded in model histories
      histories = new_state.model_histories
      assert map_size(histories) > 0

      # Find the failure entry in any model's history
      has_failure_entry =
        Enum.any?(histories, fn {_model_id, history} ->
          Enum.any?(history, fn entry ->
            entry.type == :result and
              is_binary(entry.content) and
              String.contains?(entry.content, "child-failed-2")
          end)
        end)

      assert has_failure_entry,
             "Expected failure entry in history mentioning child_id"
    end
  end

  # ============================================================================
  # FIX_SpawnFailedHandler - R3: Child Removed from Children
  # [UNIT] WHEN spawn_failed received IF child was in children list
  # THEN child removed
  #
  # FAILS: handle_spawn_failed does not exist yet.
  # ============================================================================

  describe "R3: spawn_failed removes child" do
    test "spawn_failed removes child from children list",
         %{state: state} do
      child_id = "child-to-remove-#{System.unique_integer([:positive])}"

      # Pre-populate children list with the child that will fail
      state = %{
        state
        | children: [
            %{agent_id: child_id, spawned_at: DateTime.utc_now()},
            %{agent_id: "other-child", spawned_at: DateTime.utc_now()}
          ]
      }

      data = %{
        child_id: child_id,
        reason: {:spawn_crashed, "Config build failed"},
        task: "Failed task"
      }

      {:noreply, new_state} = MessageInfoHandler.handle_spawn_failed(data, state)

      # Child should be removed
      child_ids = Enum.map(new_state.children, & &1.agent_id)
      refute child_id in child_ids, "Failed child should be removed from children"
      assert "other-child" in child_ids, "Other children should remain"
    end
  end

  # ============================================================================
  # FIX_SpawnFailedHandler - R4: Consensus Continues
  # [UNIT] WHEN spawn_failed received THEN consensus continuation scheduled
  #
  # FAILS: handle_spawn_failed does not exist yet.
  # ============================================================================

  describe "R4: spawn_failed continues consensus" do
    test "spawn_failed schedules consensus continuation",
         %{state: state} do
      data = %{
        child_id: "child-failed-4",
        reason: :timeout,
        task: "Task that timed out"
      }

      {:noreply, new_state} = MessageInfoHandler.handle_spawn_failed(data, state)

      # Consensus should be scheduled so agent can react to the failure
      assert new_state.consensus_scheduled == true,
             "consensus_scheduled should be set to true after spawn_failed"
    end
  end

  # ============================================================================
  # FIX_SpawnFailedHandler - R5: No Children to Remove
  # [UNIT] WHEN spawn_failed received IF child NOT in children list
  # THEN children unchanged
  #
  # FAILS: handle_spawn_failed does not exist yet.
  # ============================================================================

  describe "R5: spawn_failed unknown child" do
    test "spawn_failed with unknown child leaves children unchanged",
         %{state: state} do
      # Pre-populate children with some OTHER children
      state = %{
        state
        | children: [
            %{agent_id: "existing-child-1", spawned_at: DateTime.utc_now()},
            %{agent_id: "existing-child-2", spawned_at: DateTime.utc_now()}
          ]
      }

      data = %{
        child_id: "never-tracked-child",
        reason: :budget_required,
        task: "Unknown task"
      }

      {:noreply, new_state} = MessageInfoHandler.handle_spawn_failed(data, state)

      # Children should be unchanged
      assert length(new_state.children) == 2
      child_ids = Enum.map(new_state.children, & &1.agent_id)
      assert "existing-child-1" in child_ids
      assert "existing-child-2" in child_ids
    end
  end

  # ============================================================================
  # FIX_BudgetCallbackElimination - R1: Spawn No Longer Calls
  # Core.update_budget_committed
  # [UNIT] WHEN spawn executes successfully THEN does NOT call
  # Core.update_budget_committed
  #
  # FAILS: Current spawn.ex line 297 still calls
  # Core.update_budget_committed(parent_pid, budget_result.escrow_amount)
  # ============================================================================

  describe "R65: spawn no budget callback" do
    test "spawn does not call Core.update_budget_committed",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      # Create parent agent with budget
      parent_agent_config = %{
        agent_id: "parent-no-callback-#{System.unique_integer([:positive])}",
        task_id: Ecto.UUID.generate(),
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        budget_data: %{mode: :root, allocated: Decimal.new("100.00"), committed: Decimal.new("0")},
        prompt_fields: %{
          provided: %{task_description: "Parent task"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: [],
        capability_groups: [:hierarchy]
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, parent_agent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Get initial committed state
      {:ok, initial_state} = Core.get_state(parent_pid)
      initial_committed = initial_state.budget_data.committed

      # Create a profile for the child spawn
      profile = create_test_profile()

      # Build parent_config for ConfigBuilder (prevents GenServer.call back to Core)
      parent_config_for_spawn = %{
        task_id: initial_state.task_id,
        prompt_fields: initial_state.prompt_fields,
        models: initial_state.models,
        sandbox_owner: sandbox_owner,
        test_mode: true,
        pubsub: deps.pubsub,
        skip_auto_consensus: true
      }

      # Execute spawn via Spawn.execute directly with budget
      spawn_result =
        Quoracle.Actions.Spawn.execute(
          %{
            "task_description" => "Test task for child",
            "success_criteria" => "Complete",
            "immediate_context" => "Test",
            "approach_guidance" => "Standard",
            "profile" => profile.name,
            "budget" => "30.00"
          },
          initial_state.agent_id,
          agent_pid: parent_pid,
          registry: deps.registry,
          dynsup: deps.dynsup,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner,
          budget_data: initial_state.budget_data,
          spent: Decimal.new("0"),
          spawn_complete_notify: self(),
          parent_config: parent_config_for_spawn
        )

      assert {:ok, %{agent_id: child_id}} = spawn_result

      # Wait for background spawn to complete
      assert_receive {:spawn_complete, ^child_id, {:ok, child_pid}}, 30_000
      register_agent_cleanup(child_pid)

      # After spawn, get parent's state directly
      {:ok, post_state} = Core.get_state(parent_pid)

      # The committed budget should NOT have been updated by Spawn's
      # Core.update_budget_committed callback.
      # Currently FAILS because spawn.ex:297 calls Core.update_budget_committed.
      # After fix: budget_committed stays at initial value because the update
      # is deferred to result processing in handle_action_result.
      assert Decimal.equal?(post_state.budget_data.committed, initial_committed),
             "Spawn should NOT update budget_committed via callback. " <>
               "Expected #{initial_committed}, got #{post_state.budget_data.committed}"
    end
  end

  # ============================================================================
  # ACTION_Spawn v19.0 - R66: Child Spawned Cast Preserved
  # [UNIT] WHEN spawn_child succeeds THEN still sends {:child_spawned, ...}
  # cast to parent
  #
  # This tests that the {:child_spawned, ...} cast is NOT removed along with
  # the budget_committed callback. Should pass with current implementation
  # (the cast is already there), but verifies it's preserved after the fix.
  # ============================================================================

  describe "R66: child_spawned cast preserved" do
    test "spawn still sends child_spawned cast to parent",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      parent_config = %{
        agent_id: "parent-cast-#{System.unique_integer([:positive])}",
        task_id: Ecto.UUID.generate(),
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        budget_data: nil,
        prompt_fields: %{
          provided: %{task_description: "Parent task"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: [],
        capability_groups: [:hierarchy]
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, initial_state} = Core.get_state(parent_pid)
      profile = create_test_profile()

      parent_config_for_spawn = %{
        task_id: initial_state.task_id,
        prompt_fields: initial_state.prompt_fields,
        models: initial_state.models,
        sandbox_owner: sandbox_owner,
        test_mode: true,
        pubsub: deps.pubsub,
        skip_auto_consensus: true
      }

      spawn_result =
        Quoracle.Actions.Spawn.execute(
          %{
            "task_description" => "Cast test child task",
            "success_criteria" => "Complete",
            "immediate_context" => "Test",
            "approach_guidance" => "Standard",
            "profile" => profile.name
          },
          initial_state.agent_id,
          agent_pid: parent_pid,
          registry: deps.registry,
          dynsup: deps.dynsup,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner,
          spawn_complete_notify: self(),
          parent_config: parent_config_for_spawn
        )

      assert {:ok, %{agent_id: child_id}} = spawn_result

      # Wait for background spawn to complete
      assert_receive {:spawn_complete, ^child_id, {:ok, child_pid}}, 30_000
      register_agent_cleanup(child_pid)

      # After spawn completes, parent should have received {:child_spawned, ...}
      # and tracked the child. Verify by checking parent's children list.
      {:ok, post_state} = Core.get_state(parent_pid)

      child_ids = Enum.map(post_state.children, & &1.agent_id)

      assert child_id in child_ids,
             "Parent should have tracked child via {:child_spawned, ...} cast"
    end
  end

  # ============================================================================
  # FIX_BudgetCallbackElimination - R2 / ACTION_Spawn v19.0 R67:
  # Budget Committed Updated on Spawn Result
  # [INTEGRATION] WHEN spawn_child result received by Core THEN
  # budget_data.committed increased by budget_allocated
  #
  # FAILS: Current handle_action_result does not update budget_committed
  # from spawn_child results. The update only happens via the
  # Core.update_budget_committed callback in spawn.ex:297.
  # ============================================================================

  describe "R67: result updates budget_committed" do
    test "spawn_child result updates budget_committed in Core",
         %{state: state} do
      action_id = "action_spawn_budget_1"
      budget_amount = Decimal.new("30.00")

      state = %{
        state
        | pending_actions: %{
            action_id => %{
              type: :spawn_child,
              params: %{profile: "researcher", budget: "30.00"},
              timestamp: DateTime.utc_now()
            }
          },
          budget_data: %{
            mode: :root,
            allocated: Decimal.new("100.00"),
            committed: Decimal.new("0")
          }
      }

      # Simulate spawn_child result with budget_allocated
      child_result = %{
        agent_id: "child-budget-#{System.unique_integer([:positive])}",
        spawned_at: DateTime.utc_now(),
        budget_allocated: budget_amount
      }

      opts = [
        action_atom: :spawn_child,
        wait_value: false,
        always_sync: true,
        action_response: %{
          action: :spawn_child,
          params: %{profile: "researcher", budget: "30.00"},
          wait: false
        }
      ]

      {:noreply, new_state} =
        MessageHandler.handle_action_result(
          state,
          action_id,
          {:ok, child_result},
          opts
        )

      # Budget committed should be updated by handle_action_result
      # FAILS: Current implementation does not update budget_committed
      # in handle_action_result — only via the (deadlocking) callback.
      assert Decimal.equal?(new_state.budget_data.committed, budget_amount),
             "budget_committed should be #{budget_amount}, " <>
               "got #{new_state.budget_data.committed}"
    end
  end

  # ============================================================================
  # FIX_BudgetCallbackElimination - R5: No Budget Update for Non-Budgeted Spawn
  # [UNIT] WHEN spawn_child result has nil budget_allocated THEN
  # budget_data unchanged
  #
  # FAILS: handle_action_result does not have budget update logic yet.
  # (Though nil case wouldn't crash, the test validates the full path exists.)
  # ============================================================================

  describe "R5-budget: nil budget leaves state" do
    test "spawn_child result with nil budget leaves budget unchanged",
         %{state: state} do
      action_id = "action_spawn_no_budget_1"

      state = %{
        state
        | pending_actions: %{
            action_id => %{
              type: :spawn_child,
              params: %{profile: "researcher"},
              timestamp: DateTime.utc_now()
            }
          },
          budget_data: %{
            mode: :root,
            allocated: Decimal.new("100.00"),
            committed: Decimal.new("10.00")
          }
      }

      # Spawn result WITHOUT budget_allocated
      child_result = %{
        agent_id: "child-no-budget-#{System.unique_integer([:positive])}",
        spawned_at: DateTime.utc_now(),
        budget_allocated: nil
      }

      opts = [
        action_atom: :spawn_child,
        wait_value: false,
        always_sync: true,
        action_response: %{
          action: :spawn_child,
          params: %{profile: "researcher"},
          wait: false
        }
      ]

      {:noreply, new_state} =
        MessageHandler.handle_action_result(
          state,
          action_id,
          {:ok, child_result},
          opts
        )

      # Budget should remain unchanged at 10.00
      assert Decimal.equal?(new_state.budget_data.committed, Decimal.new("10.00")),
             "Budget committed should remain 10.00 when budget_allocated is nil, " <>
               "got #{new_state.budget_data.committed}"
    end
  end

  # ============================================================================
  # ACTION_AdjustBudget v2.0 - R11: Uses opts Parent Config
  # [UNIT] WHEN adjust_budget executes with parent_config in opts THEN
  # uses opts state instead of Core.get_state
  #
  # FAILS: Current get_parent_state/2 always calls Core.get_state via
  # Registry lookup. It does not accept or check opts[:parent_config].
  # ============================================================================

  describe "R11: adjust_budget opts parent_config" do
    test "adjust_budget uses parent_config from opts",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      parent_id = "parent-adj-opts-#{System.unique_integer([:positive])}"
      child_id = "child-adj-opts-#{System.unique_integer([:positive])}"

      # Spawn a child agent with budget that we can adjust
      child_config = %{
        agent_id: child_id,
        task_id: Ecto.UUID.generate(),
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        budget_data: %{
          mode: :allocated,
          allocated: Decimal.new("50.00"),
          committed: Decimal.new("0")
        },
        prompt_fields: %{
          provided: %{task_description: "Child task"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: [],
        capability_groups: []
      }

      {:ok, _child_pid} =
        spawn_agent_with_cleanup(deps.dynsup, child_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Create a fake parent state to pass via parent_config
      # (parent is NOT a running GenServer — this is the point)
      fake_parent_state = %{
        agent_id: parent_id,
        children: [%{agent_id: child_id, spawned_at: DateTime.utc_now()}],
        budget_data: %{
          mode: :root,
          allocated: Decimal.new("200.00"),
          committed: Decimal.new("50.00")
        }
      }

      # Execute adjust_budget with parent_config in opts
      # FAILS: current get_parent_state/2 ignores opts, looks up Registry,
      # and fails because parent_id is not registered.
      result =
        AdjustBudget.execute(
          %{child_id: child_id, new_budget: 60},
          parent_id,
          registry: deps.registry,
          parent_config: fake_parent_state
        )

      # Should succeed using the fake parent state from opts
      assert {:ok, %{action: "adjust_budget", child_id: ^child_id}} = result
    end
  end

  # ============================================================================
  # ACTION_AdjustBudget v2.0 - R12: Fallback to Registry
  # [INTEGRATION] WHEN adjust_budget executes without parent_config in opts
  # THEN falls back to Registry lookup
  #
  # This should pass with current implementation (tests existing behavior).
  # After the fix, the fallback path should still work.
  # ============================================================================

  describe "R12: adjust_budget Registry fallback" do
    test "adjust_budget falls back to Registry lookup without parent_config",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      # Spawn a real parent agent with budget
      parent_config = %{
        agent_id: "parent-adj-fallback-#{System.unique_integer([:positive])}",
        task_id: Ecto.UUID.generate(),
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        budget_data: %{mode: :root, allocated: Decimal.new("200.00"), committed: Decimal.new("0")},
        prompt_fields: %{
          provided: %{task_description: "Parent task"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: [],
        capability_groups: [:hierarchy]
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, parent_state} = Core.get_state(parent_pid)
      parent_id = parent_state.agent_id

      # Spawn child under parent
      child_id = "child-adj-fb-#{System.unique_integer([:positive])}"

      child_config = %{
        agent_id: child_id,
        task_id: Ecto.UUID.generate(),
        parent_id: parent_id,
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        budget_data: %{
          mode: :allocated,
          allocated: Decimal.new("50.00"),
          committed: Decimal.new("0")
        },
        prompt_fields: %{
          provided: %{task_description: "Child task"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: [],
        capability_groups: []
      }

      {:ok, _child_pid} =
        spawn_agent_with_cleanup(deps.dynsup, child_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Register child in parent's children list via cast
      GenServer.cast(
        parent_pid,
        {:child_spawned, %{agent_id: child_id, spawned_at: DateTime.utc_now()}}
      )

      # Wait for cast to be processed
      {:ok, _state} = Core.get_state(parent_pid)

      # Execute WITHOUT parent_config — should use Registry fallback
      result =
        AdjustBudget.execute(
          %{child_id: child_id, new_budget: 60},
          parent_id,
          registry: deps.registry
        )

      # Should succeed via Registry lookup (existing behavior)
      assert {:ok, %{action: "adjust_budget", child_id: ^child_id}} = result
    end
  end

  # ============================================================================
  # FIX_BudgetCallbackElimination - R3: AdjustBudget Uses opts Parent Config
  # (Same as R11, tested above - shared requirement)
  # ============================================================================

  # ============================================================================
  # FIX_BudgetCallbackElimination - R4: AdjustBudget Fallback Works
  # (Same as R12, tested above - shared requirement)
  # ============================================================================

  # ============================================================================
  # FIX_BudgetCallbackElimination - R6: Escrow Still Locked Before Spawn
  # [INTEGRATION] WHEN spawn_child dispatched THEN
  # Escrow.lock_budget_for_spawn called before dispatch (unchanged)
  #
  # This validates the escrow lock is preserved. The escrow lock happens
  # BEFORE the background spawn, and that behavior should not change.
  # This test should pass with current implementation.
  # ============================================================================

  describe "R6: escrow locked before spawn" do
    test "escrow locked before spawn dispatch",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      parent_config = %{
        agent_id: "parent-escrow-#{System.unique_integer([:positive])}",
        task_id: Ecto.UUID.generate(),
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        budget_data: %{mode: :root, allocated: Decimal.new("100.00"), committed: Decimal.new("0")},
        prompt_fields: %{
          provided: %{task_description: "Parent task"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: [],
        capability_groups: [:hierarchy]
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, parent_state} = Core.get_state(parent_pid)
      profile = create_test_profile()

      parent_config_for_spawn = %{
        task_id: parent_state.task_id,
        prompt_fields: parent_state.prompt_fields,
        models: parent_state.models,
        sandbox_owner: sandbox_owner,
        test_mode: true,
        pubsub: deps.pubsub,
        skip_auto_consensus: true
      }

      # Try to spawn a child with budget larger than available
      spawn_result =
        Quoracle.Actions.Spawn.execute(
          %{
            "task_description" => "Escrow test task",
            "success_criteria" => "Complete",
            "immediate_context" => "Test",
            "approach_guidance" => "Standard",
            "profile" => profile.name,
            "budget" => "999.00"
          },
          parent_state.agent_id,
          agent_pid: parent_pid,
          registry: deps.registry,
          dynsup: deps.dynsup,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner,
          budget_data: parent_state.budget_data,
          spent: Decimal.new("0"),
          parent_config: parent_config_for_spawn
        )

      # Should fail because escrow validation (lock_budget_for_spawn)
      # checks that parent has sufficient budget BEFORE spawning
      assert {:error, :insufficient_budget} = spawn_result
    end
  end

  # ============================================================================
  # AGENT_Core v35.0 R1: Spawn Failed Delegation
  # [UNIT] WHEN Core receives {:spawn_failed, data} THEN delegates to
  # MessageInfoHandler.handle_spawn_failed
  #
  # FAILS: No handle_info({:spawn_failed, ...}) clause in Core.
  # Sending the message would cause a FunctionClauseError.
  # ============================================================================

  describe "R1-core: spawn_failed delegation" do
    test "Core handles spawn_failed without crashing",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      agent_config = %{
        agent_id: "agent-sf-delegation-#{System.unique_integer([:positive])}",
        task_id: Ecto.UUID.generate(),
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        budget_data: nil,
        prompt_fields: %{
          provided: %{task_description: "Test task"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: [],
        capability_groups: []
      }

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, agent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Send spawn_failed message directly to the Core GenServer
      spawn_failed_data = %{
        child_id: "failed-child-gen",
        reason: :timeout,
        task: "Background task that failed"
      }

      send(agent_pid, {:spawn_failed, spawn_failed_data})

      # Agent should still be alive after processing the message.
      # FAILS: No matching handle_info clause → FunctionClauseError → crash
      # Use get_state as a synchronization point (call after the info message)
      assert {:ok, _state} = Core.get_state(agent_pid),
             "Agent should still be alive after receiving spawn_failed"

      assert Process.alive?(agent_pid),
             "Agent process should not have crashed from spawn_failed"
    end
  end
end
