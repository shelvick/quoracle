defmodule Quoracle.Agent.DynSupPubSubTest do
  @moduledoc """
  Tests for DynSup PubSub dependency injection support.
  """
  use Quoracle.DataCase, async: true
  import Test.CoreTestHelpers
  import Test.AgentTestHelpers
  alias Quoracle.Agent.DynSup

  setup %{sandbox_owner: sandbox_owner} do
    # Start an isolated PubSub for testing
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Start an isolated Registry for testing
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    # Start the DynSup
    {:ok, dynsup} = start_supervised({DynSup, []}, shutdown: :infinity)

    %{dynsup: dynsup, pubsub: pubsub_name, registry: registry_name, sandbox_owner: sandbox_owner}
  end

  describe "start_agent/3 with PubSub injection" do
    test "accepts pubsub option and passes to child agent", %{
      dynsup: dynsup,
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        parent_pid: nil,
        restart: :temporary,
        test_mode: true
      }

      # Start agent with explicit pubsub and registry
      opts = [pubsub: pubsub, registry: registry, sandbox_owner: sandbox_owner]
      {:ok, agent_pid} = DynSup.start_agent(dynsup, config, opts)

      # Wait for initialization and ensure tree cleanup
      {:ok, _state} = GenServer.call(agent_pid, :get_state)

      on_exit(fn ->
        stop_agent_tree(agent_pid, registry)
      end)

      # Agent should have received pubsub in its config
      assert Process.alive?(agent_pid)

      # Check that agent registered with pubsub in its state
      {:ok, state} = GenServer.call(agent_pid, :get_state)
      assert state.pubsub == pubsub
    end

    test "accepts both registry and pubsub options", %{
      dynsup: dynsup,
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        parent_pid: nil,
        restart: :temporary,
        test_mode: true
      }

      # Start agent with both registry and pubsub
      opts = [registry: registry, pubsub: pubsub, sandbox_owner: sandbox_owner]
      {:ok, agent_pid} = DynSup.start_agent(dynsup, config, opts)

      # Wait for initialization and ensure tree cleanup
      {:ok, _state} = GenServer.call(agent_pid, :get_state)

      on_exit(fn ->
        stop_agent_tree(agent_pid, registry)
      end)

      # Agent should have both in its state
      {:ok, state} = GenServer.call(agent_pid, :get_state)
      assert state.pubsub == pubsub
      assert state.registry == registry
    end

    test "uses isolated pubsub to prevent cross-test contamination", %{
      dynsup: dynsup,
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        parent_pid: nil,
        restart: :temporary,
        pubsub: pubsub,
        registry: registry,
        test_mode: true
      }

      # Start agent with isolated pubsub option
      {:ok, agent_pid} = DynSup.start_agent(dynsup, config, sandbox_owner: sandbox_owner)

      # Wait for initialization and ensure cleanup
      {:ok, _state} = GenServer.call(agent_pid, :get_state)

      on_exit(fn ->
        stop_agent_gracefully(agent_pid)
      end)

      # Should use isolated PubSub, not global
      {:ok, state} = GenServer.call(agent_pid, :get_state)
      assert state.pubsub == pubsub
    end
  end

  describe "child agent isolation" do
    test "agents with different pubsub instances are isolated", %{
      dynsup: dynsup,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      # Create two isolated PubSub instances
      pubsub1 = :"pubsub_1_#{System.unique_integer([:positive])}"
      pubsub2 = :"pubsub_2_#{System.unique_integer([:positive])}"

      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub1}, id: :pubsub1)
      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub2}, id: :pubsub2)

      # Start agents with different pubsub instances
      config1 = %{
        agent_id: "agent1_#{System.unique_integer([:positive])}",
        parent_pid: nil,
        test_mode: true
      }

      config2 = %{
        agent_id: "agent2_#{System.unique_integer([:positive])}",
        parent_pid: nil,
        test_mode: true
      }

      {:ok, agent1} =
        DynSup.start_agent(dynsup, config1,
          pubsub: pubsub1,
          registry: registry,
          sandbox_owner: sandbox_owner
        )

      {:ok, agent2} =
        DynSup.start_agent(dynsup, config2,
          pubsub: pubsub2,
          registry: registry,
          sandbox_owner: sandbox_owner
        )

      # Wait for initialization and ensure tree cleanup for both agents
      {:ok, _state1} = GenServer.call(agent1, :get_state)
      {:ok, _state2} = GenServer.call(agent2, :get_state)

      on_exit(fn ->
        stop_agent_tree(agent1, registry)
        stop_agent_tree(agent2, registry)
      end)

      # Subscribe to agent1's pubsub
      Phoenix.PubSub.subscribe(pubsub1, "agents:#{config1.agent_id}:logs")

      # Agent1 broadcasts should only go to pubsub1 using test helper
      broadcast_test_message(agent1, pubsub1, "test message")

      agent1_id = config1.agent_id
      assert_receive {:log_entry, %{agent_id: ^agent1_id}}

      # Should not receive broadcasts from agent2's pubsub
      agent2_id = config2.agent_id
      refute_receive {:log_entry, %{agent_id: ^agent2_id}}, 100
    end
  end
end
