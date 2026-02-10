defmodule Quoracle.Actions.RouterAutoCompleteTodoTest do
  @moduledoc """
  Tests for auto_complete_todo integration in ACTION_Router (v16.0)
  WorkGroupID: autocomplete-20251116-001905
  """
  use ExUnit.Case, async: true
  import Test.AgentTestHelpers
  alias Quoracle.Actions.Router

  setup do
    # Create isolated dependencies
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"

    {:ok, _} = start_supervised({Registry, keys: :unique, name: registry_name})

    # CRITICAL: shutdown must be in child spec, not ExUnit options (ExUnit ignores it)
    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: dynsup_name]]},
      shutdown: :infinity
    }

    {:ok, _} = start_supervised(dynsup_spec)
    {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Start sandbox owner for DB access
    sandbox_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Quoracle.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox_owner) end)

    %{
      registry: registry_name,
      dynsup: dynsup_name,
      pubsub: pubsub_name,
      sandbox_owner: sandbox_owner
    }
  end

  describe "auto_complete_todo parameter handling" do
    # R7: Auto-Complete TODO on Success
    test "successful action with auto_complete_todo triggers TODO completion", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: owner
    } do
      # Spawn an agent with a TODO list
      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "test-agent-#{System.unique_integer([:positive])}",
            objective: "Test agent",
            todos: [
              %{item: "Task 1", state: :todo},
              %{item: "Task 2", state: :todo}
            ]
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: owner
        )

      # Execute action with auto_complete_todo=true (at response level, not in params)
      action = %{
        action: :wait,
        params: %{
          wait: 0
        },
        auto_complete_todo: true
      }

      # Subscribe to PubSub to verify the cast was processed
      agent_id = GenServer.call(agent_pid, :get_agent_id)
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      {:ok, _result} =
        Router.execute(action, agent_pid,
          registry: registry,
          agent_pid: agent_pid,
          pubsub: pubsub
        )

      # Wait for TODO update broadcast
      assert_receive {:todos_updated, _}, 30_000

      # Ensure agent has finished all DB operations before test exits
      # (Synchronous call forces completion of any pending casts/DB writes)
      {:ok, state} = GenServer.call(agent_pid, :get_state)
      assert [first_todo | _] = state.todos
      assert first_todo.state == :done
    end

    # R8: Auto-Complete TODO Only on Success
    test "failed action with auto_complete_todo does not mark TODO done", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: owner
    } do
      # Spawn an agent with a TODO list
      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "test-agent-#{System.unique_integer([:positive])}",
            objective: "Test agent",
            todos: [
              %{item: "Task 1", state: :todo},
              %{item: "Task 2", state: :todo}
            ]
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: owner
        )

      # Execute action that will fail (invalid URL)
      action = %{
        action: :fetch_web,
        params: %{
          url: "not-a-valid-url",
          question: "test"
        },
        auto_complete_todo: true
      }

      {:error, _reason} =
        Router.execute(action, agent_pid,
          registry: registry,
          agent_pid: agent_pid,
          pubsub: pubsub
        )

      # Verify TODO was NOT marked as done (check immediately as no async operation should occur)
      {:ok, state} = GenServer.call(agent_pid, :get_state)
      assert [first_todo | _] = state.todos
      assert first_todo.state == :todo
    end

    # R9: Auto-Complete TODO Defaults to False
    test "action without auto_complete_todo parameter does not trigger completion", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: owner
    } do
      # Spawn an agent with a TODO list
      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "test-agent-#{System.unique_integer([:positive])}",
            objective: "Test agent",
            todos: [
              %{item: "Task 1", state: :todo},
              %{item: "Task 2", state: :todo}
            ]
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: owner
        )

      # Execute action WITHOUT auto_complete_todo (not at response level)
      action = %{
        action: :wait,
        params: %{
          wait: 0
        }
      }

      {:ok, _result} =
        Router.execute(action, agent_pid,
          registry: registry,
          agent_pid: agent_pid,
          pubsub: pubsub
        )

      # Verify TODO was NOT marked as done (check immediately as no cast should be sent)
      {:ok, state} = GenServer.call(agent_pid, :get_state)
      assert [first_todo | _] = state.todos
      assert first_todo.state == :todo
    end

    # R10: Auto-Complete TODO with False Value
    test "action with auto_complete_todo=false does not trigger completion", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: owner
    } do
      # Spawn an agent with a TODO list
      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "test-agent-#{System.unique_integer([:positive])}",
            objective: "Test agent",
            todos: [
              %{item: "Task 1", state: :todo},
              %{item: "Task 2", state: :todo}
            ]
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: owner
        )

      # Execute action with auto_complete_todo=false (at response level)
      action = %{
        action: :wait,
        params: %{
          wait: 0
        },
        auto_complete_todo: false
      }

      {:ok, _result} =
        Router.execute(action, agent_pid,
          registry: registry,
          agent_pid: agent_pid,
          pubsub: pubsub
        )

      # Verify TODO was NOT marked as done (check immediately since false means no async op)
      {:ok, state} = GenServer.call(agent_pid, :get_state)
      assert [first_todo | _] = state.todos
      assert first_todo.state == :todo
    end

    # R11: Auto-Complete TODO Race Condition Safety
    test "concurrent actions with auto_complete_todo handled by GenServer serialization", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: owner
    } do
      # Spawn an agent with multiple TODOs
      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "test-agent-#{System.unique_integer([:positive])}",
            objective: "Test agent",
            todos: [
              %{item: "Task 1", state: :todo},
              %{item: "Task 2", state: :todo},
              %{item: "Task 3", state: :todo}
            ]
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: owner
        )

      # Subscribe to PubSub to track TODO updates
      agent_id = GenServer.call(agent_pid, :get_agent_id)
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      # Launch multiple concurrent actions with auto_complete_todo=true (at response level)
      tasks =
        for _i <- 1..3 do
          Task.async(fn ->
            action = %{
              action: :wait,
              params: %{
                wait: 0
              },
              auto_complete_todo: true
            }

            Router.execute(action, agent_pid,
              registry: registry,
              agent_pid: agent_pid,
              pubsub: pubsub
            )
          end)
        end

      # Wait for all to complete
      results = Task.await_many(tasks)
      assert Enum.all?(results, fn {status, _} -> status == :ok end)

      # Wait for all 3 TODO updates via PubSub
      for _ <- 1..3 do
        assert_receive {:todos_updated, _}, 30_000
      end

      # Ensure all DB operations complete before test exits:
      # Synchronous call to agent ensures agent has processed all casts
      {:ok, state} = GenServer.call(agent_pid, :get_state)

      # Per-action Router (v28.0): Each action's Router already terminated after completion
      # No need to sync with router - the PubSub receives confirm completion

      assert Enum.all?(state.todos, fn todo -> todo.state == :done end),
             "All TODOs should be marked done due to GenServer serialization"
    end
  end

  describe "integration with Core.TodoHandler" do
    test "auto_complete_todo integrates with existing Core.TodoHandler", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: owner
    } do
      # Spawn an agent with TODOs
      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "test-agent-#{System.unique_integer([:positive])}",
            objective: "Test agent",
            todos: [
              %{item: "Task 1", state: :todo},
              %{item: "Task 2", state: :todo}
            ]
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: owner
        )

      # Subscribe to PubSub to verify broadcast
      agent_id = GenServer.call(agent_pid, :get_agent_id)
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      # Execute action with auto_complete_todo (at response level)
      action = %{
        action: :orient,
        params: %{
          current_situation: "Testing auto_complete_todo",
          goal_clarity: "Clear",
          available_resources: "Test environment",
          key_challenges: "None",
          delegation_consideration: "None needed"
        },
        auto_complete_todo: true
      }

      {:ok, _result} =
        Router.execute(action, agent_pid,
          registry: registry,
          agent_pid: agent_pid,
          pubsub: pubsub
        )

      # Wait for async processing and broadcast
      assert_receive {:todos_updated, %{todos: todos}}, 30_000

      # Verify TODO update
      assert [first_todo | rest] = todos
      assert first_todo.state == :done
      assert Enum.all?(rest, fn todo -> todo.state == :todo end)
    end

    test "auto_complete_todo silent no-op when no TODOs exist", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: owner
    } do
      # Spawn an agent WITHOUT TODOs
      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: "test-agent-#{System.unique_integer([:positive])}",
            objective: "Test agent"
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: owner
        )

      # Execute action with auto_complete_todo (at response level)
      action = %{
        action: :wait,
        params: %{
          wait: 0
        },
        auto_complete_todo: true
      }

      # Should not crash, should be silent no-op
      assert {:ok, _result} =
               Router.execute(action, agent_pid,
                 registry: registry,
                 agent_pid: agent_pid,
                 pubsub: pubsub
               )

      # Verify agent is still alive
      assert Process.alive?(agent_pid)
    end
  end
end
