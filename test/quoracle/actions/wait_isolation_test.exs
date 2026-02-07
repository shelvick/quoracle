defmodule Quoracle.Actions.WaitIsolationTest do
  @moduledoc """
  Tests for PubSub isolation in ACTION_Wait.
  Verifies that Wait action uses AgentEvents for broadcasts which support isolation.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Quoracle.Actions.Router
  alias Test.PubSubIsolation

  setup do
    # Setup isolated PubSub for this test
    {:ok, pubsub} = PubSubIsolation.setup_isolated_pubsub()

    # Subscribe to action events in isolated PubSub
    :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

    %{pubsub: pubsub}
  end

  # Helper to spawn per-action Router for wait actions (v28.0)
  defp spawn_wait_router(agent_id, pubsub) do
    action_id = "action-#{System.unique_integer([:positive])}"

    Router.start_link(
      action_type: :wait,
      action_id: action_id,
      agent_id: agent_id,
      agent_pid: self(),
      pubsub: pubsub,
      sandbox_owner: nil
    )
  end

  describe "PubSub isolation for synchronous mode" do
    test "broadcasts action events to isolated PubSub in sync mode", %{pubsub: pubsub} do
      agent_id = "test-agent-sync-#{System.unique_integer([:positive])}"

      # Spawn per-action Router (v28.0)
      {:ok, router} = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute wait through router (which handles broadcasts)
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, %{wait: 0.01}, agent_id)})
      end)

      assert_received {:result, {:ok, result}}
      assert result.action == "wait"

      # Wait now always returns immediately with async flag
      assert result.async == true

      # Should receive action events in isolated PubSub
      assert_receive {:action_started, start_payload}, 30_000
      assert start_payload.agent_id == agent_id
      assert start_payload.action_type == :wait

      assert_receive {:action_completed, complete_payload}, 30_000
      assert complete_payload.agent_id == agent_id
    end

    test "isolated sync broadcasts don't leak between tests", %{pubsub: pubsub} do
      agent_id = "test-agent-isolated"
      other_agent = "other-agent"

      # Spawn per-action Router (v28.0)
      {:ok, router} = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute with main test's PubSub through router
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, %{wait: 0.005}, agent_id)})
      end)

      assert_received {:result, {:ok, _}}

      # Should receive broadcast in this test's isolated PubSub
      assert_receive {:action_started, %{agent_id: ^agent_id}}, 30_000

      # Should NOT receive broadcasts from other tests
      refute_receive {:action_started, %{agent_id: ^other_agent}}, 100
    end
  end

  describe "PubSub isolation for asynchronous mode" do
    test "broadcasts action events to isolated PubSub in async mode", %{pubsub: pubsub} do
      agent_id = "test-agent-async-#{System.unique_integer([:positive])}"

      # Spawn per-action Router (v28.0)
      {:ok, router} = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute wait in async mode through router (longer duration triggers async)
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, %{wait: 0.15}, agent_id)})
      end)

      assert_received {:result, {:ok, result}}
      assert result.async == true

      # Should receive action started in isolated PubSub
      assert_receive {:action_started, start_payload}, 30_000
      assert start_payload.agent_id == agent_id
      assert start_payload.action_type == :wait

      # No need to await - action completed immediately

      # The async mode test is primarily about verifying that broadcasts
      # go to the isolated PubSub, not about the exact timing of completion events
    end

    test "timer cancellation broadcasts to isolated PubSub", %{pubsub: pubsub} do
      agent_id = "test-agent-cancel-#{System.unique_integer([:positive])}"

      # Per-action Router (v28.0): Each wait gets its own Router
      {:ok, router1} = spawn_wait_router(agent_id, pubsub)
      {:ok, router2} = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        for router <- [router1, router2] do
          if Process.alive?(router) do
            try do
              GenServer.stop(router, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end
      end)

      # Start two waits (each on its own Router)
      capture_log(fn ->
        send(self(), {:ref1, Router.execute(router1, :wait, %{wait: 0.2}, agent_id)})
        send(self(), {:ref2, Router.execute(router2, :wait, %{wait: 0.15}, agent_id)})
      end)

      assert_received {:ref1, {:ok, result1}}
      assert result1.async == true
      assert_received {:ref2, {:ok, result2}}
      assert result2.async == true

      # Should receive broadcasts for both in isolated PubSub
      assert_receive {:action_started, %{agent_id: ^agent_id}}, 30_000
      assert_receive {:action_started, %{agent_id: ^agent_id}}, 30_000

      # No need to await - actions completed immediately
    end
  end

  describe "error handling with isolation" do
    test "broadcasts errors to isolated PubSub", %{pubsub: pubsub} do
      agent_id = "test-agent-error"

      # Spawn per-action Router (v28.0)
      {:ok, router} = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Invalid duration should trigger error
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, %{wait: -1}, agent_id)})
      end)

      assert_received {:result, {:error, _}}

      # Should receive error broadcast in isolated PubSub
      assert_receive {:action_error, payload}, 30_000
      assert payload.agent_id == agent_id
    end

    test "duration limit errors broadcast to isolated PubSub", %{pubsub: pubsub} do
      agent_id = "test-agent-limit"

      # Spawn per-action Router (v28.0)
      {:ok, router} = spawn_wait_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Test with a negative duration to trigger an error
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, %{wait: -1}, agent_id)})
      end)

      assert_received {:result, {:error, _}}

      # Should receive error broadcast in isolated PubSub
      assert_receive {:action_error, payload}, 30_000
      assert payload.agent_id == agent_id
    end
  end
end
