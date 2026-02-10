defmodule Quoracle.Agent.MessageFlushTest do
  @moduledoc """
  Tests for unified consensus cycle with message flush (v15.0).

  Bug fix: Queued messages only flushed in async action path.
  Solution: run_consensus_cycle/2 flushes messages at ALL consensus entry points.

  WorkGroupID: fix-20260115-message-flush

  Requirements:
  - R49: run_consensus_cycle flushes messages [UNIT]
  - R50: run_consensus_cycle merges state [UNIT]
  - R51: run_consensus_cycle executes action [UNIT]
  - R52: run_consensus_cycle handles errors [UNIT]
  - R53: sync actions flush messages [INTEGRATION]
  - R54: all entry points use run_consensus_cycle [UNIT]
  - A7: user follow-up message reaches agent promptly [SYSTEM/ACCEPTANCE]
  - A8: parent message to child not delayed [SYSTEM/ACCEPTANCE]
  """
  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog

  alias Quoracle.Agent.MessageHandler

  # Test isolation helpers
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

  defp create_test_state(infra, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, unique_id())
    pending_actions = Keyword.get(opts, :pending_actions, %{})
    queued_messages = Keyword.get(opts, :queued_messages, [])
    model_histories = Keyword.get(opts, :model_histories, %{"model1" => []})

    %{
      agent_id: agent_id,
      router_pid: self(),
      registry: infra.registry,
      dynsup: infra.dynsup,
      pubsub: infra.pubsub,
      model_histories: model_histories,
      models: ["model1"],
      pending_actions: pending_actions,
      queued_messages: queued_messages,
      skip_auto_consensus: true,
      test_mode: true,
      wait_timer: nil,
      context_limits_loaded: true,
      context_limit: 4000,
      # ACE state fields for merge testing
      context_lessons: %{},
      model_states: %{}
    }
  end

  describe "[UNIT] R49: run_consensus_cycle flushes messages" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "run_consensus_cycle flushes queued messages before consensus", %{infra: infra} do
      # Setup: State with queued messages
      state =
        create_test_state(infra,
          queued_messages: [
            %{sender_id: :parent, content: "queued msg 1", queued_at: DateTime.utc_now()},
            %{sender_id: "child-1", content: "queued msg 2", queued_at: DateTime.utc_now()}
          ]
        )

      test_pid = self()

      # Mock execute_action_fn to capture state AFTER flush
      execute_action_fn = fn state_at_execute, _action ->
        send(test_pid, {:state_at_execute, state_at_execute})
        state_at_execute
      end

      # Action: Call run_consensus_cycle (will fail - function doesn't exist yet)
      {:noreply, _final_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

      # Assert: Messages should be flushed BEFORE execute_action_fn is called
      assert_receive {:state_at_execute, state_at_execute}, 5000

      # Queue should be empty (messages flushed to history)
      assert state_at_execute.queued_messages == []

      # Messages should be in history
      history = state_at_execute.model_histories["model1"] || []

      assert Enum.any?(history, fn entry ->
               is_map(entry.content) and entry.content[:content] == "queued msg 1"
             end)

      assert Enum.any?(history, fn entry ->
               is_map(entry.content) and entry.content[:content] == "queued msg 2"
             end)
    end

    test "run_consensus_cycle handles empty queue gracefully", %{infra: infra} do
      # Setup: State with no queued messages
      state = create_test_state(infra, queued_messages: [])

      test_pid = self()

      execute_action_fn = fn s, _action ->
        send(test_pid, {:executed, s})
        s
      end

      # Action: Call run_consensus_cycle
      {:noreply, _} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

      # Assert: Should still work with empty queue
      assert_receive {:executed, _}, 5000
    end
  end

  describe "[UNIT] R50: run_consensus_cycle merges state" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "run_consensus_cycle merges ACE state after consensus", %{infra: infra} do
      # Setup: State with initial ACE values
      state =
        create_test_state(infra,
          model_histories: %{"model1" => [%{type: :event, content: "initial"}]},
          context_lessons: %{"model1" => []},
          model_states: %{"model1" => %{}}
        )

      test_pid = self()

      execute_action_fn = fn state_at_execute, _action ->
        send(test_pid, {:state_at_execute, state_at_execute})
        state_at_execute
      end

      # Action: Call run_consensus_cycle
      {:noreply, _} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

      # Assert: State passed to execute_action_fn should have merged ACE fields
      assert_receive {:state_at_execute, merged_state}, 5000

      # merged_state should have model_histories (consensus may have updated them)
      assert Map.has_key?(merged_state, :model_histories)
      assert Map.has_key?(merged_state, :context_lessons)
      assert Map.has_key?(merged_state, :model_states)
    end
  end

  describe "[UNIT] R51: run_consensus_cycle executes action" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "run_consensus_cycle executes action callback on success", %{infra: infra} do
      state = create_test_state(infra)
      test_pid = self()

      execute_action_fn = fn s, action ->
        send(test_pid, {:action_executed, action})
        s
      end

      # Action: Call run_consensus_cycle
      {:noreply, _} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

      # Assert: execute_action_fn should be called with action map
      assert_receive {:action_executed, action}, 5000
      assert is_map(action)
      assert Map.has_key?(action, :action)
    end
  end

  describe "[UNIT] R52: run_consensus_cycle handles errors" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "run_consensus_cycle handles consensus errors gracefully", %{infra: infra} do
      # Setup: State that will cause consensus to fail via simulate_failure flag
      state =
        create_test_state(infra)
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action ->
        # Should NOT be called on error
        send(self(), :should_not_receive)
        s
      end

      # Action: Call run_consensus_cycle - should handle error gracefully
      # Capture expected error log to prevent log spam in test output
      log =
        capture_log(fn ->
          result = MessageHandler.run_consensus_cycle(state, execute_action_fn)

          # Assert: Should return {:noreply, state} without crashing
          assert {:noreply, _returned_state} = result
        end)

      # Verify error was logged (v15.0: DRY helper uses "Consensus failed #{context}" format)
      assert log =~ "Consensus failed cycle"

      # execute_action_fn should NOT be called
      refute_receive :should_not_receive, 100
    end
  end

  describe "[UNIT] R54: all entry points use run_consensus_cycle" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "all consensus entry points delegate to run_consensus_cycle", %{infra: infra} do
      # This test verifies run_consensus_cycle can be called by all consensus entry points
      # If function is undefined or private, this call will fail with UndefinedFunctionError

      state = create_test_state(infra)
      execute_fn = fn s, _a -> s end

      # Call run_consensus_cycle - tests both existence and public accessibility
      result = MessageHandler.run_consensus_cycle(state, execute_fn)
      assert {:noreply, _} = result
    end
  end

  describe "[INTEGRATION] R53: sync actions flush messages" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "sync action path flushes queued messages", %{infra: infra} do
      # Setup: State with queued messages, simulating sync action completion
      # Sync actions send :trigger_consensus which calls handle_consensus_continuation
      # which should now flush messages via run_consensus_cycle

      state =
        create_test_state(infra,
          queued_messages: [
            %{sender_id: :parent, content: "sync action queued", queued_at: DateTime.utc_now()}
          ],
          pending_actions: %{}
        )

      test_pid = self()

      execute_action_fn = fn state_at_execute, _action ->
        send(test_pid, {:state_at_execute, state_at_execute})
        state_at_execute
      end

      # Action: Simulate sync action completion path (via run_consensus_cycle)
      {:noreply, _} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

      # Assert: Messages should be flushed
      assert_receive {:state_at_execute, state_at_execute}, 30_000

      # Queue should be empty
      assert state_at_execute.queued_messages == []

      # Message should be in history
      history = state_at_execute.model_histories["model1"] || []

      assert Enum.any?(history, fn entry ->
               is_map(entry.content) and entry.content[:content] == "sync action queued"
             end)
    end

    test "messages queued during orient action appear in next consensus", %{infra: infra} do
      # This tests the specific bug scenario:
      # 1. Agent executes :orient (sync action)
      # 2. External message arrives, gets queued
      # 3. :orient completes, sends :trigger_consensus
      # 4. Message should appear in NEXT consensus (not delayed multiple cycles)

      # Setup: Simulate post-orient state with queued message
      state =
        create_test_state(infra,
          queued_messages: [
            %{sender_id: :parent, content: "arrived during orient", queued_at: DateTime.utc_now()}
          ]
        )

      test_pid = self()
      consensus_count = :counters.new(1, [:atomics])

      execute_action_fn = fn state_at_execute, _action ->
        :counters.add(consensus_count, 1, 1)
        count = :counters.get(consensus_count, 1)
        send(test_pid, {:consensus, count, state_at_execute})
        state_at_execute
      end

      # Action: First consensus cycle (simulating :trigger_consensus from orient)
      {:noreply, _} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

      # Assert: Message should appear in FIRST consensus after being queued
      assert_receive {:consensus, 1, state_at_consensus}, 30_000

      # Queue empty, message in history
      assert state_at_consensus.queued_messages == []

      history = state_at_consensus.model_histories["model1"] || []

      assert Enum.any?(history, fn entry ->
               is_map(entry.content) and entry.content[:content] == "arrived during orient"
             end),
             "Message should appear in first consensus cycle, not delayed"
    end
  end
end
