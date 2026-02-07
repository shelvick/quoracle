defmodule Quoracle.Agent.SenderInfoAcceptanceTest do
  @moduledoc """
  Acceptance tests for Bug 1: Sender Info in Messages
  WorkGroupID: fix-20251211-051748
  Packet: 1

  These tests verify end-to-end behavior using real agent processes.
  They test from user entry point to observable outcome.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.{Core, ContextManager}

  describe "acceptance: sender attribution in LLM context" do
    setup %{sandbox_owner: sandbox_owner} do
      # Create isolated dependencies (includes registry, dynsup, pubsub)
      deps = create_isolated_deps()

      {:ok, deps: deps, sandbox_owner: sandbox_owner}
    end

    test "child receives parent message with sender attribution", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Step 1: Spawn a child agent (simulating spawn_child result)
      child_config = %{
        agent_id: "child-agent-#{System.unique_integer([:positive])}",
        task_id: "test-task-#{System.unique_integer([:positive])}",
        parent_pid: self(),
        test_mode: true
      }

      {:ok, child_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          child_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Step 2: Simulate parent sending message to child (entry point)
      # This is what happens when parent executes send_message action
      sender_id = :parent
      message_content = "Complete the assigned subtask"

      # Send agent message (this is how messages arrive from parent)
      send(child_pid, {:agent_message, sender_id, message_content})

      # Wait for message to be processed
      # Use a sync call to ensure message was handled
      {:ok, child_state} = Core.get_state(child_pid)

      # Step 3: Verify the user-observable outcome
      # Build messages as LLM would see them
      model_id = child_state.model_histories |> Map.keys() |> List.first()
      messages = ContextManager.build_conversation_messages(child_state, model_id)

      # Find the user message from the event
      user_msg =
        Enum.find(messages, fn msg ->
          msg.role == "user" && msg.content =~ "subtask"
        end)

      # This will FAIL until implementation is complete:
      # - MessageHandler.handle_agent_message/3 must exist
      # - MessageHandler must store structured content with :from
      # - ContextManager must format as JSON
      assert user_msg != nil, "Message not found in conversation"

      assert user_msg.content =~ "\"from\": \"parent\"",
             "Expected sender attribution in JSON, got: #{inspect(user_msg.content)}"

      assert user_msg.content =~ "\"content\": \"Complete the assigned subtask\"",
             "Expected message content in JSON, got: #{inspect(user_msg.content)}"
    end

    test "parent receives child message with sender attribution", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Step 1: Spawn a parent agent
      parent_config = %{
        agent_id: "parent-agent-#{System.unique_integer([:positive])}",
        task_id: "test-task-#{System.unique_integer([:positive])}",
        parent_pid: nil,
        test_mode: true
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Step 2: Simulate child sending message to parent
      # This is what happens when child executes send_message to parent
      child_agent_id = "child-worker-#{System.unique_integer([:positive])}"
      message_content = "Subtask completed successfully"

      # Send agent message from child
      send(parent_pid, {:agent_message, child_agent_id, message_content})

      # Wait for message to be processed
      {:ok, parent_state} = Core.get_state(parent_pid)

      # Step 3: Verify the user-observable outcome
      model_id = parent_state.model_histories |> Map.keys() |> List.first()
      messages = ContextManager.build_conversation_messages(parent_state, model_id)

      # Find the user message from the event
      user_msg =
        Enum.find(messages, fn msg ->
          msg.role == "user" && msg.content =~ "completed"
        end)

      # This will FAIL until implementation is complete
      assert user_msg != nil, "Message not found in conversation"

      assert user_msg.content =~ "\"from\": \"#{child_agent_id}\"",
             "Expected child agent_id in JSON, got: #{inspect(user_msg.content)}"

      assert user_msg.content =~ "\"content\": \"Subtask completed successfully\"",
             "Expected message content in JSON, got: #{inspect(user_msg.content)}"
    end
  end
end
