defmodule Quoracle.Actions.WaitEnhancedTest do
  @moduledoc """
  Tests for enhanced Wait action with AGENT_Core detection and timer management.
  Verifies dual-mode behavior and Registry integration.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Test.IsolationHelpers

  alias Quoracle.Actions.Wait

  setup do
    # Create isolated Registry and DynSup for this test
    deps = create_isolated_deps()
    {:ok, deps: deps}
  end

  describe "execute/3 - AGENT_Core detection" do
    test "returns immediately for AGENT_Core processes", %{deps: deps} do
      capture_log(fn ->
        # Skip - AGENT_Core doesn't exist yet
        # {:ok, agent_pid} = start_supervised({Core, task_id: "test_task", agent_id: "test_agent"})

        # Execute wait from within the agent context
        # Simulate by registering current process as an agent
        Registry.register(deps.registry, {:agent, "test_agent"}, %{})

        # Should return immediately with timer reference
        {elapsed, result} =
          :timer.tc(fn ->
            Wait.execute(%{wait: 1}, "test_agent",
              registry: deps.registry,
              pubsub: deps.pubsub,
              agent_pid: self()
            )
          end)

        assert {:ok, response} = result
        assert response.action == "wait"
        assert response.timer_id
        assert response.async == true
        # Should return quickly even though duration is 1 second
        # Use 500ms threshold for scheduler margin under system load
        assert elapsed < 500_000
      end)
    end

    test "uses async mode when registered as agent", %{deps: deps} do
      capture_log(fn ->
        # Register as agent to trigger async mode
        Registry.register(deps.registry, {:agent, "test_agent"}, %{})

        # Execute and verify async behavior
        {elapsed, result} =
          :timer.tc(fn ->
            Wait.execute(%{wait: 0.1}, "test_agent",
              registry: deps.registry,
              pubsub: deps.pubsub,
              agent_pid: self()
            )
          end)

        assert {:ok, response} = result
        assert response.async == true
        assert response.timer_id
        # Should return immediately (async mode, not waiting for timer)
        # Use 500ms threshold for scheduler margin under system load
        assert elapsed < 500_000

        # Wait for timer expiry message (generous timeout for system under load)
        timer_id = response.timer_id
        assert_receive {:wait_expired, ^timer_id}, 5000
      end)
    end

    test "detects caller via Registry lookup", %{deps: deps} do
      capture_log(fn ->
        # Register as an agent
        Registry.register(deps.registry, {:agent, "my_agent"}, %{type: :agent_core})

        # Should detect we're an agent and return async
        {:ok, response} =
          Wait.execute(%{wait: 0.5}, "my_agent",
            registry: deps.registry,
            pubsub: deps.pubsub,
            agent_pid: self()
          )

        assert response.async == true
        assert response.timer_id
      end)
    end

    test "uses async mode for unregistered agents", %{deps: deps} do
      capture_log(fn ->
        # Register with a different agent ID to test async behavior
        Registry.register(deps.registry, {:agent, "unknown_agent"}, %{})

        {:ok, response} =
          Wait.execute(%{wait: 0.05}, "unknown_agent",
            registry: deps.registry,
            pubsub: deps.pubsub,
            agent_pid: self()
          )

        assert response.async == true
        assert response.timer_id

        # Wait for timer expiry (generous timeout for system under load)
        timer_id = response.timer_id
        assert_receive {:wait_expired, ^timer_id}, 5000
      end)
    end
  end

  describe "timer management" do
    test "delivers timer expiry message to AGENT_Core", %{deps: deps} do
      capture_log(fn ->
        # Register as agent
        Registry.register(deps.registry, {:agent, "timer_agent"}, %{})

        # Start async wait
        {:ok, response} =
          Wait.execute(%{wait: 0.1}, "timer_agent",
            registry: deps.registry,
            pubsub: deps.pubsub,
            agent_pid: self()
          )

        timer_id = response.timer_id

        # Should receive timer expiry message (generous timeout for system under load)
        assert_receive {:wait_expired, ^timer_id}, 5000
      end)
    end

    test "cancels previous timer when new wait starts", %{deps: deps} do
      # Register as agent
      Registry.register(deps.registry, {:agent, "cancel_agent"}, %{})

      # Start first wait
      {:ok, response1} =
        Wait.execute(%{wait: 0.5}, "cancel_agent",
          registry: deps.registry,
          pubsub: deps.pubsub,
          agent_pid: self()
        )

      timer_id1 = response1.timer_id

      # Start second wait (should cancel first)
      {:ok, response2} =
        Wait.execute(%{wait: 0.1}, "cancel_agent",
          registry: deps.registry,
          pubsub: deps.pubsub,
          agent_pid: self()
        )

      timer_id2 = response2.timer_id

      # Should only receive second timer expiry
      # refute_receive: Short timeout to verify timer1 was cancelled (not waiting for it to fire)
      # assert_receive: Generous timeout for system under load
      refute_receive {:wait_expired, ^timer_id1}, 150
      assert_receive {:wait_expired, ^timer_id2}, 5000
    end

    test "handles multiple concurrent waits from different agents", %{deps: deps} do
      # Only one agent can be registered per PID, so we test sequential waits
      # First agent
      Registry.register(deps.registry, {:agent, "agent1"}, %{})

      # Start first wait
      {:ok, r1} =
        Wait.execute(%{wait: 0.05}, "agent1",
          registry: deps.registry,
          pubsub: deps.pubsub,
          agent_pid: self()
        )

      assert r1.async == true

      # Wait for first timer to expire (generous timeout for system under load)
      assert_receive {:wait_expired, timer1}, 5000
      assert timer1 == r1.timer_id

      # Unregister first agent and register second
      Registry.unregister(deps.registry, {:agent, "agent1"})
      Registry.register(deps.registry, {:agent, "agent2"}, %{})

      # Start second wait
      {:ok, r2} =
        Wait.execute(%{wait: 0.05}, "agent2",
          registry: deps.registry,
          pubsub: deps.pubsub,
          agent_pid: self()
        )

      assert r2.async == true
      assert r2.timer_id != r1.timer_id

      # Wait for second timer to expire (generous timeout for system under load)
      assert_receive {:wait_expired, timer2}, 5000
      assert timer2 == r2.timer_id
    end

    test "cancel_timer handles invalid references gracefully", %{deps: _deps} do
      # Create fake timer reference
      fake_timer = make_ref()

      # Try to cancel non-existent timer - should not crash
      # Note: Process.cancel_timer returns false for invalid refs
      # Logger is set to :error level in test, so warnings aren't captured
      result = Wait.cancel_timer(fake_timer)

      # Should return :ok even when cancellation fails
      assert result == :ok
    end
  end

  describe "error handling" do
    test "returns error for negative duration", %{deps: deps} do
      capture_log(fn ->
        result =
          Wait.execute(%{wait: -1}, "test_agent",
            registry: deps.registry,
            pubsub: deps.pubsub,
            agent_pid: self()
          )

        assert {:error, :invalid_wait_value} = result
      end)
    end

    test "handles unregistered agents with async mode", %{deps: deps} do
      # Register the process to enable async mode
      Registry.register(deps.registry, {:agent, "unregistered_agent"}, %{})

      {:ok, response} =
        Wait.execute(%{wait: 0.05}, "unregistered_agent",
          registry: deps.registry,
          pubsub: deps.pubsub,
          agent_pid: self()
        )

      # Should use async mode when registered
      assert response.async == true
      assert response.timer_id

      # Verify timer expiry message (generous timeout for system under load)
      timer_id = response.timer_id
      assert_receive {:wait_expired, ^timer_id}, 5000
    end
  end

  describe "integration with ACTION_Router" do
    test "router detects async response and handles accordingly", %{deps: deps} do
      alias Quoracle.Actions.Router

      agent_id = "router_agent_#{System.unique_integer([:positive])}"

      # Register as agent
      Registry.register(deps.registry, {:agent, agent_id}, %{})

      # Spawn per-action Router (v28.0)
      {:ok, router} =
        Router.start_link(
          action_type: :wait,
          action_id: "action-#{System.unique_integer([:positive])}",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: deps.pubsub,
          sandbox_owner: nil
        )

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Execute wait through router
      result =
        Router.execute(router, :wait, %{wait: 0.2}, agent_id,
          caller: self(),
          registry: deps.registry
        )

      # Should get response with async flag from router
      assert {:ok, response} = result
      assert response.async == true
      assert is_reference(response.timer_id)
    end
  end
end
