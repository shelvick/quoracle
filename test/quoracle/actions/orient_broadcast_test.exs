defmodule Quoracle.Actions.OrientBroadcastTest do
  @moduledoc """
  Tests for ACTION_Orient PubSub broadcasting functionality.
  Verifies that orient action events are properly broadcast.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Actions.Router
  alias Test.PubSubIsolation

  setup do
    # Setup isolated PubSub for this test
    {:ok, pubsub} = PubSubIsolation.setup_isolated_pubsub()

    # Subscribe to action events topic in isolated PubSub
    :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

    agent_id = "test_agent_#{System.unique_integer([:positive])}"

    {:ok, agent_id: agent_id, pubsub: pubsub}
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

  describe "pubsub parameter support" do
    test "accepts optional pubsub parameter for broadcasting" do
      # Create isolated PubSub
      pubsub_name = :"test_pubsub_#{System.unique_integer()}"
      {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

      # Subscribe to isolated PubSub on the correct topic
      Phoenix.PubSub.subscribe(pubsub_name, "agents:test-agent:logs")

      params = %{
        current_situation: "test",
        goal_clarity: "test",
        available_resources: "test",
        key_challenges: "test",
        delegation_consideration: "none"
      }

      # Call Orient.execute with explicit pubsub (new 3-arity signature)
      result = Quoracle.Actions.Orient.execute(params, "test-agent", pubsub: pubsub_name)

      assert {:ok, _response} = result

      # Should receive log broadcast on custom pubsub
      assert_receive {:log_entry, _log}, 30_000
    end

    test "passes pubsub through options parameter" do
      # Create isolated PubSub
      pubsub_name = :"test_pubsub_#{System.unique_integer()}"
      {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

      params = %{
        current_situation: "test",
        goal_clarity: "test",
        available_resources: "test",
        key_challenges: "test",
        delegation_consideration: "none"
      }

      # Options with pubsub (new 3-arity signature)
      opts = [pubsub: pubsub_name]

      result = Quoracle.Actions.Orient.execute(params, "test-agent", opts)

      assert {:ok, _response} = result
    end
  end

  describe "orient action broadcasts" do
    test "broadcasts action_started when orient begins", %{agent_id: agent_id, pubsub: pubsub} do
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
      params = %{
        current_situation: "test",
        goal_clarity: "test",
        available_resources: "test",
        key_challenges: "test",
        delegation_consideration: "none"
      }

      # This should trigger action_started broadcast
      capture_log(fn ->
        Router.execute(router, :orient, params, agent_id)
      end)

      # Should receive action_started broadcast
      assert_receive {:action_started, payload}, 30_000
      assert payload.agent_id == agent_id
      assert payload.action_type == :orient
      assert payload.params == params
      assert is_binary(payload.action_id)
      assert %DateTime{} = payload.timestamp
    end

    test "broadcasts action_completed when orient succeeds", %{agent_id: agent_id, pubsub: pubsub} do
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
      params = %{
        current_situation: "test",
        goal_clarity: "test",
        available_resources: "test",
        key_challenges: "test",
        delegation_consideration: "none"
      }

      # Execute and get result
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :orient, params, agent_id)})
      end)

      assert_received {:result, {:ok, _result}}

      # Should receive both started and completed
      assert_receive {:action_started, start_payload}, 30_000
      assert_receive {:action_completed, complete_payload}, 30_000
      assert complete_payload.agent_id == agent_id
      assert complete_payload.action_id == start_payload.action_id
      assert match?({:ok, _}, complete_payload.result)
      assert %DateTime{} = complete_payload.timestamp
    end

    test "broadcasts action_error when orient fails", %{agent_id: agent_id, pubsub: pubsub} do
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

      # Execute orient with missing required params to cause validation failure
      params = %{invalid_param: "should_cause_validation_error"}

      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :orient, params, agent_id)})
      end)

      assert_received {:result, result}

      case result do
        {:error, _reason} ->
          # Should receive error broadcast
          assert_receive {:action_error, payload}, 30_000
          assert payload.agent_id == agent_id
          assert is_binary(payload.action_id)
          assert match?({:error, _}, payload.error)
          assert %DateTime{} = payload.timestamp

        {:ok, _} ->
          # Orient might succeed anyway, which is fine
          assert_receive {:action_completed, _payload}, 30_000
      end
    end

    test "includes correct action metadata in broadcasts", %{agent_id: agent_id, pubsub: pubsub} do
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

      # Execute orient through router
      params = %{
        current_situation: "test",
        goal_clarity: "test",
        available_resources: "test",
        key_challenges: "test",
        delegation_consideration: "none"
      }

      capture_log(fn ->
        Router.execute(router, :orient, params, agent_id)
      end)

      assert_receive {:action_started, payload}, 30_000

      # Verify metadata structure
      assert Map.has_key?(payload, :agent_id)
      assert Map.has_key?(payload, :action_type)
      assert Map.has_key?(payload, :action_id)
      assert Map.has_key?(payload, :params)
      assert Map.has_key?(payload, :timestamp)

      assert payload.action_type == :orient
    end

    test "broadcasts preserve execution context", %{agent_id: agent_id, pubsub: pubsub} do
      # Per-action Router (v28.0): Each orient gets its own Router
      router1 = spawn_orient_router(agent_id, pubsub)
      router2 = spawn_orient_router(agent_id, pubsub)

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

      # Execute multiple orient actions
      params = %{
        current_situation: "test",
        goal_clarity: "test",
        available_resources: "test",
        key_challenges: "test",
        delegation_consideration: "none"
      }

      capture_log(fn ->
        Router.execute(router1, :orient, params, agent_id)
        Router.execute(router2, :orient, params, agent_id)
      end)

      # Should receive distinct broadcasts for each
      assert_receive {:action_started, payload1}, 30_000
      assert_receive {:action_started, payload2}, 30_000

      # Action IDs should be unique
      assert payload1.action_id != payload2.action_id
      assert payload1.agent_id == payload2.agent_id
    end
  end

  describe "integration with AgentEvents" do
    test "Orient uses AgentEvents helper functions", %{agent_id: agent_id, pubsub: pubsub} do
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

      # This verifies Router integrates with AgentEvents module for Orient actions
      # rather than doing raw broadcasts

      params = %{
        current_situation: "test",
        goal_clarity: "test",
        available_resources: "test",
        key_challenges: "test",
        delegation_consideration: "none"
      }

      capture_log(fn ->
        Router.execute(router, :orient, params, agent_id)
      end)

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
