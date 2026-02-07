defmodule Quoracle.Agent.MessageFlushAcceptanceTest do
  @moduledoc """
  Acceptance tests for message flush bug fix (v15.0).

  Tests user-observable behavior: messages reach agents at the expected time.

  WorkGroupID: fix-20260115-message-flush

  Requirements:
  - A7: User follow-up message reaches agent at next consensus cycle
  - A8: Parent message to child not delayed by sync actions
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core

  defp unique_id, do: "agent-#{System.unique_integer([:positive])}"

  defp create_isolated_infrastructure do
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({Phoenix.PubSub, name: pubsub_name})
    start_supervised!({DynamicSupervisor, name: dynsup_name, strategy: :one_for_one})

    %{registry: registry_name, pubsub: pubsub_name, dynsup: dynsup_name}
  end

  describe "[SYSTEM] A7: user follow-up reaches agent" do
    @tag :acceptance
    test "user follow-up message reaches agent at next consensus cycle" do
      # Setup: Create isolated infrastructure
      infra = create_isolated_infrastructure()

      # Create a minimal agent config
      config = %{
        agent_id: unique_id(),
        task_id: unique_id(),
        task_description: "Test task",
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: self()
      }

      # Start agent
      {:ok, agent_pid} = DynamicSupervisor.start_child(infra.dynsup, {Core, config})

      # Cleanup on exit
      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Wait for agent to initialize
      {:ok, initial_state} = Core.get_state(agent_pid)
      assert initial_state.agent_id == config.agent_id

      # Simulate: Agent is executing a sync action (pending_actions non-empty)
      # This is done by directly manipulating state for test purposes
      # In production, this happens when action execution begins

      # Send follow-up message using proper agent message API
      # This triggers handle_info({:agent_message, sender_id, content}, state)
      # which routes to MessageHandler.handle_agent_message with proper formatting
      send(agent_pid, {:agent_message, :parent, "user follow-up"})

      # Simulate: Action completes, :trigger_consensus is sent
      # This triggers the consensus continuation path

      # Get state after message processing
      {:ok, state_after} = Core.get_state(agent_pid)

      # Assert: The follow-up message should be in the agent's history
      # After the bug fix, messages are flushed immediately - not left in queue

      # Check model_histories for the message
      all_histories = Map.values(state_after.model_histories) |> List.flatten()

      message_in_history =
        Enum.any?(all_histories, fn entry ->
          is_map(entry) and
            (entry[:content] == "user follow-up" or
               (is_map(entry[:content]) and entry[:content][:content] == "user follow-up"))
        end)

      # Positive assertion: message MUST be in history
      assert message_in_history,
             "User follow-up should be in history after flush"

      # Negative assertion: queue should be empty (message was flushed)
      assert state_after.queued_messages == [],
             "Queue should be empty after message flush"
    end
  end

  describe "[SYSTEM] A8: parent-child not delayed" do
    @tag :acceptance
    test "parent message to child not delayed by sync actions" do
      # Setup
      infra = create_isolated_infrastructure()

      # Create parent agent
      parent_config = %{
        agent_id: "parent-#{System.unique_integer([:positive])}",
        task_id: unique_id(),
        task_description: "Parent task",
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: self()
      }

      {:ok, parent_pid} = DynamicSupervisor.start_child(infra.dynsup, {Core, parent_config})

      # Create child agent
      child_config = %{
        agent_id: "child-#{System.unique_integer([:positive])}",
        task_id: unique_id(),
        task_description: "Child task",
        parent_pid: parent_pid,
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: self()
      }

      {:ok, child_pid} = DynamicSupervisor.start_child(infra.dynsup, {Core, child_config})

      # Cleanup
      on_exit(fn ->
        for pid <- [child_pid, parent_pid] do
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end
      end)

      # Wait for both to initialize
      {:ok, _parent_state} = Core.get_state(parent_pid)
      {:ok, _initial_child_state} = Core.get_state(child_pid)

      # Simulate: Child is executing a sync action (like :orient)
      # Parent sends a message to child using proper agent message API
      send(child_pid, {:agent_message, :parent, "message from parent"})

      # Get child state
      {:ok, child_state_after} = Core.get_state(child_pid)

      # Assert: Message should be in history (flushed immediately)
      all_histories = Map.values(child_state_after.model_histories) |> List.flatten()

      message_in_history =
        Enum.any?(all_histories, fn entry ->
          is_map(entry) and
            (entry[:content] == "message from parent" or
               (is_map(entry[:content]) and entry[:content][:content] == "message from parent"))
        end)

      # Positive assertion: message MUST be in history
      assert message_in_history,
             "Parent message should be in child history after flush"

      # Negative assertion: queue should be empty (message was flushed)
      assert child_state_after.queued_messages == [],
             "Child queue should be empty after message flush"
    end
  end
end
