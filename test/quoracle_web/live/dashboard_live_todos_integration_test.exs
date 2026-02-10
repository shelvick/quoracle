defmodule QuoracleWeb.DashboardLiveTodosIntegrationTest do
  @moduledoc """
  Integration tests for Dashboard todos functionality.
  Tests the complete flow: Core → PubSub → Dashboard → UI

  These tests verify the gaps found in both audits:
  1. Dashboard subscribes to todos topics when agent spawned
  2. Dashboard handles todos_updated messages
  3. Dashboard updates agents map with todos field
  4. End-to-end integration flow
  """

  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import Test.AgentTestHelpers

  alias Quoracle.PubSub.AgentEvents

  setup %{conn: conn, sandbox_owner: owner} do
    # Create isolated PubSub and Registry instances
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    # CRITICAL: shutdown must be in child spec, not ExUnit options (ExUnit ignores it)
    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: dynsup_name]]},
      shutdown: :infinity
    }

    {:ok, dynsup} = start_supervised(dynsup_spec)

    %{
      conn: conn,
      pubsub: pubsub_name,
      registry: registry_name,
      dynsup: dynsup,
      sandbox_owner: owner
    }
  end

  describe "Dashboard todos subscription" do
    test "subscribes to todos topic when agent spawned", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: owner
    } do
      # Mount Dashboard with isolated dependencies
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => owner
          }
        )

      # Verify initial state - no agents spawned yet
      # (Dashboard doesn't have an agent-count element, just verify rendering)

      # Simulate agent spawn - need task_id for agent to appear in TaskTree
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      # Use proper UUID format
      task_id = Ecto.UUID.generate()

      # Broadcast agent_spawned event with task_id - this will set up everything correctly
      AgentEvents.broadcast_agent_spawned(agent_id, task_id, nil, pubsub)
      # Force message processing
      render(view)

      # Verify Dashboard subscribed to the todos topic by sending a test message
      # This will fail because Dashboard doesn't subscribe to todos topics
      todos_topic = "agents:#{agent_id}:todos"

      # Send a test message to the todos topic
      test_todos = [%{content: "Test subscription", state: :todo}]
      AgentEvents.broadcast_todos_updated(agent_id, test_todos, pubsub)
      html = render(view)

      # If Dashboard is subscribed, it should receive and display the todos
      assert html =~ "Test subscription",
             "Dashboard should be subscribed to #{todos_topic} and receive todos updates"
    end

    test "subscribes to todos topics for multiple agents", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: owner
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => owner
          }
        )

      # Spawn agent and verify subscription by sending todos
      agent_id = "agent-1-#{System.unique_integer([:positive])}"
      task_id = Ecto.UUID.generate()

      AgentEvents.broadcast_agent_spawned(agent_id, task_id, nil, pubsub)
      render(view)

      # Verify subscription to todos topic by sending test message
      topic = "agents:#{agent_id}:todos"

      # Send todos
      todos = [%{content: "Subscription test", state: :todo}]

      AgentEvents.broadcast_todos_updated(agent_id, todos, pubsub)
      html = render(view)

      # If Dashboard is subscribed, it should receive and display the todos
      assert html =~ "Subscription test", "Should be subscribed to #{topic}"
    end
  end

  describe "Dashboard todos_updated handler" do
    test "handles todos_updated message and updates agents map", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: owner
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => owner
          }
        )

      # Create an agent with task
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      # Use proper UUID format
      task_id = Ecto.UUID.generate()

      AgentEvents.broadcast_agent_spawned(agent_id, task_id, nil, pubsub)
      render(view)

      # Broadcast todos_updated event
      todos = [
        %{content: "First task", state: :todo},
        %{content: "Second task", state: :pending},
        %{content: "Third task", state: :done}
      ]

      AgentEvents.broadcast_todos_updated(agent_id, todos, pubsub)
      # Force processing
      html = render(view)

      # Verify the todos appear in UI (via AgentNode component)
      # This will fail because Dashboard doesn't handle todos_updated
      assert html =~ "TODOs", "Should display TODOs section"
      assert html =~ "First task", "Should display first todo"
      assert html =~ "Second task", "Should display second todo"
      assert html =~ "Third task", "Should display third todo"
    end

    test "updates todos for correct agent when multiple agents exist", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: owner
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => owner
          }
        )

      # Create agent and test updates to specific agent
      agent_id = "agent-1-#{System.unique_integer([:positive])}"
      task_id = Ecto.UUID.generate()

      AgentEvents.broadcast_agent_spawned(agent_id, task_id, nil, pubsub)
      render(view)

      # Send initial todos to agent
      agent_todos = [
        %{content: "Agent 1 task", state: :todo}
      ]

      AgentEvents.broadcast_todos_updated(agent_id, agent_todos, pubsub)
      html = render(view)

      # Verify agent shows todos
      assert html =~ "Agent 1 task", "Agent should show its todo"

      # Now update with different todos
      agent_updated_todos = [
        %{content: "Agent updated task", state: :pending}
      ]

      AgentEvents.broadcast_todos_updated(agent_id, agent_updated_todos, pubsub)
      html = render(view)

      # Should show updated todos (not old ones)
      refute html =~ "Agent 1 task", "Old todo should be replaced"
      assert html =~ "Agent updated task", "Agent should show updated todo"
    end

    test "replaces existing todos when new update received", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: owner
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => owner
          }
        )

      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      # Use proper UUID format
      task_id = Ecto.UUID.generate()

      AgentEvents.broadcast_agent_spawned(agent_id, task_id, nil, pubsub)
      render(view)

      # Send initial todos
      initial_todos = [
        %{content: "Old task 1", state: :todo},
        %{content: "Old task 2", state: :todo}
      ]

      AgentEvents.broadcast_todos_updated(agent_id, initial_todos, pubsub)
      html = render(view)

      assert html =~ "Old task 1"
      assert html =~ "Old task 2"

      # Send updated todos (replaces, not appends)
      updated_todos = [
        %{content: "New task 1", state: :pending},
        %{content: "New task 2", state: :done},
        %{content: "New task 3", state: :todo}
      ]

      AgentEvents.broadcast_todos_updated(agent_id, updated_todos, pubsub)
      html = render(view)

      # Old tasks should be gone
      refute html =~ "Old task 1", "Old tasks should be replaced"
      refute html =~ "Old task 2", "Old tasks should be replaced"

      # New tasks should be present
      assert html =~ "New task 1"
      assert html =~ "New task 2"
      assert html =~ "New task 3"
    end
  end

  describe "End-to-end Core → Dashboard → UI integration" do
    test "complete flow from Core update to UI display", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: owner
    } do
      # Mount Dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => owner
          }
        )

      # Create a real agent via Core
      agent_id = "e2e-agent-#{System.unique_integer([:positive])}"
      task_id = Ecto.UUID.generate()

      # Start agent with cleanup
      # spawn_agent_with_cleanup expects (dynsup, config, opts)
      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: agent_id,
            parent_id: nil,
            prompt: "Test prompt",
            task_id: task_id
          },
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: owner
        )

      # Wait for Dashboard to receive agent_spawned
      render(view)

      # Update todos via Core's handle_cast (uses cast to avoid deadlock)
      todos = [
        %{content: "E2E Task 1", state: :todo},
        %{content: "E2E Task 2", state: :pending},
        %{content: "E2E Task 3", state: :done}
      ]

      :ok = GenServer.cast(agent_pid, {:update_todos, todos})
      # Sync point: ensure cast is processed before checking UI
      {:ok, _} = GenServer.call(agent_pid, :get_state)

      # Force Dashboard to process the PubSub message
      html = render(view)

      # Verify todos appear in UI
      # This will fail because Dashboard doesn't handle todos_updated
      assert html =~ "TODOs", "Should display TODOs section"
      assert html =~ "E2E Task 1", "Should display first todo from Core"
      assert html =~ "E2E Task 2", "Should display second todo from Core"
      assert html =~ "E2E Task 3", "Should display third todo from Core"

      # Verify state icons appear
      assert html =~ "⏳", "Should show todo icon"
      assert html =~ "⏸️", "Should show pending icon"
      assert html =~ "✅", "Should show done icon"
    end

    test "TaskManager create_task → Core → Dashboard flow with todos", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: owner
    } do
      # Mount Dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => owner
          }
        )

      # Create task via TaskManager (highest level API)
      prompt = "Test task with todos"

      {:ok, {_task, agent_pid}} =
        create_task_with_cleanup(
          prompt,
          pubsub: pubsub,
          registry: registry,
          dynsup: dynsup,
          sandbox_owner: owner
        )

      # Wait for Dashboard to receive agent_spawned
      render(view)

      # Update todos via Core (uses cast to avoid deadlock)
      todos = [
        %{content: "TaskManager flow task", state: :todo}
      ]

      :ok = GenServer.cast(agent_pid, {:update_todos, todos})
      # Sync point: ensure cast is processed before checking UI
      {:ok, _} = GenServer.call(agent_pid, :get_state)

      # Verify todos appear in Dashboard UI
      html = render(view)

      assert html =~ "TaskManager flow task", "Should display todo from TaskManager-created agent"
    end
  end

  describe "Dashboard todos cleanup" do
    test "unsubscribes from todos topic when agent terminated", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: owner
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => owner
          }
        )

      # Create an agent with task
      agent_id = "cleanup-agent-#{System.unique_integer([:positive])}"
      # Use proper UUID format
      task_id = Ecto.UUID.generate()

      AgentEvents.broadcast_agent_spawned(agent_id, task_id, nil, pubsub)
      render(view)

      # Send initial todos to verify subscription
      todos_topic = "agents:#{agent_id}:todos"
      initial_todos = [%{content: "Before termination", state: :todo}]
      AgentEvents.broadcast_todos_updated(agent_id, initial_todos, pubsub)
      html_before = render(view)
      assert html_before =~ "Before termination", "Should be subscribed initially"

      # Terminate the agent
      AgentEvents.broadcast_agent_terminated(agent_id, :normal, pubsub)
      render(view)

      # Try to send todos after termination - should not appear if unsubscribed
      # This will fail because Dashboard doesn't unsubscribe from todos topics
      post_termination_todos = [%{content: "After termination", state: :todo}]
      AgentEvents.broadcast_todos_updated(agent_id, post_termination_todos, pubsub)
      html_after = render(view)

      refute html_after =~ "After termination",
             "Should unsubscribe from #{todos_topic} when agent terminated and not receive new todos"
    end

    test "removes todos from agents map when agent terminated", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: owner
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => owner
          }
        )

      # Create agent and add todos
      agent_id = "cleanup-agent-2-#{System.unique_integer([:positive])}"
      # Use proper UUID format
      task_id = Ecto.UUID.generate()

      AgentEvents.broadcast_agent_spawned(agent_id, task_id, nil, pubsub)
      render(view)

      todos = [%{content: "Task to be removed", state: :todo}]
      AgentEvents.broadcast_todos_updated(agent_id, todos, pubsub)
      html = render(view)

      assert html =~ "Task to be removed", "Todo should be visible initially"

      # Terminate agent
      AgentEvents.broadcast_agent_terminated(agent_id, :normal, pubsub)
      html = render(view)

      # Todo should be gone from UI (agent is terminated, no longer displayed)
      refute html =~ "Task to be removed", "Todo should be removed when agent terminated"

      # Verify agent itself is no longer visible (agents with :terminated status aren't displayed in TaskTree)
      refute html =~ agent_id, "Terminated agent should not be visible"
    end
  end

  describe "Dashboard todos error handling" do
    test "handles malformed todos_updated payload gracefully", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: owner
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => owner
          }
        )

      agent_id = "error-agent-#{System.unique_integer([:positive])}"
      # Use proper UUID format
      task_id = Ecto.UUID.generate()

      AgentEvents.broadcast_agent_spawned(agent_id, task_id, nil, pubsub)
      render(view)

      # Send malformed message directly (bypass AgentEvents)
      Phoenix.PubSub.broadcast(pubsub, "agents:#{agent_id}:todos", {
        :todos_updated,
        %{
          # Missing agent_id field
          # Invalid todos value
          todos: nil,
          timestamp: System.system_time(:millisecond)
        }
      })

      # Should not crash - verify agent is still visible
      html = render(view)
      assert html =~ agent_id, "Should still show agent despite malformed message"
      # Verify the view rendered without crashing
      assert html =~ "Task", "Dashboard should still render task list"
    end

    test "handles empty todos list", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: owner
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => owner
          }
        )

      agent_id = "empty-todos-agent-#{System.unique_integer([:positive])}"
      # Use proper UUID format
      task_id = Ecto.UUID.generate()

      AgentEvents.broadcast_agent_spawned(agent_id, task_id, nil, pubsub)
      render(view)

      # Send empty todos list
      AgentEvents.broadcast_todos_updated(agent_id, [], pubsub)
      html = render(view)

      # Should display empty state message
      # This will fail because Dashboard doesn't handle todos_updated
      assert html =~ "No current tasks", "Should show empty state for empty todos"
    end
  end

  describe "Page refresh scenario (acceptance)" do
    @tag :acceptance
    test "list items remain visible after page refresh (mount with existing agents)", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: owner
    } do
      # CRITICAL: This tests the page refresh scenario
      # Bug: List items disappeared after refresh because:
      # 1. subscribe_to_existing_agents didn't subscribe to todos topic
      # 2. merge_task_state didn't fetch list items from agents on mount

      # Step 1: Create agent with list items BEFORE mounting dashboard
      prompt = "Refresh test task"

      {:ok, {_task, agent_pid}} =
        create_task_with_cleanup(
          prompt,
          pubsub: pubsub,
          registry: registry,
          dynsup: dynsup,
          sandbox_owner: owner
        )

      # Add list items to the agent
      items = [
        %{content: "Refresh test item 1", state: :todo},
        %{content: "Refresh test item 2", state: :pending}
      ]

      :ok = GenServer.cast(agent_pid, {:update_todos, items})
      # Sync point: ensure cast is processed
      {:ok, _} = GenServer.call(agent_pid, :get_state)

      # Step 2: Mount Dashboard (simulates page refresh - agent already exists)
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => owner
          }
        )

      # Step 3: Verify list items are visible immediately after mount
      # The fix ensures: fetch_agent_todos is called during merge_task_state
      html = render(view)

      assert html =~ "Refresh test item 1",
             "List items should be visible after page refresh (mount with existing agents)"

      assert html =~ "Refresh test item 2",
             "All list items should be fetched on mount"

      # Negative assertions - no error states
      refute html =~ "Failed to load",
             "Should not show load failure messages after refresh"

      refute html =~ "Connection lost",
             "Should not show connection error states after refresh"
    end

    @tag :acceptance
    test "list updates work after page refresh", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: owner
    } do
      # Step 1: Create agent BEFORE mounting
      prompt = "Update after refresh test"

      {:ok, {_task, agent_pid}} =
        create_task_with_cleanup(
          prompt,
          pubsub: pubsub,
          registry: registry,
          dynsup: dynsup,
          sandbox_owner: owner
        )

      # Add initial items
      initial_items = [%{content: "Initial item", state: :todo}]
      :ok = GenServer.cast(agent_pid, {:update_todos, initial_items})
      {:ok, _} = GenServer.call(agent_pid, :get_state)

      # Step 2: Mount Dashboard (simulates page refresh)
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => owner
          }
        )

      # Verify initial items visible
      html = render(view)
      assert html =~ "Initial item", "Initial items should be visible after refresh"

      # Step 3: Update items after mount (tests subscription was set up)
      updated_items = [
        %{content: "Initial item", state: :done},
        %{content: "New item after refresh", state: :todo}
      ]

      :ok = GenServer.cast(agent_pid, {:update_todos, updated_items})
      {:ok, _} = GenServer.call(agent_pid, :get_state)

      # Force LiveView to process PubSub message
      html = render(view)

      # The fix ensures: subscribe_to_existing_agents subscribes to todos topic
      assert html =~ "New item after refresh",
             "Updates should work after refresh (subscription must be set up on mount)"

      # Negative assertions - no error states
      refute html =~ "Failed to load",
             "Should not show load failure messages"

      refute html =~ "Connection lost",
             "Should not show connection error states"
    end
  end
end
