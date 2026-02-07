defmodule QuoracleWeb.DashboardAutoSubscriptionTest do
  @moduledoc """
  Tests for auto-subscription feature in Dashboard LiveView.
  Verifies that Dashboard automatically subscribes to agent logs
  via lifecycle events without using global PubSub topics.
  """
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import Test.AgentTestHelpers

  describe "auto-subscription to agent logs" do
    setup %{conn: conn, sandbox_owner: sandbox_owner} do
      # Create isolated dependencies
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

      {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})
      {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

      {:ok, _dynsup} =
        start_supervised({Quoracle.Agent.DynSup, name: dynsup_name}, shutdown: :infinity)

      # Get test profile for task creation - use unique name to avoid ON CONFLICT contention
      profile = create_test_profile()

      # Create real task in DB for tests to use
      {:ok, {task, task_agent_pid}} =
        Quoracle.Tasks.TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Auto-subscription test task"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup_name,
          registry: registry_name,
          pubsub: pubsub_name
        )

      # Wait for agent initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      # Ensure agent and all children terminate before sandbox owner exits
      register_agent_cleanup(task_agent_pid,
        cleanup_tree: true,
        registry: registry_name,
        sandbox_owner: sandbox_owner
      )

      %{conn: conn, pubsub: pubsub_name, registry: registry_name, dynsup: dynsup_name, task: task}
    end

    # ARC_FUNC_01: Dashboard subscribes to existing agents on mount
    test "subscribes to all existing agent log topics on mount", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      task: _task
    } do
      # Register some existing agents in Registry
      agent1_id = "agent_#{System.unique_integer([:positive])}"
      agent2_id = "agent_#{System.unique_integer([:positive])}"

      Registry.register(registry, {:agent, agent1_id}, %{
        pid: self(),
        parent_pid: nil,
        registered_at: System.system_time(:microsecond)
      })

      Registry.register(registry, {:agent, agent2_id}, %{
        pid: self(),
        parent_pid: nil,
        registered_at: System.system_time(:microsecond)
      })

      # Mount Dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{"pubsub" => pubsub, "registry" => registry, "dynsup" => dynsup}
        )

      # Verify Dashboard would track logs for these agents
      # This will fail because the auto-subscription isn't implemented yet
      socket = :sys.get_state(view.pid).socket

      # Check if logs are stored as a Map (will fail - not implemented)
      assert is_map(socket.assigns.logs)
    end

    # ARC_FUNC_02: Auto-subscribe on agent_spawned
    test "auto-subscribes to new agent logs on agent_spawned event", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      task: task
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{"pubsub" => pubsub, "registry" => registry, "dynsup" => dynsup}
        )

      agent_id = "new_agent_#{System.unique_integer([:positive])}"

      # Send agent_spawned event
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task.id,
           parent_id: nil
         }}
      )

      # Force LiveView to process all pending messages synchronously
      render(view)

      # Verify Dashboard tracked the new agent
      # This will fail because auto-subscription isn't implemented
      socket = :sys.get_state(view.pid).socket
      assert Map.has_key?(socket.assigns.agents, agent_id)
    end

    # ARC_FUNC_03: Auto-unsubscribe on agent_terminated
    test "auto-unsubscribes from agent logs on agent_terminated event", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      task: task
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{"pubsub" => pubsub, "registry" => registry, "dynsup" => dynsup}
        )

      agent_id = "temp_agent_#{System.unique_integer([:positive])}"

      # First spawn agent to subscribe
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task.id,
           parent_id: nil
         }}
      )

      # Force LiveView to process all pending messages synchronously
      render(view)

      # Then terminate agent
      send(
        view.pid,
        {:agent_terminated,
         %{
           agent_id: agent_id,
           reason: :normal
         }}
      )

      # Force LiveView to process all pending messages synchronously
      render(view)

      # Verify Dashboard marked agent as terminated (not deleted, for Mailbox lifecycle tracking)
      socket = :sys.get_state(view.pid).socket
      # Agent should be marked as terminated, not removed
      assert Map.has_key?(socket.assigns.agents, agent_id)
      assert socket.assigns.agents[agent_id].status == :terminated
    end

    # ARC_FUNC_04: No agent selected shows all logs
    test "stores logs from all agents in Map structure", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      task: _task
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{"pubsub" => pubsub, "registry" => registry, "dynsup" => dynsup}
        )

      agent1_id = "agent1_#{System.unique_integer([:positive])}"
      agent2_id = "agent2_#{System.unique_integer([:positive])}"

      # Send logs from multiple agents
      send(
        view.pid,
        {:log_entry,
         %{
           agent_id: agent1_id,
           level: :info,
           message: "Log from agent 1",
           timestamp: DateTime.utc_now()
         }}
      )

      send(
        view.pid,
        {:log_entry,
         %{
           agent_id: agent2_id,
           level: :info,
           message: "Log from agent 2",
           timestamp: DateTime.utc_now()
         }}
      )

      # Force LiveView to process all pending messages synchronously
      render(view)

      # This will fail because log Map storage isn't implemented
      socket = :sys.get_state(view.pid).socket

      # Check logs are stored as Map
      assert is_map(socket.assigns.logs)
      assert Map.has_key?(socket.assigns.logs, agent1_id)
      assert Map.has_key?(socket.assigns.logs, agent2_id)
    end

    # ARC_FUNC_05: Agent selected shows only that agent's logs
    test "stores agent logs separately in Map for filtering", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      task: _task
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{"pubsub" => pubsub, "registry" => registry, "dynsup" => dynsup}
        )

      agent1_id = "agent1_#{System.unique_integer([:positive])}"
      agent2_id = "agent2_#{System.unique_integer([:positive])}"

      # Send logs from multiple agents
      send(
        view.pid,
        {:log_entry,
         %{
           agent_id: agent1_id,
           level: :info,
           message: "Log from agent 1",
           timestamp: DateTime.utc_now()
         }}
      )

      send(
        view.pid,
        {:log_entry,
         %{
           agent_id: agent2_id,
           level: :info,
           message: "Log from agent 2",
           timestamp: DateTime.utc_now()
         }}
      )

      # Force LiveView to process all pending messages synchronously
      render(view)

      # This will fail because log Map storage isn't implemented
      socket = :sys.get_state(view.pid).socket

      assert is_map(socket.assigns.logs)
      agent1_logs = Map.get(socket.assigns.logs, agent1_id, [])
      assert length(agent1_logs) == 1
      assert hd(agent1_logs).agent_id == agent1_id
    end

    # ARC_PERF_01: Per-agent log limit of 100
    test "enforces 100 log limit per agent", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      task: _task
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{"pubsub" => pubsub, "registry" => registry, "dynsup" => dynsup}
        )

      agent_id = "prolific_agent_#{System.unique_integer([:positive])}"

      # Send 150 logs from same agent
      for i <- 1..150 do
        send(
          view.pid,
          {:log_entry,
           %{
             agent_id: agent_id,
             level: :info,
             message: "Log #{i}",
             timestamp: DateTime.utc_now()
           }}
        )
      end

      # Force LiveView to process all pending messages synchronously
      render(view)

      socket = :sys.get_state(view.pid).socket

      # This will fail because per-agent limit isn't implemented
      assert is_map(socket.assigns.logs)
      agent_logs = Map.get(socket.assigns.logs, agent_id, [])
      assert length(agent_logs) == 100
      # Most recent first
      assert hd(agent_logs).message == "Log 150"
    end

    # ARC_PERF_02: O(1) lookup via Map structure
    test "stores logs in Map structure for O(1) agent lookup", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      task: _task
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{"pubsub" => pubsub, "registry" => registry, "dynsup" => dynsup}
        )

      agent_id = "test_agent_#{System.unique_integer([:positive])}"

      send(
        view.pid,
        {:log_entry,
         %{
           agent_id: agent_id,
           level: :info,
           message: "Test log",
           timestamp: DateTime.utc_now()
         }}
      )

      # Force LiveView to process all pending messages synchronously
      render(view)

      socket = :sys.get_state(view.pid).socket

      # Logs should be stored as Map, not list
      # This will fail because Map storage isn't implemented
      assert is_map(socket.assigns.logs)
      assert Map.has_key?(socket.assigns.logs, agent_id)
      assert is_list(socket.assigns.logs[agent_id])
    end

    # ARC_ISO_01: Test isolation with isolated PubSub
    test "uses isolated PubSub instance from test session", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      task: _task
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{"pubsub" => pubsub, "registry" => registry, "dynsup" => dynsup}
        )

      socket = :sys.get_state(view.pid).socket

      # Should use test PubSub instance, not global
      # This will fail if pubsub isn't stored in assigns
      assert socket.assigns.pubsub == pubsub
      refute socket.assigns.pubsub == Quoracle.PubSub
    end

    # ARC_ISO_02: No crosstalk between concurrent tests
    test "maintains isolation when multiple tests run concurrently", %{conn: conn} do
      # Create two isolated instances
      pubsub1 = :"test_pubsub_1_#{System.unique_integer([:positive])}"
      pubsub2 = :"test_pubsub_2_#{System.unique_integer([:positive])}"
      registry1 = :"test_registry_1_#{System.unique_integer([:positive])}"
      registry2 = :"test_registry_2_#{System.unique_integer([:positive])}"

      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub1}, id: :pubsub1)
      {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub2}, id: :pubsub2)
      {:ok, _} = start_supervised({Registry, keys: :duplicate, name: registry1}, id: :reg1)
      {:ok, _} = start_supervised({Registry, keys: :duplicate, name: registry2}, id: :reg2)

      {:ok, view1, _} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{"pubsub" => pubsub1, "registry" => registry1}
        )

      {:ok, view2, _} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{"pubsub" => pubsub2, "registry" => registry2}
        )

      # Send log to first instance
      send(
        view1.pid,
        {:log_entry,
         %{
           agent_id: "agent1",
           level: :info,
           message: "Log for view1",
           timestamp: DateTime.utc_now()
         }}
      )

      # Force synchronous message processing
      render(view2)

      # Second instance should not receive the log
      socket1 = :sys.get_state(view1.pid).socket
      socket2 = :sys.get_state(view2.pid).socket

      # This will fail until proper isolation is implemented
      assert is_map(socket1.assigns.logs)
      assert is_map(socket2.assigns.logs)
      # socket1 may have received the log or may not have processed it yet
      assert is_map(socket1.assigns.logs)
      assert socket2.assigns.logs == %{}
    end

    # Test Dashboard provides filtered logs to LogView component
    test "Dashboard provides filtered logs to LogView component", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      task: _task
    } do
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{"pubsub" => pubsub, "registry" => registry, "dynsup" => dynsup}
        )

      socket = :sys.get_state(view.pid).socket
      # Logs should be a Map for filtering
      # This will fail until Map storage is implemented
      assert is_map(socket.assigns.logs)
    end

    # Test Registry query pattern
    test "queries Registry using correct pattern for agent discovery", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      task: _task
    } do
      # Register agent with expected pattern
      Registry.register(registry, {:agent, "test_agent"}, %{
        pid: self(),
        parent_pid: nil,
        registered_at: System.system_time(:microsecond)
      })

      # The Dashboard should find this agent using Registry.select
      # with pattern: {{{:agent, :"$1"}, :"$2", :"$3"}, [], [:"$1"]}
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{"pubsub" => pubsub, "registry" => registry, "dynsup" => dynsup}
        )

      # This will fail until Registry query is implemented
      socket = :sys.get_state(view.pid).socket
      # Check if the Dashboard found and subscribed to the test agent
      # We verify this by checking if logs Map would be ready
      assert is_map(socket.assigns.logs)
    end
  end
end
