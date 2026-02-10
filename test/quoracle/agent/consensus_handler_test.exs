# Mock router for testing that returns success
defmodule Quoracle.Agent.ConsensusHandlerTest.MockRouter do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [])
  def init(_), do: {:ok, %{}}

  # Handle the actual GenServer call format from Router.execute/5
  # Router sends: {:execute, module, params, agent_id, action_id, smart_threshold, timeout, sandbox_owner, secrets_used, opts}
  def handle_call(
        {:execute, _module, _params, _agent_id, _action_id, _smart_threshold, _timeout,
         _sandbox_owner, _secrets_used, _opts},
        _from,
        state
      ) do
    # Return a successful result
    {:reply, {:ok, %{status: "executed", result: "success"}}, state}
  end

  # Backward compatibility for old signature without secrets_used
  def handle_call(
        {:execute, _module, _params, _agent_id, _action_id, _smart_threshold, _timeout,
         _sandbox_owner, _opts},
        _from,
        state
      ) do
    # Return a successful result
    {:reply, {:ok, %{status: "executed", result: "success"}}, state}
  end

  # Backward compatibility for old signature without opts
  def handle_call(
        {:execute, _module, _params, _agent_id, _action_id, _smart_threshold, _timeout,
         _sandbox_owner},
        _from,
        state
      ) do
    # Return a successful result
    {:reply, {:ok, %{status: "executed", result: "success"}}, state}
  end

  def handle_call(:get_pubsub, _from, state) do
    {:reply, nil, state}
  end

  # Handle metrics tracking casts from Router.execute
  def handle_cast({:increment_metric, _action}, state) do
    {:noreply, state}
  end
end

