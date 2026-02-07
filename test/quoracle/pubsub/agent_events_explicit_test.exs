defmodule Quoracle.PubSub.AgentEventsExplicitTest do
  @moduledoc """
  Tests for AgentEvents with explicit PubSub parameter passing for isolation.
  All functions require explicit pubsub parameter - no defaults.
  """
  use ExUnit.Case, async: true

  alias Quoracle.PubSub.AgentEvents

  setup do
    # Create isolated PubSub instance for testing
    unique_id = System.unique_integer([:positive])
    pubsub_name = :"test_pubsub_#{unique_id}"

    # Use start_supervised for proper cleanup
    start_supervised!({Phoenix.PubSub, name: pubsub_name, adapter: Phoenix.PubSub.PG2})

    {:ok, pubsub: pubsub_name}
  end

  describe "broadcast_agent_spawned/4 with explicit pubsub" do
    test "broadcasts to specified pubsub instance", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "agents:lifecycle")

      :ok = AgentEvents.broadcast_agent_spawned("agent-1", "task-1", self(), pubsub)

      assert_receive {:agent_spawned, payload}
      assert payload.agent_id == "agent-1"
      assert payload.task_id == "task-1"
    end
  end

  describe "broadcast_agent_terminated/3 with explicit pubsub" do
    test "broadcasts to specified pubsub instance", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "agents:lifecycle")

      :ok = AgentEvents.broadcast_agent_terminated("agent-1", :normal, pubsub)

      assert_receive {:agent_terminated, payload}
      assert payload.agent_id == "agent-1"
      assert payload.reason == :normal
    end
  end

  describe "broadcast_action_started/5 with explicit pubsub" do
    test "broadcasts to specified pubsub instance", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      params = %{wait: 100}
      :ok = AgentEvents.broadcast_action_started("agent-1", :wait, "action-1", params, pubsub)

      assert_receive {:action_started, payload}
      assert payload.agent_id == "agent-1"
      assert payload.action_type == :wait
      assert payload.action_id == "action-1"
    end
  end

  describe "broadcast_action_completed/4 with explicit pubsub" do
    test "broadcasts to specified pubsub instance", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      result = {:ok, %{waited: 100}}
      :ok = AgentEvents.broadcast_action_completed("agent-1", "action-1", result, pubsub)

      assert_receive {:action_completed, payload}
      assert payload.agent_id == "agent-1"
      assert payload.action_id == "action-1"
      assert payload.result == result
    end
  end

  describe "broadcast_action_error/4 with explicit pubsub" do
    test "broadcasts to specified pubsub instance", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      error = {:error, :timeout}
      :ok = AgentEvents.broadcast_action_error("agent-1", "action-1", error, pubsub)

      assert_receive {:action_error, payload}
      assert payload.agent_id == "agent-1"
      assert payload.error == error
    end
  end

  describe "broadcast_log/5 with explicit pubsub" do
    test "broadcasts to specified pubsub instance", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "agents:agent-1:logs")

      metadata = %{action: "orient"}
      :ok = AgentEvents.broadcast_log("agent-1", :info, "Test message", metadata, pubsub)

      assert_receive {:log_entry, payload}
      assert payload.agent_id == "agent-1"
      assert payload.level == :info
      assert payload.message == "Test message"
      assert payload.metadata == metadata
    end
  end

  describe "broadcast_user_message/4 with explicit pubsub" do
    test "broadcasts to specified pubsub instance", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "tasks:task-1:messages")

      :ok = AgentEvents.broadcast_user_message("task-1", "agent-1", "Hello", pubsub)

      assert_receive {:agent_message, payload}
      assert payload.from == :user
      assert payload.sender_id == "agent-1"
      assert payload.content == "Hello"
      assert payload.status == :received
    end
  end

  describe "broadcast_state_change/4 with explicit pubsub" do
    test "broadcasts to specified pubsub instance", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "agents:agent-1:state")

      :ok = AgentEvents.broadcast_state_change("agent-1", :idle, :busy, pubsub)

      assert_receive {:state_changed, payload}
      assert payload.agent_id == "agent-1"
      assert payload.old_state == :idle
      assert payload.new_state == :busy
    end
  end

  describe "isolation between tests" do
    test "multiple tests get different pubsub instances", %{pubsub: pubsub1} do
      unique_id = "#{System.monotonic_time()}#{System.unique_integer([:positive])}"
      pubsub2 = :"test_pubsub_#{unique_id}"

      start_supervised!({Phoenix.PubSub, name: pubsub2, adapter: Phoenix.PubSub.PG2}, id: pubsub2)

      Phoenix.PubSub.subscribe(pubsub1, "agents:lifecycle")
      Phoenix.PubSub.subscribe(pubsub2, "agents:lifecycle")

      :ok = AgentEvents.broadcast_agent_spawned("agent-1", "task-1", self(), pubsub1)

      assert_receive {:agent_spawned, payload}
      assert payload.agent_id == "agent-1"

      refute_receive {:agent_spawned, _}, 100
    end

    test "concurrent tests don't interfere", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      unique_id = "#{System.monotonic_time()}#{System.unique_integer([:positive])}"
      other_pubsub = :"test_pubsub_task_#{unique_id}"

      start_supervised!({Phoenix.PubSub, name: other_pubsub, adapter: Phoenix.PubSub.PG2},
        id: other_pubsub
      )

      task =
        Task.async(fn ->
          Phoenix.PubSub.subscribe(other_pubsub, "actions:all")

          :ok =
            AgentEvents.broadcast_action_started(
              "other-agent",
              :orient,
              "other-action",
              %{},
              other_pubsub
            )

          assert_receive {:action_started, payload}
          assert payload.agent_id == "other-agent"

          refute_receive {:action_started, %{agent_id: "main-agent"}}, 100
        end)

      :ok = AgentEvents.broadcast_action_started("main-agent", :wait, "main-action", %{}, pubsub)

      assert_receive {:action_started, payload}
      assert payload.agent_id == "main-agent"

      refute_receive {:action_started, %{agent_id: "other-agent"}}, 100

      Task.await(task)

      stop_supervised(other_pubsub)
    end
  end

  describe "No Process dictionary usage" do
    test "does not use Process dictionary", %{pubsub: pubsub} do
      Process.delete(:test_pubsub)
      assert Process.get(:test_pubsub) == nil

      Phoenix.PubSub.subscribe(pubsub, "agents:lifecycle")

      :ok = AgentEvents.broadcast_agent_spawned("agent-1", "task-1", self(), pubsub)

      assert_receive {:agent_spawned, _}

      assert Process.get(:test_pubsub) == nil
    end

    test "ignores Process dictionary even if set", %{pubsub: pubsub} do
      wrong_pubsub = :wrong_pubsub
      Process.put(:test_pubsub, wrong_pubsub)

      Phoenix.PubSub.subscribe(pubsub, "agents:lifecycle")

      :ok = AgentEvents.broadcast_agent_spawned("agent-1", "task-1", self(), pubsub)

      assert_receive {:agent_spawned, _}

      Process.delete(:test_pubsub)
    end
  end
end
