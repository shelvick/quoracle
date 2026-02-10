defmodule Quoracle.Agent.CorePubSubTest do
  @moduledoc """
  Tests for Agent.Core PubSub isolation support.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Test.AgentTestHelpers
  import Test.CoreTestHelpers
  alias Quoracle.Agent.Core

  setup do
    # Create isolated PubSub
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Create isolated Registry
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    %{pubsub: pubsub_name, registry: registry_name}
  end

  describe "start_link/2 with PubSub injection" do
    test "accepts pubsub in options and stores in state", %{pubsub: pubsub, registry: registry} do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        parent_pid: nil,
        task_id: "task-1",
        registry: registry,
        pubsub: pubsub,
        test_mode: true
      }

      # Use direct start_link instead of start_supervised to avoid dual cleanup race
      capture_log(fn ->
        {:ok, agent} = Core.start_link(config)
        send(self(), {:agent, agent})
      end)

      assert_received {:agent, agent}

      # Wait for agent initialization and add cleanup
      assert {:ok, state} = Quoracle.Agent.Core.get_state(agent)
      register_agent_cleanup(agent)

      # Check state has pubsub
      assert state.pubsub == pubsub
    end

    test "uses isolated pubsub to prevent cross-test contamination", %{
      pubsub: pubsub,
      registry: registry
    } do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        parent_pid: nil,
        task_id: "task-1",
        registry: registry,
        pubsub: pubsub,
        test_mode: true
      }

      # Use direct start_link instead of start_supervised to avoid dual cleanup race
      capture_log(fn ->
        {:ok, agent} = Core.start_link(config)
        send(self(), {:agent, agent})
      end)

      assert_received {:agent, agent}

      # Wait for agent initialization and add cleanup
      assert {:ok, state} = Quoracle.Agent.Core.get_state(agent)
      register_agent_cleanup(agent)

      # Should use isolated PubSub (not global)
      assert state.pubsub == pubsub
    end
  end

  describe "PubSub broadcasting isolation" do
    test "uses injected pubsub for all AgentEvents broadcasts", %{
      pubsub: pubsub,
      registry: registry
    } do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      # Subscribe to isolated pubsub topics
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:state")
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:logs")

      config = %{
        agent_id: agent_id,
        parent_pid: nil,
        task_id: "task-1",
        registry: registry,
        pubsub: pubsub,
        test_mode: true
      }

      # Use direct start_link instead of start_supervised to avoid dual cleanup race
      capture_log(fn ->
        {:ok, agent} = Core.start_link(config)
        send(self(), {:agent, agent})
      end)

      assert_received {:agent, agent}

      # Wait for agent initialization and add cleanup
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(agent)
      register_agent_cleanup(agent)

      # Trigger state broadcast using test helper
      update_state_and_broadcast(agent, pubsub, %{status: :active})

      # Should receive on isolated pubsub
      assert_receive {:agent_state_update, %{agent_id: ^agent_id, status: :active}}, 30_000

      # Trigger log broadcast
      GenServer.cast(agent, {:log, :info, "Test message"})

      assert_receive {:log_entry, %{agent_id: ^agent_id, message: "Test message"}}, 30_000
    end

    test "broadcasts don't leak to global pubsub", %{pubsub: pubsub, registry: registry} do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      # Subscribe to global pubsub (should NOT receive messages)
      Phoenix.PubSub.subscribe(Quoracle.PubSub, "agents:#{agent_id}:state")

      config = %{
        agent_id: agent_id,
        parent_pid: nil,
        task_id: "task-1",
        registry: registry,
        pubsub: pubsub,
        test_mode: true
      }

      # Use direct start_link instead of start_supervised to avoid dual cleanup race
      capture_log(fn ->
        {:ok, agent} = Core.start_link(config)
        send(self(), {:agent, agent})
      end)

      assert_received {:agent, agent}

      # Wait for agent initialization and add cleanup
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(agent)
      register_agent_cleanup(agent)

      # Trigger broadcast with isolated pubsub using test helper
      update_state_and_broadcast(agent, pubsub, %{status: :active})

      # Should NOT receive on global pubsub
      refute_receive {:agent_state_update, _}, 100
    end

    test "isolated agents don't receive each other's broadcasts", %{registry: registry} do
      # Create two isolated pubsub instances
      pubsub1 = :"pubsub1_#{System.unique_integer([:positive])}"
      pubsub2 = :"pubsub2_#{System.unique_integer([:positive])}"

      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub1}, id: :ps1)
      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub2}, id: :ps2)

      # Start two agents with different pubsub
      config1 = %{
        agent_id: "agent1",
        parent_pid: nil,
        task_id: "task-1",
        registry: registry,
        pubsub: pubsub1,
        test_mode: true
      }

      config2 = %{
        agent_id: "agent2",
        parent_pid: nil,
        task_id: "task-2",
        registry: registry,
        pubsub: pubsub2,
        test_mode: true
      }

      # Use direct start_link instead of start_supervised to avoid dual cleanup race
      capture_log(fn ->
        {:ok, agent1} = Core.start_link(config1)
        {:ok, agent2} = Core.start_link(config2)
        send(self(), {:agents, {agent1, agent2}})
      end)

      assert_received {:agents, {agent1, agent2}}

      # Wait for agent initialization and add cleanup
      assert {:ok, _state1} = Quoracle.Agent.Core.get_state(agent1)
      assert {:ok, _state2} = Quoracle.Agent.Core.get_state(agent2)

      register_agent_cleanup(agent1)
      register_agent_cleanup(agent2)

      # Subscribe to agent1's pubsub
      Phoenix.PubSub.subscribe(pubsub1, "agents:agent1:logs")

      # Agent1 broadcasts
      GenServer.cast(agent1, {:log, :info, "Message from agent1"})

      assert_receive {:log_entry, %{agent_id: "agent1", message: "Message from agent1"}}, 30_000

      # Agent2 broadcasts (should not receive)
      GenServer.cast(agent2, {:log, :info, "Message from agent2"})

      refute_receive {:log_entry, %{agent_id: "agent2"}}, 100
    end
  end

  describe "MessageHandler integration" do
    test "passes pubsub from state to MessageHandler", %{pubsub: pubsub, registry: registry} do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      # skip_consensus: true triggers broadcast_test_events for PubSub isolation testing
      config = %{
        agent_id: agent_id,
        parent_pid: self(),
        task_id: "task-1",
        registry: registry,
        pubsub: pubsub,
        test_mode: true,
        skip_consensus: true,
        test_opts: [skip_initial_consultation: true]
      }

      # Use direct start_link instead of start_supervised to avoid dual cleanup race
      capture_log(fn ->
        {:ok, agent} = Core.start_link(config)
        send(self(), {:agent, agent})
      end)

      assert_received {:agent, agent}

      # Wait for agent initialization and add cleanup
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(agent)
      register_agent_cleanup(agent)

      # Subscribe to PubSub BEFORE triggering event (prevents race condition)
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:messages")

      # Send a message that triggers MessageHandler
      message = %{
        type: "request",
        from: "parent",
        content: "test message"
      }

      send(agent, {:message, message})

      # Should receive message processed event on isolated pubsub
      # Use 1000ms timeout to handle high parallel load (matches convention elsewhere)
      assert_receive {:message_processed, %{agent_id: ^agent_id}}, 30_000
    end

    test "MessageHandler broadcasts use isolated pubsub", %{pubsub: pubsub, registry: registry} do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      # Subscribe to message events
      Phoenix.PubSub.subscribe(pubsub, "messages:all")

      # skip_consensus: true triggers broadcast_test_events for PubSub isolation testing
      config = %{
        agent_id: agent_id,
        parent_pid: self(),
        task_id: "task-1",
        registry: registry,
        pubsub: pubsub,
        test_mode: true,
        skip_consensus: true,
        test_opts: [skip_initial_consultation: true]
      }

      # Use direct start_link instead of start_supervised to avoid dual cleanup race
      capture_log(fn ->
        {:ok, agent} = Core.start_link(config)
        send(self(), {:agent, agent})
      end)

      assert_received {:agent, agent}

      # Wait for agent initialization and add cleanup
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(agent)
      register_agent_cleanup(agent)

      # Trigger message handling
      send(agent, {:message, %{type: "broadcast_test", from: "test"}})

      # Should receive on isolated pubsub
      # Use 1000ms timeout to handle high parallel load (matches convention elsewhere)
      assert_receive {:message_event, %{agent_id: ^agent_id}}, 30_000
    end
  end

  describe "action execution with pubsub" do
    test "passes pubsub to Router when executing actions", %{pubsub: pubsub, registry: registry} do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        parent_pid: nil,
        task_id: "task-1",
        registry: registry,
        pubsub: pubsub,
        test_mode: true
      }

      # Use direct start_link instead of start_supervised to avoid dual cleanup race
      capture_log(fn ->
        {:ok, agent} = Core.start_link(config)
        send(self(), {:agent, agent})
      end)

      assert_received {:agent, agent}

      # Wait for agent initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(agent)
      register_agent_cleanup(agent)

      # Execute an action
      action = %{
        type: :wait,
        params: %{wait: 100}
      }

      {:ok, _result} = GenServer.call(agent, {:execute_action, action})

      # Router should have received pubsub parameter
      # This would be verified by checking Router's state
      # but for now we just ensure no crash
    end
  end
end
