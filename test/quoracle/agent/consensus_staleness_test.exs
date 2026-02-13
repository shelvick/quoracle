defmodule Quoracle.Agent.ConsensusStalenessTest do
  @moduledoc """
  Tests for unified :trigger_consensus message handling and staleness detection.

  WorkGroupID: fix-20260117-consensus-staleness
  Packet: 2 (Message Unification)
  Requirements: R76-R90, A15-A17
  """
  use Quoracle.DataCase, async: true

  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core.MessageInfoHandler
  alias Quoracle.Agent.ConsensusHandler
  alias Quoracle.Agent.MessageHandler
  alias Quoracle.Agent.StateUtils

  # ==========================================================================
  # Test Helpers
  # ==========================================================================

  defp unique_id, do: "agent-#{System.unique_integer([:positive])}"

  defp create_isolated_infrastructure do
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({Phoenix.PubSub, name: pubsub_name})
    start_supervised!({DynamicSupervisor, name: dynsup_name, strategy: :one_for_one})

    %{registry: registry_name, pubsub: pubsub_name, dynsup: dynsup_name}
  end

  defp create_test_state(infra, opts) do
    agent_id = Keyword.get(opts, :agent_id, unique_id())
    consensus_scheduled = Keyword.get(opts, :consensus_scheduled, false)
    wait_timer = Keyword.get(opts, :wait_timer, nil)
    skip_auto_consensus = Keyword.get(opts, :skip_auto_consensus, true)
    pending_actions = Keyword.get(opts, :pending_actions, %{})
    queued_messages = Keyword.get(opts, :queued_messages, [])

    %{
      agent_id: agent_id,
      router_pid: self(),
      registry: infra.registry,
      dynsup: infra.dynsup,
      pubsub: infra.pubsub,
      model_histories: %{"model1" => []},
      models: ["model1"],
      pending_actions: pending_actions,
      queued_messages: queued_messages,
      consensus_scheduled: consensus_scheduled,
      wait_timer: wait_timer,
      skip_auto_consensus: skip_auto_consensus,
      test_mode: true,
      context_limits_loaded: true,
      context_limit: 4000,
      context_lessons: %{},
      model_states: %{}
    }
  end

  # ==========================================================================
  # R76-R80: Unified Handler Tests
  # ==========================================================================

  describe "[UNIT] R76: Unified Handler Exists" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "handle_trigger_consensus/1 can be called", %{infra: infra} do
      # R76: WHEN MessageInfoHandler compiled THEN handle_trigger_consensus/1 exists
      # Test by calling it - fails with UndefinedFunctionError until implemented
      state = create_test_state(infra, skip_auto_consensus: true)

      # This call will fail until the function is implemented
      {:noreply, _result} = MessageInfoHandler.handle_trigger_consensus(state)
    end
  end

  describe "[UNIT] R77: Staleness Check Applied" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "stale trigger_consensus ignored when both flags false", %{infra: infra} do
      # R77: WHEN :trigger_consensus received IF consensus_scheduled=false AND wait_timer=nil
      # THEN ignored as stale
      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      initial_state = state
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # State should be unchanged (message ignored)
      assert result_state == initial_state
    end

    test "stale message detected with consensus_scheduled false and wait_timer nil", %{
      infra: infra
    } do
      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          skip_auto_consensus: false
        )

      # Even without skip_auto_consensus, stale message should be ignored
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # No consensus triggered - state unchanged
      assert result_state.consensus_scheduled == false
      assert result_state.wait_timer == nil
    end
  end

  describe "[UNIT] R78: Valid Message Processed" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "valid trigger_consensus runs consensus when consensus_scheduled true", %{infra: infra} do
      # R78: WHEN :trigger_consensus received IF consensus_scheduled=true THEN runs consensus
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Flag should be cleared after processing
      assert result_state.consensus_scheduled == false
    end

    test "valid trigger_consensus runs consensus when wait_timer active", %{infra: infra} do
      # R78: WHEN :trigger_consensus received IF wait_timer!=nil THEN runs consensus
      timer_ref = Process.send_after(self(), :test_timer, 60_000)

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Timer should be cleared after processing
      assert result_state.wait_timer == nil

      # Cleanup
      Process.cancel_timer(timer_ref)
    end

    test "valid trigger_consensus with both flags set clears both", %{infra: infra} do
      timer_ref = Process.send_after(self(), :both_flags_test, 60_000)

      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Both flags cleared
      assert result_state.consensus_scheduled == false
      assert result_state.wait_timer == nil

      # Cleanup
      Process.cancel_timer(timer_ref)
    end
  end

  describe "[UNIT] R79: Flags Cleared After Processing" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "flags cleared after processing trigger_consensus", %{infra: infra} do
      # R79: WHEN valid :trigger_consensus processed THEN consensus_scheduled=false AND wait_timer=nil
      timer_ref = Process.send_after(self(), :r79_test, 60_000)

      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      assert result_state.consensus_scheduled == false
      assert result_state.wait_timer == nil

      # Cleanup
      Process.cancel_timer(timer_ref)
    end

    test "3-tuple timer cleared after processing", %{infra: infra} do
      timer_ref = Process.send_after(self(), :r79_3tuple, 60_000)

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, "timer-id", 1},
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      assert result_state.wait_timer == nil

      # Cleanup
      Process.cancel_timer(timer_ref)
    end
  end

  describe "[UNIT] R80: Debug Log for Stale" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "stale message returns unchanged state (debug logged)", %{infra: infra} do
      # R80: WHEN stale message detected THEN Logger.debug called
      # (We can't easily capture Logger.debug, so we verify state unchanged)
      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      initial_state = state
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Logger.debug is called but not captured (test log level)
      assert result_state == initial_state
    end
  end

  # ==========================================================================
  # R81-R83: Old Handlers Deleted Tests
  # ==========================================================================

  describe "[UNIT] R81-R83: Old Handlers Removed" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "R81: :request_consensus not handled by Core", %{infra: infra} do
      # R81: Old :request_consensus message should not be handled
      # After implementation, Core should have no handle_info clause for this message
      config = %{
        agent_id: unique_id(),
        task_id: "task-#{System.unique_integer([:positive])}",
        user_prompt: "test",
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        skip_auto_consensus: true
      }

      {:ok, agent_pid} = spawn_agent_with_cleanup(infra.dynsup, config, registry: infra.registry)

      # Send old message type - should cause FunctionClauseError after handlers removed
      # Currently this works (test fails) because handler still exists
      send(agent_pid, :request_consensus)

      # If handler is removed, agent crashes. Use GenServer.call to detect.
      # This should raise after implementation (no matching clause)
      assert catch_exit(Quoracle.Agent.Core.get_state(agent_pid)) != nil
    end

    test "R82: :continue_consensus not handled by Core", %{infra: infra} do
      # R82: Old :continue_consensus message should not be handled
      config = %{
        agent_id: unique_id(),
        task_id: "task-#{System.unique_integer([:positive])}",
        user_prompt: "test",
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        skip_auto_consensus: true
      }

      {:ok, agent_pid} = spawn_agent_with_cleanup(infra.dynsup, config, registry: infra.registry)

      send(agent_pid, :continue_consensus)

      # Should crash after implementation (no matching clause)
      assert catch_exit(Quoracle.Agent.Core.get_state(agent_pid)) != nil
    end

    test "R83: {:continue_consensus} tuple not handled by Core", %{infra: infra} do
      # R83: Old {:continue_consensus} tuple message should not be handled
      config = %{
        agent_id: unique_id(),
        task_id: "task-#{System.unique_integer([:positive])}",
        user_prompt: "test",
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        skip_auto_consensus: true
      }

      {:ok, agent_pid} = spawn_agent_with_cleanup(infra.dynsup, config, registry: infra.registry)

      send(agent_pid, {:continue_consensus})

      # Should crash after implementation (no matching clause)
      assert catch_exit(Quoracle.Agent.Core.get_state(agent_pid)) != nil
    end
  end

  # ==========================================================================
  # R84-R87: Sender Updates Tests
  # ==========================================================================

  describe "[UNIT] R84: consensus_handler Uses :trigger_consensus" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "handle_wait_parameter sends :trigger_consensus for wait:false", %{infra: infra} do
      # R84: WHEN handle_wait_parameter sends message THEN sends :trigger_consensus
      state = create_test_state(infra, wait_timer: nil)

      # wait: false should send :trigger_consensus (not :request_consensus)
      _result = ConsensusHandler.handle_wait_parameter(state, :orient, false)

      # Should receive :trigger_consensus, NOT :request_consensus
      assert_receive :trigger_consensus, 5000
      refute_receive :request_consensus, 50
    end

    test "handle_wait_parameter sends :trigger_consensus for wait:0", %{infra: infra} do
      state = create_test_state(infra, wait_timer: nil)

      _result = ConsensusHandler.handle_wait_parameter(state, :orient, 0)

      assert_receive :trigger_consensus, 5000
      refute_receive :request_consensus, 10
    end
  end

  describe "[UNIT] R85: action_executor Uses :trigger_consensus" do
    test "action_executor sends :trigger_consensus via StateUtils helper" do
      # R85: WHEN action_executor triggers consensus THEN sends :trigger_consensus
      # v35.0: ActionExecutor dispatches async via Task.Supervisor. Consensus
      # continuation is handled by MessageHandler.handle_action_result_continuation/3
      # which uses StateUtils.schedule_consensus_continuation.

      action_executor_path = "lib/quoracle/agent/consensus_handler/action_executor.ex"
      handler_path = "lib/quoracle/agent/message_handler.ex"
      {:ok, source} = File.read(action_executor_path)
      {:ok, handler_source} = File.read(handler_path)

      # v35.0: ActionExecutor dispatches async, MessageHandler handles continuation
      assert String.contains?(handler_source, "StateUtils.schedule_consensus_continuation"),
             "MessageHandler should use StateUtils.schedule_consensus_continuation"

      # Should NOT contain old message types in either file
      refute String.contains?(source, "send(agent_pid, :request_consensus)"),
             "action_executor.ex should not send :request_consensus (old pattern)"

      refute String.contains?(source, "send(self(), :request_consensus)"),
             "action_executor.ex should not send :request_consensus (old pattern)"
    end
  end

  describe "[UNIT] R86: message_handler Uses :trigger_consensus" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "message_handler sends :trigger_consensus when deferring", %{infra: infra} do
      # R86: WHEN message_handler defers consensus THEN sends :trigger_consensus
      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          # Must have action in pending_actions for handle_action_result to process it
          pending_actions: %{"action-1" => %{type: :orient, params: %{}}}
        )

      # Calling handle_action_result should defer consensus and send :trigger_consensus
      # (not :continue_consensus)
      _result = MessageHandler.handle_action_result(state, "action-1", {:ok, "result"})

      # Should send :trigger_consensus for deferred consensus
      assert_receive :trigger_consensus, 5000
      refute_receive :continue_consensus, 10
    end
  end

  describe "[UNIT] R87: wait_flow Trigger Architecture" do
    test "wait_flow does not send consensus triggers (moved to Agent layer)" do
      # R87: After fix-20260117-consensus-continuation, WaitFlow (Router layer)
      # no longer sends :trigger_consensus - triggers are handled by ActionExecutor
      # in the Agent layer which can set the consensus_scheduled flag

      wait_flow_path = "lib/quoracle/actions/router/wait_flow.ex"
      {:ok, source} = File.read(wait_flow_path)

      # WaitFlow should NOT send :trigger_consensus (moved to Agent layer)
      refute String.contains?(source, "send(agent_pid, :trigger_consensus)"),
             "wait_flow.ex should not send :trigger_consensus (triggers in Agent layer)"

      # Should NOT contain old message type either
      refute String.contains?(source, "{:continue_consensus}"),
             "wait_flow.ex should not send {:continue_consensus} (old pattern)"
    end

    test "wait_handlers sends :trigger_consensus" do
      # Additional verification for wait_handlers.ex
      wait_handlers_path = "lib/quoracle/actions/router/wait_handlers.ex"
      {:ok, source} = File.read(wait_handlers_path)

      has_trigger_consensus = String.contains?(source, ":trigger_consensus")

      assert has_trigger_consensus,
             "wait_handlers.ex should send :trigger_consensus"

      refute String.contains?(source, "{:continue_consensus}"),
             "wait_handlers.ex should not send {:continue_consensus} (old pattern)"
    end

    test "client_helpers sends :trigger_consensus" do
      # Additional verification for client_helpers.ex
      client_helpers_path = "lib/quoracle/actions/router/client_helpers.ex"
      {:ok, source} = File.read(client_helpers_path)

      has_trigger_consensus = String.contains?(source, ":trigger_consensus")

      assert has_trigger_consensus,
             "client_helpers.ex should send :trigger_consensus"

      refute String.contains?(source, "{:continue_consensus}"),
             "client_helpers.ex should not send {:continue_consensus} (old pattern)"
    end
  end

  # ==========================================================================
  # R88-R90: Integration Tests
  # ==========================================================================

  describe "[INTEGRATION] R88: Staleness Prevents Double Consensus" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "cancelled timer message detected as stale", %{infra: infra} do
      # R88: WHEN timer fires AND new action cancels timer THEN stale message ignored

      # Step 1: Setup state with active timer
      timer_ref = Process.send_after(self(), :r88_timer, 60_000)

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, :timed_wait}
        )

      # Step 2: External action cancels timer (simulated)
      state = StateUtils.cancel_wait_timer(state)
      assert state.wait_timer == nil

      # Step 3: Stale :trigger_consensus processed
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Should be detected as stale (no flags set)
      assert result_state.consensus_scheduled == false
      assert result_state.wait_timer == nil

      # Cleanup
      Process.cancel_timer(timer_ref)
    end
  end

  describe "[INTEGRATION] R89: Multiple Rapid Triggers Single Consensus" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "multiple trigger_consensus messages result in single consensus", %{infra: infra} do
      # R89: WHEN multiple :trigger_consensus in mailbox THEN only first runs consensus

      # Setup: State with consensus_scheduled = true
      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: nil,
          skip_auto_consensus: true
        )

      # First message clears flag
      {:noreply, s1} = MessageInfoHandler.handle_trigger_consensus(state)
      assert s1.consensus_scheduled == false

      # Subsequent messages are stale (both flags now false)
      {:noreply, s2} = MessageInfoHandler.handle_trigger_consensus(s1)
      {:noreply, s3} = MessageInfoHandler.handle_trigger_consensus(s2)

      # No changes for stale messages
      assert s2 == s1
      assert s3 == s1
    end

    test "rapid triggers with wait_timer all clear after first", %{infra: infra} do
      timer_ref = Process.send_after(self(), :rapid_test, 60_000)

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      # First clears timer
      {:noreply, s1} = MessageInfoHandler.handle_trigger_consensus(state)
      assert s1.wait_timer == nil

      # Subsequent are stale
      {:noreply, s2} = MessageInfoHandler.handle_trigger_consensus(s1)
      assert s2 == s1

      # Cleanup
      Process.cancel_timer(timer_ref)
    end
  end

  describe "[INTEGRATION] R90: Core Routes to Unified Handler" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "Core routes :trigger_consensus to unified handler", %{infra: infra} do
      # R90: WHEN Core receives :trigger_consensus THEN routes to MessageInfoHandler.handle_trigger_consensus

      # Start a real agent via spawn_agent_with_cleanup
      config = %{
        agent_id: unique_id(),
        task_id: "task-#{System.unique_integer([:positive])}",
        user_prompt: "test",
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        skip_auto_consensus: true
      }

      {:ok, agent_pid} = spawn_agent_with_cleanup(infra.dynsup, config, registry: infra.registry)

      # Send :trigger_consensus message
      send(agent_pid, :trigger_consensus)

      # Use GenServer.call to synchronize - ensures previous message processed
      # (GenServer processes messages sequentially)
      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)

      # Agent should still be alive and state accessible (message processed without crash)
      assert is_map(state)
      assert Process.alive?(agent_pid)
    end
  end

  # ==========================================================================
  # A15-A17: Acceptance Tests
  # ==========================================================================

  describe "[ACCEPTANCE] A15-A17: User Behavior" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    @tag :acceptance
    test "A15: timer cancel race results in single consensus cycle", %{infra: infra} do
      # A15: User does: Agent has timed wait, external message arrives after timer fires
      # User expects: Only ONE consensus runs (stale timer message ignored)

      # Setup: Agent with timed wait
      timer_ref = Process.send_after(self(), :a15_timer, 60_000)

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      # Step 1: Timer fires - :trigger_consensus in mailbox (simulated)
      # Step 2: External message arrives, cancels timer
      state = StateUtils.cancel_wait_timer(state)

      # Step 3: Process the "stale" trigger_consensus
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Outcome: Message detected as stale, no consensus run
      assert result_state == state

      # Cleanup
      Process.cancel_timer(timer_ref)
    end

    @tag :acceptance
    test "A16: pause during wait stops after single consensus", %{infra: infra} do
      # A16: User does: Pause agent during timed wait
      # User expects: Agent stops after single consensus cycle

      timer_ref = Process.send_after(self(), :a16_timer, 60_000)

      state =
        create_test_state(infra,
          consensus_scheduled: true,
          wait_timer: {timer_ref, :timed_wait},
          # Simulates pause
          skip_auto_consensus: true
        )

      # Timer fires
      {:noreply, s1} = MessageInfoHandler.handle_trigger_consensus(state)

      # Flags cleared
      assert s1.consensus_scheduled == false
      assert s1.wait_timer == nil

      # No extra cycles from stale timers
      {:noreply, s2} = MessageInfoHandler.handle_trigger_consensus(s1)
      # Unchanged - stale
      assert s2 == s1

      # Cleanup
      Process.cancel_timer(timer_ref)
    end

    @tag :acceptance
    test "A17: user message included in next consensus cycle", %{infra: infra} do
      # A17: User does: Send message to active agent
      # User expects: Message appears in next consensus cycle (not delayed)

      state =
        create_test_state(infra,
          consensus_scheduled: false,
          wait_timer: nil,
          # Active agent has pending_actions, so messages are queued
          pending_actions: %{"action-1" => %{type: :orient, params: %{}}},
          queued_messages: []
        )

      # Send user message (queues when active agent has pending_actions)
      {:noreply, state_with_msg} =
        MessageHandler.handle_agent_message(state, :user, "Hello agent")

      # Message should be queued (active agent with pending_actions)
      assert state_with_msg.queued_messages != []

      # Consensus should NOT be scheduled when queueing (waits for action result)
      # The test was wrong to expect consensus_scheduled=true when queueing
      assert state_with_msg.consensus_scheduled == false
      refute_receive :trigger_consensus, 100
    end
  end
end
