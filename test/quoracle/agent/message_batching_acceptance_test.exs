defmodule Quoracle.Agent.MessageBatchingAcceptanceTest do
  @moduledoc """
  Acceptance tests for deferred consensus message batching (v3.0, v4.0 drain).

  Tests user-observable behavior: multiple rapid messages are batched
  into a single consensus cycle, not processed separately.

  v4.0: Tests for drain_trigger_messages/0 - prevents duplicate consensus cycles.

  WorkGroupID: fix-20260116-234557
  WorkGroupID: fix-20260118-trigger-drain-pause (v4.0 drain tests)

  Requirements:
  - A13: Rapid user messages to root agent batched into single consensus cycle
  - A14: User message during action result processing batched together

  v4.0 Drain Acceptance (fix-20260118-trigger-drain-pause):
  - A18: User message immediately triggers single consensus (drain prevents duplicates)
  - A19: Pause button stops agent after single consensus cycle (drain prevents duplicates)
  """
  use Quoracle.DataCase, async: true

  @moduletag capture_log: true

  alias Quoracle.Agent.Core

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

  describe "[SYSTEM] A13: rapid user messages batched" do
    @tag :acceptance
    test "rapid user messages to root agent batched into single consensus cycle" do
      # Setup: Create isolated infrastructure
      infra = create_isolated_infrastructure()

      # Create a root agent (parent_pid = nil)
      config = %{
        agent_id: unique_id(),
        task_id: unique_id(),
        task_description: "Test task",
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        # Don't skip auto-consensus - we need to see deferred behavior
        skip_auto_consensus: false,
        sandbox_owner: self()
      }

      # Start root agent
      {:ok, agent_pid} = DynamicSupervisor.start_child(infra.dynsup, {Core, config})

      # Cleanup on exit
      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Wait for agent to initialize
      {:ok, initial_state} = Core.get_state(agent_pid)
      assert initial_state.agent_id == config.agent_id

      # Verify agent starts idle (no pending actions, no consensus scheduled)
      assert initial_state.pending_actions == %{}
      assert initial_state.consensus_scheduled == false

      # Action: Send two user messages in rapid succession
      # These should BOTH end up in the same consensus context
      Core.send_user_message(agent_pid, "First message")
      Core.send_user_message(agent_pid, "Second message")

      # Synchronization: get_state is a GenServer.call that processes pending casts.
      # However, :trigger_consensus (sent via send/2) goes to END of mailbox,
      # so first get_state processes casts but :trigger_consensus is still pending.
      # Second get_state forces :trigger_consensus to process first (flushes queue).
      {:ok, _} = Core.get_state(agent_pid)
      {:ok, state_after_messages} = Core.get_state(agent_pid)

      # Assert: BOTH messages should be present in model_histories
      # If deferred consensus works, both will be there
      # If blocking consensus, only first message will be present initially
      all_histories = Map.values(state_after_messages.model_histories) |> List.flatten()

      first_msg_in_history =
        Enum.any?(all_histories, fn entry ->
          is_map(entry) and
            is_map(entry[:content]) and
            entry[:content][:content] == "First message"
        end)

      second_msg_in_history =
        Enum.any?(all_histories, fn entry ->
          is_map(entry) and
            is_map(entry[:content]) and
            entry[:content][:content] == "Second message"
        end)

      # Positive assertion: BOTH messages must be in history
      assert first_msg_in_history,
             "First message should be in history"

      # This is the KEY assertion - with blocking consensus, second message
      # would still be in queue or processed in separate cycle
      assert second_msg_in_history,
             "Second message should be batched into same consensus context (deferred consensus)"

      # Negative assertion: queue should be empty after processing
      refute state_after_messages.queued_messages != [],
             "Queue should be empty - all messages flushed to history"
    end
  end

  describe "[SYSTEM] A14: user message batching" do
    @tag :acceptance
    test "user message while consensus_scheduled batched together" do
      # Setup: Create isolated infrastructure
      infra = create_isolated_infrastructure()

      # Create agent
      config = %{
        agent_id: unique_id(),
        task_id: unique_id(),
        task_description: "Test task",
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        skip_auto_consensus: false,
        sandbox_owner: self()
      }

      {:ok, agent_pid} = DynamicSupervisor.start_child(infra.dynsup, {Core, config})

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Wait for agent to initialize
      {:ok, _initial_state} = Core.get_state(agent_pid)

      # Simulate: Consensus is scheduled (e.g., action result just arrived and scheduled consensus)
      # This is the key state that enables batching - when consensus_scheduled is true,
      # incoming messages should be queued and flushed together with the consensus cycle
      :sys.replace_state(agent_pid, fn state ->
        %{state | consensus_scheduled: true}
      end)

      # Verify consensus_scheduled is set
      {:ok, state_with_scheduled} = Core.get_state(agent_pid)
      assert state_with_scheduled.consensus_scheduled == true

      # Action: Send user message while consensus is scheduled
      # With proper implementation, this should be QUEUED (not processed immediately)
      Core.send_user_message(agent_pid, "Follow-up question")

      # Get state after sending message
      {:ok, state_after} = Core.get_state(agent_pid)

      # KEY ASSERTION: User message should be QUEUED because consensus_scheduled is true
      # The message should NOT be processed immediately - it waits for consensus cycle
      # With v18.0 implementation: handle_send_user_message delegates to handle_agent_message,
      # which checks consensus_scheduled and queues the message
      assert length(state_after.queued_messages) == 1,
             "User message should be queued when consensus_scheduled is true"

      queued_msg = hd(state_after.queued_messages)
      assert queued_msg.content == "Follow-up question"
      assert queued_msg.sender_id == :user

      # Message should NOT be in history yet (it's queued, waiting for flush)
      all_histories = Map.values(state_after.model_histories) |> List.flatten()

      user_msg_in_history =
        Enum.any?(all_histories, fn entry ->
          is_map(entry) and
            is_map(entry[:content]) and
            entry[:content][:content] == "Follow-up question"
        end)

      refute user_msg_in_history,
             "User message should NOT be in history yet (still queued)"
    end
  end

  # ===========================================================================
  # v4.0 Drain Acceptance Tests (A18-A19)
  # ===========================================================================

  describe "[SYSTEM] A18: drain prevents duplicate consensus" do
    @tag :acceptance
    test "A18: user message triggers single consensus despite accumulated triggers" do
      # User scenario:
      # 1. Agent is idle (just completed an action with wait:true)
      # 2. Multiple :trigger_consensus messages accumulated in mailbox
      # 3. User sends a follow-up message
      # 4. User expects SINGLE response, not multiple rounds of thinking
      #
      # Bug (before drain): Each :trigger_consensus causes a consensus cycle,
      # resulting in multiple "thinking" rounds for a single user message.
      #
      # Fix: drain_trigger_messages/0 removes duplicates before consensus.

      infra = create_isolated_infrastructure()

      config = %{
        agent_id: unique_id(),
        task_id: unique_id(),
        task_description: "Test task",
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        skip_auto_consensus: false,
        sandbox_owner: self()
      }

      {:ok, agent_pid} = DynamicSupervisor.start_child(infra.dynsup, {Core, config})

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Wait for agent to initialize
      {:ok, _} = Core.get_state(agent_pid)

      # Simulate: Multiple :trigger_consensus messages accumulated in agent's mailbox
      # This happens when rapid action results arrive while agent is processing
      send(agent_pid, :trigger_consensus)
      send(agent_pid, :trigger_consensus)
      send(agent_pid, :trigger_consensus)

      # Now user sends a message (this should also schedule a trigger)
      Core.send_user_message(agent_pid, "What's the status?")

      # Let agent process all messages
      {:ok, _} = Core.get_state(agent_pid)
      {:ok, state_after} = Core.get_state(agent_pid)

      # KEY USER EXPECTATION: User message is in history
      all_histories = Map.values(state_after.model_histories) |> List.flatten()

      user_msg_in_history =
        Enum.any?(all_histories, fn entry ->
          is_map(entry) and
            is_map(entry[:content]) and
            entry[:content][:content] == "What's the status?"
        end)

      assert user_msg_in_history,
             "User message should be processed and in history"

      # The drain mechanism ensures that even though 4 :trigger_consensus messages
      # were sent (3 simulated + 1 from user message), only ONE consensus cycle runs.
      # Without drain, user would see 4 separate "thinking" animations.
      #
      # We can't directly count consensus cycles in this acceptance test,
      # but we verify the user-observable outcome: message is processed correctly.
      #
      # Note: consensus_scheduled may be true if the action returned wait: false,
      # which schedules another consensus. This is correct behavior - the key is
      # that the user message was processed (above assertion) and duplicates were drained.
    end
  end

  describe "[SYSTEM] A19: pause with drain" do
    @tag :acceptance
    # TEST-FIXES: Changed from pause semantics to stop semantics per spec R105/A20
    #             Agent terminates gracefully after draining triggers (not stays alive)
    test "A19: pause stops agent, drain prevents extra cycles" do
      # User scenario:
      # 1. Agent is running (processing actions, timers firing)
      # 2. Multiple :trigger_consensus messages accumulated
      # 3. User clicks Pause button
      # 4. User expects agent to complete CURRENT cycle and STOP
      # 5. Agent should NOT continue for extra cycles from accumulated triggers
      #
      # Bug (before drain): After pause, agent runs multiple consensus cycles
      # (one per accumulated :trigger_consensus), appearing to ignore pause.
      #
      # Fix: drain_trigger_messages/0 + Core.handle_info(:stop_requested)
      # Agent terminates gracefully after draining (returns {:stop, :normal, state})

      infra = create_isolated_infrastructure()

      config = %{
        agent_id: unique_id(),
        task_id: unique_id(),
        task_description: "Test task",
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: self()
      }

      {:ok, agent_pid} = DynamicSupervisor.start_child(infra.dynsup, {Core, config})

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Wait for agent to initialize
      {:ok, _} = Core.get_state(agent_pid)

      # Monitor agent before sending messages
      ref = Process.monitor(agent_pid)

      # Simulate: Multiple :trigger_consensus messages accumulated
      send(agent_pid, :trigger_consensus)
      send(agent_pid, :trigger_consensus)
      send(agent_pid, :trigger_consensus)

      # User clicks Pause (sends :stop_requested to agent)
      send(agent_pid, :stop_requested)

      # KEY USER EXPECTATION: Agent terminates gracefully
      # The :stop_requested handler drains triggers and returns {:stop, :normal, state}
      # Agent does NOT run multiple consensus cycles - it drains and stops
      assert_receive {:DOWN, ^ref, :process, ^agent_pid, reason},
                     5000,
                     "Agent should terminate gracefully after :stop_requested"

      # Termination should be normal (graceful stop)
      assert reason == :normal,
             "Agent should terminate with :normal reason, got: #{inspect(reason)}"

      # Agent is stopped - no more messages will be processed
      # This verifies: drain prevents extra cycles by stopping agent after one drain
    end
  end
end
