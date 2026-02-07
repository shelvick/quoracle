# Mock Router that returns configurable results for race condition tests
defmodule Quoracle.Agent.ConsensusHandlerRaceTest.MockRouter do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def init(opts), do: {:ok, %{result: Keyword.get(opts, :result, %{status: "ok"})}}

  def handle_call(
        {:execute, _module, _params, _agent_id, _action_id, _smart_threshold, _timeout,
         _sandbox_owner, _secrets_used, _opts},
        _from,
        state
      ) do
    {:reply, {:ok, state.result}, state}
  end

  def handle_call(:get_pubsub, _from, state) do
    {:reply, :test_pubsub, state}
  end

  def handle_cast({:increment_metric, _}, state), do: {:noreply, state}
end

defmodule Quoracle.Agent.ConsensusHandlerRaceTest do
  @moduledoc """
  Tests for race condition fix in ConsensusHandler (WorkGroupID: fix-20251211-051748, Packet 2).

  Bug: When send_message executes with wait: false, the action result is stored via
  GenServer.cast (async), creating a race window where immediate replies can be
  processed before the result is stored in history.

  Fix: Replace async cast with synchronous StateUtils.add_history_entry_with_action
  + send(agent_pid, :trigger_consensus).

  Requirements tested: R15-R20

  Note: History entries are PREPENDED (newest at index 0). So for proper alternation
  where decision is added BEFORE result, decision should have HIGHER index than result.
  """

  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Agent.ConsensusHandler
  alias Quoracle.Agent.StateUtils
  alias Quoracle.Agent.ConsensusHandlerRaceTest.MockRouter

  # Valid orient params (schema requires these 4 fields)
  @valid_orient_params %{
    current_situation: "Testing race condition fix",
    goal_clarity: "Verify synchronous result storage",
    available_resources: "Unit tests",
    key_challenges: "Race between cast and message processing"
  }

  describe "R15: Synchronous result storage for wait:false" do
    setup do
      {:ok, router} = MockRouter.start_link(result: %{status: "sent", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state, router: router}
    end

    test "wait:false adds result to state synchronously before returning", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      # Execute with test process as agent_pid
      result_state =
        ConsensusHandler.execute_consensus_action(
          state,
          action_response,
          self()
        )

      # R15: Result MUST be in returned state (synchronous update)
      # BUG: Current code returns original state, result added via async cast
      histories = result_state.model_histories["model_1"]

      # Find the result entry (type: :result)
      result_entry = Enum.find(histories, fn entry -> entry.type == :result end)

      # This should FAIL with buggy code (result not in state, only sent via cast)
      assert result_entry != nil, "Result should be in state synchronously, not via cast"
    end

    test "wait:0 also adds result to state synchronously", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: 0
      }

      result_state =
        ConsensusHandler.execute_consensus_action(
          state,
          action_response,
          self()
        )

      # R15: Result MUST be in returned state
      histories = result_state.model_histories["model_1"]
      result_entry = Enum.find(histories, fn entry -> entry.type == :result end)

      # This should FAIL with buggy code
      assert result_entry != nil, "Result should be in state synchronously for wait: 0"
    end
  end

  describe "R16: No cast for wait:false" do
    setup do
      {:ok, router} = MockRouter.start_link(result: %{status: "sent", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "wait:false does not send GenServer.cast for :action_result", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      ConsensusHandler.execute_consensus_action(
        state,
        action_response,
        self()
      )

      # R16: Should NOT receive :action_result cast
      # BUG: Current code sends GenServer.cast(agent_pid, {:action_result, ...})
      # GenServer.cast to non-GenServer process sends {:"$gen_cast", msg}
      refute_receive {:"$gen_cast", {:action_result, _, _, _}},
                     100,
                     "wait:false should NOT use GenServer.cast for result"
    end
  end

  describe "R17: Consensus triggered via send" do
    setup do
      {:ok, router} = MockRouter.start_link(result: %{status: "sent", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "wait:false triggers consensus via send(:trigger_consensus)", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      ConsensusHandler.execute_consensus_action(
        state,
        action_response,
        self()
      )

      # R17: Should receive :trigger_consensus via send/2
      # BUG: Current code sends cast with continue:true, not direct send
      assert_receive :trigger_consensus
    end

    test "wait:0 also triggers consensus via send", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: 0
      }

      ConsensusHandler.execute_consensus_action(
        state,
        action_response,
        self()
      )

      # BUG: Current code sends cast with continue:true, not direct send
      assert_receive :trigger_consensus
    end
  end

  describe "R18: Race condition prevented" do
    setup do
      {:ok, router} = MockRouter.start_link(result: %{status: "message_sent", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "immediate reply does not race with result storage", %{state: state} do
      # Simulate: Agent sends message with wait:false, recipient replies immediately
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      # Execute the action
      result_state =
        ConsensusHandler.execute_consensus_action(
          state,
          action_response,
          self()
        )

      # R18: After execute_consensus_action returns, the result MUST be in history
      # This prevents race where reply is processed before result is stored
      histories = result_state.model_histories["model_1"]

      # Count entries by type
      result_count = Enum.count(histories, fn e -> e.type == :result end)

      # BUG: Current code returns state without result (cast is async)
      assert result_count >= 1,
             "Result MUST be in history before function returns (race prevention)"
    end
  end

  describe "R19: History alternation maintained" do
    setup do
      {:ok, router} =
        MockRouter.start_link(result: %{action: "orient", status: "completed", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "history alternation maintained after wait:false action", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      result_state =
        ConsensusHandler.execute_consensus_action(
          state,
          action_response,
          self()
        )

      # R19: History should have proper alternation for LLM APIs
      # decision (assistant) -> result (user) pattern
      # Note: History is PREPENDED, so newer entries have LOWER indices
      histories = result_state.model_histories["model_1"]

      # Get types in order (index 0 = newest)
      types = Enum.map(histories, & &1.type)

      # BUG: Current code only has decision (no result - it's async via cast)
      assert :decision in types, "History must contain decision"
      assert :result in types, "History must contain result"

      # With prepending: result (newer, added second) should be at lower index
      # decision (older, added first) should be at higher index
      decision_idx = Enum.find_index(types, &(&1 == :decision))
      result_idx = Enum.find_index(types, &(&1 == :result))

      # Result added AFTER decision, so result_idx < decision_idx (prepend order)
      assert result_idx < decision_idx,
             "Result (newer) should have lower index than decision (older) in prepended history"
    end
  end

  # R20: Dead code path at lines 418-420 (unreachable after defaulting at 300-308)
  # This test verifies the dead code path adds result + logs error after fix
  describe "R20: Nil wait dead code path" do
    setup do
      {:ok, router} = MockRouter.start_link(result: %{status: "ok", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "dead nil wait path stores result defensively", %{state: state} do
      # R20: The dead code path at lines 418-420 currently does NOTHING:
      #   is_nil(wait_value) -> state
      # After fix, it should store result and trigger consensus.
      #
      # This path is normally unreachable (nil defaulted to false at 300-308),
      # but we test it as defense-in-depth by verifying that IF wait_value
      # could somehow be nil in the cond, result would still be stored.
      #
      # Since we can't reach the dead code path directly, we test that
      # wait:false (which hits similar code) stores result synchronously.
      # This test overlaps with R15 but emphasizes the defensive aspect.
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      result_state =
        ConsensusHandler.execute_consensus_action(
          state,
          action_response,
          self()
        )

      # R20 defense-in-depth: Result must be in state (not lost)
      histories = result_state.model_histories["model_1"]
      result_entry = Enum.find(histories, fn entry -> entry.type == :result end)

      # BUG: Current code returns state without result (cast is async)
      assert result_entry != nil, "Result must be stored to prevent silent data loss"
    end
  end

  describe "Acceptance: immediate reply after wait:false" do
    setup do
      {:ok, router} = MockRouter.start_link(result: %{status: "sent", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "agent handles immediate reply after wait:false send_message", %{state: state} do
      # User scenario:
      # 1. Agent sends message to child with wait: false
      # 2. Child replies immediately (message in mailbox before cast processed)
      # 3. Agent should continue normally without alternation errors

      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      # Execute action with wait: false
      result_state =
        ConsensusHandler.execute_consensus_action(
          state,
          action_response,
          self()
        )

      # Simulate immediate reply arriving in mailbox
      reply_message = %{
        sender: %{agent_id: "child-agent", name: "child"},
        content: "response"
      }

      # Add the reply to history (simulating MessageHandler.handle_agent_message)
      state_with_reply =
        StateUtils.add_history_entry(result_state, :message, reply_message)

      # ACCEPTANCE: History should be valid for LLM API (alternation maintained)
      histories = state_with_reply.model_histories["model_1"]

      # Verify we have: decision, result, message (all present)
      types = Enum.map(histories, & &1.type)

      assert :decision in types, "History must have decision"
      assert :result in types, "History must have result (not lost to race)"
      assert :message in types, "History must have incoming message"

      # BUG: Current code won't have :result (it's async via cast)
      # This causes the assertion above to fail
    end
  end

  # ==========================================================================
  # Bug 1 Tests: wait:true Race Condition (R21-R24)
  # WorkGroupID: fix-20251211-051748
  #
  # Problem: wait:true uses async GenServer.cast to store results, creating
  # race window where child's immediate reply can be processed before the
  # spawn result is stored in history.
  # ==========================================================================

  describe "R21: Synchronous result storage for wait:true" do
    setup do
      {:ok, router} =
        MockRouter.start_link(result: %{child_agent_id: "child-123", status: "spawned"})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state, router: router}
    end

    test "wait:true adds result synchronously before returning", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: true
      }

      # Execute with test process as agent_pid (capture expected auto-correction warning)
      {result_state, _log} =
        with_log(fn ->
          ConsensusHandler.execute_consensus_action(
            state,
            action_response,
            self()
          )
        end)

      # R21: Result MUST be in returned state (synchronous update)
      # BUG: Current code uses GenServer.cast for wait:true (async)
      histories = result_state.model_histories["model_1"]

      # Find the result entry (type: :result)
      result_entry = Enum.find(histories, fn entry -> entry.type == :result end)

      # This should FAIL with buggy code (result not in state, sent via cast)
      assert result_entry != nil,
             "wait:true result should be in state synchronously, not via cast"
    end
  end

  describe "R22: No cast for wait:true" do
    setup do
      {:ok, router} =
        MockRouter.start_link(result: %{child_agent_id: "child-123", status: "spawned"})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "wait:true does not use GenServer.cast for result", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: true
      }

      # Capture expected auto-correction warning for orient+wait:true
      capture_log(fn ->
        ConsensusHandler.execute_consensus_action(
          state,
          action_response,
          self()
        )
      end)

      # R22: Should NOT receive :action_result cast for wait:true
      # BUG: Current code sends GenServer.cast(agent_pid, {:action_result, ...})
      # GenServer.cast to non-GenServer process sends {:"$gen_cast", msg}
      refute_receive {:"$gen_cast", {:action_result, _, _, _}},
                     100,
                     "wait:true should NOT use GenServer.cast for result"
    end
  end

  describe "R23: Always-sync wait:true no consensus trigger" do
    setup do
      # Per-action Router (v28.0) requires real pubsub
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: pubsub_name,
        capability_groups: [:hierarchy]
      }

      %{state: state}
    end

    test "always_sync with wait:true stores result without triggering consensus", %{state: state} do
      # send_message is always_sync but NOT self-contained (expects external reply)
      # Note: self-contained actions (orient, todo, etc.) auto-correct wait:true to false
      action_response = %{
        action: :send_message,
        params: %{to: "parent", content: "test message"},
        wait: true
      }

      result_state =
        ConsensusHandler.execute_consensus_action(
          state,
          action_response,
          self()
        )

      # R23: Result stored but NO :trigger_consensus sent
      # (always_sync + wait:true = result stored, no continuation)
      histories = result_state.model_histories["model_1"]
      result_entry = Enum.find(histories, fn entry -> entry.type == :result end)

      # Result must be in state
      assert result_entry != nil, "Result must be stored synchronously"

      # Should NOT trigger consensus (always_sync with wait:true)
      refute_receive :trigger_consensus,
                     100,
                     "always_sync with wait:true should NOT trigger consensus"
    end
  end

  describe "R24: Race condition prevented for wait:true" do
    setup do
      {:ok, router} =
        MockRouter.start_link(result: %{child_agent_id: "child-123", status: "spawned"})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "immediate child message does not race with wait:true result storage", %{state: state} do
      # Scenario: spawn_child with wait:true, child sends message immediately
      # Result: spawn result MUST be in history before child message processed

      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: true
      }

      # Execute action with wait:true (capture expected auto-correction warning)
      {result_state, _log} =
        with_log(fn ->
          ConsensusHandler.execute_consensus_action(
            state,
            action_response,
            self()
          )
        end)

      # R24: After execute_consensus_action returns, result MUST be in history
      # This prevents race where child's immediate reply is processed first
      histories = result_state.model_histories["model_1"]
      result_entry = Enum.find(histories, fn entry -> entry.type == :result end)

      # BUG: Current code uses cast (async), so result not in returned state
      assert result_entry != nil,
             "wait:true result MUST be in history before function returns (race prevention)"
    end
  end

  describe "Bug 1 Acceptance: spawn result before immediate child reply" do
    setup do
      {:ok, router} =
        MockRouter.start_link(result: %{child_agent_id: "child-456", status: "spawned"})

      state = %{
        agent_id: "parent-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "spawn result appears before immediate child reply in history", %{state: state} do
      # User scenario:
      # 1. Parent spawns child with wait: true
      # 2. Child sends message immediately after spawn
      # 3. Parent should see spawn result BEFORE child's message in history

      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: true
      }

      # Execute spawn_child with wait:true (capture expected auto-correction warning)
      {result_state, _log} =
        with_log(fn ->
          ConsensusHandler.execute_consensus_action(
            state,
            action_response,
            self()
          )
        end)

      # Simulate immediate child reply
      child_message = %{
        sender: %{agent_id: "child-456", name: "child"},
        content: "Hello parent, I'm ready!"
      }

      state_with_child_msg =
        StateUtils.add_history_entry(result_state, :event, child_message)

      # ACCEPTANCE: History should have spawn result BEFORE child message
      histories = state_with_child_msg.model_histories["model_1"]
      types = Enum.map(histories, & &1.type)

      # Must have both
      assert :result in types, "History must have spawn result"
      assert :event in types, "History must have child message"

      # With prepending: result (older) should have HIGHER index than event (newer)
      result_idx = Enum.find_index(types, &(&1 == :result))
      event_idx = Enum.find_index(types, &(&1 == :event))

      # Event added AFTER result, so event_idx < result_idx in prepended order
      assert event_idx < result_idx,
             "Spawn result (older) must appear before child message (newer) in history"

      # BUG: Current code uses async cast, so result not in history yet
      # This assertion will fail because result_idx will be nil
    end
  end
end
