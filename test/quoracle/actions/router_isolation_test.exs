defmodule Quoracle.Actions.RouterIsolationTest do
  @moduledoc """
  Tests for PubSub isolation in ACTION_Router.
  Verifies that Router uses AgentEvents for broadcasts which support isolation.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Quoracle.Actions.Router
  alias Test.PubSubIsolation

  setup do
    # Setup isolated PubSub for this test
    {:ok, pubsub} = PubSubIsolation.setup_isolated_pubsub()

    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0) - use :orient for isolation tests
    {:ok, router} =
      Router.start_link(
        action_type: :orient,
        action_id: "action-#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub
      )

    # Ensure router terminates before test exits
    on_exit(fn ->
      if Process.alive?(router) do
        try do
          GenServer.stop(router, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    # Subscribe to action events in isolated PubSub
    :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

    %{router: router, pubsub: pubsub, agent_id: agent_id}
  end

  describe "PubSub isolation" do
    test "broadcasts action_started events to isolated PubSub", %{router: router} do
      # Execute an action that should broadcast
      capture_log(fn ->
        Router.execute(router, :wait, %{wait: 0.01}, "test-agent-123")
      end)

      # Should receive broadcast in isolated PubSub
      assert_receive {:action_started, payload}
      assert payload.agent_id == "test-agent-123"
      assert payload.action_type == :wait
    end

    test "broadcasts action_completed events to isolated PubSub", %{router: router} do
      # Execute a quick action that completes synchronously
      capture_log(fn ->
        Router.execute(
          router,
          :orient,
          %{
            current_situation: "test",
            goal_clarity: "clear",
            available_resources: "test env",
            key_challenges: "none",
            delegation_consideration: "none"
          },
          "test-agent-456"
        )
      end)

      # Should receive completion broadcast in isolated PubSub
      assert_receive {:action_completed, payload}
      assert payload.agent_id == "test-agent-456"
    end

    test "broadcasts action_error events to isolated PubSub", %{router: router} do
      # Execute with invalid params to trigger error
      capture_log(fn ->
        Router.execute(router, :wait, %{wait: -1}, "test-agent-789")
      end)

      # Should receive error broadcast in isolated PubSub
      assert_receive {:action_error, payload}
      assert payload.agent_id == "test-agent-789"
    end

    test "isolated broadcasts don't leak between tests", %{router: router} do
      # This test's broadcasts should be isolated
      agent_id = "test-agent-main"
      other_agent = "other-agent"

      # Set up another isolated PubSub instance
      {:ok, other_pubsub} = PubSubIsolation.setup_isolated_pubsub()

      # Subscribe to the other PubSub instance
      Phoenix.PubSub.subscribe(other_pubsub, "actions:all")

      # Execute with the main router (using this test's PubSub)
      capture_log(fn ->
        Router.execute(router, :wait, %{wait: 0.005}, agent_id)
      end)

      # Should receive broadcast in this test's isolated PubSub
      assert_receive {:action_started, %{agent_id: ^agent_id}}

      # Should NOT receive broadcasts from other tests
      refute_receive {:action_started, %{agent_id: ^other_agent}}, 100
    end
  end
end
