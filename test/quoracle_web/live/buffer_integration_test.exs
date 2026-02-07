defmodule QuoracleWeb.BufferIntegrationTest do
  @moduledoc """
  Integration tests for LiveView mount with EventHistory buffer replay.
  Verifies logs and messages are hydrated from buffer on page refresh.

  Tests UI_Dashboard v9.0 requirements (R35-R42) and TEST_BUFFER_Integration (R17-R24).
  """

  use QuoracleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import Test.IsolationHelpers, only: [poll_until: 1]

  alias Quoracle.UI.EventHistory
  alias Phoenix.PubSub

  # Test fixtures
  # IDs must be unique across all agents/tasks to avoid component ID collisions in LiveView
  defp sample_log(agent_id, id) do
    %{
      id: "#{agent_id}-log-#{id}",
      agent_id: agent_id,
      level: :info,
      message: "Buffered log #{id}",
      metadata: %{},
      timestamp: DateTime.utc_now()
    }
  end

  defp sample_message(task_id, id) do
    %{
      id: "#{task_id}-msg-#{id}",
      task_id: task_id,
      from: :agent,
      sender_id: "agent-001",
      content: "Buffered message #{id}",
      timestamp: DateTime.utc_now(),
      status: :received
    }
  end

  # Generate a fake UUID for tests (doesn't need to exist in DB for most tests)
  defp fake_task_id do
    Ecto.UUID.generate()
  end

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated dependencies
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    reg_name = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: reg_name})

    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
      shutdown: :infinity
    }

    {:ok, dynsup} = start_supervised(dynsup_spec)

    # Start EventHistory with isolated PubSub
    {:ok, event_history} = start_supervised({EventHistory, pubsub: pubsub_name})

    # CRITICAL: Sync to ensure handle_continue(:setup) has completed
    # and EventHistory is subscribed to "agents:lifecycle" before tests run.
    # Without this, broadcasts can be lost under heavy parallel load.
    :sys.get_state(event_history)

    # Generate a test task_id for use across tests
    test_task_id = fake_task_id()

    %{
      pubsub: pubsub_name,
      registry: reg_name,
      dynsup: dynsup,
      event_history: event_history,
      sandbox_owner: sandbox_owner,
      test_task_id: test_task_id
    }
  end

  # ============================================================
  # UI_Dashboard v9.0 Requirements (R35-R42)
  # EventHistory integration in Dashboard mount
  # ============================================================

  describe "R35-R42: EventHistory integration in Dashboard mount" do
    # R35: EventHistory PID Extraction [UNIT]
    test "R35: mount extracts event_history_pid from session", ctx do
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Get socket assigns to verify event_history_pid is stored
      socket_assigns = :sys.get_state(view.pid).socket.assigns

      assert Map.has_key?(socket_assigns, :event_history_pid),
             "Socket should have event_history_pid assign"

      assert socket_assigns.event_history_pid == ctx.event_history,
             "event_history_pid should match session value"
    end

    # R36: Production EventHistory Discovery [UNIT]
    test "R36: mount discovers EventHistory PID in production", ctx do
      # Production supervisor starts EventHistory with name Quoracle.UI.EventHistory
      # Verify it's running
      production_eh = EventHistory.get_pid()
      assert is_pid(production_eh), "Production EventHistory should be running"

      # Mount WITHOUT event_history_pid in session
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner
            # No event_history_pid - should discover via EventHistory.get_pid()
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Verify event_history_pid was discovered
      socket_assigns = :sys.get_state(view.pid).socket.assigns

      assert Map.has_key?(socket_assigns, :event_history_pid),
             "Socket should have event_history_pid from production discovery"

      assert socket_assigns.event_history_pid == production_eh,
             "Should discover the production EventHistory PID"
    end

    # R37: Buffer Query with Agent IDs [INTEGRATION]
    test "R37: mount queries EventHistory with agent IDs", ctx do
      # Pre-populate EventHistory buffer with logs for specific agent
      agent_id = "agent-buffer-query"
      task_id = ctx.test_task_id

      # Spawn agent in EventHistory
      PubSub.broadcast(
        ctx.pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id
         }}
      )

      :sys.get_state(ctx.event_history)

      # Add logs to buffer
      for id <- 1..3 do
        PubSub.broadcast(
          ctx.pubsub,
          "agents:#{agent_id}:logs",
          {:log_entry, sample_log(agent_id, id)}
        )
      end

      # Poll until all 3 logs are buffered (PubSub delivery is async)
      assert :ok =
               poll_until(fn ->
                 buffered_logs = EventHistory.get_logs(ctx.event_history, [agent_id])
                 length(buffered_logs[agent_id] || []) == 3
               end),
             "Buffer should have 3 logs"

      # Mount Dashboard - should query buffer with agent IDs
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Simulate agent exists so mount queries for its logs
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id,
           parent_id: nil,
           timestamp: DateTime.utc_now()
         }}
      )

      render(view)

      # Socket should have logs from buffer
      socket_assigns = :sys.get_state(view.pid).socket.assigns

      assert Map.has_key?(socket_assigns.logs, agent_id),
             "Socket logs should include agent_id from buffer query"
    end

    # R38: Initial Logs from Buffer [INTEGRATION]
    test "R38: socket.assigns.logs populated from buffer", ctx do
      # Pre-populate EventHistory buffer
      agent_id = "agent-initial-logs"
      task_id = ctx.test_task_id

      PubSub.broadcast(
        ctx.pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id
         }}
      )

      :sys.get_state(ctx.event_history)

      for id <- 1..5 do
        PubSub.broadcast(
          ctx.pubsub,
          "agents:#{agent_id}:logs",
          {:log_entry, sample_log(agent_id, id)}
        )
      end

      # Poll until all 5 logs are buffered (PubSub delivery is async)
      assert :ok =
               poll_until(fn ->
                 buffered = EventHistory.get_logs(ctx.event_history, [agent_id])
                 length(buffered[agent_id] || []) == 5
               end)

      # Mount Dashboard with EventHistory
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Add agent to view state so logs are relevant
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id,
           parent_id: nil,
           timestamp: DateTime.utc_now()
         }}
      )

      # Logs should be populated from buffer on mount
      socket_assigns = :sys.get_state(view.pid).socket.assigns

      assert Map.has_key?(socket_assigns.logs, agent_id),
             "socket.assigns.logs should have buffer data"

      assert length(socket_assigns.logs[agent_id]) == 5,
             "Should have all 5 logs from buffer"

      # Logs should also be visible in HTML
      html = render(view)
      assert html =~ "Buffered log 1", "Buffered logs should be visible in UI"
    end

    # R39: Initial Messages from Buffer [INTEGRATION]
    test "R39: socket.assigns.messages populated from buffer", ctx do
      # Create a real task in DB so Dashboard loads it on mount
      alias Quoracle.Tasks.Task
      alias Quoracle.Repo

      agent_id = "agent-initial-msgs-#{System.unique_integer([:positive])}"

      {:ok, task} =
        %Task{}
        |> Task.changeset(%{prompt: "Test task for buffer", status: "running"})
        |> Repo.insert()

      task_id = task.id

      # Spawn agent and set up task subscription in EventHistory
      PubSub.broadcast(
        ctx.pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id
         }}
      )

      :sys.get_state(ctx.event_history)

      for id <- 1..3 do
        PubSub.broadcast(
          ctx.pubsub,
          "tasks:#{task_id}:messages",
          {:agent_message, sample_message(task_id, id)}
        )
      end

      :sys.get_state(ctx.event_history)

      # Mount Dashboard with EventHistory - task exists in DB so it's loaded on mount
      # and messages are queried from EventHistory buffer
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      render(view)

      # Messages should be populated from buffer (queried at mount since task exists in DB)
      socket_assigns = :sys.get_state(view.pid).socket.assigns

      assert is_list(socket_assigns.messages),
             "socket.assigns.messages should be a list"

      assert length(socket_assigns.messages) == 3,
             "Should have all 3 messages from buffer. Got: #{length(socket_assigns.messages)}"
    end

    # R40: Log Deduplication [INTEGRATION]
    test "R40: duplicate log entries skipped by id", ctx do
      agent_id = "agent-dedup-logs"
      task_id = ctx.test_task_id

      # Spawn agent in EventHistory
      PubSub.broadcast(
        ctx.pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id
         }}
      )

      :sys.get_state(ctx.event_history)

      # Add log to buffer
      PubSub.broadcast(
        ctx.pubsub,
        "agents:#{agent_id}:logs",
        {:log_entry, sample_log(agent_id, 1)}
      )

      :sys.get_state(ctx.event_history)

      # Mount Dashboard - should get log from buffer
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Add agent to state
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id,
           parent_id: nil,
           timestamp: DateTime.utc_now()
         }}
      )

      render(view)

      # Get initial log count
      socket_assigns = :sys.get_state(view.pid).socket.assigns
      initial_count = length(Map.get(socket_assigns.logs, agent_id, []))

      # Send duplicate log (same id) via PubSub - should be deduplicated
      send(view.pid, {:log_entry, sample_log(agent_id, 1)})
      render(view)

      # Log count should not increase (duplicate skipped)
      socket_assigns = :sys.get_state(view.pid).socket.assigns
      final_count = length(Map.get(socket_assigns.logs, agent_id, []))

      assert final_count == initial_count,
             "Duplicate log should be skipped. Initial: #{initial_count}, Final: #{final_count}"
    end

    # R41: Message Deduplication [INTEGRATION]
    test "R41: duplicate messages skipped by id", ctx do
      task_id = ctx.test_task_id
      agent_id = "agent-dedup-msgs"

      # Spawn agent in EventHistory
      PubSub.broadcast(
        ctx.pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id
         }}
      )

      :sys.get_state(ctx.event_history)

      # Add message to buffer
      PubSub.broadcast(
        ctx.pubsub,
        "tasks:#{task_id}:messages",
        {:agent_message, sample_message(task_id, 1)}
      )

      :sys.get_state(ctx.event_history)

      # Mount Dashboard - should get message from buffer
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Simulate agent exists so Dashboard queries buffer for its task's messages
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id,
           parent_id: nil,
           timestamp: DateTime.utc_now()
         }}
      )

      render(view)

      # Get initial message count (should have 1 from buffer)
      socket_assigns = :sys.get_state(view.pid).socket.assigns
      initial_count = length(socket_assigns.messages)

      assert initial_count == 1,
             "Should have 1 message from buffer initially. Got: #{initial_count}"

      # Send duplicate message (same id) - should be deduplicated
      send(view.pid, {:agent_message, sample_message(task_id, 1)})
      render(view)

      # Message count should not increase (duplicate skipped)
      socket_assigns = :sys.get_state(view.pid).socket.assigns
      final_count = length(socket_assigns.messages)

      assert final_count == initial_count,
             "Duplicate message should be skipped. Initial: #{initial_count}, Final: #{final_count}"
    end

    # R42: Graceful Fallback [UNIT]
    test "R42: mount succeeds when EventHistory unavailable", ctx do
      # Mount Dashboard with nil event_history_pid
      {:ok, view, html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => nil
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Dashboard should mount successfully
      assert html =~ "Task Tree", "Dashboard should render"
      assert Process.alive?(view.pid), "LiveView should be alive"

      # Socket should have empty logs/messages
      socket_assigns = :sys.get_state(view.pid).socket.assigns
      assert socket_assigns.logs == %{}, "Logs should be empty map"
      assert socket_assigns.messages == [], "Messages should be empty list"
    end
  end

  # ============================================================
  # TEST_BUFFER_Integration Requirements (R17-R24)
  # End-to-end integration tests for buffer replay
  # ============================================================

  describe "R17-R24: page refresh replay" do
    # R17: Log Replay on Mount [SYSTEM] - ACCEPTANCE
    @tag :acceptance
    test "R17: logs visible immediately after page refresh", ctx do
      agent_id = "agent-refresh-logs"
      task_id = ctx.test_task_id

      # Pre-populate buffer with logs (simulating prior session)
      PubSub.broadcast(
        ctx.pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id
         }}
      )

      :sys.get_state(ctx.event_history)

      for id <- 1..3 do
        PubSub.broadcast(
          ctx.pubsub,
          "agents:#{agent_id}:logs",
          {:log_entry, sample_log(agent_id, id)}
        )
      end

      # Poll until all 3 logs are buffered (PubSub delivery is async)
      assert :ok =
               poll_until(fn ->
                 buffered = EventHistory.get_logs(ctx.event_history, [agent_id])
                 length(buffered[agent_id] || []) == 3
               end)

      # Mount Dashboard (simulates page refresh)
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Add agent to view state
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id,
           parent_id: nil,
           timestamp: DateTime.utc_now()
         }}
      )

      # First render processes agent_spawned, which may trigger async log fetch
      render(view)

      # Second render ensures any async effects (log fetching) have completed
      html = render(view)

      # Logs should be visible IMMEDIATELY (from buffer)
      assert html =~ "Buffered log 1", "First buffered log should be visible"
      assert html =~ "Buffered log 3", "Last buffered log should be visible"

      # No error flash messages (not matching Phoenix flash element IDs like "client-error")
      refute html =~ "phx-flash-error"
    end

    # R18: Message Replay on Mount [SYSTEM] - ACCEPTANCE
    @tag :acceptance
    test "R18: messages visible immediately after page refresh", ctx do
      task_id = ctx.test_task_id
      agent_id = "agent-refresh-msgs"

      # Pre-populate buffer with messages
      PubSub.broadcast(
        ctx.pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id
         }}
      )

      :sys.get_state(ctx.event_history)

      for id <- 1..2 do
        PubSub.broadcast(
          ctx.pubsub,
          "tasks:#{task_id}:messages",
          {:agent_message, sample_message(task_id, id)}
        )
      end

      :sys.get_state(ctx.event_history)

      # Mount Dashboard (simulates page refresh)
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Simulate agent exists so Dashboard queries buffer for its task's messages
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id,
           parent_id: nil,
           timestamp: DateTime.utc_now()
         }}
      )

      # Force LiveView to process pending messages (render is synchronous)
      # First render processes agent_spawned and triggers buffer query
      _ = render(view)
      # Second render ensures buffer query results are rendered
      html = render(view)

      # Messages should be visible IMMEDIATELY (from buffer)
      assert html =~ "Buffered message 1", "First buffered message should be visible"
      assert html =~ "Buffered message 2", "Second buffered message should be visible"

      # No error flash messages
      refute html =~ "phx-flash-error"
    end

    # R19: Buffer Query with Agent IDs [INTEGRATION]
    test "R19: mount queries buffer with correct agent IDs", ctx do
      # Create multiple agents with logs
      agent_ids = ["agent-query-1", "agent-query-2"]
      task_id = ctx.test_task_id

      for agent_id <- agent_ids do
        PubSub.broadcast(
          ctx.pubsub,
          "agents:lifecycle",
          {:agent_spawned,
           %{
             agent_id: agent_id,
             task_id: task_id
           }}
        )

        :sys.get_state(ctx.event_history)

        PubSub.broadcast(
          ctx.pubsub,
          "agents:#{agent_id}:logs",
          {:log_entry, sample_log(agent_id, 1)}
        )

        :sys.get_state(ctx.event_history)
      end

      # Mount Dashboard
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Add both agents to view state
      for agent_id <- agent_ids do
        send(
          view.pid,
          {:agent_spawned,
           %{
             agent_id: agent_id,
             task_id: task_id,
             parent_id: nil,
             timestamp: DateTime.utc_now()
           }}
        )
      end

      render(view)

      # Verify both agents' logs were queried
      socket_assigns = :sys.get_state(view.pid).socket.assigns

      for agent_id <- agent_ids do
        assert Map.has_key?(socket_assigns.logs, agent_id),
               "Buffer should be queried for #{agent_id}"
      end
    end

    # R20: Deduplication by Log ID [INTEGRATION]
    test "R20: duplicate logs deduplicated by id", ctx do
      agent_id = "agent-dedup-test"
      task_id = ctx.test_task_id

      # Add log to buffer
      PubSub.broadcast(
        ctx.pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id
         }}
      )

      :sys.get_state(ctx.event_history)

      log = sample_log(agent_id, 42)
      PubSub.broadcast(ctx.pubsub, "agents:#{agent_id}:logs", {:log_entry, log})
      :sys.get_state(ctx.event_history)

      # Mount Dashboard
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Add agent
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id,
           parent_id: nil,
           timestamp: DateTime.utc_now()
         }}
      )

      render(view)

      # Send same log again (race condition simulation)
      send(view.pid, {:log_entry, log})
      render(view)

      # Should only have one instance of the log
      socket_assigns = :sys.get_state(view.pid).socket.assigns
      log_ids = Enum.map(socket_assigns.logs[agent_id] || [], & &1.id)
      expected_id = "#{agent_id}-log-42"

      assert Enum.count(log_ids, &(&1 == expected_id)) == 1,
             "Log id #{expected_id} should appear exactly once. Got: #{inspect(log_ids)}"
    end

    # R21: Deduplication by Message ID [INTEGRATION]
    test "R21: duplicate messages deduplicated by id", ctx do
      task_id = ctx.test_task_id
      agent_id = "agent-msg-dedup"

      # Add message to buffer
      PubSub.broadcast(
        ctx.pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id
         }}
      )

      :sys.get_state(ctx.event_history)

      msg = sample_message(task_id, 99)
      PubSub.broadcast(ctx.pubsub, "tasks:#{task_id}:messages", {:agent_message, msg})
      :sys.get_state(ctx.event_history)

      # Mount Dashboard
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Simulate agent exists so Dashboard queries buffer for its task's messages
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: agent_id,
           task_id: task_id,
           parent_id: nil,
           timestamp: DateTime.utc_now()
         }}
      )

      render(view)

      # Send same message again (race condition simulation)
      send(view.pid, {:agent_message, msg})
      render(view)

      # Should only have one instance of the message
      socket_assigns = :sys.get_state(view.pid).socket.assigns
      msg_ids = Enum.map(socket_assigns.messages, & &1.id)
      expected_id = "#{task_id}-msg-99"

      assert Enum.count(msg_ids, &(&1 == expected_id)) == 1,
             "Message id #{expected_id} should appear exactly once. Got: #{inspect(msg_ids)}"
    end

    # R22: Empty Buffer Mount [INTEGRATION]
    test "R22: mount works with empty buffer", ctx do
      # Don't pre-populate buffer - it's empty

      # Mount Dashboard
      {:ok, view, html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Dashboard should render normally with empty state
      assert html =~ "Task Tree"
      assert html =~ "Logs"
      assert html =~ "Mailbox"

      # Socket should have empty logs/messages
      socket_assigns = :sys.get_state(view.pid).socket.assigns
      assert socket_assigns.logs == %{}, "Logs should be empty"
      assert socket_assigns.messages == [], "Messages should be empty"
    end

    # R23: Multi-Agent Log Replay [INTEGRATION]
    test "R23: logs replayed for multiple agents", ctx do
      agent_ids = ["agent-multi-1", "agent-multi-2", "agent-multi-3"]
      task_id = ctx.test_task_id

      # Pre-populate buffer with logs for each agent
      for agent_id <- agent_ids do
        PubSub.broadcast(
          ctx.pubsub,
          "agents:lifecycle",
          {:agent_spawned,
           %{
             agent_id: agent_id,
             task_id: task_id
           }}
        )

        :sys.get_state(ctx.event_history)

        for id <- 1..2 do
          PubSub.broadcast(
            ctx.pubsub,
            "agents:#{agent_id}:logs",
            {:log_entry, sample_log(agent_id, id)}
          )
        end
      end

      # Poll until all agents have 2 logs each (PubSub delivery is async)
      assert :ok =
               poll_until(fn ->
                 Enum.all?(agent_ids, fn agent_id ->
                   buffered = EventHistory.get_logs(ctx.event_history, [agent_id])
                   length(buffered[agent_id] || []) == 2
                 end)
               end)

      # Mount Dashboard
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Add all agents to view
      for agent_id <- agent_ids do
        send(
          view.pid,
          {:agent_spawned,
           %{
             agent_id: agent_id,
             task_id: task_id,
             parent_id: nil,
             timestamp: DateTime.utc_now()
           }}
        )

        # Sync after each agent_spawned to ensure replay completes
        render(view)
      end

      # Final render to ensure all events processed
      render(view)

      # Verify all agents' logs were replayed
      socket_assigns = :sys.get_state(view.pid).socket.assigns

      for agent_id <- agent_ids do
        assert Map.has_key?(socket_assigns.logs, agent_id),
               "Logs for #{agent_id} should be replayed"

        assert length(socket_assigns.logs[agent_id]) == 2,
               "#{agent_id} should have 2 logs"
      end
    end

    # R24: Multi-Task Message Replay [INTEGRATION]
    test "R24: messages replayed for multiple tasks", ctx do
      # Generate 3 unique task UUIDs
      task_ids = [Ecto.UUID.generate(), Ecto.UUID.generate(), Ecto.UUID.generate()]

      # Pre-populate buffer with messages for each task
      for {task_id, idx} <- Enum.with_index(task_ids) do
        agent_id = "agent-task-#{idx}"

        PubSub.broadcast(
          ctx.pubsub,
          "agents:lifecycle",
          {:agent_spawned,
           %{
             agent_id: agent_id,
             task_id: task_id
           }}
        )

        :sys.get_state(ctx.event_history)

        PubSub.broadcast(
          ctx.pubsub,
          "tasks:#{task_id}:messages",
          {:agent_message, sample_message(task_id, idx + 1)}
        )

        :sys.get_state(ctx.event_history)
      end

      # Mount Dashboard
      {:ok, view, _html} =
        live_isolated(ctx.conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => ctx.pubsub,
            "registry" => ctx.registry,
            "dynsup" => ctx.dynsup,
            "sandbox_owner" => ctx.sandbox_owner,
            "event_history_pid" => ctx.event_history
          }
        )

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Simulate agents exist so Dashboard queries buffer for their tasks' messages
      for {task_id, idx} <- Enum.with_index(task_ids) do
        agent_id = "agent-task-#{idx}"

        send(
          view.pid,
          {:agent_spawned,
           %{
             agent_id: agent_id,
             task_id: task_id,
             parent_id: nil,
             timestamp: DateTime.utc_now()
           }}
        )
      end

      render(view)

      # Verify messages from all tasks were replayed
      socket_assigns = :sys.get_state(view.pid).socket.assigns

      assert length(socket_assigns.messages) == 3,
             "Should have messages from all 3 tasks. Got: #{length(socket_assigns.messages)}"

      # Verify task_ids are present
      message_task_ids = Enum.map(socket_assigns.messages, & &1.task_id)

      for task_id <- task_ids do
        assert task_id in message_task_ids,
               "Message for task #{task_id} should be replayed"
      end
    end
  end
end
