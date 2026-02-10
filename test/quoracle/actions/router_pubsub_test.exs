defmodule Quoracle.Actions.RouterPubSubTest do
  @moduledoc """
  Tests for PubSub broadcasting in Action.Router.
  Verifies that router broadcasts action lifecycle events.
  """

  # async: true - Uses isolated PubSub instance for test isolation
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Actions.Router
  alias Quoracle.PubSub.AgentEvents

  setup do
    # Create isolated PubSub instance for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    # Generate a unique agent_id for this test
    agent_id = "test_agent_#{System.unique_integer([:positive])}"

    # Subscribe to action events on isolated PubSub
    :ok = AgentEvents.subscribe_to_all_agents(pubsub_name)

    # Per-action Router (v28.0)
    {:ok, router} =
      Router.start_link(
        action_type: :orient,
        action_id: "action-#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub_name
      )

    on_exit(fn ->
      if Process.alive?(router) do
        try do
          GenServer.stop(router, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{
      router: router,
      agent_id: agent_id,
      pubsub: pubsub_name
    }
  end

  describe "Router with custom PubSub" do
    test "uses custom pubsub for all broadcasts when configured", %{pubsub: _pubsub} do
      # Create another isolated PubSub for this specific test
      custom_pubsub = :"custom_pubsub_#{System.unique_integer()}"
      {:ok, _} = start_supervised({Phoenix.PubSub, name: custom_pubsub}, id: :custom_pubsub)

      # Subscribe ONLY to custom PubSub
      Phoenix.PubSub.subscribe(custom_pubsub, "actions:all")

      agent_id = "test_agent_#{System.unique_integer()}"

      # Per-action Router (v28.0) with custom pubsub
      {:ok, router} =
        Router.start_link(
          action_type: :orient,
          action_id: "action-#{System.unique_integer([:positive])}",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: custom_pubsub
        )

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute action - should broadcast to custom pubsub
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, %{wait: 0.01}, agent_id)})
      end)

      assert_received {:result, {:ok, _result}}

      # Should receive events on custom pubsub
      assert_receive {:action_started, event}, 30_000
      assert event.agent_id == agent_id
    end

    test "passes pubsub to background tasks in async mode", %{pubsub: _pubsub} do
      # Create another isolated PubSub for this specific test
      async_pubsub = :"async_pubsub_#{System.unique_integer()}"
      {:ok, _} = start_supervised({Phoenix.PubSub, name: async_pubsub}, id: :async_pubsub)

      # Subscribe ONLY to async PubSub
      Phoenix.PubSub.subscribe(async_pubsub, "actions:all")

      agent_id = "test_agent_#{System.unique_integer()}"

      # Per-action Router (v28.0) with async pubsub
      {:ok, router} =
        Router.start_link(
          action_type: :orient,
          action_id: "action-#{System.unique_integer([:positive])}",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: async_pubsub
        )

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute async action
      {:ok, response} = Router.execute(router, :wait, %{wait: 0.15}, agent_id)
      assert response.async == true

      # Should receive started event from task
      assert_receive {:action_started, _}, 30_000
      # No need to await - action completed immediately

      # Should receive completed event from task
      assert_receive {:action_completed, _}, 30_000
    end
  end

  describe "execute/5 - PubSub broadcasting" do
    test "broadcasts action_started event when action begins", %{
      router: router,
      agent_id: agent_id
    } do
      # Execute a simple action
      Router.execute(router, :wait, %{wait: 0.01}, agent_id)

      # Should receive action_started event
      assert_receive {:action_started, event}, 30_000
      assert event.agent_id == agent_id
      assert event.action_type == :wait
      assert event.params == %{wait: 0.01}
      assert is_binary(event.action_id)
      assert %DateTime{} = event.timestamp
    end

    test "broadcasts action_completed event when action succeeds", %{
      router: router,
      agent_id: agent_id
    } do
      # Execute a short action that completes quickly
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, %{wait: 0.01}, agent_id)})
      end)

      assert_received {:result, {:ok, _result}}

      # Should receive both started and completed events
      assert_receive {:action_started, _}, 30_000
      assert_receive {:action_completed, event}, 30_000
      assert event.agent_id == agent_id
      assert match?({:ok, _}, event.result)
      assert is_binary(event.action_id)
      assert %DateTime{} = event.timestamp
    end

    test "broadcasts action_error event when action fails", %{router: router, agent_id: agent_id} do
      # Execute with invalid parameters
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, %{wait: -1}, agent_id)})
      end)

      assert_received {:result, {:error, _}}

      # Should receive action_error event
      assert_receive {:action_error, event}, 30_000
      assert event.agent_id == agent_id
      assert match?({:error, _}, event.error)
      assert is_binary(event.action_id)
      assert %DateTime{} = event.timestamp
    end

    test "broadcasts events for async actions", %{router: router, agent_id: agent_id} do
      # Execute a long-running async action
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, %{wait: 150}, agent_id)})
      end)

      assert_received {:result, {:ok, response}}
      assert response.async == true

      # Should receive action_started immediately
      assert_receive {:action_started, start_event}, 30_000
      assert start_event.agent_id == agent_id
      assert start_event.action_type == :wait

      # No need to await - action completed immediately

      # Should receive action_completed after await
      assert_receive {:action_completed, complete_event}, 30_000
      assert complete_event.agent_id == agent_id
      assert complete_event.action_id == start_event.action_id
    end

    test "includes execution metrics in completed event", %{router: router, agent_id: agent_id} do
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :orient, valid_orient_params(), agent_id)})
      end)

      assert_received {:result, {:ok, result}}

      assert_receive {:action_completed, _event}, 30_000
      # execution_time_ms is in the result, not the event
      assert is_number(result.execution_time_ms)
      assert result.execution_time_ms >= 0
    end

    test "broadcasts error event when action crashes", %{router: router, agent_id: agent_id} do
      # This would cause a crash if not validated
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, %{wait: "invalid"}, agent_id)})
      end)

      assert_received {:result, {:error, _}}

      assert_receive {:action_error, event}, 30_000
      assert event.agent_id == agent_id
      assert match?({:error, _}, event.error)
    end

    test "broadcasts events with consistent action_id", %{router: router, agent_id: agent_id} do
      # Clear any existing messages
      receive do
        _ -> :ok
      after
        0 -> :ok
      end

      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, %{wait: 0.01}, agent_id)})
      end)

      assert_received {:result, {:ok, _}}

      assert_receive {:action_started, start_event}, 30_000
      assert start_event.agent_id == agent_id

      assert_receive {:action_completed, complete_event}, 30_000
      assert complete_event.agent_id == agent_id

      # Same action_id for lifecycle events
      assert start_event.action_id == complete_event.action_id
    end
  end

  # Helper functions
  defp valid_orient_params do
    %{
      current_situation: "Testing router",
      goal_clarity: "Clear objectives",
      available_resources: "Test environment",
      key_challenges: "None identified",
      delegation_consideration: "No delegation needed"
    }
  end
end