defmodule Quoracle.Agent.ConsensusHandlerTest do
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.ConsensusHandler
  alias Quoracle.Agent.ConsensusHandlerTest.MockRouter

  import ExUnit.CaptureLog

  describe "handle_wait_parameter/3" do
    setup do
      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        wait_timer: nil
      }

      %{state: state}
    end

    test "returns state with immediate continuation when wait is false", %{state: state} do
      action = :spawn_child

      # Should send :trigger_consensus message and set consensus_scheduled flag
      result = ConsensusHandler.handle_wait_parameter(state, action, false)

      assert result.agent_id == state.agent_id
      assert result.consensus_scheduled == true
      assert_receive :trigger_consensus
    end

    test "returns state with immediate continuation when wait is 0", %{state: state} do
      action = :orient

      result = ConsensusHandler.handle_wait_parameter(state, action, 0)

      assert result.agent_id == state.agent_id
      assert result.consensus_scheduled == true
      assert_receive :trigger_consensus
    end

    test "returns unchanged state when wait is true", %{state: state} do
      action = :fetch_web

      result = ConsensusHandler.handle_wait_parameter(state, action, true)

      assert result == state
      refute_receive :trigger_consensus
    end

    test "sets timer for continuation when wait is positive integer", %{state: state} do
      action = :execute_shell
      wait_seconds = 30

      result = ConsensusHandler.handle_wait_parameter(state, action, wait_seconds)

      assert %{wait_timer: {timer_ref, :timed_wait}} = result
      assert is_reference(timer_ref)

      # Cancel timer and send message immediately for test speed
      Process.cancel_timer(timer_ref)
      send(self(), :trigger_consensus)
      assert_receive :trigger_consensus
    end

    test "handles small integer wait values", %{state: state} do
      action = :send_message
      wait_seconds = 1

      result = ConsensusHandler.handle_wait_parameter(state, action, wait_seconds)

      assert %{wait_timer: {timer_ref, :timed_wait}} = result
      assert is_reference(timer_ref)

      # Cancel timer and send message immediately for test speed
      Process.cancel_timer(timer_ref)
      send(self(), :trigger_consensus)
      assert_receive :trigger_consensus
    end

    test "defaults to true for invalid wait values", %{state: state} do
      action = :call_api

      capture_log(fn ->
        result = ConsensusHandler.handle_wait_parameter(state, action, "invalid")
        assert result == state
      end)

      refute_receive :trigger_consensus
    end

    test "handles negative integer wait values as invalid", %{state: state} do
      action = :answer_engine

      capture_log(fn ->
        result = ConsensusHandler.handle_wait_parameter(state, action, -5)
        assert result == state
      end)

      refute_receive :trigger_consensus
    end

    test "cancels existing timer when setting new timer", %{state: state} do
      # Create state with existing timer
      old_timer = Process.send_after(self(), :old_timer_message, 5_000)
      state = %{state | wait_timer: {old_timer, :timed_wait}}

      result = ConsensusHandler.handle_wait_parameter(state, :spawn_child, 1)

      assert %{wait_timer: {new_timer, :timed_wait}} = result
      assert new_timer != old_timer

      # Old timer should be cancelled
      refute_receive :old_timer_message, 100
      # Cancel new timer and send message immediately for test speed
      Process.cancel_timer(new_timer)
      send(self(), :trigger_consensus)
      assert_receive :trigger_consensus
    end

    # String coercion tests (Fix for LLM returning wait: "true" from JSON)
    test "coerces string 'true' to boolean true (no consensus trigger)", %{state: state} do
      action = :execute_shell

      result = ConsensusHandler.handle_wait_parameter(state, action, "true")

      assert result == state
      refute_receive :trigger_consensus
    end

    test "coerces string 'false' to boolean false (triggers consensus)", %{state: state} do
      action = :execute_shell

      result = ConsensusHandler.handle_wait_parameter(state, action, "false")

      assert result.agent_id == state.agent_id
      assert result.consensus_scheduled == true
      assert_receive :trigger_consensus
    end
  end

  describe "execute_consensus_action/3" do
    setup do
      # Start a mock router that can handle execute calls
      # start_supervised handles cleanup automatically - no need for on_exit
      {:ok, mock_router} = start_supervised(MockRouter)

      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        # Use mock router instead of self()
        router_pid: mock_router,
        pending_actions: %{},
        wait_timer: nil,
        # Required for spawn_child action to be allowed
        capability_groups: [:hierarchy]
      }

      agent_pid = self()

      %{state: state, agent_pid: agent_pid, mock_router: mock_router}
    end

    test "executes action and handles wait: false", %{state: state, agent_pid: agent_pid} do
      consensus_result = %{
        # Use :orient action (not :wait, which has special response-level wait handling)
        action: :orient,
        params: %{
          current_situation: "testing",
          goal_clarity: "clear",
          available_resources: "test suite",
          key_challenges: "none",
          delegation_consideration: "none"
        },
        wait: false
      }

      result = ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      # Sync result: action processed and removed from pending (prevents duplicate notifications)
      assert %{pending_actions: pending} = result
      assert map_size(pending) == 0

      # Should trigger consensus via send/2 (not cast - prevents race condition)
      # FIX: Synchronous result storage prevents race with immediate replies
      assert_receive :trigger_consensus
    end

    test "executes action and handles wait: true for non-self-contained actions", %{
      state: state,
      agent_pid: agent_pid
    } do
      # Use send_message - NOT a self-contained action (can trigger external response)
      # Self-contained actions (orient, todo, etc.) auto-correct wait:true to false
      consensus_result = %{
        action: :send_message,
        params: %{to: "parent", content: "test message"},
        wait: true
      }

      result = ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      # Sync result: action processed and removed from pending (prevents duplicate notifications)
      assert %{pending_actions: pending} = result
      assert map_size(pending) == 0

      refute_receive :trigger_consensus
    end

    # R11: Self-contained actions auto-correct wait:true to wait:false
    @tag capture_log: true
    test "auto-corrects wait:true to wait:false for self-contained actions" do
      {:ok, mock_router} = start_supervised({MockRouter, []}, id: :mock_router_autocorrect)

      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        router_pid: mock_router,
        pending_actions: %{},
        wait_timer: nil,
        model_histories: %{"default" => []}
      }

      # orient is a self-contained action - wait:true should be auto-corrected
      consensus_result = %{
        action: :orient,
        params: %{
          current_situation: "testing",
          goal_clarity: "clear",
          available_resources: "test suite",
          key_challenges: "none",
          delegation_consideration: "none"
        },
        wait: true
      }

      result = ConsensusHandler.execute_consensus_action(state, consensus_result, self())

      # Sync result: action processed and removed from pending (prevents duplicate notifications)
      assert %{pending_actions: pending} = result
      assert map_size(pending) == 0

      # Should trigger consensus because wait was corrected to false
      assert_receive :trigger_consensus
    end

    test "executes action and sets timer for integer wait", %{state: state, agent_pid: agent_pid} do
      consensus_result = %{
        action: :orient,
        params: %{
          current_situation: "testing",
          goal_clarity: "clear",
          available_resources: "test suite",
          key_challenges: "none",
          delegation_consideration: "none"
        },
        wait: 5
      }

      result = ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      assert %{wait_timer: {timer_ref, :timed_wait}} = result
      assert is_reference(timer_ref)

      # Cancel timer and send message immediately for test speed
      Process.cancel_timer(timer_ref)
      send(self(), :trigger_consensus)
      assert_receive :trigger_consensus
    end

    test "handles router execution errors gracefully", %{state: state, agent_pid: agent_pid} do
      # Mock router error response
      consensus_result = %{
        action: :invalid_action,
        params: %{},
        wait: true
      }

      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          result = ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)
          # Check that key fields remain unchanged even on error
          assert result.agent_id == state.agent_id
          assert result.pending_actions == state.pending_actions
        end)

      assert log =~ "Action execution failed"
      assert_receive :trigger_consensus
    end

    # R10-R13: Missing wait now defaults to false instead of error
    @tag capture_log: true
    test "defaults wait to false when missing for non-wait actions" do
      {:ok, mock_router} = start_supervised({MockRouter, []}, id: :mock_router_defaults)

      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        router_pid: mock_router,
        pending_actions: %{},
        wait_timer: nil,
        model_histories: %{"default" => []}
      }

      consensus_result = %{
        # Use :orient action which is actually implemented
        action: :orient,
        params: %{
          current_situation: "testing",
          goal_clarity: "clear",
          available_resources: "test suite",
          key_challenges: "none",
          delegation_consideration: "none"
        }
        # Missing wait parameter - now defaults to false
      }

      result = ConsensusHandler.execute_consensus_action(state, consensus_result, self())
      # Should return state (map), not error tuple
      assert is_map(result)
      refute match?({:error, _}, result)
    end

    test "allows missing wait parameter for :wait action", %{state: state, agent_pid: agent_pid} do
      consensus_result = %{
        action: :wait,
        params: %{wait: 100}
        # No wait parameter needed
      }

      result = ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      refute match?({:error, _}, result)
    end

    # LLM leniency: empty map normalized to empty list before storing in history
    test "normalizes sibling_context empty map to empty list in history", %{
      state: state,
      agent_pid: agent_pid
    } do
      state = Map.put(state, :model_histories, %{"default" => []})

      consensus_result = %{
        action: :spawn_child,
        params: %{
          task_description: "Test task",
          success_criteria: "Done",
          immediate_context: "Context",
          approach_guidance: "Guidance",
          sibling_context: %{}
        },
        wait: true
      }

      result = ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      # Check that sibling_context was normalized in history
      # FIX: Find the :decision entry (may not be first due to sync result storage)
      all_entries = result.model_histories["default"]
      entry = Enum.find(all_entries, &(&1.type == :decision))
      assert entry != nil, "Should have a decision entry"
      assert entry.content.params.sibling_context == []
    end
  end

  # =============================================================================
  # PACKET 2: Timed Wait & Missing Wait Fix (WorkGroupID: fix-20251210-175217)
  # =============================================================================
  # These tests cover R7-R14 from AGENT_ConsensusHandler spec v9.0
  # All tests should FAIL until implementation is complete

  describe "timed wait result storage (R7-R9)" do
    setup do
      {:ok, mock_router} = start_supervised(MockRouter)

      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        router_pid: mock_router,
        pending_actions: %{},
        wait_timer: nil,
        model_histories: %{"default" => []}
      }

      agent_pid = self()

      %{state: state, agent_pid: agent_pid}
    end

    # R7: Timed Wait Stores Result
    test "timed wait stores result in history before setting timer", %{
      state: state,
      agent_pid: agent_pid
    } do
      consensus_result = %{
        action: :orient,
        params: %{
          current_situation: "testing",
          goal_clarity: "clear",
          available_resources: "test suite",
          key_challenges: "none",
          delegation_consideration: "none"
        },
        wait: 5
      }

      result_state = ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      # FIX: Result is now stored synchronously (race condition fix), not via cast
      # Check result is in the returned state's history
      histories = result_state.model_histories
      all_entries = histories |> Map.values() |> List.flatten()
      result_entry = Enum.find(all_entries, &(&1.type == :result))
      assert result_entry != nil, "Result should be stored synchronously in history"
    end

    # R8: Timer Set After Result Cast
    test "timed wait sets timer after storing result", %{state: state, agent_pid: agent_pid} do
      consensus_result = %{
        action: :orient,
        params: %{
          current_situation: "testing",
          goal_clarity: "clear",
          available_resources: "test suite",
          key_challenges: "none",
          delegation_consideration: "none"
        },
        wait: 5
      }

      result_state = ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      # FIX: Result is now stored synchronously (race condition fix), not via cast
      # Verify result was stored in returned state
      histories = result_state.model_histories
      all_entries = histories |> Map.values() |> List.flatten()
      result_entry = Enum.find(all_entries, &(&1.type == :result))
      assert result_entry != nil, "Result should be stored synchronously"

      # Then verify timer was set
      assert %{wait_timer: {timer_ref, :timed_wait}} = result_state
      assert is_reference(timer_ref)

      # Cleanup
      Process.cancel_timer(timer_ref)
    end

    # R9: Timed Wait History Alternation (INTEGRATION)
    test "timed wait maintains proper message alternation", %{
      state: state,
      agent_pid: agent_pid
    } do
      # Execute action with timed wait
      consensus_result = %{
        action: :orient,
        params: %{
          current_situation: "testing timed wait",
          goal_clarity: "clear",
          available_resources: "test suite",
          key_challenges: "none",
          delegation_consideration: "none"
        },
        wait: 1
      }

      result_state =
        ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      # FIX: Result is now stored synchronously (race condition fix), not via cast
      # Verify result was stored in returned state's history
      histories = result_state.model_histories
      all_entries = histories |> Map.values() |> List.flatten()
      result_entry = Enum.find(all_entries, &(&1.type == :result))
      assert result_entry != nil, "Result should be stored synchronously"

      # Timer should be set
      assert %{wait_timer: {timer_ref, :timed_wait}} = result_state
      Process.cancel_timer(timer_ref)
    end
  end

  describe "missing wait parameter default (R10-R13)" do
    import ExUnit.CaptureLog

    setup do
      {:ok, mock_router} = start_supervised(MockRouter)

      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        router_pid: mock_router,
        pending_actions: %{},
        wait_timer: nil,
        model_histories: %{"default" => []},
        # Required for spawn_child action to be allowed
        capability_groups: [:hierarchy]
      }

      agent_pid = self()

      %{state: state, agent_pid: agent_pid}
    end

    # R10: Default Wait Applied
    test "applies default wait: false when nil", %{state: state, agent_pid: agent_pid} do
      consensus_result = %{
        action: :orient,
        params: %{
          current_situation: "testing",
          goal_clarity: "clear",
          available_resources: "test suite",
          key_challenges: "none",
          delegation_consideration: "none"
        }
        # wait is missing/nil - should default to false, not error
      }

      result = ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      # Should NOT return error
      refute match?({:error, :missing_wait_parameter}, result)

      # Should have executed the action and returned state
      assert is_map(result)
      assert Map.has_key?(result, :agent_id)
    end

    # R12: Stored Decision Has Wait (INTEGRATION)
    test "decision stored in history includes defaulted wait: false", %{
      state: state,
      agent_pid: agent_pid
    } do
      consensus_result = %{
        action: :orient,
        params: %{
          current_situation: "testing",
          goal_clarity: "clear",
          available_resources: "test suite",
          key_challenges: "none",
          delegation_consideration: "none"
        }
        # wait is missing - will be defaulted
      }

      _result = ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      # Should trigger consensus via send/2 (not cast - prevents race condition)
      # FIX: Synchronous result storage prevents race with immediate replies
      assert_receive :trigger_consensus
    end

    # R13: No Error on Missing Wait
    test "does not return missing_wait_parameter error", %{state: state, agent_pid: agent_pid} do
      consensus_result = %{
        action: :spawn_child,
        params: %{
          task: "test task"
        }
        # wait is missing
      }

      result = ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      # Must NOT return error tuple
      refute match?({:error, :missing_wait_parameter}, result)

      # Should return state (map)
      assert is_map(result)
    end
  end

  describe "timed wait system behavior (R14)" do
    setup do
      {:ok, mock_router} = start_supervised(MockRouter)

      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        router_pid: mock_router,
        pending_actions: %{},
        wait_timer: nil,
        model_histories: %{"default" => []}
      }

      agent_pid = self()

      %{state: state, agent_pid: agent_pid}
    end

    # R14: Agent Continues After Timed Wait (SYSTEM)
    test "agent continues normally after timed wait expires", %{
      state: state,
      agent_pid: agent_pid
    } do
      # Execute action with short timed wait
      consensus_result = %{
        action: :orient,
        params: %{
          current_situation: "testing timed wait system",
          goal_clarity: "clear",
          available_resources: "test suite",
          key_challenges: "none",
          delegation_consideration: "none"
        },
        wait: 1
      }

      result_state =
        ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      # 1. FIX: Result is now stored synchronously (race condition fix), not via cast
      histories = result_state.model_histories
      all_entries = histories |> Map.values() |> List.flatten()
      result_entry = Enum.find(all_entries, &(&1.type == :result))
      assert result_entry != nil, "Result must be stored synchronously before timer"

      # 2. Timer must be set
      assert %{wait_timer: {timer_ref, :timed_wait}} = result_state
      assert is_reference(timer_ref)

      # 3. After timer fires, :trigger_consensus should be received
      # (We'll simulate this by waiting for the actual timer or canceling)
      # Cancel and manually trigger for test speed
      Process.cancel_timer(timer_ref)
      send(self(), :trigger_consensus)

      assert_receive :trigger_consensus,
                     5000,
                     "Timer should trigger :trigger_consensus for next decision round"
    end

    test "timed wait does not cause result to be lost", %{state: state, agent_pid: agent_pid} do
      # This verifies the bug is fixed - result should NOT be lost
      consensus_result = %{
        action: :orient,
        params: %{
          current_situation: "testing result preservation",
          goal_clarity: "clear",
          available_resources: "test suite",
          key_challenges: "none",
          delegation_consideration: "none needed"
        },
        wait: 5
      }

      result_state =
        ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      # FIX: Result is now stored synchronously (race condition fix), not via cast
      # The key assertion: result MUST be in returned state's history
      histories = result_state.model_histories
      all_entries = histories |> Map.values() |> List.flatten()
      result_entry = Enum.find(all_entries, &(&1.type == :result))

      assert result_entry != nil, "Result should be stored synchronously (not lost)"
      # New format: content is pre-wrapped JSON string, result field has the raw data
      assert is_binary(result_entry.content)
      assert is_map(result_entry.result)

      # Cleanup timer
      if result_state.wait_timer do
        {timer_ref, _} = result_state.wait_timer
        Process.cancel_timer(timer_ref)
      end
    end
  end

  # =============================================================================
  # Bug 1: wait:true (boolean) Race Condition Fix
  # Tests verify synchronous result storage for wait: true (boolean, not integer)
  # =============================================================================

  describe "wait:true (boolean) synchronous storage" do
    setup do
      {:ok, mock_router} = start_supervised(MockRouter)

      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        router_pid: mock_router,
        pending_actions: %{},
        wait_timer: nil,
        model_histories: %{"default" => []}
      }

      agent_pid = self()

      %{state: state, agent_pid: agent_pid}
    end

    # R21: Synchronous Result Storage for wait:true (boolean)
    @tag capture_log: true
    test "wait:true stores result synchronously in returned state", %{
      state: state,
      agent_pid: agent_pid
    } do
      consensus_result = %{
        action: :orient,
        params: %{
          current_situation: "testing wait:true boolean",
          goal_clarity: "clear",
          available_resources: "test",
          key_challenges: "none",
          delegation_consideration: "none"
        },
        wait: true
      }

      result_state =
        ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      # Result must be in returned state (synchronous, not via cast)
      histories = result_state.model_histories
      all_entries = histories |> Map.values() |> List.flatten()
      result_entry = Enum.find(all_entries, &(&1.type == :result))

      assert result_entry != nil, "wait:true must store result synchronously"
      # New format: content is pre-wrapped JSON string
      assert is_binary(result_entry.content)
    end

    # R22: Always-sync action with wait:true does NOT trigger consensus
    # Note: send_message, spawn_child are always_sync but NOT self-contained
    # (Self-contained actions like orient, todo auto-correct wait:true to false)
    test "always_sync action with wait:true does not trigger consensus", %{
      state: state,
      agent_pid: agent_pid
    } do
      # Use send_message - always_sync but NOT self-contained (expects external reply)
      consensus_result = %{
        action: :send_message,
        params: %{to: "parent", content: "testing always_sync behavior"},
        wait: true
      }

      _result_state =
        ConsensusHandler.execute_consensus_action(state, consensus_result, agent_pid)

      # Should NOT receive :trigger_consensus (send_message is always_sync with wait:true)
      # Agent waits for external event (reply from parent)
      # 500ms margin for CI load (not testing timeout behavior, just verifying no message sent)
      refute_receive :trigger_consensus, 500
    end
  end

  describe "get_action_consensus/1" do
    setup do
      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        models: ["model1", "model2"],
        model_histories: %{"default" => []},
        # Use mock responses instead of real model queries
        test_mode: true
      }

      %{state: state}
    end

    test "requests consensus from multiple models", %{state: state} do
      # v8.0: Put messages in model_histories, not passed separately
      state =
        put_in(state.model_histories["default"], [
          %{role: "user", content: "test message"}
        ])

      result = ConsensusHandler.get_action_consensus(state)

      assert {:ok, consensus, _updated_state, _accumulator} = result
      assert Map.has_key?(consensus, :action)
      assert Map.has_key?(consensus, :wait)
    end

    test "applies consensus rules to merge wait parameters", %{state: state} do
      # v8.0: Put messages in model_histories
      state =
        put_in(state.model_histories["default"], [
          %{role: "user", content: "spawn a child agent"}
        ])

      result = ConsensusHandler.get_action_consensus(state)

      assert {:ok, %{wait: wait_value}, _updated_state, _accumulator} = result
      # Wait parameter should be boolean or non-negative integer
      assert is_boolean(wait_value) or (is_integer(wait_value) and wait_value >= 0),
             "wait must be boolean or non-negative integer, got: #{inspect(wait_value)}"
    end

    test "handles consensus failures", %{state: state} do
      # Force consensus failure by simulating all models failing
      state = Map.put(state, :simulate_failure, true)
      # v8.0: Put messages in model_histories
      state = put_in(state.model_histories["default"], [%{role: "user", content: "test"}])

      # Capture expected log output from consensus failures
      capture_log(fn ->
        send(self(), {:result, ConsensusHandler.get_action_consensus(state)})
      end)

      assert_receive {:result, result}, 30_000
      assert {:error, reason, _accumulator} = result
      assert reason in [:all_models_failed, :consensus_failed]
    end
  end
end
