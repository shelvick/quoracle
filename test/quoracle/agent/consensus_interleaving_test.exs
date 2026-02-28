defmodule Quoracle.Agent.ConsensusInterleavingTest do
  @moduledoc """
  Tests for consensus interleaving deferral (v27.0)

  WorkGroupID: fix-20260221-consensus-interleaving
  Packet: 1 (Single Packet)

  Bug: When multiple actions are in pending_actions simultaneously (e.g., async
  shell Phase 1 retains entry while a new action is dispatched), results from
  different rounds can interleave. A stale result (e.g., check_id error) can
  trigger consensus before the current round's fast self_contained action
  (e.g., batch_sync with todo + file_read) completes. This causes:
  1. TODO updates invisible (the {:update_todos} cast hasn't been processed yet)
  2. File read results missing from history
  3. LLM sees stale error as latest context

  Fix: Before calling schedule_consensus_continuation, check if any remaining
  pending_actions entries are self_contained. If so, skip the trigger — the
  self_contained action will complete imminently and trigger consensus with all
  effects visible.

  ARC Verification Criteria: R60-R64 (predicate), R200-R207 (deferral + integration + system)
  """

  use Quoracle.DataCase, async: true

  import Test.AgentTestHelpers

  alias Quoracle.Agent.ConsensusHandler.Helpers
  alias Quoracle.Agent.MessageHandler
  alias Quoracle.Agent.Core

  alias Test.IsolationHelpers

  @moduletag capture_log: true

  # ============================================================================
  # Setup
  # ============================================================================

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()

    # Base state for unit tests against ActionResultHandler directly.
    # Mirrors the pattern from action_executor_regressions_test.exs and
    # shell_phase2_lifecycle_test.exs.
    base_state = %{
      agent_id: "agent-interleave-#{System.unique_integer([:positive])}",
      task_id: "task-#{System.unique_integer([:positive])}",
      pending_actions: %{},
      model_histories: %{},
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
      budget_data: nil,
      over_budget: false,
      dismissing: false,
      capability_groups: [:hierarchy, :local_execution],
      consensus_retry_count: 0,
      prompt_fields: nil,
      system_prompt: nil,
      active_skills: [],
      todos: [],
      parent_pid: nil,
      active_routers: %{},
      shell_routers: %{}
    }

    %{state: base_state, deps: deps, sandbox_owner: sandbox_owner}
  end

  # Helper: create a pending_actions entry for a given action type
  defp pending_entry(type) do
    %{type: type, params: %{}, timestamp: DateTime.utc_now()}
  end

  # Helper: flush all messages from the process mailbox
  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # ============================================================================
  # [UNIT] R60-R64: Self-contained predicate
  # ============================================================================

  describe "[UNIT] R60-R64: Self-contained predicate" do
    test "R60: returns true when self_contained action is pending", %{state: state} do
      state_with_todo = %{
        state
        | pending_actions: %{
            "action-1" => pending_entry(:todo)
          }
      }

      assert Helpers.has_pending_self_contained?(state_with_todo)
    end

    test "R61: returns false when only non-self-contained actions pending", %{state: state} do
      state_with_non_sc = %{
        state
        | pending_actions: %{
            "action-1" => pending_entry(:execute_shell),
            "action-2" => pending_entry(:call_api)
          }
      }

      refute Helpers.has_pending_self_contained?(state_with_non_sc)
    end

    test "R62: returns false when pending_actions is empty", %{state: state} do
      state_empty = %{state | pending_actions: %{}}

      refute Helpers.has_pending_self_contained?(state_empty)
    end

    test "R63: detects all self_contained action types", %{state: state} do
      for action_type <- Helpers.self_contained_actions() do
        test_state = %{
          state
          | pending_actions: %{
              "action-#{action_type}" => pending_entry(action_type)
            }
        }

        assert Helpers.has_pending_self_contained?(test_state),
               "has_pending_self_contained? should return true for #{action_type}"
      end
    end

    test "R64: returns true with mixed pending actions containing self_contained", %{
      state: state
    } do
      state_mixed = %{
        state
        | pending_actions: %{
            "action-1" => pending_entry(:execute_shell),
            "action-2" => pending_entry(:file_read)
          }
      }

      # file_read is self_contained, so mixed map should return true
      assert Helpers.has_pending_self_contained?(state_mixed)
    end
  end

  # ============================================================================
  # [UNIT] R200-R204: Deferral guard
  # ============================================================================

  describe "[UNIT] R200-R204: Deferral guard" do
    test "R200: defers consensus when self_contained action is pending (wait:false path)", %{
      state: state
    } do
      action_id = "action-r200-#{System.unique_integer([:positive])}"

      # State: The current action's result just arrived, but there's a self_contained
      # action still pending (e.g., batch_sync dispatched concurrently)
      state = %{
        state
        | pending_actions: %{
            action_id => pending_entry(:execute_shell),
            "batch-sync-pending" => pending_entry(:batch_sync)
          }
      }

      opts = [
        action_atom: :execute_shell,
        wait_value: false,
        always_sync: false,
        action_response: %{action: :execute_shell, params: %{command: "echo hi"}, wait: false}
      ]

      flush_mailbox()

      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, action_id, {:ok, %{output: "hi"}}, opts)

      # BUG (current behavior): consensus IS scheduled even though batch_sync is pending
      # FIX: consensus should NOT be scheduled — defer until batch_sync completes
      refute new_state.consensus_scheduled,
             "Consensus should be deferred when self_contained action (batch_sync) is still pending"

      refute_receive :trigger_consensus,
                     50,
                     "Should not have sent :trigger_consensus when deferring"
    end

    test "R201: triggers consensus when only non-self-contained actions pending", %{
      state: state
    } do
      action_id = "action-r201-#{System.unique_integer([:positive])}"

      # State: Only non-self-contained actions remain after this result
      state = %{
        state
        | pending_actions: %{
            action_id => pending_entry(:todo),
            "shell-pending" => pending_entry(:execute_shell)
          }
      }

      opts = [
        action_atom: :todo,
        wait_value: false,
        always_sync: true,
        action_response: %{action: :todo, params: %{items: []}, wait: false}
      ]

      flush_mailbox()

      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, action_id, {:ok, %{items: []}}, opts)

      # After removing :todo from pending, only :execute_shell remains (non-self-contained)
      # Verify the predicate confirms no self_contained actions remain
      refute Helpers.has_pending_self_contained?(new_state),
             "No self_contained actions should remain in pending after :todo removed"

      # Consensus should trigger normally
      assert new_state.consensus_scheduled,
             "Consensus should be scheduled when only non-self-contained actions remain"
    end

    test "R202: triggers consensus when no pending actions remain (single-action flow)", %{
      state: state
    } do
      action_id = "action-r202-#{System.unique_integer([:positive])}"

      # State: Only the current action was pending (normal single-action flow)
      state = %{
        state
        | pending_actions: %{
            action_id => pending_entry(:orient)
          }
      }

      opts = [
        action_atom: :orient,
        wait_value: false,
        always_sync: true,
        action_response: %{
          action: :orient,
          params: %{situation_analysis: "Testing"},
          wait: false
        }
      ]

      flush_mailbox()

      {:noreply, new_state} =
        MessageHandler.handle_action_result(
          state,
          action_id,
          {:ok, %{situation_analysis: "Testing"}},
          opts
        )

      # Verify the predicate confirms no self_contained actions remain
      refute Helpers.has_pending_self_contained?(new_state),
             "No self_contained actions should remain after single action completes"

      # No regression: single-action flow still triggers consensus immediately
      assert new_state.consensus_scheduled,
             "Consensus should be scheduled when no pending actions remain (single-action regression)"
    end

    test "R203: defers consensus on default branch when self_contained pending", %{
      state: state
    } do
      action_id = "action-r203-#{System.unique_integer([:positive])}"

      # State: pending_actions has a self_contained entry
      # Use a weird wait_value that falls through to the default branch
      state = %{
        state
        | pending_actions: %{
            action_id => pending_entry(:execute_shell),
            "file-read-pending" => pending_entry(:file_read)
          }
      }

      opts = [
        action_atom: :execute_shell,
        wait_value: :unexpected_value,
        always_sync: false,
        action_response: %{
          action: :execute_shell,
          params: %{command: "echo default"},
          wait: :unexpected_value
        }
      ]

      flush_mailbox()

      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, action_id, {:ok, %{output: "default"}}, opts)

      # BUG: Default branch always triggers consensus
      # FIX: Default branch should also check for self_contained pending
      refute new_state.consensus_scheduled,
             "Consensus should be deferred on default branch when self_contained is pending"
    end

    test "R204: defers consensus on legacy path when self_contained pending", %{
      state: state
    } do
      action_id = "action-r204-#{System.unique_integer([:positive])}"

      # State: Legacy path has nil action_atom (no opts from non-blocking dispatch)
      # with a self_contained action still pending
      state = %{
        state
        | pending_actions: %{
            action_id => pending_entry(:execute_shell),
            "orient-pending" => pending_entry(:orient)
          }
      }

      # Legacy opts: no action_atom, no wait_value (pre-v35.0 path)
      opts = [continue: true]

      flush_mailbox()

      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, action_id, {:ok, %{output: "legacy"}}, opts)

      # BUG: Legacy path always triggers consensus when continue: true
      # FIX: Legacy path should also check for self_contained pending
      refute new_state.consensus_scheduled,
             "Consensus should be deferred on legacy path when self_contained is pending"
    end
  end

  # ============================================================================
  # [INTEGRATION] R205-R206: Completion flow
  # ============================================================================

  describe "[INTEGRATION] R205-R206: Completion flow" do
    test "R205: last self_contained action completion triggers consensus", %{state: state} do
      shell_action_id = "shell-r205-#{System.unique_integer([:positive])}"
      batch_action_id = "batch-r205-#{System.unique_integer([:positive])}"

      # State: Two pending actions — shell (non-SC) and batch_sync (SC)
      state = %{
        state
        | pending_actions: %{
            shell_action_id => pending_entry(:execute_shell),
            batch_action_id => pending_entry(:batch_sync)
          }
      }

      # Step 1: Shell result arrives first — should defer (batch_sync still pending)
      shell_opts = [
        action_atom: :execute_shell,
        wait_value: false,
        always_sync: false,
        action_response: %{action: :execute_shell, params: %{command: "echo 1"}, wait: false}
      ]

      flush_mailbox()

      {:noreply, state_after_shell} =
        MessageHandler.handle_action_result(
          state,
          shell_action_id,
          {:ok, %{output: "1"}},
          shell_opts
        )

      # Deferred: batch_sync is still pending
      refute state_after_shell.consensus_scheduled,
             "Consensus should be deferred while batch_sync is pending"

      # Step 2: Batch sync result arrives — now no SC actions pending, should trigger
      batch_opts = [
        action_atom: :batch_sync,
        wait_value: false,
        always_sync: true,
        action_response: %{action: :batch_sync, params: %{actions: []}, wait: false}
      ]

      {:noreply, state_after_batch} =
        MessageHandler.handle_action_result(
          state_after_shell,
          batch_action_id,
          {:ok, %{results: []}},
          batch_opts
        )

      # Triggered: no self_contained actions left
      assert state_after_batch.consensus_scheduled,
             "Consensus should trigger when last self_contained action completes"
    end

    test "R206: shell result deferred for batch_sync, triggers on completion", %{state: state} do
      # More specific scenario: shell result deferred specifically because
      # batch_sync is the self_contained action
      phase1_shell_id = "phase1-shell-r206-#{System.unique_integer([:positive])}"
      batch_id = "batch-r206-#{System.unique_integer([:positive])}"
      stale_check_id = "stale-check-r206-#{System.unique_integer([:positive])}"

      # State: Async shell Phase 1 entry retained + batch_sync dispatched + stale check_id
      state = %{
        state
        | pending_actions: %{
            # Retained Phase 1 entry (async shell still running)
            phase1_shell_id => pending_entry(:execute_shell),
            # Stale check_id action (will error immediately)
            stale_check_id => pending_entry(:execute_shell),
            # batch_sync just dispatched
            batch_id => pending_entry(:batch_sync)
          }
      }

      # Step 1: Stale check_id error arrives (fast — command_not_found)
      stale_opts = [
        action_atom: :execute_shell,
        wait_value: false,
        always_sync: false,
        action_response: %{
          action: :execute_shell,
          params: %{check_id: "nonexistent"},
          wait: false
        }
      ]

      flush_mailbox()

      {:noreply, state_after_stale} =
        MessageHandler.handle_action_result(
          state,
          stale_check_id,
          {:error, :command_not_found},
          stale_opts
        )

      # Deferred: batch_sync (self_contained) is still pending
      refute state_after_stale.consensus_scheduled,
             "Stale check_id error should not trigger consensus while batch_sync is pending"

      # Step 2: batch_sync completes
      batch_opts = [
        action_atom: :batch_sync,
        wait_value: false,
        always_sync: true,
        action_response: %{action: :batch_sync, params: %{actions: []}, wait: false}
      ]

      {:noreply, state_after_batch} =
        MessageHandler.handle_action_result(
          state_after_stale,
          batch_id,
          {:ok, %{results: []}},
          batch_opts
        )

      # Triggered: batch_sync completed, only non-SC shell Phase 1 remains
      assert state_after_batch.consensus_scheduled,
             "Consensus should trigger after batch_sync completes (only non-SC shell remaining)"
    end
  end

  # ============================================================================
  # [SYSTEM] R207: Interleaving fix
  # ============================================================================

  describe "[SYSTEM] R207: Interleaving fix" do
    test "stale check_id deferred until batch_sync completes", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # End-to-end test with a real Core GenServer demonstrating the actual
      # interleaving fix. Tests that consensus waits for batch_sync to complete
      # before running.

      agent_id = "agent-r207-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        task_id: "task-r207-#{System.unique_integer([:positive])}",
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        budget_data: nil,
        prompt_fields: %{
          provided: %{task_description: "Interleaving test task"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: [],
        capability_groups: [:hierarchy, :local_execution]
      }

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Wait for init
      {:ok, _initial_state} = Core.get_state(agent_pid)

      # Set up the interleaving scenario:
      # 1. Inject pending_actions that simulate the bug scenario
      #    - Retained async shell Phase 1 entry
      #    - A stale check_id action
      #    - A batch_sync action (self_contained)

      phase1_shell_id = "phase1-#{System.unique_integer([:positive])}"
      stale_check_id = "stale-#{System.unique_integer([:positive])}"
      batch_id = "batch-#{System.unique_integer([:positive])}"

      :sys.replace_state(agent_pid, fn state ->
        %{
          state
          | pending_actions: %{
              phase1_shell_id => pending_entry(:execute_shell),
              stale_check_id => pending_entry(:execute_shell),
              batch_id => pending_entry(:batch_sync)
            }
        }
      end)

      # Step 1: Deliver stale check_id error result via GenServer.cast
      # (same mechanism as non-blocking dispatch sends results)
      stale_opts = [
        action_atom: :execute_shell,
        wait_value: false,
        always_sync: false,
        action_response: %{
          action: :execute_shell,
          params: %{check_id: "nonexistent"},
          wait: false
        }
      ]

      GenServer.cast(
        agent_pid,
        {:action_result, stale_check_id, {:error, :command_not_found}, stale_opts}
      )

      # Force processing of the cast
      {:ok, state_after_stale} = Core.get_state(agent_pid)

      # BUG (current): consensus_scheduled is true after stale error
      # FIX: consensus_scheduled should be false — deferred for batch_sync
      refute state_after_stale.consensus_scheduled,
             "System test: stale check_id error should not trigger consensus while batch_sync pending"

      # Step 2: Deliver batch_sync result
      batch_opts = [
        action_atom: :batch_sync,
        wait_value: false,
        always_sync: true,
        action_response: %{action: :batch_sync, params: %{actions: []}, wait: false}
      ]

      GenServer.cast(
        agent_pid,
        {:action_result, batch_id, {:ok, %{results: []}}, batch_opts}
      )

      # Force processing of cast + any self-sent :trigger_consensus
      # Note: schedule_consensus_continuation sends :trigger_consensus to self during the
      # cast callback. With skip_auto_consensus: true, handle_trigger_consensus clears the
      # consensus_scheduled flag without running consensus. By the time get_state returns,
      # the flag may already be false. Instead of checking the transient flag, verify the
      # outcomes: batch_sync removed from pending_actions and both results in history.
      {:ok, state_after_batch} = Core.get_state(agent_pid)

      # batch_sync should be consumed, only phase1 shell remains
      refute Map.has_key?(state_after_batch.pending_actions, batch_id),
             "batch_sync should be removed from pending_actions after result delivery"

      assert Map.has_key?(state_after_batch.pending_actions, phase1_shell_id),
             "phase1 shell entry should still be retained (async Phase 1)"

      # Verify both results are in history (not just the stale error)
      all_entries =
        state_after_batch.model_histories
        |> Map.values()
        |> List.flatten()

      result_entries = Enum.filter(all_entries, &(&1.type == :result))

      # Both the stale error and batch_sync result should be in history
      assert length(result_entries) >= 2,
             "Both stale check_id error and batch_sync result should be in history, " <>
               "got #{length(result_entries)} result entries"
    end
  end
end
