defmodule Quoracle.Agent.ConsensusHandlerUIBroadcastTest do
  @moduledoc """
  Tests for UI broadcast including ACE context in sent_messages.

  WorkGroupID: wip-20260104-ace-injector
  Packet: 2 (UI Broadcast Fix)

  Problem: The `sent_messages` broadcast in ConsensusHandler.get_action_consensus
  builds messages for UI display but doesn't include ACE injection. This means
  the UI shows a different view than what's actually sent to the LLM.

  Fix: Add inject_ace_context call to sent_messages building in get_action_consensus.

  ARC Verification Criteria: R71-R73
  """
  use ExUnit.Case, async: true

  import Test.IsolationHelpers

  alias Quoracle.Agent.ConsensusHandler

  # ========== TEST HELPERS ==========

  defp make_lesson(content, type \\ :factual, confidence \\ 0.8) do
    %{content: content, type: type, confidence: confidence}
  end

  defp make_model_state(summary) do
    %{summary: summary}
  end

  defp make_history_entry(type, content) do
    %{type: type, content: content, timestamp: DateTime.utc_now()}
  end

  defp make_state_with_ace(model_id, pubsub) do
    %{
      agent_id: "test-agent-#{System.unique_integer([:positive])}",
      task_id: "test-task",
      model_pool: [model_id],
      model_histories: %{
        model_id => [
          make_history_entry(:user, "User message"),
          make_history_entry(:assistant, "Assistant response")
        ]
      },
      context_lessons: %{model_id => [make_lesson("UI should see this lesson")]},
      model_states: %{model_id => make_model_state("Task progress visible in UI")},
      todos: [%{content: "Current task", state: :todo}],
      children: [],
      budget_data: nil,
      registry: nil,
      pubsub: pubsub,
      test_mode: true,
      test_opts: []
    }
  end

  # ========== R71: UI BROADCAST INCLUDES ACE ==========

  describe "R71: sent_messages includes ACE" do
    test "sent_messages contains ACE lessons for UI display" do
      deps = create_isolated_deps()
      model_id = "test-model"
      state = make_state_with_ace(model_id, deps.pubsub)

      # Subscribe to the agent-specific log topic
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:#{state.agent_id}:logs")

      # Call get_action_consensus - it will broadcast sent_messages
      _result = ConsensusHandler.get_action_consensus(state)

      # Wait for the broadcast (format is {:log_entry, %{...}})
      assert_receive {:log_entry, log_entry}, 30_000

      # Find the "Sending to consensus" log which contains sent_messages
      assert log_entry.message =~ "Sending to consensus",
             "Expected 'Sending to consensus' log, got: #{log_entry.message}"

      metadata = log_entry.metadata
      sent_messages = metadata[:sent_messages]
      assert is_list(sent_messages), "sent_messages should be a list"

      # Find the messages for our model
      model_entry = Enum.find(sent_messages, &(&1.model_id == model_id))
      assert model_entry, "Should have entry for #{model_id}"

      messages = model_entry.messages

      all_content =
        Enum.map_join(messages, " ", fn msg ->
          case msg.content do
            c when is_binary(c) -> c
            list when is_list(list) -> Enum.map_join(list, " ", &to_string(&1[:text] || ""))
          end
        end)

      # ACE should be included in sent_messages for UI visibility
      assert all_content =~ "<lessons>",
             "sent_messages should include ACE lessons (currently missing)"

      assert all_content =~ "UI should see this lesson"
    end

    test "sent_messages contains ACE state for UI display" do
      deps = create_isolated_deps()
      model_id = "test-model"
      state = make_state_with_ace(model_id, deps.pubsub)

      Phoenix.PubSub.subscribe(deps.pubsub, "agents:#{state.agent_id}:logs")

      _result = ConsensusHandler.get_action_consensus(state)

      assert_receive {:log_entry, log_entry}, 30_000

      assert log_entry.message =~ "Sending to consensus"
      metadata = log_entry.metadata
      sent_messages = metadata[:sent_messages]
      model_entry = Enum.find(sent_messages, &(&1.model_id == model_id))
      messages = model_entry.messages

      all_content =
        Enum.map_join(messages, " ", fn msg ->
          case msg.content do
            c when is_binary(c) -> c
            list when is_list(list) -> Enum.map_join(list, " ", &to_string(&1[:text] || ""))
          end
        end)

      # ACE state should be included
      assert all_content =~ "<state>",
             "sent_messages should include ACE state (currently missing)"

      assert all_content =~ "Task progress visible in UI"
    end
  end

  # ========== R72: UI AND LLM RECEIVE SAME CONTEXT ==========

  describe "R72: UI matches LLM context" do
    test "sent_messages has same injections as actual LLM query" do
      deps = create_isolated_deps()
      model_id = "test-model"
      state = make_state_with_ace(model_id, deps.pubsub)

      Phoenix.PubSub.subscribe(deps.pubsub, "agents:#{state.agent_id}:logs")

      _result = ConsensusHandler.get_action_consensus(state)

      assert_receive {:log_entry, log_entry}, 30_000

      assert log_entry.message =~ "Sending to consensus"
      metadata = log_entry.metadata
      sent_messages = metadata[:sent_messages]
      model_entry = Enum.find(sent_messages, &(&1.model_id == model_id))
      messages = model_entry.messages

      all_content =
        Enum.map_join(messages, " ", fn msg ->
          case msg.content do
            c when is_binary(c) -> c
            list when is_list(list) -> Enum.map_join(list, " ", &to_string(&1[:text] || ""))
          end
        end)

      # All injectors should be present (matching what LLM receives)
      assert all_content =~ "<lessons>", "Should have ACE lessons"
      assert all_content =~ "<todos>", "Should have todos"
      # Note: children/budget may be empty but tags should still be present if data exists
    end
  end

  # ========== R73: ACE INJECTION ORDER IN UI ==========

  describe "R73: ACE in first user message" do
    test "ACE in first user message, todos in last (same as LLM)" do
      deps = create_isolated_deps()
      model_id = "test-model"
      state = make_state_with_ace(model_id, deps.pubsub)

      Phoenix.PubSub.subscribe(deps.pubsub, "agents:#{state.agent_id}:logs")

      _result = ConsensusHandler.get_action_consensus(state)

      assert_receive {:log_entry, log_entry}, 30_000

      assert log_entry.message =~ "Sending to consensus"
      metadata = log_entry.metadata
      sent_messages = metadata[:sent_messages]
      model_entry = Enum.find(sent_messages, &(&1.model_id == model_id))
      messages = model_entry.messages

      # Find first user message
      first_user = Enum.find(messages, &(&1.role == "user"))
      assert first_user, "Should have at least one user message"

      first_user_content =
        case first_user.content do
          c when is_binary(c) -> c
          list when is_list(list) -> Enum.map_join(list, " ", &to_string(&1[:text] || ""))
        end

      # Find last message
      last_msg = List.last(messages)

      last_content =
        case last_msg.content do
          c when is_binary(c) -> c
          list when is_list(list) -> Enum.map_join(list, " ", &to_string(&1[:text] || ""))
        end

      # ACE should be in first user message
      assert first_user_content =~ "<lessons>",
             "First user message should contain ACE lessons"

      # If first != last, ACE should NOT be in last
      if first_user_content != last_content do
        refute last_content =~ "<lessons>",
               "ACE should only be in first user message, not last"
      end
    end
  end
end
