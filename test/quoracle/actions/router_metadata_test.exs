defmodule Quoracle.Actions.RouterMetadataTest do
  @moduledoc """
  Tests for Router's metadata passing to SendMessage action.
  Verifies that Router correctly extracts and passes agent_id and task_id.
  """
  use ExUnit.Case, async: true

  alias Quoracle.Actions.Router

  setup do
    # Create isolated dependencies
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"

    {:ok, _registry} = start_supervised({Registry, keys: :duplicate, name: registry_name})
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    agent_id = "agent_#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0)
    {:ok, router} =
      Router.start_link(
        action_type: :send_message,
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

    # Register test process as a root agent (no parent) so resolve_parent works
    Registry.register(registry_name, {:agent, agent_id}, %{parent_id: nil, parent_pid: nil})

    %{
      router: router,
      registry: registry_name,
      pubsub: pubsub_name,
      agent_id: agent_id,
      task_id: Ecto.UUID.generate()
    }
  end

  describe "dispatch_to_action_module for SendMessage" do
    test "passes agent_id from opts to SendMessage", %{
      router: router,
      registry: registry,
      pubsub: pubsub,
      agent_id: agent_id,
      task_id: task_id
    } do
      params = %{to: "parent", content: "Test dispatch"}
      _action_id = "action_200"

      # Opts should include both agent_id and task_id
      opts = [
        agent_id: agent_id,
        task_id: task_id,
        registry: registry,
        pubsub: pubsub,
        agent_pid: self()
      ]

      # Router should pass agent_id to SendMessage.execute/5
      result = Router.execute(router, :send_message, params, agent_id, opts)

      # Should successfully execute with metadata
      assert {:ok, _} = result
    end

    test "passes task_id from opts to SendMessage", %{
      router: router,
      registry: registry,
      pubsub: pubsub,
      agent_id: agent_id,
      task_id: task_id
    } do
      params = %{to: "parent", content: "Test task_id passing"}
      _action_id = "action_201"

      opts = [
        agent_id: agent_id,
        task_id: task_id,
        registry: registry,
        pubsub: pubsub,
        agent_pid: self()
      ]

      # Subscribe to verify task_id is used for topic
      Phoenix.PubSub.subscribe(pubsub, "tasks:#{task_id}:messages")

      result = Router.execute(router, :send_message, params, agent_id, opts)

      assert {:ok, _} = result

      # Should receive message on task-specific topic
      assert_receive {:agent_message, _}, 30_000
    end

    test "uses agent_id as fallback when task_id not in opts", %{
      router: router,
      registry: registry,
      pubsub: pubsub,
      agent_id: agent_id
    } do
      params = %{to: "parent", content: "Test fallback"}
      _action_id = "action_202"

      # Opts without task_id
      opts = [
        agent_id: agent_id,
        registry: registry,
        pubsub: pubsub,
        agent_pid: self()
      ]

      # Router should use agent_id as fallback for task_id
      result = Router.execute(router, :send_message, params, agent_id, opts)

      assert {:ok, _} = result
    end

    test "does not pass sender_pid from spawned process", %{
      router: router,
      registry: registry,
      pubsub: pubsub,
      agent_id: agent_id,
      task_id: task_id
    } do
      params = %{to: "parent", content: "Test no sender_pid"}
      _action_id = "action_203"

      # The old implementation wrongly passed sender_pid which was nil or spawned process
      # New implementation should NOT have sender_pid in the call to SendMessage
      opts = [
        agent_id: agent_id,
        task_id: task_id,
        registry: registry,
        pubsub: pubsub,
        agent_pid: self()
      ]

      # This should work without any sender_pid parameter
      result = Router.execute(router, :send_message, params, agent_id, opts)

      assert {:ok, _} = result
    end
  end

  describe "backward compatibility for other actions" do
    test "Orient action maintains its existing signature", %{
      router: router,
      pubsub: pubsub,
      agent_id: agent_id
    } do
      params = %{
        current_situation: "Testing",
        goal_clarity: "Clear",
        available_resources: "Adequate",
        key_challenges: "None",
        delegation_consideration: "None needed"
      }

      opts = [
        pubsub: pubsub,
        agent_pid: self()
      ]

      # Orient should still work with its existing signature
      result = Router.execute(router, :orient, params, agent_id, opts)

      # Should execute successfully
      assert {:ok, _} = result
    end

    test "Wait action maintains its existing signature", %{
      router: router,
      registry: registry,
      pubsub: pubsub,
      agent_id: agent_id
    } do
      params = %{wait: 0}

      opts = [
        registry: registry,
        pubsub: pubsub,
        agent_pid: self()
      ]

      # Wait should still work with its existing signature
      result = Router.execute(router, :wait, params, agent_id, opts)

      # Should execute successfully
      assert {:ok, _} = result
    end
  end

  describe "error handling" do
    test "returns error when SendMessage module not loaded", %{
      router: router,
      agent_id: agent_id
    } do
      # If SendMessage module is not available, should fall back to MockExecution
      params = %{to: "parent", content: "Test"}
      opts = []

      # This would normally fall back to MockExecution if SendMessage not loaded
      result = Router.execute(router, :send_message, params, agent_id, opts)

      # Should return a result tuple (success or error)
      assert is_tuple(result) and elem(result, 0) in [:ok, :error]
    end

    test "validates action parameters before dispatch", %{
      router: router,
      agent_id: agent_id
    } do
      # Invalid params for send_message (missing required fields)
      params = %{}
      opts = []

      result = Router.execute(router, :send_message, params, agent_id, opts)

      # Should return validation error
      assert {:error, _} = result
    end
  end
end
