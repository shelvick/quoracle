defmodule Quoracle.PubSub.AgentEventsTest do
  # async: true - Uses isolated PubSub instance for test isolation
  use ExUnit.Case, async: true

  alias Quoracle.PubSub.AgentEvents

  setup do
    # Create isolated PubSub instance for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Subscribe to test topics on isolated instance
    :ok = Phoenix.PubSub.subscribe(pubsub_name, "agents:lifecycle")
    :ok = Phoenix.PubSub.subscribe(pubsub_name, "actions:all")

    %{
      agent_id: "test_agent_#{System.unique_integer([:positive])}",
      task_id: Ecto.UUID.generate(),
      pubsub: pubsub_name
    }
  end

  describe "broadcast_agent_spawned/3" do
    test "broadcasts agent spawned event to lifecycle topic", %{
      agent_id: agent_id,
      task_id: task_id,
      pubsub: pubsub
    } do
      parent_pid = self()

      assert :ok = AgentEvents.broadcast_agent_spawned(agent_id, task_id, parent_pid, pubsub)

      assert_receive {:agent_spawned, payload}, 30_000
      assert payload.agent_id == agent_id
      assert payload.task_id == task_id
      assert payload.parent_id == parent_pid
      assert %DateTime{} = payload.timestamp
    end

    test "broadcasts with nil parent for root agents", %{
      agent_id: agent_id,
      task_id: task_id,
      pubsub: pubsub
    } do
      assert :ok = AgentEvents.broadcast_agent_spawned(agent_id, task_id, nil, pubsub)

      assert_receive {:agent_spawned, payload}, 30_000
      assert payload.parent_id == nil
    end
  end

  describe "broadcast_agent_terminated/2" do
    test "broadcasts agent terminated event", %{agent_id: agent_id, pubsub: pubsub} do
      reason = :normal

      assert :ok = AgentEvents.broadcast_agent_terminated(agent_id, reason, pubsub)

      assert_receive {:agent_terminated, payload}, 30_000
      assert payload.agent_id == agent_id
      assert payload.reason == reason
      assert %DateTime{} = payload.timestamp
    end
  end

  describe "broadcast_action_started/4" do
    test "broadcasts action started event", %{agent_id: agent_id, pubsub: pubsub} do
      action_type = :wait
      action_id = "action_#{System.unique_integer([:positive])}"
      params = %{wait: 1000}

      assert :ok =
               AgentEvents.broadcast_action_started(
                 agent_id,
                 action_type,
                 action_id,
                 params,
                 pubsub
               )

      assert_receive {:action_started, payload}, 30_000
      assert payload.agent_id == agent_id
      assert payload.action_type == action_type
      assert payload.action_id == action_id
      assert payload.params == params
      assert %DateTime{} = payload.timestamp
    end
  end

  describe "broadcast_action_completed/3" do
    test "broadcasts action completed event", %{agent_id: agent_id, pubsub: pubsub} do
      action_id = "action_#{System.unique_integer([:positive])}"
      result = {:ok, "completed"}

      assert :ok = AgentEvents.broadcast_action_completed(agent_id, action_id, result, pubsub)

      assert_receive {:action_completed, payload}, 30_000
      assert payload.agent_id == agent_id
      assert payload.action_id == action_id
      assert payload.result == result
      assert %DateTime{} = payload.timestamp
    end
  end

  describe "broadcast_action_error/3" do
    test "broadcasts action error event", %{agent_id: agent_id, pubsub: pubsub} do
      action_id = "action_#{System.unique_integer([:positive])}"
      error = {:error, "something went wrong"}

      assert :ok = AgentEvents.broadcast_action_error(agent_id, action_id, error, pubsub)

      assert_receive {:action_error, payload}, 30_000
      assert payload.agent_id == agent_id
      assert payload.action_id == action_id
      assert payload.error == error
      assert %DateTime{} = payload.timestamp
    end
  end

  describe "broadcast_log/4" do
    test "broadcasts log entry to agent-specific topic", %{agent_id: agent_id, pubsub: pubsub} do
      # Subscribe to agent-specific log topic
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:logs")

      level = :info
      message = "Test log message"
      metadata = %{module: "TestModule"}

      assert :ok = AgentEvents.broadcast_log(agent_id, level, message, metadata, pubsub)

      assert_receive {:log_entry, payload}, 30_000
      assert payload.agent_id == agent_id
      assert payload.level == level
      assert payload.message == message
      assert payload.metadata == metadata
      assert %DateTime{} = payload.timestamp
    end

    # R1 [UNIT]: broadcast_log/5 includes unique monotonic :id field
    test "broadcast_log assigns monotonic id", %{agent_id: agent_id, pubsub: pubsub} do
      # Subscribe to agent-specific log topic
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:logs")

      assert :ok = AgentEvents.broadcast_log(agent_id, :info, "Test message", %{}, pubsub)

      assert_receive {:log_entry, payload}, 30_000

      # R1: Log entry MUST include an :id field with a positive monotonic integer
      assert is_integer(payload.id),
             "Expected :id field to be an integer, got: #{inspect(payload[:id])}"

      assert payload.id > 0, "Expected :id to be positive"
    end

    # R2 [INTEGRATION]: rapid successive broadcasts produce unique IDs (no collisions)
    test "concurrent broadcasts generate unique ids", %{agent_id: agent_id, pubsub: pubsub} do
      # Subscribe to agent-specific log topic
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:logs")

      # Broadcast 100 logs rapidly to test for ID collisions
      broadcast_count = 100

      for i <- 1..broadcast_count do
        AgentEvents.broadcast_log(agent_id, :info, "Message #{i}", %{index: i}, pubsub)
      end

      # Collect all received log entries
      ids =
        for _ <- 1..broadcast_count do
          assert_receive {:log_entry, payload}, 30_000
          payload.id
        end

      # R2: All IDs must be unique (no collisions)
      unique_ids = Enum.uniq(ids)

      assert length(unique_ids) == broadcast_count,
             "Expected #{broadcast_count} unique IDs, got #{length(unique_ids)} (duplicates: #{broadcast_count - length(unique_ids)})"

      # All IDs should be positive integers
      assert Enum.all?(ids, &(is_integer(&1) and &1 > 0)),
             "All IDs should be positive integers"

      # IDs should be monotonically increasing (since we use :monotonic option)
      sorted_ids = Enum.sort(ids)
      assert ids == sorted_ids, "IDs should be monotonically increasing"
    end
  end

  describe "broadcast_user_message/3" do
    test "broadcasts user message to task-specific topic", %{
      task_id: task_id,
      agent_id: agent_id,
      pubsub: pubsub
    } do
      # Subscribe to task-specific message topic
      :ok = Phoenix.PubSub.subscribe(pubsub, "tasks:#{task_id}:messages")

      content = "Hello from agent"

      assert :ok = AgentEvents.broadcast_user_message(task_id, agent_id, content, pubsub)

      # Now broadcasts as :agent_message with from: :user
      assert_receive {:agent_message, payload}, 30_000
      assert payload.from == :user
      assert payload.sender_id == agent_id
      assert payload.content == content
      assert payload.status == :received
      assert %DateTime{} = payload.timestamp
    end
  end

  describe "broadcast_state_change/3" do
    test "broadcasts state change to agent-specific topic", %{agent_id: agent_id, pubsub: pubsub} do
      # Subscribe to agent-specific state topic
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:state")

      old_state = :idle
      new_state = :working

      assert :ok = AgentEvents.broadcast_state_change(agent_id, old_state, new_state, pubsub)

      assert_receive {:state_changed, payload}, 30_000
      assert payload.agent_id == agent_id
      assert payload.old_state == old_state
      assert payload.new_state == new_state
      assert %DateTime{} = payload.timestamp
    end
  end

  describe "subscribe_to_agent/1" do
    test "subscribes to all agent-specific topics", %{agent_id: agent_id, pubsub: pubsub} do
      assert :ok = AgentEvents.subscribe_to_agent(agent_id, pubsub)

      # Test that we receive events on all agent topics
      AgentEvents.broadcast_log(agent_id, :info, "test", %{}, pubsub)
      assert_receive {:log_entry, _}, 30_000

      AgentEvents.broadcast_state_change(agent_id, :idle, :working, pubsub)
      assert_receive {:state_changed, _}, 30_000
    end
  end

  describe "subscribe_to_task/1" do
    test "subscribes to task message topic", %{
      task_id: task_id,
      agent_id: agent_id,
      pubsub: pubsub
    } do
      assert :ok = AgentEvents.subscribe_to_task(task_id, pubsub)

      AgentEvents.broadcast_user_message(task_id, agent_id, "test message", pubsub)
      # Now broadcasts as :agent_message with from: :user
      assert_receive {:agent_message, message}, 30_000
      assert message.from == :user
    end
  end

  describe "broadcast_todos_updated/3" do
    test "broadcasts todos update to agent-specific todos topic", %{
      agent_id: agent_id,
      pubsub: pubsub
    } do
      # Subscribe to agent-specific todos topic
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      todos = [
        %{content: "First task", state: :todo},
        %{content: "Second task", state: :pending},
        %{content: "Third task", state: :done}
      ]

      assert :ok = AgentEvents.broadcast_todos_updated(agent_id, todos, pubsub)

      assert_receive {:todos_updated, payload}, 30_000
      assert payload.agent_id == agent_id
      assert payload.todos == todos
      assert length(payload.todos) == 3
      assert %DateTime{} = payload.timestamp
    end

    test "broadcasts empty todos list", %{agent_id: agent_id, pubsub: pubsub} do
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      assert :ok = AgentEvents.broadcast_todos_updated(agent_id, [], pubsub)

      assert_receive {:todos_updated, payload}, 30_000
      assert payload.agent_id == agent_id
      assert payload.todos == []
      assert %DateTime{} = payload.timestamp
    end

    test "includes all todo fields in broadcast", %{agent_id: agent_id, pubsub: pubsub} do
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      todos = [
        %{content: "Complex task", state: :todo, priority: :high, tags: ["urgent", "important"]}
      ]

      assert :ok = AgentEvents.broadcast_todos_updated(agent_id, todos, pubsub)

      assert_receive {:todos_updated, payload}, 30_000
      [first_todo] = payload.todos
      assert first_todo.content == "Complex task"
      assert first_todo.state == :todo
      assert first_todo.priority == :high
      assert first_todo.tags == ["urgent", "important"]
    end

    test "broadcasts to correct topic pattern", %{agent_id: agent_id, pubsub: pubsub} do
      # Subscribe to a different agent's topic - should NOT receive
      other_agent = "other-agent-123"
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{other_agent}:todos")

      # Subscribe to correct agent's topic - should receive
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      todos = [%{content: "Test", state: :todo}]
      assert :ok = AgentEvents.broadcast_todos_updated(agent_id, todos, pubsub)

      # Should receive on correct topic
      assert_receive {:todos_updated, payload}, 30_000
      assert payload.agent_id == agent_id

      # Should not receive duplicate for other agent
      refute_receive {:todos_updated, %{agent_id: ^other_agent}}, 100
    end

    test "preserves todo order in broadcast", %{agent_id: agent_id, pubsub: pubsub} do
      :ok = Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      todos = for i <- 1..5, do: %{content: "Task #{i}", state: :todo}

      assert :ok = AgentEvents.broadcast_todos_updated(agent_id, todos, pubsub)

      assert_receive {:todos_updated, payload}, 30_000
      assert length(payload.todos) == 5

      assert Enum.map(payload.todos, & &1.content) == [
               "Task 1",
               "Task 2",
               "Task 3",
               "Task 4",
               "Task 5"
             ]
    end
  end

  describe "subscribe_to_all_agents/0" do
    test "subscribes to lifecycle and action topics", %{pubsub: pubsub} do
      assert :ok = AgentEvents.subscribe_to_all_agents(pubsub)

      # Already subscribed in setup, but test the function exists
      # and returns :ok
    end
  end

  describe "error handling" do
    test "handles invalid agent_id gracefully", %{pubsub: pubsub} do
      # Should log warning but still return :ok
      assert :ok = AgentEvents.broadcast_log(nil, :info, "test", %{}, pubsub)
      assert :ok = AgentEvents.broadcast_log("", :info, "test", %{}, pubsub)
    end

    test "timestamp is always added automatically", %{pubsub: pubsub} do
      agent_id = "test_#{System.unique_integer([:positive])}"

      # Even if we don't provide timestamp, it should be added
      assert :ok = AgentEvents.broadcast_agent_spawned(agent_id, "task_id", nil, pubsub)

      assert_receive {:agent_spawned, payload}, 30_000
      assert %DateTime{} = payload.timestamp
      # Timestamp should be recent (within last second)
      assert DateTime.diff(DateTime.utc_now(), payload.timestamp) <= 1
    end
  end
end
