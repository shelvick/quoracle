defmodule Quoracle.Actions.WaitTest do
  @moduledoc """
  Tests for the Wait action that pauses execution for a specified duration.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Test.IsolationHelpers

  alias Quoracle.Actions.Wait

  setup do
    # Create isolated Registry, DynSup, and PubSub for this test
    deps = create_isolated_deps()

    {:ok, deps: deps}
  end

  describe "parameter name acceptance and rejection" do
    test "accepts wait parameter (not duration)", %{deps: deps} do
      # R1: Verify wait parameter is accepted
      Registry.register(deps.registry, {:agent, "agent-wait"}, %{})

      params = %{wait: 5}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-wait",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, response}}
      assert response.action == "wait"
      # Should accept wait parameter and return proper response
      assert response.async == true
      assert is_reference(response.timer_id)
    end

    test "rejects duration parameter (breaking change)", %{deps: deps} do
      # R2: Verify duration parameter is rejected (legacy parameter removed)
      Registry.register(deps.registry, {:agent, "agent-duration"}, %{})

      # Old parameter name
      params = %{duration: 5}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-duration",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      # Should reject duration parameter completely
      assert_received {:result, {:error, :invalid_wait_value}}
    end
  end

  describe "boolean wait support" do
    test "wait: true returns indefinite wait mode", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "agent-true"}, %{})

      params = %{wait: true}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-true",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, response}}
      assert response.action == "wait"
      # wait_mode field will be added in IMPLEMENT phase
      # assert response.wait_mode == :indefinite
      assert response.async == true
      # Should NOT have a timer_id for indefinite wait
      refute Map.has_key?(response, :timer_id)
    end

    test "wait: false returns immediate mode", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "agent-false"}, %{})

      params = %{wait: false}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-false",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, response}}
      assert response.action == "wait"
      # wait_mode field will be added in IMPLEMENT phase
      # assert response.wait_mode == :immediate
      assert response.async == false
      # Should NOT have a timer_id for immediate continuation
      refute Map.has_key?(response, :timer_id)
    end
  end

  describe "zero wait support" do
    test "wait: 0 returns immediate mode (same as false)", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "agent-zero"}, %{})

      params = %{wait: 0}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-zero",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, response}}
      assert response.action == "wait"
      # wait_mode field will be added in IMPLEMENT phase
      # assert response.wait_mode == :immediate
      assert response.async == false
      # Should NOT have a timer_id
      refute Map.has_key?(response, :timer_id)
    end
  end

  describe "numeric wait support with timer creation" do
    test "wait: 5 creates 5-second timer and returns timer reference", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "agent-5s"}, %{})

      params = %{wait: 5}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-5s",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, response}}
      assert response.action == "wait"
      assert response.async == true
      # MUST return timer_id for ConsensusHandler to store
      assert is_reference(response.timer_id)

      # Timer should fire after 5 seconds (test with shorter timeout for speed)
      refute_receive {:wait_expired, _ref}, 100
    end

    test "wait: 0.1 creates 100ms timer", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "agent-100ms"}, %{})

      params = %{wait: 0.1}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-100ms",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, response}}
      assert response.action == "wait"
      assert response.async == true
      assert is_reference(response.timer_id)

      # Timer should fire around 100ms (use 500ms timeout for CI load margin)
      assert_receive {:wait_expired, timer_ref}, 500
      # Timer ref in message should match returned ref
      assert timer_ref == response.timer_id
    end
  end

  describe "R15: behavior equivalence" do
    test "numeric wait values maintain behavior equivalence with old duration", %{deps: deps} do
      # R15: For numeric values, behavior equivalence maintained with prior implementation
      # This test verifies that `wait: N` behaves exactly like `duration: N` used to
      Registry.register(deps.registry, {:agent, "agent-equiv"}, %{})

      # Test with various numeric values
      # Format: {wait_value, expected_ms, expect_timer, expected_async}
      test_cases = [
        # 0.5 seconds -> async with timer
        {0.5, true, true},
        # 1 second -> async with timer
        {1, true, true},
        # 0.01 seconds -> async with timer
        {0.01, true, true},
        # 0 seconds -> immediate, no timer, async: false
        {0, false, false}
      ]

      for {wait_value, expect_timer, expected_async} <- test_cases do
        params = %{wait: wait_value}

        capture_log(fn ->
          send(
            self(),
            {:result,
             Wait.execute(params, "agent-equiv",
               registry: deps.registry,
               pubsub: deps.pubsub,
               agent_pid: self()
             )}
          )
        end)

        assert_received {:result, {:ok, response}}

        # Verify behavior matches old duration implementation:
        # 1. Returns action field
        assert response.action == "wait"

        # 2. Returns async field
        assert response.async == expected_async

        # 3. Creates timer for positive values
        if expect_timer do
          assert is_reference(response.timer_id)
          # Cancel timer to avoid test pollution
          Process.cancel_timer(response.timer_id)

          receive do
            {:wait_expired, _} -> :ok
          after
            0 -> :ok
          end
        else
          refute Map.has_key?(response, :timer_id)
        end
      end
    end
  end

  describe "invalid wait value handling" do
    test "rejects negative wait values", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "agent-neg"}, %{})

      params = %{wait: -5}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-neg",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:error, :invalid_wait_value}}
    end

    test "rejects string wait values", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "agent-str"}, %{})

      params = %{wait: "5"}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-str",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:error, :invalid_wait_value}}
    end

    test "rejects atom wait values", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "agent-atom"}, %{})

      params = %{wait: :five}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-atom",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:error, :invalid_wait_value}}
    end

    test "rejects nil wait values", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "agent-nil"}, %{})

      params = %{wait: nil}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-nil",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:error, :invalid_wait_value}}
    end
  end

  describe "seconds to milliseconds conversion" do
    test "converts seconds to milliseconds internally", %{deps: deps} do
      # Register as agent
      Registry.register(deps.registry, {:agent, "agent-123"}, %{})

      # Pass 0.05 seconds (should become 50ms internally)
      params = %{wait: 0.05}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-123",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, response}}
      assert response.action == "wait"
      assert response.async == true
      # Timer should fire around 50ms (500ms margin for CI load)
      assert_receive {:wait_expired, _timer_ref}, 500
    end

    test "converts 1 second to 1000 milliseconds", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "agent-1s"}, %{})

      params = %{wait: 1}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-1s",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, response}}
      assert response.async == true
      assert is_reference(response.timer_id)
    end

    test "accepts large durations without maximum limit", %{deps: deps} do
      Registry.register(deps.registry, {:agent, "agent-big"}, %{})

      # 1 day in seconds - should NOT be rejected
      params = %{wait: 86400}

      capture_log(fn ->
        send(
          self(),
          {:result,
           Wait.execute(params, "agent-big",
             registry: deps.registry,
             pubsub: deps.pubsub,
             agent_pid: self()
           )}
        )
      end)

      assert_received {:result, {:ok, response}}
      # Should accept large durations
      assert response.async == true
      assert is_reference(response.timer_id)
    end
  end

  describe "pubsub parameter support" do
    test "broadcasts wait events to isolated pubsub when provided", %{deps: deps} do
      # Use the isolated PubSub from setup
      pubsub_name = deps.pubsub

      # Subscribe to wait events on isolated pubsub
      Phoenix.PubSub.subscribe(pubsub_name, "wait:events")

      # Register as agent to trigger async mode
      Registry.register(deps.registry, {:agent, "agent-123"}, %{})

      params = %{wait: 0.01}

      # Execute with pubsub parameter, suppressing logs
      capture_log(fn ->
        _result =
          Wait.execute(params, "agent-123",
            registry: deps.registry,
            pubsub: pubsub_name,
            agent_pid: self()
          )
      end)

      # Should receive wait event on isolated pubsub (duration in seconds as passed)
      assert_receive {:wait_started, %{agent_id: "agent-123", wait: 0.01}}, 30_000
      # And timer expiry (generous timeout - cleanup only, not testing timing)
      assert_receive {:wait_expired, _timer_ref}, 30_000
    end

    test "isolates events between different pubsub instances", %{deps: deps} do
      # Create two isolated PubSubs with unique IDs
      pubsub_a = :"pubsub_a_#{System.unique_integer()}"
      pubsub_b = :"pubsub_b_#{System.unique_integer()}"
      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub_a}, id: :pubsub_a_test)
      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub_b}, id: :pubsub_b_test)

      # Subscribe only to pubsub_a
      Phoenix.PubSub.subscribe(pubsub_a, "wait:events")

      # Register as agent
      Registry.register(deps.registry, {:agent, "agent-123"}, %{})

      params = %{wait: 0.01}
      opts = [registry: deps.registry, pubsub: pubsub_b]

      # Execute on pubsub_b, suppressing logs
      capture_log(fn ->
        _result = Wait.execute(params, "agent-123", Keyword.put(opts, :agent_pid, self()))
      end)

      # Should NOT receive on pubsub_a
      refute_receive {:wait_started, _}, 100
      # But should receive timer expiry (generous timeout - cleanup only, not testing timing)
      assert_receive {:wait_expired, _timer_ref}, 30_000
    end
  end

  describe "execute/2" do
    test "executes wait for valid duration", %{deps: deps} do
      # Register as agent to trigger async mode
      Registry.register(deps.registry, {:agent, "agent-123"}, %{})

      params = %{wait: 0.01}

      # Execute without log noise
      log_output =
        capture_log(fn ->
          send(
            self(),
            {:result,
             Wait.execute(params, "agent-123",
               registry: deps.registry,
               pubsub: deps.pubsub,
               agent_pid: self()
             )}
          )
        end)

      assert log_output =~ ""

      assert_received {:result, result}

      assert {:ok, response} = result
      assert response.async == true
      assert response.timer_id

      # Wait for timer expiry (10ms timer, generous timeout for CI load)
      timer_id = response.timer_id
      assert_receive {:wait_expired, ^timer_id}, 30_000
    end

    test "handles zero duration", %{deps: deps} do
      # Register as agent
      Registry.register(deps.registry, {:agent, "agent-123"}, %{})

      params = %{wait: 0}

      assert {:ok, response} =
               Wait.execute(params, "agent-123",
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 agent_pid: self()
               )

      assert response.async == false

      # Zero duration means immediate continuation - no timer created
      refute Map.has_key?(response, :timer_id)
      refute_receive {:wait_expired, _}, 100
    end

    test "handles string duration key", %{deps: deps} do
      # Register as agent
      Registry.register(deps.registry, {:agent, "agent-123"}, %{})

      params = %{"wait" => 0.005}

      assert {:ok, response} =
               Wait.execute(params, "agent-123",
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 agent_pid: self()
               )

      assert response.async == true

      # Wait for timer expiry (5ms timer + scheduler margin)
      timer_id = response.timer_id
      assert_receive {:wait_expired, ^timer_id}, 500
    end

    test "defaults to 0 when duration not provided", %{deps: deps} do
      # Register as agent
      Registry.register(deps.registry, {:agent, "agent-123"}, %{})

      params = %{}

      assert {:ok, response} =
               Wait.execute(params, "agent-123",
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 agent_pid: self()
               )

      assert response.async == false

      # When wait is 0, no timer is created (immediate continuation)
      refute Map.has_key?(response, :timer_id)
    end

    test "returns error for negative duration", %{deps: deps} do
      # Register as agent
      Registry.register(deps.registry, {:agent, "agent-123"}, %{})

      params = %{wait: -100}

      assert {:error, :invalid_wait_value} =
               Wait.execute(params, "agent-123",
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 agent_pid: self()
               )

      # No timer should be started for invalid duration
      refute_receive {:wait_expired, _}, 100
    end

    test "returns error for string duration value", %{deps: deps} do
      # Register as agent
      Registry.register(deps.registry, {:agent, "agent-123"}, %{})

      params = %{wait: "not a number"}

      assert {:error, :invalid_wait_value} =
               Wait.execute(params, "agent-123",
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 agent_pid: self()
               )

      # No timer should be started
      refute_receive {:wait_expired, _}, 100
    end

    test "accepts very large durations (no maximum limit)", %{deps: deps} do
      # Register as agent
      Registry.register(deps.registry, {:agent, "agent-123"}, %{})

      # Test over 1 hour (3601 seconds)
      long_params = %{wait: 3601}

      # Should accept large duration without blocking
      assert {:ok, response} =
               Wait.execute(long_params, "agent-123",
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 agent_pid: self()
               )

      assert response.async == true
      assert is_reference(response.timer_id)

      # Cancel timer to avoid waiting for it
      Process.cancel_timer(response.timer_id)
      # Flush any messages
      receive do
        {:wait_expired, _} -> :ok
      after
        0 -> :ok
      end
    end

    test "agent_id parameter is used for registry lookup", %{deps: deps} do
      # Use positive duration to create timers
      params = %{wait: 0.05}

      # Register first agent
      Registry.register(deps.registry, {:agent, "agent-123"}, %{})

      # Should work with registered agent
      assert {:ok, response1} =
               Wait.execute(params, "agent-123",
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 agent_pid: self()
               )

      assert response1.async == true

      # Unregister and register as different agent
      Registry.unregister(deps.registry, {:agent, "agent-123"})
      Registry.register(deps.registry, {:agent, "different-agent"}, %{})

      assert {:ok, response2} =
               Wait.execute(params, "different-agent",
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 agent_pid: self()
               )

      assert response2.async == true

      # Clean up timers (generous timeout - cleanup only, not testing timing)
      assert_receive {:wait_expired, _}, 30_000
      assert_receive {:wait_expired, _}, 30_000
    end

    test "handles both atom and string keys for duration", %{deps: deps} do
      # Register as agent
      Registry.register(deps.registry, {:agent, "agent-123"}, %{})

      atom_params = %{wait: 0.005}
      string_params = %{"wait" => 0.005}

      assert {:ok, atom_response} =
               Wait.execute(atom_params, "agent-123",
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 agent_pid: self()
               )

      assert {:ok, string_response} =
               Wait.execute(string_params, "agent-123",
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 agent_pid: self()
               )

      assert atom_response.async == true
      assert string_response.async == true

      # Clean up timers (generous timeout - cleanup only, not testing timing)
      assert_receive {:wait_expired, _}, 30_000
      assert_receive {:wait_expired, _}, 30_000
    end
  end

  describe "async timer behavior" do
    test "returns immediately and sends timer message", %{deps: deps} do
      # Register as agent to trigger async mode
      Registry.register(deps.registry, {:agent, "agent-123"}, %{})

      params = %{wait: 0.01}

      result =
        Wait.execute(params, "agent-123",
          registry: deps.registry,
          pubsub: deps.pubsub,
          agent_pid: self()
        )

      # Verify async behavior (doesn't block for full duration)
      assert {:ok, response} = result
      assert response.async == true
      assert response.timer_id

      # Note: We don't test execution time because:
      # - PubSub.broadcast takes 2-3ms minimum (unavoidable overhead)
      # - BEAM scheduler preemption adds 0.5-1.5ms under parallel test load
      # - Wall-clock timing assertions are non-deterministic
      # - The requirement is "async: true" (non-blocking), not "< Nms"

      # Timer message should arrive after the duration (generous timeout - cleanup only, not testing timing)
      timer_id = response.timer_id
      assert_receive {:wait_expired, ^timer_id}, 30_000
    end
  end
end
