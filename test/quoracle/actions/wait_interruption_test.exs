defmodule Quoracle.Actions.WaitInterruptionTest do
  @moduledoc """
  Integration tests for wait action interruption behavior.
  Tests verify that wait action with timer support will be interruptible.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Test.IsolationHelpers

  alias Quoracle.Actions.Wait

  setup do
    # Create isolated dependencies for testing
    deps = create_isolated_deps()
    {:ok, deps: deps}
  end

  describe "wait action timer behavior" do
    test "wait action with numeric value should return timer_id for interruption", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "wait-agent-1"}, %{})

      # Execute wait action with 5-second timer
      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(%{wait: 5}, "wait-agent-1",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, wait_result}}
      assert wait_result.action == "wait"
      # Should return timer_id for ConsensusHandler to store
      assert is_reference(wait_result.timer_id)
      assert wait_result.async == true

      # Timer message should arrive after 5 seconds (we won't wait that long)
      refute_receive {:wait_expired, _}, 100
    end

    test "wait action with true should not return timer_id (indefinite wait)", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "wait-agent-2"}, %{})

      # Execute wait action with indefinite wait
      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(%{wait: true}, "wait-agent-2",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, wait_result}}
      assert wait_result.action == "wait"
      # Should NOT have timer_id for indefinite wait
      refute Map.has_key?(wait_result, :timer_id)
      assert wait_result.async == true

      # No timer to expire
      refute_receive {:wait_expired, _}, 100
    end

    test "wait action with false should not create timer (immediate continuation)", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "wait-agent-3"}, %{})

      # Execute wait action with immediate continuation
      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(%{wait: false}, "wait-agent-3",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, wait_result}}
      assert wait_result.action == "wait"
      # Should NOT have timer_id for immediate continuation
      refute Map.has_key?(wait_result, :timer_id)
      assert wait_result.async == false

      # No timer to expire
      refute_receive {:wait_expired, _}, 100
    end

    test "wait timer expiry sends correct message", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "wait-agent-4"}, %{})

      # Execute wait action with timer (500ms for reliable timing)
      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(%{wait: 0.5}, "wait-agent-4",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, wait_result}}
      assert is_reference(wait_result.timer_id)

      # Wait for timer to expire (3x margin for scheduler variance)
      timer_id = wait_result.timer_id
      assert_receive {:wait_expired, ^timer_id}, 1500
    end

    test "different wait values create different timer behaviors", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "wait-agent-5"}, %{})

      # Test multiple wait values
      test_cases = [
        # indefinite wait
        {true, :no_timer, true},
        # immediate continuation
        {false, :no_timer, false},
        # zero wait
        {0, :no_timer, false},
        # 1 second wait
        {1, :has_timer, true},
        # 50ms wait
        {0.05, :has_timer, true}
      ]

      for {wait_value, timer_expectation, async_expected} <- test_cases do
        capture_log(fn ->
          send(
            self(),
            {:result,
             Wait.execute(%{wait: wait_value}, "wait-agent-5",
               registry: deps.registry,
               pubsub: deps.pubsub,
               agent_pid: self()
             )}
          )
        end)

        assert_received {:result, {:ok, result}}
        assert result.action == "wait"
        assert result.async == async_expected

        case timer_expectation do
          :has_timer ->
            assert is_reference(result.timer_id)

          :no_timer ->
            refute Map.has_key?(result, :timer_id)
        end
      end
    end
  end

  describe "wait action return values for interruption support" do
    test "timed wait returns metadata for timer storage", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "wait-storage-1"}, %{})

      # Execute wait action with timer
      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(%{wait: 1}, "wait-storage-1",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, wait_result}}
      # Should return timer_id that ConsensusHandler can store
      assert is_reference(wait_result.timer_id)
      assert wait_result.async == true
    end

    test "wait action timer can coexist with wait parameter timer concept", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "wait-storage-2"}, %{})

      # Execute wait action
      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(%{wait: 0.5}, "wait-storage-2",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, wait_result}}
      action_timer_ref = wait_result.timer_id
      assert is_reference(action_timer_ref)

      # The timer will fire after 500ms (use default timeout for CI stability)
      assert_receive {:wait_expired, ^action_timer_ref}, 30_000
    end
  end
end
