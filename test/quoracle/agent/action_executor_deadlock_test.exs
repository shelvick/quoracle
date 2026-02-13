defmodule Quoracle.Agent.ActionExecutorDeadlockTest do
  @moduledoc """
  Tests for FIX_ActionExecutorDeadlock - Non-blocking action execution.

  WorkGroupID: fix-20260212-action-deadlock
  Packet: 1 (Foundation)

  Verifies the non-blocking dispatch pattern where ActionExecutor dispatches
  actions to Task.Supervisor instead of executing synchronously. Results
  arrive back via GenServer.cast with wait parameter info in opts.

  ARC Verification Criteria: R1-R6
  (R7-R11 test existing behavior and are deferred to IMPLEMENT phase)
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.ConsensusHandler.ActionExecutor
  alias Quoracle.Agent.MessageHandler

  alias Test.IsolationHelpers

  # ============================================================================
  # Setup
  # ============================================================================

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()

    base_state = %{
      agent_id: "agent-deadlock-#{System.unique_integer([:positive])}",
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
  # R1: Non-blocking dispatch
  # [UNIT] ActionExecutor dispatches to Task.Supervisor, returns immediately
  # with action still in pending_actions.
  #
  # FAILS: Current implementation executes synchronously and clears
  # pending_actions before returning.
  # ============================================================================

  describe "R1: non-blocking action dispatch" do
    test "action remains in pending_actions after dispatch",
         %{state: state} do
      action_response = %{
        action: :orient,
        params: %{thought: "testing non-blocking dispatch"},
        wait: false
      }

      result_state = ActionExecutor.execute_consensus_action(state, action_response)

      assert is_map(result_state)

      # After non-blocking dispatch, action should STILL be pending
      # (result hasn't arrived yet via cast).
      # Fails: synchronous execution clears pending_actions.
      assert map_size(result_state.pending_actions) >= 1,
             "Action was processed synchronously - " <>
               "pending_actions empty after dispatch"
    end
  end

  # ============================================================================
  # R2: Result delivered via cast
  # [UNIT] Dispatched task sends result back via GenServer.cast to agent_pid.
  #
  # FAILS: Current implementation processes results synchronously inline;
  # no cast is ever sent.
  # ============================================================================

  describe "R2: result delivered via cast" do
    test "dispatch sends result back via GenServer.cast",
         %{state: state} do
      action_response = %{
        action: :orient,
        params: %{thought: "testing cast delivery"},
        wait: false
      }

      # Execute with self() as agent_pid
      _result_state =
        ActionExecutor.execute_consensus_action(state, action_response, self())

      # Background task should cast result back as $gen_cast.
      # Fails: no background task, no cast sent.
      assert_receive {:"$gen_cast", {:action_result, _action_id, _result, _opts}},
                     5000
    end
  end

  # ============================================================================
  # R3: Pending actions populated before dispatch
  # [UNIT] pending_actions contains action entry with correct structure
  # immediately after execute returns (before result arrives).
  #
  # FAILS: Same as R1 - synchronous processing clears pending_actions.
  # ============================================================================

  describe "R3: pending_actions populated on dispatch" do
    test "entry has correct structure after dispatch",
         %{state: state} do
      action_response = %{
        action: :send_message,
        params: %{target: "agent-1", content: "hello"},
        wait: false
      }

      result_state = ActionExecutor.execute_consensus_action(state, action_response)

      # Should contain entry after non-blocking dispatch.
      # Fails: synchronous processing cleared it.
      assert map_size(result_state.pending_actions) >= 1,
             "pending_actions empty - action was processed synchronously"

      [{_action_id, entry}] = Map.to_list(result_state.pending_actions)
      assert entry.type in [:send_message, "send_message"]
      assert is_map(entry.params)
      assert %DateTime{} = entry.timestamp
    end
  end

  # ============================================================================
  # R4: Wait parameter handling in handle_action_result
  # [UNIT] New opts keys (action_atom, wait_value, always_sync) control
  # wait behavior in handle_action_result instead of ActionExecutor.
  #
  # FAILS: Current handle_action_result ignores these new opts keys.
  # ============================================================================

  describe "R4: wait handling in handle_action_result" do
    test "wait:true + always_sync skips consensus",
         %{state: state} do
      action_id = "action_wait_sync_1"

      state = %{
        state
        | pending_actions: %{
            action_id => %{
              type: :send_message,
              params: %{target: "agent-1", content: "hi"},
              timestamp: DateTime.utc_now()
            }
          }
      }

      # New opts format from ActionExecutor dispatch
      opts = [
        action_atom: :send_message,
        wait_value: true,
        always_sync: true,
        action_response: %{
          action: :send_message,
          params: %{target: "agent-1", content: "hi"},
          wait: true
        }
      ]

      {:noreply, new_state} =
        MessageHandler.handle_action_result(
          state,
          action_id,
          {:ok, %{sent: true}},
          opts
        )

      # always_sync + wait:true = wait for external event.
      # Fails: current code ignores opts, always schedules consensus.
      refute new_state.consensus_scheduled,
             "Consensus should NOT be scheduled for always_sync + wait:true"
    end

    test "wait:5 (timed) sets wait_timer",
         %{state: state} do
      action_id = "action_timed_wait_1"

      state = %{
        state
        | pending_actions: %{
            action_id => %{
              type: :fetch_web,
              params: %{url: "http://example.com"},
              timestamp: DateTime.utc_now()
            }
          }
      }

      opts = [
        action_atom: :fetch_web,
        wait_value: 5,
        always_sync: false,
        action_response: %{
          action: :fetch_web,
          params: %{url: "http://example.com"},
          wait: 5
        }
      ]

      {:noreply, new_state} =
        MessageHandler.handle_action_result(
          state,
          action_id,
          {:ok, %{body: "html"}},
          opts
        )

      # Timed wait (5s) should set a wait_timer.
      # Fails: current code ignores wait_value in opts.
      assert new_state.wait_timer != nil,
             "wait_timer should be set for timed wait (5s)"
    end
  end

  # ============================================================================
  # R5: Children tracked on spawn_child result
  # [UNIT] handle_action_result detects spawn_child via opts[:action_atom]
  # and updates children list with child_data from result.
  #
  # FAILS: Current handle_action_result does not track children.
  # Children tracking is in ActionExecutor.handle_success (synchronous path).
  # ============================================================================

  describe "R5: spawn_child result tracks children" do
    test "adds child to children list on spawn result",
         %{state: state} do
      action_id = "action_spawn_1"

      state = %{
        state
        | pending_actions: %{
            action_id => %{
              type: :spawn_child,
              params: %{profile: "researcher"},
              timestamp: DateTime.utc_now()
            }
          }
      }

      child_result = %{
        agent_id: "child-agent-123",
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

      # Children list should be updated.
      # Fails: current handle_action_result does not track children.
      assert length(new_state.children) == 1,
             "Expected 1 child after spawn result, got 0"

      [child] = new_state.children
      assert child.agent_id == "child-agent-123"
    end
  end

  # ============================================================================
  # R6: Sandbox isolation in dispatch task
  # [INTEGRATION] Task.Supervisor child has DB access via sandbox_owner.
  #
  # FAILS: No Task.Supervisor dispatch exists; no cast sent.
  # ============================================================================

  describe "R6: sandbox isolation in dispatch task" do
    test "dispatch task accesses DB via sandbox_owner",
         %{state: state, sandbox_owner: sandbox_owner} do
      state = Map.put(state, :sandbox_owner, sandbox_owner)

      action_response = %{
        action: :orient,
        params: %{thought: "testing sandbox access"},
        wait: false
      }

      _result_state =
        ActionExecutor.execute_consensus_action(
          state,
          action_response,
          self()
        )

      # Dispatched task should cast result back with DB access.
      # Fails: no dispatch task exists, no cast sent.
      assert_receive {:"$gen_cast", {:action_result, _action_id, result, _opts}},
                     5000

      case result do
        {:error, %DBConnection.OwnershipError{}} ->
          flunk("Sandbox not propagated to dispatch task")

        {:error, {:ownership_error, _}} ->
          flunk("Sandbox not propagated to dispatch task")

        _ ->
          :ok
      end
    end
  end
end
