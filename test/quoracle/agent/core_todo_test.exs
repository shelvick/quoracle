defmodule Quoracle.Agent.CoreTodoTest do
  @moduledoc """
  Tests for TODO state management in Core GenServer.

  Verifies that Core properly stores, retrieves, and updates TODO lists
  as part of agent state management (Packet 2 - State Management).
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.Core

  setup do
    # Create isolated dependencies
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    dynsup = :"test_dynsup_#{System.unique_integer([:positive])}"

    start_supervised!({Phoenix.PubSub, name: pubsub})
    start_supervised!({Registry, keys: :duplicate, name: registry})

    # CRITICAL: shutdown must be in child spec, not ExUnit options (ExUnit ignores it)
    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: dynsup]]},
      shutdown: :infinity
    }

    start_supervised!(dynsup_spec)

    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    # Start core with todos field in initial state
    {:ok, core_pid} =
      Core.start_link(
        agent_id: agent_id,
        parent_agent_id: nil,
        dynsup: dynsup,
        registry: registry,
        pubsub: pubsub,
        test_mode: true,
        skip_auto_consensus: true
      )

    on_exit(fn ->
      if Process.alive?(core_pid) do
        try do
          GenServer.stop(core_pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{
      core_pid: core_pid,
      agent_id: agent_id,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup
    }
  end

  describe "initial state" do
    test "includes empty todos list", %{core_pid: core_pid} do
      {:ok, state} = GenServer.call(core_pid, :get_state)
      assert Map.has_key?(state, :todos)
      assert state.todos == []
    end
  end

  describe "handle_cast({:update_todos, items}, state)" do
    test "updates todos in state", %{core_pid: core_pid} do
      todos = [
        %{content: "First task", state: :todo},
        %{content: "Second task", state: :pending}
      ]

      GenServer.cast(core_pid, {:update_todos, todos})
      # Sync point: cast is async, so wait for processing
      {:ok, state} = GenServer.call(core_pid, :get_state)
      assert state.todos == todos
    end

    test "replaces existing todos completely", %{core_pid: core_pid} do
      initial_todos = [
        %{content: "Old task", state: :done}
      ]

      new_todos = [
        %{content: "New task", state: :todo},
        %{content: "Another task", state: :pending}
      ]

      GenServer.cast(core_pid, {:update_todos, initial_todos})
      {:ok, state1} = GenServer.call(core_pid, :get_state)
      assert state1.todos == initial_todos

      GenServer.cast(core_pid, {:update_todos, new_todos})
      {:ok, state2} = GenServer.call(core_pid, :get_state)
      assert state2.todos == new_todos
      # Old todos should be completely replaced
      refute Enum.any?(state2.todos, fn t -> t.content == "Old task" end)
    end

    test "accepts empty list to clear todos", %{core_pid: core_pid} do
      todos = [%{content: "Task", state: :todo}]

      GenServer.cast(core_pid, {:update_todos, todos})
      # Sync before next cast
      {:ok, _} = GenServer.call(core_pid, :get_state)
      GenServer.cast(core_pid, {:update_todos, []})

      {:ok, state} = GenServer.call(core_pid, :get_state)
      assert state.todos == []
    end

    test "broadcasts todos_updated event via AgentEvents", %{
      core_pid: core_pid,
      agent_id: agent_id,
      pubsub: pubsub
    } do
      # Subscribe to agent's todos topic
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      todos = [
        %{content: "Task 1", state: :todo},
        %{content: "Task 2", state: :pending}
      ]

      GenServer.cast(core_pid, {:update_todos, todos})

      assert_receive {:todos_updated, payload}, 30_000
      assert payload.todos == todos
      assert payload.agent_id == agent_id
      assert %DateTime{} = payload.timestamp
    end

    # Note: Non-list values are rejected by guard clause `when is_list(items)`
    # and won't match the handler. This is acceptable "let it crash" behavior.
  end

  describe "handle_call(:get_todos, _, state)" do
    test "returns current todos list", %{core_pid: core_pid} do
      todos = [
        %{content: "Task A", state: :todo},
        %{content: "Task B", state: :done}
      ]

      GenServer.cast(core_pid, {:update_todos, todos})
      # Sync point before get
      {:ok, _} = GenServer.call(core_pid, :get_state)

      retrieved = GenServer.call(core_pid, :get_todos)
      assert retrieved == todos
    end

    test "returns empty list when no todos", %{core_pid: core_pid} do
      todos = GenServer.call(core_pid, :get_todos)
      assert todos == []
    end

    test "returns todos in same order as stored", %{core_pid: core_pid} do
      todos = for i <- 1..5, do: %{content: "Task #{i}", state: :todo}

      GenServer.cast(core_pid, {:update_todos, todos})
      # Sync point before get
      {:ok, _} = GenServer.call(core_pid, :get_state)
      retrieved = GenServer.call(core_pid, :get_todos)

      assert retrieved == todos
      # Verify order explicitly
      assert Enum.map(retrieved, & &1.content) == [
               "Task 1",
               "Task 2",
               "Task 3",
               "Task 4",
               "Task 5"
             ]
    end
  end

  describe "handle_cast(:mark_first_todo_done, state)" do
    test "marks first non-done todo as done", %{
      core_pid: core_pid,
      agent_id: agent_id,
      pubsub: pubsub
    } do
      # Subscribe to todos topic to wait for update
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      todos = [
        %{content: "First", state: :todo},
        %{content: "Second", state: :pending},
        %{content: "Third", state: :done}
      ]

      GenServer.cast(core_pid, {:update_todos, todos})
      # Clear the initial update message
      assert_receive {:todos_updated, _}, 30_000

      GenServer.cast(core_pid, :mark_first_todo_done)

      # Wait for the todos_updated broadcast
      assert_receive {:todos_updated, payload}, 30_000
      assert payload.agent_id == agent_id
      assert %DateTime{} = payload.timestamp

      updated_todos = GenServer.call(core_pid, :get_todos)

      # First todo should now be done
      assert Enum.at(updated_todos, 0).state == :done
      assert Enum.at(updated_todos, 0).content == "First"
      # Others unchanged
      assert Enum.at(updated_todos, 1).state == :pending
      assert Enum.at(updated_todos, 2).state == :done
    end

    test "marks first pending if no todo state items", %{
      core_pid: core_pid,
      agent_id: agent_id,
      pubsub: pubsub
    } do
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      todos = [
        %{content: "First", state: :done},
        %{content: "Second", state: :pending},
        %{content: "Third", state: :pending}
      ]

      GenServer.cast(core_pid, {:update_todos, todos})
      assert_receive {:todos_updated, _}, 30_000

      GenServer.cast(core_pid, :mark_first_todo_done)
      assert_receive {:todos_updated, payload}, 30_000
      assert payload.agent_id == agent_id

      updated_todos = GenServer.call(core_pid, :get_todos)

      # First pending should now be done
      assert Enum.at(updated_todos, 0).state == :done
      assert Enum.at(updated_todos, 1).state == :done
      assert Enum.at(updated_todos, 2).state == :pending
    end

    test "does nothing if all todos are done", %{
      core_pid: core_pid,
      agent_id: agent_id,
      pubsub: pubsub
    } do
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      todos = [
        %{content: "First", state: :done},
        %{content: "Second", state: :done}
      ]

      GenServer.cast(core_pid, {:update_todos, todos})
      assert_receive {:todos_updated, _}, 30_000

      GenServer.cast(core_pid, :mark_first_todo_done)
      # Should not receive any update since nothing changed
      refute_receive {:todos_updated, _}, 100

      updated_todos = GenServer.call(core_pid, :get_todos)

      # Nothing should change
      assert updated_todos == todos
    end

    test "does nothing if todos list is empty", %{
      core_pid: core_pid,
      agent_id: agent_id,
      pubsub: pubsub
    } do
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      GenServer.cast(core_pid, :mark_first_todo_done)
      # Should not receive any update since list is empty
      refute_receive {:todos_updated, _}, 100

      todos = GenServer.call(core_pid, :get_todos)
      assert todos == []
    end

    test "broadcasts todos_updated after marking done", %{
      core_pid: core_pid,
      agent_id: agent_id,
      pubsub: pubsub
    } do
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      todos = [
        %{content: "Task", state: :todo}
      ]

      GenServer.cast(core_pid, {:update_todos, todos})

      # Clear the update broadcast
      assert_receive {:todos_updated, _}, 30_000

      GenServer.cast(core_pid, :mark_first_todo_done)

      # Should receive update with marked task
      assert_receive {:todos_updated, payload}, 30_000
      assert payload.agent_id == agent_id
      assert hd(payload.todos).state == :done
    end

    test "preserves todo order when marking done", %{
      core_pid: core_pid,
      agent_id: agent_id,
      pubsub: pubsub
    } do
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      todos = [
        %{content: "A", state: :todo},
        %{content: "B", state: :pending},
        %{content: "C", state: :todo}
      ]

      GenServer.cast(core_pid, {:update_todos, todos})
      assert_receive {:todos_updated, _}, 30_000

      GenServer.cast(core_pid, :mark_first_todo_done)
      assert_receive {:todos_updated, payload}, 30_000
      assert payload.agent_id == agent_id

      updated = GenServer.call(core_pid, :get_todos)

      # Order should be preserved
      assert Enum.map(updated, & &1.content) == ["A", "B", "C"]
      # First todo marked done
      assert Enum.at(updated, 0).state == :done
    end
  end

  describe "todos persistence" do
    test "todos survive message processing", %{core_pid: core_pid} do
      todos = [%{content: "Persistent task", state: :todo}]

      GenServer.cast(core_pid, {:update_todos, todos})
      # Sync point
      {:ok, _} = GenServer.call(core_pid, :get_state)

      # Process some other messages
      GenServer.call(core_pid, :get_state)
      send(core_pid, :trigger_consensus)

      # Use a synchronous call to ensure processing is complete
      GenServer.call(core_pid, :get_state)

      # Todos should still be there
      retrieved = GenServer.call(core_pid, :get_todos)
      assert retrieved == todos
    end

    test "todos maintained across consensus cycles", %{
      core_pid: core_pid
    } do
      todos = [
        %{content: "Task 1", state: :todo},
        %{content: "Task 2", state: :pending}
      ]

      GenServer.cast(core_pid, {:update_todos, todos})
      # Sync point
      {:ok, _} = GenServer.call(core_pid, :get_state)

      # Trigger consensus request
      send(core_pid, :trigger_consensus)

      # Use a synchronous call to ensure processing is complete
      GenServer.call(core_pid, :get_state)

      # Todos should remain unchanged
      assert GenServer.call(core_pid, :get_todos) == todos
    end
  end

  describe "concurrent operations" do
    test "handles concurrent todo updates", %{core_pid: core_pid} do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            todos = [%{content: "Task from #{i}", state: :todo}]
            GenServer.cast(core_pid, {:update_todos, todos})
          end)
        end

      Enum.each(tasks, &Task.await/1)
      # Sync point after all casts
      {:ok, _} = GenServer.call(core_pid, :get_state)

      # Should have the todos from one of the updates (last one wins)
      final_todos = GenServer.call(core_pid, :get_todos)
      assert length(final_todos) == 1
      assert final_todos |> hd() |> Map.get(:content) |> String.starts_with?("Task from")
    end

    test "handles interleaved reads and writes", %{core_pid: core_pid} do
      # Start with initial todos
      initial = [%{content: "Initial", state: :todo}]
      GenServer.cast(core_pid, {:update_todos, initial})
      {:ok, _} = GenServer.call(core_pid, :get_state)

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              # Write (cast returns :ok immediately)
              GenServer.cast(core_pid, {:update_todos, [%{content: "Task #{i}", state: :todo}]})
              :ok
            else
              # Read
              GenServer.call(core_pid, :get_todos)
            end
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All reads should have gotten valid todo lists
      read_results = Enum.reject(results, &(&1 == :ok))
      assert Enum.all?(read_results, &is_list/1)
    end
  end

  describe "error handling" do
    # Note: Invalid input (non-list) is rejected by guard clause `when is_list(items)`
    # and won't match the handler. This is acceptable "let it crash" behavior.

    test "recovers from cast errors gracefully", %{core_pid: core_pid} do
      todos = [%{content: "Task", state: :todo}]
      GenServer.cast(core_pid, {:update_todos, todos})
      # Sync point
      {:ok, _} = GenServer.call(core_pid, :get_state)

      # Send invalid cast (Core should handle gracefully)
      GenServer.cast(core_pid, {:invalid_message, "data"})

      # Use a synchronous call to ensure processing is complete
      GenServer.call(core_pid, :get_state)

      # Should still be able to retrieve todos
      assert GenServer.call(core_pid, :get_todos) == todos
    end
  end
end
