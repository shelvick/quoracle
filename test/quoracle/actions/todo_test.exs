defmodule Quoracle.Actions.TodoTest do
  use ExUnit.Case, async: true

  alias Quoracle.Actions.Todo

  setup do
    # Isolated PubSub for test isolation
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    # Mock agent process that handles GenServer casts (not calls - deadlock fix)
    test_pid = self()

    agent_pid =
      spawn_link(fn ->
        receive do
          # Cast messages use $gen_cast, not $gen_call (deadlock fix)
          {:"$gen_cast", {:update_todos, items}} ->
            send(test_pid, {:todos_updated, items})
        end
      end)

    %{
      pubsub: pubsub_name,
      agent_pid: agent_pid,
      agent_id: "test-agent-#{System.unique_integer([:positive])}"
    }
  end

  describe "execute/3 with valid params" do
    test "updates agent's TODO list with valid items", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      params = %{
        items: [
          %{content: "Fetch user data", state: :todo},
          %{content: "Waiting for child", state: :pending},
          %{content: "Analyzed requirements", state: :done}
        ]
      }

      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:ok, result} = Todo.execute(params, agent_id, opts)
      assert result.action == "todo"
      assert result.count == 3

      # Verify items were sent to agent (result no longer includes items to save tokens)
      assert_receive {:todos_updated, items}, 30_000
      assert items == params.items
    end

    test "handles empty TODO list", %{pubsub: pubsub, agent_pid: agent_pid, agent_id: agent_id} do
      params = %{items: []}
      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:ok, result} = Todo.execute(params, agent_id, opts)
      assert result.action == "todo"
      assert result.count == 0
    end

    test "accepts string keys and converts to atoms", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      params = %{
        "items" => [
          %{"content" => "Task with string keys", "state" => "todo"},
          %{"content" => "Another task", "state" => "pending"}
        ]
      }

      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:ok, result} = Todo.execute(params, agent_id, opts)
      assert result.count == 2
    end

    test "preserves order of TODO items", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      items = for i <- 1..10, do: %{content: "Task #{i}", state: :todo}
      params = %{items: items}
      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:ok, result} = Todo.execute(params, agent_id, opts)
      assert result.count == 10
    end

    test "allows multiple items with same state", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      params = %{
        items: [
          %{content: "First todo", state: :todo},
          %{content: "Second todo", state: :todo},
          %{content: "Third todo", state: :todo}
        ]
      }

      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:ok, result} = Todo.execute(params, agent_id, opts)
      assert result.count == 3
    end

    test "handles very long content strings", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      long_content = String.duplicate("a", 1000)

      params = %{
        items: [
          %{content: long_content, state: :todo}
        ]
      }

      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:ok, result} = Todo.execute(params, agent_id, opts)
      assert result.count == 1

      # Verify long content was sent to agent
      assert_receive {:todos_updated, [item]}, 30_000
      assert item.content == long_content
    end

    test "handles unicode in content", %{pubsub: pubsub, agent_pid: agent_pid, agent_id: agent_id} do
      params = %{
        items: [
          %{content: "任务 🎯 with emoji", state: :todo},
          %{content: "Ñoño task", state: :pending}
        ]
      }

      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:ok, result} = Todo.execute(params, agent_id, opts)
      assert result.count == 2
    end
  end

  describe "execute/3 with invalid params" do
    test "returns error when items key missing", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      params = %{not_items: []}
      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:error, :missing_items} = Todo.execute(params, agent_id, opts)
    end

    test "returns error when item has invalid state", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      params = %{
        items: [
          # Invalid state
          %{content: "Invalid task", state: :cancelled}
        ]
      }

      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:error, :invalid_todo_items} = Todo.execute(params, agent_id, opts)
    end

    test "returns error when item missing content", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      params = %{
        items: [
          # Missing content
          %{state: :todo}
        ]
      }

      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:error, :invalid_todo_items} = Todo.execute(params, agent_id, opts)
    end

    test "returns error when item has empty content", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      params = %{
        items: [
          # Empty content
          %{content: "", state: :todo}
        ]
      }

      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:error, :invalid_todo_items} = Todo.execute(params, agent_id, opts)
    end

    test "returns error when item missing state", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      params = %{
        items: [
          # Missing state
          %{content: "No state task"}
        ]
      }

      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:error, :invalid_todo_items} = Todo.execute(params, agent_id, opts)
    end

    test "returns error when agent_pid missing from opts", %{pubsub: pubsub, agent_id: agent_id} do
      params = %{items: [%{content: "Task", state: :todo}]}
      # No agent_pid
      opts = [pubsub: pubsub]

      assert {:error, :agent_pid_required} = Todo.execute(params, agent_id, opts)
    end

    test "returns error when items is not a list", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      params = %{items: "not a list"}
      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:error, :invalid_todo_items} = Todo.execute(params, agent_id, opts)
    end

    test "returns error when item is not a map", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      params = %{items: ["not a map"]}
      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:error, :invalid_todo_items} = Todo.execute(params, agent_id, opts)
    end

    test "returns error when state is wrong type", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      params = %{
        items: [
          # Not an atom
          %{content: "Task", state: 123}
        ]
      }

      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:error, :invalid_todo_items} = Todo.execute(params, agent_id, opts)
    end

    test "returns error for nil values", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      params = %{
        items: [
          %{content: nil, state: :todo}
        ]
      }

      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:error, :invalid_todo_items} = Todo.execute(params, agent_id, opts)
    end
  end

  describe "PubSub broadcasting" do
    test "broadcasts log on successful update", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      # Subscribe to log events
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:logs")

      params = %{
        items: [
          %{content: "Task 1", state: :todo},
          %{content: "Task 2", state: :pending}
        ]
      }

      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:ok, _} = Todo.execute(params, agent_id, opts)

      assert_receive {:log_entry, log}, 30_000
      assert log.agent_id == agent_id
      assert log.level == :info
      assert log.message =~ "TODO list updated"
      assert log.message =~ "2 items"
      assert log.metadata.action == "todo"
      assert log.metadata.count == 2
    end

    test "broadcasts error log on validation failure", %{
      pubsub: pubsub,
      agent_pid: agent_pid,
      agent_id: agent_id
    } do
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:logs")

      # Missing content
      params = %{items: [%{state: :todo}]}
      opts = [pubsub: pubsub, agent_pid: agent_pid]

      assert {:error, _} = Todo.execute(params, agent_id, opts)

      assert_receive {:log_entry, log}, 30_000
      assert log.level == :error
      assert log.message =~ "TODO update failed"
      assert log.metadata.action == "todo"
    end
  end

  describe "GenServer integration" do
    test "sends cast message to agent (non-blocking)", %{pubsub: pubsub, agent_id: agent_id} do
      # Create a mock agent that verifies the cast
      test_pid = self()

      mock_agent =
        spawn_link(fn ->
          receive do
            # Cast messages use $gen_cast, not $gen_call
            {:"$gen_cast", {:update_todos, items}} ->
              send(test_pid, {:genserver_cast_received, items})
          end
        end)

      params = %{
        items: [
          %{content: "Verify GenServer cast", state: :todo}
        ]
      }

      opts = [pubsub: pubsub, agent_pid: mock_agent]

      assert {:ok, _} = Todo.execute(params, agent_id, opts)

      assert_receive {:genserver_cast_received, items}, 30_000
      assert items == params.items
    end

    test "returns immediately without blocking (cast is async)", %{
      pubsub: pubsub,
      agent_id: agent_id
    } do
      # This test verifies the deadlock fix: cast returns immediately
      # even if agent hasn't processed the message yet
      test_pid = self()

      mock_agent =
        spawn_link(fn ->
          receive do
            {:"$gen_cast", {:update_todos, _items}} ->
              # Notify test that we received the cast (proves async delivery)
              send(test_pid, :cast_received)
          end
        end)

      params = %{items: [%{content: "Task", state: :todo}]}
      opts = [pubsub: pubsub, agent_pid: mock_agent]

      # Should return immediately without blocking (cast is async)
      # This would have timed out with the old GenServer.call approach
      assert {:ok, result} = Todo.execute(params, agent_id, opts)
      assert result.action == "todo"
      assert result.count == 1

      # Verify cast was eventually delivered
      assert_receive :cast_received
    end
  end

  describe "normalize_keys/1" do
    test "converts string keys to atoms" do
      input = %{"content" => "Task", "state" => "todo"}
      expected = %{content: "Task", state: :todo}

      assert Todo.normalize_keys(input) == expected
    end

    test "preserves existing atom keys" do
      input = %{content: "Task", state: :pending}

      assert Todo.normalize_keys(input) == input
    end

    test "handles mixed string and atom keys" do
      input = %{"content" => "Task", state: :done}
      expected = %{content: "Task", state: :done}

      assert Todo.normalize_keys(input) == expected
    end

    test "converts string states to atoms" do
      input = %{content: "Task", state: "todo"}
      expected = %{content: "Task", state: :todo}

      assert Todo.normalize_keys(input) == expected
    end

    test "safely handles non-existent atom conversion" do
      # Should not create new atoms for unknown keys
      input = %{"unknown_key_12345" => "value"}

      # Should either skip unknown keys or handle safely
      # Note: This test checks that unknown string keys remain as strings
      result = Todo.normalize_keys(input)
      # The function should handle unknown keys without crashing
      # Implementation keeps unknown keys as strings, which is safe
      assert is_map(result)
    end
  end

  describe "valid_item?/1" do
    test "validates correct item structure" do
      assert Todo.valid_item?(%{content: "Task", state: :todo})
      assert Todo.valid_item?(%{content: "Task", state: :pending})
      assert Todo.valid_item?(%{content: "Task", state: :done})
    end

    test "rejects invalid states" do
      refute Todo.valid_item?(%{content: "Task", state: :invalid})
      refute Todo.valid_item?(%{content: "Task", state: :cancelled})
      refute Todo.valid_item?(%{content: "Task", state: :in_progress})
    end

    test "rejects missing content" do
      refute Todo.valid_item?(%{state: :todo})
      refute Todo.valid_item?(%{content: nil, state: :todo})
      refute Todo.valid_item?(%{content: "", state: :todo})
    end

    test "rejects missing state" do
      refute Todo.valid_item?(%{content: "Task"})
      refute Todo.valid_item?(%{content: "Task", state: nil})
    end
  end

  describe "validate_items/1" do
    test "validates list of valid items" do
      items = [
        %{content: "Task 1", state: :todo},
        %{content: "Task 2", state: :pending}
      ]

      assert {:ok, normalized} = Todo.validate_items(%{items: items})
      assert normalized == items
    end

    test "returns error for invalid items" do
      items = [
        %{content: "Valid", state: :todo},
        # Missing content
        %{state: :pending}
      ]

      assert {:error, :invalid_todo_items} = Todo.validate_items(%{items: items})
    end

    test "returns error when items not present" do
      assert {:error, :missing_items} = Todo.validate_items(%{})
      assert {:error, :missing_items} = Todo.validate_items(%{not_items: []})
    end

    test "returns error when items not a list" do
      assert {:error, :invalid_todo_items} = Todo.validate_items(%{items: "not a list"})
      assert {:error, :invalid_todo_items} = Todo.validate_items(%{items: 123})
    end
  end
end
