defmodule Quoracle.Actions.OrientIsolationTest do
  @moduledoc """
  Tests for PubSub isolation in ACTION_Orient.
  Verifies that Orient action uses AgentEvents for log broadcasts which support isolation.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Quoracle.Actions.{Router, Orient}
  alias Test.PubSubIsolation

  @valid_params %{
    current_situation: "Testing PubSub isolation",
    goal_clarity: "Verify broadcasts use isolated PubSub",
    available_resources: "Test environment with isolated PubSub",
    key_challenges: "Ensuring no message leakage between tests",
    delegation_consideration: "No delegation needed for isolation testing"
  }

  setup do
    # Setup isolated PubSub for this test
    {:ok, pubsub} = PubSubIsolation.setup_isolated_pubsub()

    %{pubsub: pubsub}
  end

  # Helper to spawn per-action Router for orient actions (v28.0)
  defp spawn_orient_router(agent_id, pubsub) do
    action_id = "action-#{System.unique_integer([:positive])}"

    {:ok, router} =
      Router.start_link(
        action_type: :orient,
        action_id: action_id,
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub,
        sandbox_owner: nil
      )

    router
  end

  describe "PubSub isolation for log broadcasts" do
    test "broadcasts log entries to isolated PubSub", %{pubsub: pubsub} do
      agent_id = "test-orient-agent-#{System.unique_integer([:positive])}"

      # Subscribe to agent's log topic in isolated PubSub
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:logs")

      # Execute orient action with isolated pubsub
      capture_log(fn ->
        send(self(), {:result, Orient.execute(@valid_params, agent_id, pubsub: pubsub)})
      end)

      assert_received {:result, {:ok, result}}
      assert result.action == "orient"

      # Should receive log broadcasts in isolated PubSub
      assert_receive {:log_entry, log_payload}
      assert log_payload.agent_id == agent_id
      assert log_payload.level == :info
      assert log_payload.message =~ "Orientation complete"
    end

    test "isolated log broadcasts don't leak between tests", %{pubsub: pubsub} do
      agent_id = "test-orient-isolated"
      other_agent = "other-orient-agent"

      # Subscribe to this test's agent logs
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:logs")

      # Execute with this test's isolated PubSub
      capture_log(fn ->
        send(self(), {:result, Orient.execute(@valid_params, agent_id, pubsub: pubsub)})
      end)

      assert_received {:result, {:ok, _}}

      # Should receive broadcast in this test's isolated PubSub
      assert_receive {:log_entry, log_payload}
      assert log_payload.agent_id == agent_id
      assert log_payload.message == "Orientation complete"

      # Should NOT receive broadcasts from hypothetical other tests
      refute_receive {:log_entry, %{agent_id: ^other_agent}}, 100
    end

    test "multiple log entries all use isolated PubSub", %{pubsub: pubsub} do
      agent_id = "test-orient-multi-#{System.unique_integer([:positive])}"

      # Subscribe to agent's log topic
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:logs")

      # Execute orient with detailed params to trigger multiple logs
      params = Map.put(@valid_params, :debug, true)

      capture_log(fn ->
        send(self(), {:result, Orient.execute(params, agent_id, pubsub: pubsub)})
      end)

      assert_received {:result, {:ok, _}}

      # Should receive multiple log entries, all in isolated PubSub
      logs = receive_all_logs([])
      assert logs != []
      assert Enum.all?(logs, fn log -> log.agent_id == agent_id end)
    end
  end

  describe "PubSub isolation for action events" do
    test "broadcasts action events to isolated PubSub", %{pubsub: pubsub} do
      agent_id = "test-orient-action-#{System.unique_integer([:positive])}"

      # Subscribe to action events in isolated PubSub
      :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

      # Spawn per-action Router (v28.0)
      router = spawn_orient_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute orient action through router
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :orient, @valid_params, agent_id)})
      end)

      assert_received {:result, {:ok, _}}

      # Should receive action started event
      assert_receive {:action_started, start_payload}
      assert start_payload.agent_id == agent_id
      assert start_payload.action_type == :orient

      # Should receive action completed event
      assert_receive {:action_completed, complete_payload}
      assert complete_payload.agent_id == agent_id
    end
  end

  describe "error handling with isolation" do
    test "broadcasts validation errors to isolated PubSub", %{pubsub: pubsub} do
      agent_id = "test-orient-error"

      # Subscribe to action events
      :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

      # Spawn per-action Router (v28.0)
      router = spawn_orient_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Invalid params (missing required fields)
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :orient, %{}, agent_id)})
      end)

      assert_received {:result, {:error, _validation_errors}}

      # Should receive error broadcast in isolated PubSub
      assert_receive {:action_error, payload}
      assert payload.agent_id == agent_id
    end

    test "broadcasts execution errors to isolated PubSub", %{pubsub: pubsub} do
      agent_id = "test-orient-exec-error"

      # Subscribe to both logs and actions
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:logs")
      :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

      # Spawn per-action Router (v28.0)
      router = spawn_orient_router(agent_id, pubsub)

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Params that might trigger internal error
      bad_params = Map.put(@valid_params, :current_situation, nil)

      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :orient, bad_params, agent_id)})
      end)

      assert_received {:result, result}

      case result do
        {:error, _} ->
          # Should receive error broadcast
          assert_receive {:action_error, %{agent_id: ^agent_id}}

        {:ok, _} ->
          # If it succeeds, should still receive broadcasts
          assert_receive {:log_entry, %{agent_id: ^agent_id}}
      end
    end
  end

  # Helper function to collect all log messages
  defp receive_all_logs(acc) do
    receive do
      {:log_entry, log} -> receive_all_logs([log | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
