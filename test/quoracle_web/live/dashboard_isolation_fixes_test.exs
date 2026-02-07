defmodule QuoracleWeb.DashboardIsolationFixesTest do
  @moduledoc """
  Tests for fixing isolation issues discovered in audit:
  - No global PubSub topics should be used
  - Reconnection handler must use socket.assigns.pubsub
  - Explicit agent deletion should clean up logs
  """
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import Test.AgentTestHelpers

  describe "PubSub isolation fixes" do
    setup %{conn: conn, sandbox_owner: sandbox_owner} do
      # Create isolated dependencies
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

      {:ok, _pubsub_pid} = start_supervised({Phoenix.PubSub, name: pubsub_name})
      {:ok, _registry_pid} = start_supervised({Registry, keys: :unique, name: registry_name})

      # CRITICAL: shutdown must be in child spec, not ExUnit options (ExUnit ignores it)
      dynsup_spec = %{
        id: {Quoracle.Agent.DynSup, make_ref()},
        start: {Quoracle.Agent.DynSup, :start_link, [[name: dynsup_name]]},
        shutdown: :infinity
      }

      {:ok, _dynsup_pid} = start_supervised(dynsup_spec)

      # Get test profile for task creation - use unique name to avoid ON CONFLICT contention
      profile = create_test_profile()

      # Create real task in DB for tests to use
      {:ok, {task, task_agent_pid}} =
        Quoracle.Tasks.TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Isolation test task"},
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

    # FIX_ISO_01: Dashboard must NOT subscribe to global topics
    test "Dashboard does not subscribe to global topics logs:all or messages:all", %{
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

      # Test by broadcasting on global topics - Dashboard should NOT receive them
      # Broadcast on global topics that should NOT be subscribed to
      Phoenix.PubSub.broadcast(
        pubsub,
        "logs:all",
        {:log_entry,
         %{
           agent_id: "test_agent",
           message: "Should not be received",
           level: :info
         }}
      )

      Phoenix.PubSub.broadcast(
        pubsub,
        "messages:all",
        {:message,
         %{
           content: "Should not be received"
         }}
      )

      # Force LiveView to process broadcasts
      render(view)

      # Check that the Dashboard didn't receive these messages
      socket = :sys.get_state(view.pid).socket

      # If it was subscribed to global topics, logs would have been added
      # Since we're removing global subscriptions, this should be empty
      refute Map.has_key?(socket.assigns.logs, "test_agent")
    end

    # FIX_ISO_02: Reconnection handler must use isolated PubSub
    test "reconnection handler uses socket.assigns.pubsub not hardcoded PubSub", %{
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

      # Simulate a reconnection event
      send(view.pid, {:mount, :reconnected})

      # Force LiveView to process reconnection
      render(view)

      # Test that it's using the test pubsub by broadcasting on it
      # If reconnection used hardcoded Quoracle.PubSub, it wouldn't receive this
      Phoenix.PubSub.broadcast(
        pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: "reconnect_test",
           task_id: task.id,
           parent_id: nil
         }}
      )

      # Force LiveView to process broadcast
      render(view)

      # Check that it received the message (proving it's subscribed to test pubsub)
      socket = :sys.get_state(view.pid).socket
      assert Map.has_key?(socket.assigns.agents, "reconnect_test")
    end
  end

  describe "Explicit agent deletion" do
    setup %{conn: conn, sandbox_owner: sandbox_owner} do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      {:ok, _pubsub_pid} = start_supervised({Phoenix.PubSub, name: pubsub_name})

      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      {:ok, _registry_pid} = start_supervised({Registry, keys: :unique, name: registry_name})

      dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

      # CRITICAL: shutdown must be in child spec, not ExUnit options (ExUnit ignores it)
      dynsup_spec = %{
        id: {DynamicSupervisor, make_ref()},
        start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: dynsup_name]]},
        shutdown: :infinity
      }

      {:ok, _dynsup_pid} = start_supervised(dynsup_spec)

      # Get test profile for task creation - use unique name to avoid ON CONFLICT contention
      profile = create_test_profile()

      # Create real task in DB for tests to use
      # Pass names not PIDs - Registry/DynamicSupervisor/PubSub functions expect names
      {:ok, {task, task_agent_pid}} =
        Quoracle.Tasks.TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Agent deletion test task"},
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

    # FIX_ISO_03: Explicit delete_agent event cleans up logs
    test "delete_agent event removes agent and its logs from memory", %{
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

      agent_id = "agent_#{System.unique_integer([:positive])}"

      # First spawn an agent
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task.id,
           parent_id: nil
         }}
      )

      # Add some logs for this agent
      for i <- 1..5 do
        send(
          view.pid,
          {:log_entry,
           %{
             agent_id: agent_id,
             level: :info,
             message: "Log message #{i}",
             timestamp: DateTime.utc_now()
           }}
        )
      end

      # Force LiveView to process messages
      render(view)

      # Verify agent and logs exist
      socket = :sys.get_state(view.pid).socket
      assert Map.has_key?(socket.assigns.agents, agent_id)
      assert Map.has_key?(socket.assigns.logs, agent_id)
      assert length(socket.assigns.logs[agent_id]) == 5

      # Now send delete_agent event (new feature)
      send(view.pid, {:delete_agent, agent_id})

      # Force LiveView to process deletion
      render(view)

      # Agent and logs should be removed
      socket = :sys.get_state(view.pid).socket
      refute Map.has_key?(socket.assigns.agents, agent_id)
      refute Map.has_key?(socket.assigns.logs, agent_id)
    end

    # FIX_ISO_04: Delete button in UI triggers delete_agent
    test "clicking delete button triggers agent deletion", %{
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

      agent_id = "agent_#{System.unique_integer([:positive])}"

      # Spawn an agent
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task.id,
           parent_id: nil
         }}
      )

      # Add logs
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

      # Force LiveView to process messages
      render(view)

      # Simulate delete button click event
      render_click(view, "delete_agent", %{"agent-id" => agent_id})

      # Force LiveView to process click event
      render(view)

      # Verify deletion would have occurred
      socket = :sys.get_state(view.pid).socket
      refute Map.has_key?(socket.assigns.agents, agent_id)
      refute Map.has_key?(socket.assigns.logs, agent_id)
    end

    # FIX_ISO_05: Agent termination keeps logs, only delete removes them
    test "agent_terminated event does NOT remove logs (only delete does)", %{
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

      agent_id = "agent_#{System.unique_integer([:positive])}"

      # Spawn agent and add logs
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task.id,
           parent_id: nil
         }}
      )

      send(
        view.pid,
        {:log_entry,
         %{
           agent_id: agent_id,
           level: :info,
           message: "Important log to keep",
           timestamp: DateTime.utc_now()
         }}
      )

      # Force LiveView to process messages
      render(view)

      # Terminate the agent
      send(
        view.pid,
        {:agent_terminated,
         %{
           agent_id: agent_id,
           reason: :normal
         }}
      )

      # Force LiveView to process termination
      render(view)

      socket = :sys.get_state(view.pid).socket

      # Agent should be marked as terminated, not removed (for Mailbox lifecycle tracking)
      assert Map.has_key?(socket.assigns.agents, agent_id)
      assert socket.assigns.agents[agent_id].status == :terminated

      # But logs should STILL exist for review
      assert Map.has_key?(socket.assigns.logs, agent_id)
      assert length(socket.assigns.logs[agent_id]) == 1
      assert hd(socket.assigns.logs[agent_id]).message == "Important log to keep"
    end

    # FIX_ISO_06: Deleted agents can't be re-subscribed
    test "deleting an agent unsubscribes from its log topic permanently", %{
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

      agent_id = "agent_#{System.unique_integer([:positive])}"
      topic = "agents:#{agent_id}:logs"

      # Spawn agent - should auto-subscribe to its logs
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task.id,
           parent_id: nil
         }}
      )

      # Force LiveView to process agent_spawned message
      render(view)

      # Verify subscribed by sending a log entry
      Phoenix.PubSub.broadcast(
        pubsub,
        topic,
        {:log_entry,
         %{
           agent_id: agent_id,
           level: :info,
           message: "Test subscription",
           timestamp: DateTime.utc_now()
         }}
      )

      # Force LiveView to process log_entry message
      html = render(view)

      # Check that Dashboard received and stored the log
      assert html =~ agent_id
      assert html =~ "Test subscription"
      socket = :sys.get_state(view.pid).socket
      assert Map.has_key?(socket.assigns.logs, agent_id)
      assert hd(socket.assigns.logs[agent_id]).message == "Test subscription"

      # Delete the agent
      send(view.pid, {:delete_agent, agent_id})

      # Force LiveView to process delete_agent message
      render(view)

      # Verify logs are deleted
      socket = :sys.get_state(view.pid).socket
      refute Map.has_key?(socket.assigns.logs, agent_id)

      # Even if we try to broadcast logs, they shouldn't be received
      Phoenix.PubSub.broadcast(
        pubsub,
        topic,
        {:log_entry,
         %{
           agent_id: agent_id,
           message: "Should not appear"
         }}
      )

      # Force LiveView to process broadcast (if it were subscribed)
      render(view)

      socket = :sys.get_state(view.pid).socket
      # No logs should exist for this deleted agent
      refute Map.has_key?(socket.assigns.logs, agent_id)
    end
  end

  describe "Global topic removal verification" do
    setup %{conn: conn, sandbox_owner: _sandbox_owner} do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      {:ok, _pubsub_pid} = start_supervised({Phoenix.PubSub, name: pubsub_name})

      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      {:ok, _registry_pid} = start_supervised({Registry, keys: :unique, name: registry_name})

      dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

      # CRITICAL: shutdown must be in child spec, not ExUnit options (ExUnit ignores it)
      dynsup_spec = %{
        id: {Quoracle.Agent.DynSup, make_ref()},
        start: {Quoracle.Agent.DynSup, :start_link, [[name: dynsup_name]]},
        shutdown: :infinity
      }

      {:ok, dynsup_pid} = start_supervised(dynsup_spec)

      # Create task directly in DB (no agent spawn - test simulates events)
      {:ok, task} =
        Quoracle.Repo.insert(
          Quoracle.Tasks.Task.changeset(%Quoracle.Tasks.Task{}, %{
            prompt: "Global topic test task",
            status: "running"
          })
        )

      # No agents created in this setup, but add defensive cleanup
      # in case any agents were spawned under this DynSup
      on_exit(fn ->
        # Check if dynsup is still alive before querying
        if Process.alive?(dynsup_pid) do
          # Check if any children are running under this DynSup
          children = DynamicSupervisor.which_children(dynsup_pid)

          Enum.each(children, fn
            {_id, child_pid, _type, _modules} when is_pid(child_pid) ->
              if Process.alive?(child_pid) do
                GenServer.stop(child_pid, :normal, :infinity)
              end

            _ ->
              :ok
          end)
        end
      end)

      %{conn: conn, pubsub: pubsub_name, registry: registry_name, dynsup: dynsup_name, task: task}
    end

    # FIX_ISO_07: Dashboard still receives logs via agent-specific topics
    test "Dashboard receives logs through agent-specific topics without global topics", %{
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

      agent_id = "agent_#{System.unique_integer([:positive])}"

      # Spawn agent
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task.id,
           parent_id: nil
         }}
      )

      # Force LiveView to process agent spawn
      render(view)

      # Broadcast log on agent-specific topic (not global)
      Phoenix.PubSub.broadcast(
        pubsub,
        "agents:#{agent_id}:logs",
        {:log_entry,
         %{
           agent_id: agent_id,
           level: :info,
           message: "Via specific topic",
           timestamp: DateTime.utc_now()
         }}
      )

      # Force LiveView to process log broadcast
      render(view)

      socket = :sys.get_state(view.pid).socket

      # Should receive the log via agent-specific subscription
      assert Map.has_key?(socket.assigns.logs, agent_id)
      assert length(socket.assigns.logs[agent_id]) == 1
      assert hd(socket.assigns.logs[agent_id]).message == "Via specific topic"
    end

    # FIX_ISO_08: No interference between test instances
    test "multiple Dashboard instances remain isolated without global topics", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      task: task
    } do
      # Create two separate pubsub instances
      pubsub2_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      {:ok, _pubsub2} = start_supervised({Phoenix.PubSub, name: pubsub2_name}, id: pubsub2_name)

      registry2_name = :"test_registry_#{System.unique_integer([:positive])}"

      {:ok, _registry2} =
        start_supervised({Registry, keys: :unique, name: registry2_name}, id: registry2_name)

      dynsup2_name = :"test_dynsup_#{System.unique_integer([:positive])}"

      # CRITICAL: shutdown must be in child spec, not ExUnit options (ExUnit ignores it)
      dynsup2_spec = %{
        id: {Quoracle.Agent.DynSup, make_ref()},
        start: {Quoracle.Agent.DynSup, :start_link, [[name: dynsup2_name]]},
        shutdown: :infinity
      }

      {:ok, dynsup2_pid} = start_supervised(dynsup2_spec)

      # Add cleanup for any agents spawned under dynsup2
      on_exit(fn ->
        # Check if dynsup2 is still alive before querying
        if Process.alive?(dynsup2_pid) do
          children = DynamicSupervisor.which_children(dynsup2_pid)

          Enum.each(children, fn
            {_id, child_pid, _type, _modules} when is_pid(child_pid) ->
              if Process.alive?(child_pid) do
                GenServer.stop(child_pid, :normal, :infinity)
              end

            _ ->
              :ok
          end)
        end
      end)

      # Mount two dashboards with different pubsubs
      {:ok, view1, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{"pubsub" => pubsub, "registry" => registry, "dynsup" => dynsup}
        )

      {:ok, view2, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub2_name,
            "registry" => registry2_name,
            "dynsup" => dynsup2_name
          }
        )

      # Send log to first dashboard's pubsub
      agent_id = "agent_#{System.unique_integer([:positive])}"

      send(
        view1.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task.id,
           parent_id: nil
         }}
      )

      send(
        view1.pid,
        {:log_entry,
         %{
           agent_id: agent_id,
           level: :info,
           message: "Only for view1",
           timestamp: DateTime.utc_now()
         }}
      )

      # Force LiveView to process messages
      render(view1)

      # Check both dashboards
      socket1 = :sys.get_state(view1.pid).socket
      socket2 = :sys.get_state(view2.pid).socket

      # First dashboard should have the log
      assert Map.has_key?(socket1.assigns.logs, agent_id)

      # Second dashboard should NOT have the log (isolation working)
      refute Map.has_key?(socket2.assigns.logs, agent_id)
    end
  end
end
