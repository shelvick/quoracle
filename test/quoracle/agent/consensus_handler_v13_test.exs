defmodule Quoracle.Agent.ConsensusHandlerV13Test do
  @moduledoc """
  Tests for ConsensusHandler v13.0 changes:
  - Bug 2a: TODO observability in sent_messages broadcasts (R25-R27)
  - TODO observability (R25-R27)

  WorkGroupID: fix-20251211-051748
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.ConsensusHandler

  # Valid orient params (schema requires these 5 fields)
  @valid_orient_params %{
    current_situation: "Testing v13.0 changes",
    goal_clarity: "Verify TODO observability",
    available_resources: "Unit tests",
    key_challenges: "None",
    delegation_consideration: "No delegation needed for testing"
  }

  # ==========================================================================
  # Bug 2a Tests: TODO Observability (R25-R27)
  #
  # Problem: sent_messages broadcast happens BEFORE TODO injection, so UI logs
  # don't show what the LLM actually sees (with TODOs injected).
  # ==========================================================================

  describe "R25: Broadcast includes injected TODOs" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(pubsub_name, "agents:#{agent_id}:logs")

      %{pubsub: pubsub_name, agent_id: agent_id}
    end

    test "sent_messages broadcast includes TODO context", %{
      pubsub: pubsub,
      agent_id: agent_id
    } do
      # State with TODOs that should be visible in broadcast
      state = %{
        agent_id: agent_id,
        pubsub: pubsub,
        test_mode: true,
        model_pool: [:mock_model_1],
        model_histories: %{
          :mock_model_1 => [
            %{type: :prompt, content: "Do the task", timestamp: DateTime.utc_now()}
          ]
        },
        todos: [
          %{content: "First TODO item", state: :todo},
          %{content: "Second TODO item", state: :pending}
        ],
        test_opts: [
          query_fn: fn _messages, _opts ->
            {:ok, %{action: "wait", params: %{}, reasoning: "test"}}
          end
        ]
      }

      # Call get_action_consensus - this triggers broadcast
      _result = ConsensusHandler.get_action_consensus(state)

      # R25: Broadcast MUST include TODO XML in sent_messages
      assert_receive {:log_entry, log}, 30_000

      sent_messages = log.metadata[:sent_messages]
      assert sent_messages != nil, "sent_messages should be in metadata"

      # Get the messages for the model
      model_entry = Enum.find(sent_messages, fn e -> e.model_id == :mock_model_1 end)
      assert model_entry != nil, "Model entry should exist"

      messages = model_entry.messages
      all_content = Enum.map_join(messages, "\n", & &1.content)

      # BUG: Current code broadcasts BEFORE TODO injection
      # So this assertion will FAIL - TODO XML won't be in broadcast
      assert all_content =~ "<todos>", "Broadcast must include TODO XML opening tag"
      assert all_content =~ "First TODO item", "Broadcast must include TODO content"
      assert all_content =~ "</todos>", "Broadcast must include TODO XML closing tag"
    end
  end

  describe "R26: Broadcast after injection" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(pubsub_name, "agents:#{agent_id}:logs")

      %{pubsub: pubsub_name, agent_id: agent_id}
    end

    test "UI receives same messages as LLM including TODOs", %{
      pubsub: pubsub,
      agent_id: agent_id
    } do
      # R26: sent_messages broadcast uses inject_todo_context before ensure_system_prompts
      # This mirrors PerModelQuery's message building, so UI logs match what LLM sees.
      state = %{
        agent_id: agent_id,
        pubsub: pubsub,
        test_mode: true,
        model_pool: [:mock_model_1],
        model_histories: %{
          :mock_model_1 => [
            %{type: :prompt, content: "User request", timestamp: DateTime.utc_now()}
          ]
        },
        todos: [
          %{content: "Important task", state: :todo}
        ]
      }

      _result = ConsensusHandler.get_action_consensus(state)

      # Get what UI received via broadcast
      assert_receive {:log_entry, log}, 30_000
      sent_messages = log.metadata[:sent_messages]
      model_entry = Enum.find(sent_messages, fn e -> e.model_id == :mock_model_1 end)
      ui_messages = model_entry.messages

      # R26: UI should receive messages with TODOs injected
      # Since inject_todo_context is called in BOTH sent_messages build AND
      # PerModelQuery (for LLM), they receive the same TODO-injected messages
      ui_content = Enum.map_join(ui_messages, "\n", & &1.content)

      assert ui_content =~ "<todos>", "UI should see TODOs (same injection as LLM)"
      assert ui_content =~ "Important task", "UI should see TODO content"
    end
  end

  describe "R27: Empty TODOs no injection" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(pubsub_name, "agents:#{agent_id}:logs")

      %{pubsub: pubsub_name, agent_id: agent_id}
    end

    test "empty todos results in no TODO XML in broadcast", %{
      pubsub: pubsub,
      agent_id: agent_id
    } do
      # State with empty TODOs
      state = %{
        agent_id: agent_id,
        pubsub: pubsub,
        test_mode: true,
        model_pool: [:mock_model_1],
        model_histories: %{
          :mock_model_1 => [
            %{type: :prompt, content: "User request", timestamp: DateTime.utc_now()}
          ]
        },
        todos: [],
        test_opts: [
          query_fn: fn _messages, _opts ->
            {:ok, %{action: "wait", params: %{}, reasoning: "test"}}
          end
        ]
      }

      _result = ConsensusHandler.get_action_consensus(state)

      assert_receive {:log_entry, log}, 30_000
      sent_messages = log.metadata[:sent_messages]
      model_entry = Enum.find(sent_messages, fn e -> e.model_id == :mock_model_1 end)
      messages = model_entry.messages

      all_content = Enum.map_join(messages, "\n", & &1.content)

      # R27: Empty TODOs should NOT have TODO XML
      refute all_content =~ "<todos>", "Empty TODOs should not inject TODO XML"
    end
  end

  describe "Bug 2a Acceptance: UI log shows TODO list" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(pubsub_name, "agents:#{agent_id}:logs")

      %{pubsub: pubsub_name, agent_id: agent_id}
    end

    test "UI log shows TODO list in sent messages", %{
      pubsub: pubsub,
      agent_id: agent_id
    } do
      # User scenario: Agent has TODO list, executes action
      # User expects: UI log shows TODO list in sent messages
      state = %{
        agent_id: agent_id,
        pubsub: pubsub,
        test_mode: true,
        model_pool: [:mock_model_1],
        model_histories: %{
          :mock_model_1 => [
            %{type: :prompt, content: "Please complete the tasks", timestamp: DateTime.utc_now()}
          ]
        },
        todos: [
          %{content: "Write unit tests", state: :todo},
          %{content: "Run integration tests", state: :pending},
          %{content: "Deploy to staging", state: :done}
        ],
        test_opts: [
          query_fn: fn _messages, _opts ->
            {:ok, %{action: "orient", params: @valid_orient_params, reasoning: "planning"}}
          end
        ]
      }

      _result = ConsensusHandler.get_action_consensus(state)

      # ACCEPTANCE: UI should show TODO list
      assert_receive {:log_entry, log}, 30_000
      sent_messages = log.metadata[:sent_messages]
      model_entry = Enum.find(sent_messages, fn e -> e.model_id == :mock_model_1 end)
      all_content = Enum.map_join(model_entry.messages, "\n", & &1.content)

      # User should see their TODO items in the log
      assert all_content =~ "Write unit tests", "User's TODO should be visible in UI log"
      assert all_content =~ "Run integration tests", "All TODOs should be visible"
      assert all_content =~ "Deploy to staging", "Completed TODOs should also be visible"
    end
  end
end
