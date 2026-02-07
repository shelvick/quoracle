defmodule Quoracle.Agent.WaitExpiredStalenessTest do
  @moduledoc """
  Tests for {:wait_expired, timer_ref} staleness detection.

  WorkGroupID: fix-20260120-wait-expired-staleness
  Packet: 1 (Single TDD Cycle)
  Requirements: R105-R115, A18-A20

  Problem: handle_wait_expired/2 ignores timer_ref, causing phantom consensus cycles.
  Fix: Add staleness check that validates timer_ref against state.wait_timer.
  """
  use Quoracle.DataCase, async: true

  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core
  alias Quoracle.Agent.Core.MessageInfoHandler
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
    wait_timer = Keyword.get(opts, :wait_timer, nil)
    skip_auto_consensus = Keyword.get(opts, :skip_auto_consensus, true)

    %{
      agent_id: agent_id,
      router_pid: self(),
      registry: infra.registry,
      dynsup: infra.dynsup,
      pubsub: infra.pubsub,
      model_histories: %{"model1" => []},
      models: ["model1"],
      pending_actions: %{},
      queued_messages: [],
      consensus_scheduled: false,
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
  # R105-R110: Unit Tests - Staleness Detection
  # ==========================================================================

  describe "[UNIT] R105-R110: Staleness Detection" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "R105: stale wait_expired ignored when wait_timer is nil", %{infra: infra} do
      # R105: WHEN wait_expired received WITH timer_ref
      # IF wait_timer is nil THEN message is stale, state unchanged
      state = create_test_state(infra, wait_timer: nil)
      stale_ref = make_ref()

      initial_state = state
      {:noreply, result_state} = MessageInfoHandler.handle_wait_expired(stale_ref, state)

      # State unchanged - stale message ignored
      assert result_state == initial_state
    end

    test "R106: stale wait_expired ignored when ref doesn't match 2-tuple", %{infra: infra} do
      # R106: WHEN wait_expired received WITH different timer_ref
      # IF wait_timer is {other_ref, :timed_wait} THEN message is stale
      current_ref = make_ref()
      stale_ref = make_ref()
      state = create_test_state(infra, wait_timer: {current_ref, :timed_wait})

      initial_state = state
      {:noreply, result_state} = MessageInfoHandler.handle_wait_expired(stale_ref, state)

      # State unchanged - stale message ignored
      assert result_state == initial_state
      # wait_timer NOT cleared (stale message shouldn't touch it)
      assert result_state.wait_timer == {current_ref, :timed_wait}
    end

    test "R107: stale wait_expired ignored when ref doesn't match 3-tuple", %{infra: infra} do
      # R107: WHEN wait_expired received WITH different timer_ref
      # IF wait_timer is {other_ref, timer_id, gen} THEN message is stale
      current_ref = make_ref()
      stale_ref = make_ref()
      state = create_test_state(infra, wait_timer: {current_ref, "timer-123", 1})

      initial_state = state
      {:noreply, result_state} = MessageInfoHandler.handle_wait_expired(stale_ref, state)

      # State unchanged - stale message ignored
      assert result_state == initial_state
      # wait_timer NOT cleared
      assert result_state.wait_timer == {current_ref, "timer-123", 1}
    end

    test "R108: valid wait_expired processed when ref matches 2-tuple", %{infra: infra} do
      # R108: WHEN wait_expired received WITH matching timer_ref
      # IF wait_timer is {timer_ref, :timed_wait} THEN process and clear timer
      timer_ref = make_ref()

      state =
        create_test_state(infra,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_wait_expired(timer_ref, state)

      # wait_timer cleared after processing valid message
      # NOTE: This will FAIL with buggy code - timer_ref is ignored, timer not cleared
      assert result_state.wait_timer == nil
    end

    test "R109: valid wait_expired processed when ref matches 3-tuple", %{infra: infra} do
      # R109: WHEN wait_expired received WITH matching timer_ref
      # IF wait_timer is {timer_ref, timer_id, gen} THEN process and clear timer
      timer_ref = make_ref()

      state =
        create_test_state(infra,
          wait_timer: {timer_ref, "timer-456", 2},
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_wait_expired(timer_ref, state)

      # wait_timer cleared after processing valid message
      # NOTE: This will FAIL with buggy code - timer_ref is ignored, timer not cleared
      assert result_state.wait_timer == nil
    end

    test "R110: valid wait_expired respects skip_auto_consensus flag", %{infra: infra} do
      # R110: WHEN valid wait_expired processed WITH skip_auto_consensus=true
      # THEN timer cleared but no consensus triggered
      timer_ref = make_ref()

      state =
        create_test_state(infra,
          wait_timer: {timer_ref, :timed_wait},
          skip_auto_consensus: true
        )

      {:noreply, result_state} = MessageInfoHandler.handle_wait_expired(timer_ref, state)

      # Timer cleared but no consensus triggered (skip_auto_consensus = true)
      # NOTE: This will FAIL with buggy code - timer not cleared
      assert result_state.wait_timer == nil
      # No additional state changes from consensus (consensus_scheduled still false)
      assert result_state.consensus_scheduled == false
    end
  end

  # ==========================================================================
  # R111: Unit Tests - Debug Logging
  # ==========================================================================

  describe "[UNIT] R111: Debug Logging" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "R111: stale wait_expired logs debug message", %{infra: infra} do
      # R111: WHEN stale wait_expired message detected THEN log debug message
      # NOTE: Logger.debug is called but not captured in test env (test log level).
      # We verify the stale branch is taken by checking state is unchanged.
      # (Same pattern as consensus_staleness_test.exs lines 241-253)
      state = create_test_state(infra, wait_timer: nil)
      stale_ref = make_ref()

      initial_state = state
      {:noreply, result_state} = MessageInfoHandler.handle_wait_expired(stale_ref, state)

      # State unchanged proves stale branch was taken (which includes Logger.debug call)
      assert result_state == initial_state
    end
  end

  # ==========================================================================
  # R112-R114: Integration Tests - Timer Lifecycle
  # ==========================================================================

  describe "[INTEGRATION] R112-R114: Timer Lifecycle" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "R112: cancelled timer message detected as stale", %{infra: infra} do
      # R112: WHEN timer is cancelled externally
      # AND original timer message arrives THEN detected as stale
      timer_ref = make_ref()
      state = create_test_state(infra, wait_timer: {timer_ref, :timed_wait})

      # Step 1: Timer is cancelled externally (simulated by clearing wait_timer)
      state = StateUtils.cancel_wait_timer(state)
      assert state.wait_timer == nil

      # Step 2: Original timer message arrives (now stale)
      {:noreply, result_state} = MessageInfoHandler.handle_wait_expired(timer_ref, state)

      # Should be detected as stale - no changes
      assert result_state == state
    end

    test "R113: replaced timer message detected as stale", %{infra: infra} do
      # R113: WHEN timer is replaced by new timer
      # AND old timer message arrives THEN detected as stale
      old_ref = make_ref()
      state = create_test_state(infra, wait_timer: {old_ref, :timed_wait})

      # Step 1: New timer replaces old one
      new_ref = make_ref()
      state = %{state | wait_timer: {new_ref, :timed_wait}}

      # Step 2: Old timer message arrives (now stale)
      {:noreply, result_state} = MessageInfoHandler.handle_wait_expired(old_ref, state)

      # Should be detected as stale - timer NOT cleared (new timer still active)
      assert result_state.wait_timer == {new_ref, :timed_wait}
    end

    test "R114: multiple stale wait_expired messages have no cumulative effect", %{infra: infra} do
      # R114: WHEN multiple stale messages arrive THEN no cumulative effects
      current_ref = make_ref()
      state = create_test_state(infra, wait_timer: {current_ref, :timed_wait})

      stale_refs = [make_ref(), make_ref(), make_ref()]

      final_state =
        Enum.reduce(stale_refs, state, fn stale_ref, acc ->
          {:noreply, new_state} = MessageInfoHandler.handle_wait_expired(stale_ref, acc)
          new_state
        end)

      # State unchanged after processing multiple stale messages
      assert final_state == state
      assert final_state.wait_timer == {current_ref, :timed_wait}
    end
  end

  # ==========================================================================
  # A18-A20: Acceptance Tests - User Behavior
  # ==========================================================================

  describe "[ACCEPTANCE] A18-A20: User Behavior" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra, sandbox_owner: self()}
    end

    @tag :acceptance
    test "A18: timer cancel race results in single consensus cycle", %{
      infra: infra,
      sandbox_owner: sandbox_owner
    } do
      # A18: WHEN timer fires AND external message cancels timer
      # THEN only one consensus cycle runs (stale timer ignored)

      # Setup: Start real agent
      config = %{
        agent_id: unique_id(),
        user_prompt: "Test task",
        models: ["test-model"],
        test_mode: true,
        skip_auto_consensus: true
      }

      opts = [
        registry: infra.registry,
        pubsub: infra.pubsub,
        sandbox_owner: sandbox_owner
      ]

      {:ok, agent_pid} = spawn_agent_with_cleanup(infra.dynsup, config, opts)

      # Subscribe to consensus events
      Phoenix.PubSub.subscribe(infra.pubsub, "agent:#{config.agent_id}")

      # Step 1: Set up a wait timer on the agent
      old_timer_ref = make_ref()

      :sys.replace_state(agent_pid, fn state ->
        %{state | wait_timer: {old_timer_ref, :timed_wait}, skip_auto_consensus: false}
      end)

      # Step 2: Simulate timer replacement (new wait started)
      new_timer_ref = make_ref()

      :sys.replace_state(agent_pid, fn state ->
        %{state | wait_timer: {new_timer_ref, :timed_wait}}
      end)

      # Step 3: Send old timer message (should be stale)
      send(agent_pid, {:wait_expired, old_timer_ref})

      # Step 4: Verify state - timer should NOT have been cleared by stale message
      # Core.get_state is a GenServer.call, so FIFO guarantees :wait_expired processed first
      {:ok, state} = Core.get_state(agent_pid)

      # NOTE: This will FAIL with buggy code - stale timer triggers consensus
      assert state.wait_timer == {new_timer_ref, :timed_wait}
    end

    @tag :acceptance
    test "A19: pause during wait stops after single consensus", %{
      infra: infra,
      sandbox_owner: sandbox_owner
    } do
      # A19: WHEN agent is paused (skip_auto_consensus=true)
      # AND wait timer fires THEN agent stops (no extra cycles from stale timers)

      config = %{
        agent_id: unique_id(),
        user_prompt: "Test task",
        models: ["test-model"],
        test_mode: true,
        skip_auto_consensus: true
      }

      opts = [
        registry: infra.registry,
        pubsub: infra.pubsub,
        sandbox_owner: sandbox_owner
      ]

      {:ok, agent_pid} = spawn_agent_with_cleanup(infra.dynsup, config, opts)

      # Set up timer
      timer_ref = make_ref()

      :sys.replace_state(agent_pid, fn state ->
        %{state | wait_timer: {timer_ref, :timed_wait}}
      end)

      # "Pause" agent (already paused via skip_auto_consensus)
      # Send valid wait_expired
      send(agent_pid, {:wait_expired, timer_ref})

      # Verify timer was cleared (valid message processed)
      # Core.get_state is a GenServer.call, so FIFO guarantees :wait_expired processed first
      {:ok, state} = Core.get_state(agent_pid)

      # NOTE: This will FAIL with buggy code - timer not cleared
      assert state.wait_timer == nil
      # Should still be paused
      assert state.skip_auto_consensus == true
    end

    @tag :acceptance
    test "A20: stale wait_expired doesn't interrupt subsequent wait", %{
      infra: infra,
      sandbox_owner: sandbox_owner
    } do
      # A20: WHEN old timer fires after new wait started
      # THEN stale timer ignored, new wait continues

      config = %{
        agent_id: unique_id(),
        user_prompt: "Test task",
        models: ["test-model"],
        test_mode: true,
        skip_auto_consensus: true
      }

      opts = [
        registry: infra.registry,
        pubsub: infra.pubsub,
        sandbox_owner: sandbox_owner
      ]

      {:ok, agent_pid} = spawn_agent_with_cleanup(infra.dynsup, config, opts)

      # Set up first timer (short wait)
      old_ref = make_ref()

      :sys.replace_state(agent_pid, fn state ->
        %{state | wait_timer: {old_ref, :timed_wait}}
      end)

      # Replace with second timer (longer wait)
      new_ref = make_ref()

      :sys.replace_state(agent_pid, fn state ->
        %{state | wait_timer: {new_ref, :timed_wait}}
      end)

      # Old timer fires (stale)
      send(agent_pid, {:wait_expired, old_ref})

      # Verify new wait continues (not interrupted by stale timer)
      # Core.get_state is a GenServer.call, so FIFO guarantees :wait_expired processed first
      {:ok, state} = Core.get_state(agent_pid)

      # NOTE: This will FAIL with buggy code - any wait_expired triggers consensus
      assert state.wait_timer == {new_ref, :timed_wait}
    end
  end

  # ==========================================================================
  # R115: Property-Based Test - Staleness Invariant
  # ==========================================================================

  describe "[PROPERTY] R115: Staleness Invariant" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "R115: staleness check - ref must match first element of wait_timer tuple", %{
      infra: infra
    } do
      # Property: For any timer_ref and wait_timer combination,
      # handle_wait_expired clears timer IFF timer_ref matches first element

      for _ <- 1..50 do
        timer_ref = make_ref()
        other_ref = make_ref()

        # 2-tuple case: matching ref
        state_matching =
          create_test_state(infra,
            wait_timer: {timer_ref, :timed_wait},
            skip_auto_consensus: true
          )

        # 2-tuple case: non-matching ref
        state_non_matching =
          create_test_state(infra,
            wait_timer: {other_ref, :timed_wait},
            skip_auto_consensus: true
          )

        {:noreply, result_matching} =
          MessageInfoHandler.handle_wait_expired(timer_ref, state_matching)

        {:noreply, result_non_matching} =
          MessageInfoHandler.handle_wait_expired(timer_ref, state_non_matching)

        # Matching: timer should be cleared
        # NOTE: This will FAIL with buggy code - timer not cleared
        assert result_matching.wait_timer == nil,
               "Matching timer_ref should clear wait_timer"

        # Non-matching: timer should be preserved
        assert result_non_matching.wait_timer == {other_ref, :timed_wait},
               "Non-matching timer_ref should preserve wait_timer"
      end
    end

    test "R115b: staleness check - 3-tuple format also validated", %{infra: infra} do
      # Same property but for 3-tuple timer format

      for _ <- 1..50 do
        timer_ref = make_ref()
        other_ref = make_ref()
        timer_id = "timer-#{System.unique_integer([:positive])}"
        gen = :rand.uniform(100)

        # 3-tuple case: matching ref
        state_matching =
          create_test_state(infra,
            wait_timer: {timer_ref, timer_id, gen},
            skip_auto_consensus: true
          )

        # 3-tuple case: non-matching ref
        state_non_matching =
          create_test_state(infra,
            wait_timer: {other_ref, timer_id, gen},
            skip_auto_consensus: true
          )

        {:noreply, result_matching} =
          MessageInfoHandler.handle_wait_expired(timer_ref, state_matching)

        {:noreply, result_non_matching} =
          MessageInfoHandler.handle_wait_expired(timer_ref, state_non_matching)

        # Matching: timer should be cleared
        # NOTE: This will FAIL with buggy code - timer not cleared
        assert result_matching.wait_timer == nil,
               "Matching timer_ref should clear 3-tuple wait_timer"

        # Non-matching: timer should be preserved
        assert result_non_matching.wait_timer == {other_ref, timer_id, gen},
               "Non-matching timer_ref should preserve 3-tuple wait_timer"
      end
    end
  end
end
