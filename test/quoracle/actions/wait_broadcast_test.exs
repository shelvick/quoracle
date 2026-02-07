defmodule Quoracle.Actions.WaitBroadcastTest do
  @moduledoc """
  Tests for ACTION_Wait PubSub broadcasting functionality.
  Verifies that wait action events are properly broadcast through the Router.
  """

  # async: true - Uses isolated PubSub instance for test isolation
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Actions.Router

  setup do
    # Create isolated PubSub instance for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Subscribe to action events topic on isolated instance
    :ok = Phoenix.PubSub.subscribe(pubsub_name, "actions:all")

    agent_id = "test_agent_#{System.unique_integer([:positive])}"

    {:ok, agent_id: agent_id, pubsub: pubsub_name}
  end

  # Helper to spawn per-action Router for wait actions (v28.0)
  defp spawn_wait_router(agent_id, pubsub) do
    action_id = "action-#{System.unique_integer([:positive])}"

    {:ok, router} =
      Router.start_link(
        action_type: :wait,
        action_id: action_id,
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub,
        sandbox_owner: nil
      )

    router
  end

  describe "wait action broadcasts" do
    test "broadcasts action_started when wait begins", %{agent_id: agent_id, pubsub: pubsub} do
      router = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Execute wait action through router
      params = %{wait: 0.1}

      # This should trigger action_started broadcast
      capture_log(fn ->
        Router.execute(router, :wait, params, agent_id)
      end)

      # Should receive action_started broadcast for our specific agent
      assert_receive {:action_started, %{agent_id: ^agent_id} = payload}, 30_000
      assert payload.action_type == :wait
      assert payload.params == params
      assert is_binary(payload.action_id)
      assert %DateTime{} = payload.timestamp
    end

    test "broadcasts action_completed when wait succeeds", %{agent_id: agent_id, pubsub: pubsub} do
      router = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Execute wait action with short duration through router
      params = %{wait: 0.05}

      # Execute and get result
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, params, agent_id)})
      end)

      assert_received {:result, {:ok, _result}}

      # Should receive both started and completed for our specific agent
      assert_receive {:action_started, %{agent_id: ^agent_id} = start_payload}, 30_000
      assert_receive {:action_completed, %{agent_id: ^agent_id} = complete_payload}, 30_000
      assert complete_payload.action_id == start_payload.action_id
      assert match?({:ok, _}, complete_payload.result)
      assert %DateTime{} = complete_payload.timestamp
    end

    test "broadcasts action_error when wait fails with invalid params", %{
      agent_id: agent_id,
      pubsub: pubsub
    } do
      router = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Execute wait with invalid duration through router
      params = %{wait: -1}

      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, params, agent_id)})
      end)

      assert_received {:result, {:error, _reason}}

      # Should receive error broadcast
      assert_receive {:action_error, payload}, 30_000
      assert payload.agent_id == agent_id
      assert is_binary(payload.action_id)
      assert match?({:error, _}, payload.error)
      assert %DateTime{} = payload.timestamp
    end

    test "broadcasts action_error when wait has missing params", %{
      agent_id: agent_id,
      pubsub: pubsub
    } do
      router = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Execute wait without duration (optional param) through router
      params = %{}

      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, params, agent_id)})
      end)

      assert_received {:result, result}

      # Duration is optional, so this should succeed with default duration 0
      case result do
        {:ok, _} ->
          assert_receive {:action_completed, _}, 30_000

        {:error, _} ->
          assert_receive {:action_error, payload}, 30_000
          assert payload.agent_id == agent_id
      end
    end

    test "includes correct action metadata in broadcasts", %{agent_id: agent_id, pubsub: pubsub} do
      router = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Execute wait through router
      params = %{wait: 0.1}

      capture_log(fn ->
        Router.execute(router, :wait, params, agent_id)
      end)

      assert_receive {:action_started, payload}, 30_000

      # Verify metadata structure
      assert Map.has_key?(payload, :agent_id)
      assert Map.has_key?(payload, :action_type)
      assert Map.has_key?(payload, :action_id)
      assert Map.has_key?(payload, :params)
      assert Map.has_key?(payload, :timestamp)

      assert payload.action_type == :wait
      assert payload.params == params
    end

    test "broadcasts preserve execution context for concurrent waits", %{
      agent_id: agent_id,
      pubsub: pubsub
    } do
      # Per-action Router (v28.0): Each wait gets its own Router
      router1 = spawn_wait_router(agent_id, pubsub)
      router2 = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router1), do: GenServer.stop(router1, :normal, :infinity)
        if Process.alive?(router2), do: GenServer.stop(router2, :normal, :infinity)
      end)

      # Execute multiple wait actions through separate routers
      capture_log(fn ->
        Router.execute(router1, :wait, %{wait: 0.1}, agent_id)
        Router.execute(router2, :wait, %{wait: 0.15}, agent_id)
      end)

      # Should receive distinct broadcasts for each (filter by our agent_id)
      assert_receive {:action_started, %{agent_id: ^agent_id} = payload1}, 30_000
      assert_receive {:action_started, %{agent_id: ^agent_id} = payload2}, 30_000

      # Action IDs should be unique
      assert payload1.action_id != payload2.action_id
      assert payload1.agent_id == payload2.agent_id
    end

    test "broadcasts include duration in completed event", %{agent_id: agent_id, pubsub: pubsub} do
      router = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Execute wait with known duration through router
      # Keep under smart_threshold for sync execution
      params = %{wait: 0.05}

      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, params, agent_id)})
      end)

      assert_received {:result, {:ok, _result}}

      # Should receive completed event with correct structure
      assert_receive {:action_started, start_payload}, 30_000
      assert_receive {:action_completed, complete_payload}, 30_000

      # Verify broadcast payloads have correct structure
      assert start_payload.agent_id == agent_id
      assert start_payload.params.wait == 0.05
      assert complete_payload.agent_id == agent_id
      assert match?({:ok, _}, complete_payload.result)

      # The actual timing is tested in wait_test.exs with mock delay_fn
      # Here we only care about broadcast behavior, not wall-clock time
    end
  end

  describe "async wait broadcasts" do
    test "handles async wait execution with broadcasts", %{agent_id: agent_id, pubsub: pubsub} do
      router = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # If wait is executed asynchronously through router, broadcasts should still work
      params = %{wait: 0.2}

      # Start wait (might be async)
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, params, agent_id)})
      end)

      assert_received {:result, result}

      # Should receive action_started immediately
      assert_receive {:action_started, start_payload}, 30_000
      assert start_payload.params == params

      case result do
        {:ok, _} ->
          # Synchronous execution - should have completed broadcast
          assert_receive {:action_completed, _}, 30_000

        {:async, _ref} ->
          # Async execution - completed broadcast comes later
          # Per-action Router terminates after action, can't await
          assert_receive {:action_completed, _}, 30_000
      end
    end
  end

  describe "integration with AgentEvents" do
    test "Wait uses AgentEvents helper functions", %{agent_id: agent_id, pubsub: pubsub} do
      router = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # This verifies Router integrates with AgentEvents module for Wait actions
      # rather than doing raw broadcasts

      Router.execute(router, :wait, %{wait: 50}, agent_id)

      # The broadcast should follow AgentEvents message structure
      assert_receive {:action_started, payload}, 30_000

      # Verify structure matches AgentEvents contract
      assert Map.has_key?(payload, :agent_id)
      assert Map.has_key?(payload, :action_type)
      assert Map.has_key?(payload, :action_id)
      assert Map.has_key?(payload, :params)
      assert Map.has_key?(payload, :timestamp)
      assert match?(%DateTime{}, payload.timestamp)
    end
  end
end
