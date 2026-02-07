defmodule Quoracle.Agent.MessageHandlerUserPromptRemovalTest do
  @moduledoc """
  Tests for AGENT_MessageHandler v14.0: Remove skip_initial_prompt logic.

  WorkGroupID: fix-20260106-user-prompt-removal
  Packet: 1 (Message Flow)

  These tests verify that the initial user message flows through history
  like all other messages, with no special skip logic.

  Tests call the actual MessageHandler functions. Consensus is expected to fail
  due to minimal state setup, but we verify state modification happens correctly
  BEFORE consensus is called.
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.MessageHandler

  # Create a minimal state for testing message handling
  # skip_auto_consensus: true allows verifying state changes without full consensus flow
  defp create_test_state(opts) do
    task_description = Keyword.get(opts, :task_description, "Test task description")
    histories = Keyword.get(opts, :model_histories, %{"model-a" => [], "model-b" => []})

    %{
      agent_id: "test-agent-#{System.unique_integer([:positive])}",
      task_id: "test-task-#{System.unique_integer([:positive])}",
      model_histories: histories,
      pending_actions: %{},
      pubsub: nil,
      wait_timer: nil,
      context_lessons: %{},
      model_states: %{},
      context_limits_loaded: true,
      context_limit: 100_000,
      skip_auto_consensus: true,
      prompt_fields: %{
        provided: %{task_description: task_description}
      }
    }
  end

  describe "R46: No Skip Logic - initial message added to history" do
    test "initial message added to history like any other message" do
      task_description = "Analyze the data and provide a summary"
      state = create_test_state(task_description: task_description)

      # Send the SAME content as task_description (this is the initial message scenario)
      content = task_description

      # Call the actual function - consensus will fail but state changes happen first
      {:noreply, new_state} = MessageHandler.handle_send_user_message(state, content)

      # FAIL CONDITION: Currently skip_initial_prompt? triggers and message is NOT added
      # After fix: Message should be in model_histories
      for {model_id, history} <- new_state.model_histories do
        assert history != [],
               "Model #{model_id}: Initial message should be added to history, got #{length(history)} entries"

        # Find user message entry
        user_entry = Enum.find(history, fn entry -> entry.type == :event end)

        assert user_entry != nil,
               "Model #{model_id}: Should have :event entry for user message"

        assert user_entry.content.content == content,
               "Model #{model_id}: Message content should match"
      end
    end

    test "message with same content as task_description is added to history" do
      task_description = "Process input data"
      state = create_test_state(task_description: task_description)

      # Send message matching task_description
      {:noreply, new_state} = MessageHandler.handle_send_user_message(state, task_description)

      # FAIL: Currently model_histories remain empty because skip logic triggers
      # After fix: model_histories should have the message
      [history | _] = Map.values(new_state.model_histories)

      assert history != [],
             "Message matching task_description should still be added to history"
    end
  end

  describe "R47: Consistent Entry Points - create_task and spawn_child" do
    test "create_task and spawn_child paths both add initial message to history" do
      # Both paths end up calling handle_send_user_message with initial content
      # Test that BOTH scenarios add to history (neither should skip)

      task_description = "Do something"

      # Scenario 1: Root agent (create_task path) - parent_pid is nil
      root_state =
        create_test_state(task_description: task_description)
        |> Map.put(:parent_pid, nil)

      {:noreply, root_new_state} =
        MessageHandler.handle_send_user_message(root_state, task_description)

      # Scenario 2: Child agent (spawn_child path) - parent_pid exists
      child_state =
        create_test_state(task_description: task_description)
        |> Map.put(:parent_pid, self())

      {:noreply, child_new_state} =
        MessageHandler.handle_send_user_message(child_state, task_description)

      # FAIL: Both currently skip the initial message
      # After fix: Both should have the message in history
      for {_model_id, history} <- root_new_state.model_histories do
        assert history != [], "create_task path should add initial message to history"
      end

      for {_model_id, history} <- child_new_state.model_histories do
        assert history != [], "spawn_child path should add initial message to history"
      end
    end
  end

  describe "R48: No task_description Comparison" do
    test "no comparison between content and task_description" do
      # The implementation should NOT compare content to task_description
      # Test by verifying that matching content is still added

      task_description = "Test task"
      state = create_test_state(task_description: task_description)

      # Content matches task_description exactly
      content = task_description

      {:noreply, new_state} = MessageHandler.handle_send_user_message(state, content)

      # FAIL: Currently the comparison causes skip
      # After fix: No comparison, message is added
      [history | _] = Map.values(new_state.model_histories)

      assert history != [],
             "Message should be added regardless of matching task_description"
    end

    test "message handler adds message even when content equals task_description" do
      task_description = "Identical content"
      state = create_test_state(task_description: task_description)

      # Identical content
      {:noreply, new_state} = MessageHandler.handle_send_user_message(state, task_description)

      # FAIL: Currently skipped because content == task_description
      # After fix: Added to history like any other message
      histories_have_message =
        new_state.model_histories
        |> Map.values()
        |> Enum.all?(fn history -> history != [] end)

      assert histories_have_message,
             "All model histories should have the message, not skipped due to task_description match"
    end
  end

  describe "A6: Acceptance Test - Initial Message Flows Through History" do
    @tag :acceptance
    test "user prompt reaches AI through normal history flow" do
      # This acceptance test verifies user-observable behavior:
      # User does: Create task with prompt "Hello AI"
      # User expects: The message appears in model_histories for consensus

      task_description = "Hello AI"
      state = create_test_state(task_description: task_description)

      # Simulate the initial message being sent (same as task_description)
      {:noreply, new_state} = MessageHandler.handle_send_user_message(state, task_description)

      # FAIL: Currently the message is SKIPPED from history
      # After fix: Message should be in model_histories
      for {model_id, history} <- new_state.model_histories do
        assert history != [],
               "ACCEPTANCE: Model #{model_id} should have 'Hello AI' in history"

        # Verify the content is correct
        [entry | _] = history
        assert entry.type == :event
        assert entry.content.content == "Hello AI"
        # v18.0: handle_send_user_message delegates to handle_agent_message with :user sender_id
        assert entry.content.from == "user"
      end
    end

    @tag :acceptance
    test "subsequent messages with same content are also added" do
      # Even if a subsequent message has the same content as task_description,
      # it should still be added to history (no skip logic at all)

      task_description = "Repeat this task"

      # State with existing history (not initial state)
      state =
        create_test_state(
          task_description: task_description,
          model_histories: %{
            "model-a" => [%{type: :event, content: %{from: "parent", content: "first message"}}]
          }
        )

      # Same content as task_description, but history not empty
      {:noreply, new_state} = MessageHandler.handle_send_user_message(state, task_description)

      # This should pass with current impl (because history not empty)
      # After fix: Same behavior - message added
      [history] = Map.values(new_state.model_histories)

      assert length(history) >= 2,
             "Subsequent message should be added (now have #{length(history)} entries)"
    end
  end

  describe "handle_agent_message/3 - inter-agent messages" do
    test "inter-agent messages always added to history regardless of task_description" do
      # handle_agent_message/3 should ALWAYS add messages to history
      # (it doesn't have skip_initial_prompt logic - only handle_send_user_message does)

      task_description = "Test task"

      state =
        create_test_state(task_description: task_description)
        |> Map.put(:skip_auto_consensus, true)

      # Send message with same content as task_description via inter-agent path
      {:noreply, new_state} =
        MessageHandler.handle_agent_message(state, :parent, task_description)

      # This should PASS - handle_agent_message doesn't have skip logic
      # This test documents that ONLY handle_send_user_message had the bug
      for {_model_id, history} <- new_state.model_histories do
        assert length(history) == 1, "Inter-agent message should be added to history"
      end
    end
  end
end
