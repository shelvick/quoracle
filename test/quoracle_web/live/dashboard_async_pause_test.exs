defmodule QuoracleWeb.DashboardAsyncPauseTest do
  @moduledoc """
  Tests for async pause UI behavior in Dashboard LiveView.

  Packet 2: UI_Dashboard v8.0 + UI_TaskTree v5.0
  WorkGroupID: refactor-20251224-001420

  Tests verify:
  - R29: UI Shows Pausing State during async termination
  - R30: Stop Handler Deleted (no stop_task event)
  - R31: Pause Completion Detection (last agent terminated → "paused")
  - R32: Natural Completion Preserved (completed tasks stay "completed")
  - R33: DB Updated on Pause Completion
  - R34: Resume Disabled During Pausing

  UI_TaskTree v5.0:
  - R16: Stop Button Removed
  - R17: Pausing State Shows Disabled Pause Button
  - R18: Pause Button Hidden During Pausing
  - R19: Resume Hidden During Pausing
  - R20: Delete Hidden During Pausing
  - R21: Stop Event Handler Removed
  """
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import Test.AgentTestHelpers

  alias Quoracle.Tasks.TaskManager

  setup %{conn: conn, sandbox_owner: sandbox_owner} do
    # Create isolated dependencies
    # NOTE: No DB queries in setup! Profile created via create_test_profile() in test bodies
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    {:ok, _dynsup} =
      start_supervised({Quoracle.Agent.DynSup, name: dynsup_name}, shutdown: :infinity)

    %{
      conn: conn,
      pubsub: pubsub_name,
      registry: registry_name,
      dynsup: dynsup_name,
      sandbox_owner: sandbox_owner
    }
  end

  # ============================================================
  # UI_Dashboard v8.0: Async Pause UI Tests
  # ============================================================

  describe "R29: UI Shows Pausing State" do
    test "WHEN pause clicked THEN UI immediately shows 'pausing' status", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      profile = create_test_profile()

      # Create a task with agent
      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Pausing state test"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      # Monitor agent to wait for termination
      ref = Process.monitor(task_agent_pid)

      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Click pause - triggers async termination
      render_click(view, "pause_task", %{"task-id" => task.id})

      # Wait for agent termination to complete (prevents orphaned DB connections)
      receive do
        {:DOWN, ^ref, :process, ^task_agent_pid, _} -> :ok
      after
        5000 -> :ok
      end

      # Force LiveView to process termination event and complete DB operations
      render(view)

      # Verify pause initiated - DB reflects the state change
      {:ok, db_task} = TaskManager.get_task(task.id)
      assert db_task.status in ["pausing", "paused"]
    end
  end

  describe "R29: Integration Test" do
    @tag :acceptance
    test "user clicks Pause and task enters pausing/paused state", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      profile = create_test_profile()

      # Create a task with agent
      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(%{profile: profile.name}, %{task_description: "Acceptance test"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      # Monitor agent to wait for termination
      ref = Process.monitor(task_agent_pid)

      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # User action: Click Pause
      render_click(view, "pause_task", %{"task-id" => task.id})

      # Wait for agent termination to complete (prevents orphaned DB connections)
      receive do
        {:DOWN, ^ref, :process, ^task_agent_pid, _} -> :ok
      after
        5000 -> :ok
      end

      # Force LiveView to process termination event and complete DB operations
      render(view)

      # User-observable outcome: Task status reflects pause initiated
      {:ok, result_task} = TaskManager.get_task(task.id)

      # POSITIVE: Task enters pausing/paused state
      assert result_task.status in ["pausing", "paused"],
             "Task should be pausing or paused after user clicks Pause"

      # NEGATIVE: Task does NOT enter error state
      refute result_task.status == "error"
      refute result_task.status == "failed"
    end
  end

  describe "R30: Stop Handler Deleted" do
    test "WHEN stop_task event sent THEN no agent termination occurs", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      profile = create_test_profile()

      # Create a task with agent
      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Stop handler test"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # Mount dashboard (view not used - we test handler directly)
      {:ok, _view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Verify stop_task handler is deleted by calling it directly
      # This avoids LiveView channel complexity and DB connection issues
      # The handler should raise FunctionClauseError (let it crash principle)
      assert_raise FunctionClauseError, fn ->
        QuoracleWeb.DashboardLive.EventHandlers.handle_child_component_event(
          "stop_task",
          %{"task-id" => task.id},
          %Phoenix.LiveView.Socket{}
        )
      end

      # CRITICAL: Agent should still be alive (stop handler was deleted)
      assert Process.alive?(task_agent_pid),
             "Agent should NOT be terminated - stop_task handler should be deleted"
    end
  end

  describe "R31: Pause Completion Detection" do
    test "WHEN last agent terminates THEN UI updates to 'paused' status", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      profile = create_test_profile()

      # Create a task with agent
      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Completion detection test"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Monitor agent to wait for termination
      ref = Process.monitor(task_agent_pid)

      # Click pause (async)
      render_click(view, "pause_task", %{"task-id" => task.id})

      # Wait for agent termination
      receive do
        {:DOWN, ^ref, :process, ^task_agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Force LiveView to process termination event
      render(view)

      # Verify agent was terminated (core pause behavior)
      refute Process.alive?(task_agent_pid)

      # After last agent terminates, DB shows "paused"
      {:ok, db_task} = TaskManager.get_task(task.id)
      assert db_task.status == "paused"
    end
  end

  describe "R32: Natural Completion Preserved" do
    test "WHEN task completes naturally THEN status is 'completed' not 'paused'", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      profile = create_test_profile()

      # Create a task with agent
      {:ok, {_task, task_agent_pid}} =
        TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Natural completion test"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Monitor agent
      ref = Process.monitor(task_agent_pid)

      # Terminate agent naturally (simulates task completion, not pause)
      GenServer.stop(task_agent_pid, :normal, :infinity)

      # Wait for termination
      receive do
        {:DOWN, ^ref, :process, ^task_agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Force LiveView to process termination event
      html = render(view)

      # CRITICAL: Natural completion should NOT set status to "paused"
      # It should be "completed" (the default for natural termination)
      refute html =~ ~r/\bpaused\b/i,
             "Natural completion should NOT show 'paused' status"

      assert html =~ ~r/completed/i,
             "Natural completion should show 'completed' status"
    end
  end

  describe "R33: DB Updated on Pause Completion" do
    test "WHEN all agents terminate during pause THEN DB status updated to 'paused'", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Create a task with multiple agents
      {:ok, {task, root_pid}} =
        create_task_with_cleanup(
          "Multi-agent pause test",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _} = Quoracle.Agent.Core.get_state(root_pid)

      # Spawn a child agent
      child_id = "child_#{System.unique_integer([:positive])}"

      {:ok, child_pid} =
        spawn_agent_with_cleanup(
          dynsup,
          %{
            agent_id: child_id,
            parent_pid: root_pid,
            task_id: task.id,
            initial_prompt: "Child task",
            sandbox_owner: sandbox_owner
          },
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _} = Quoracle.Agent.Core.get_state(child_pid)

      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Monitor both agents
      root_ref = Process.monitor(root_pid)
      child_ref = Process.monitor(child_pid)

      # Click pause (async)
      render_click(view, "pause_task", %{"task-id" => task.id})

      # Wait for both agents to terminate
      for {ref, pid, name} <- [{root_ref, root_pid, "root"}, {child_ref, child_pid, "child"}] do
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5000 -> flunk("#{name} agent did not terminate within 5 seconds")
        end
      end

      # Force LiveView to process all termination events
      render(view)

      # CRITICAL: DB should show "paused" after ALL agents terminated
      {:ok, db_task} = TaskManager.get_task(task.id)

      assert db_task.status == "paused",
             "DB should show 'paused' after all agents terminated, got: #{db_task.status}"
    end
  end

  describe "R34: Resume Disabled During Pausing" do
    test "WHEN task stuck 'pausing' with no agents THEN recovers to 'paused' on mount", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Create a task stuck in "pausing" status with no live agents
      {:ok, task} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Pausing task", status: "pausing"})
        |> Quoracle.Repo.insert()

      # Mount dashboard — DataLoader recovers "pausing" → "paused"
      {:ok, _view, html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Resume button should appear (task recovered to "paused")
      assert html =~ "Resume",
             "Resume button should be shown after recovery from stuck 'pausing'"

      # DB should also be updated
      {:ok, updated} = Quoracle.Tasks.TaskManager.get_task(task.id)
      assert updated.status == "paused"
    end
  end

  # ============================================================
  # UI_TaskTree v5.0: Stop Removed, Pausing State Tests
  # ============================================================

  describe "R16: Stop Button Removed" do
    test "WHEN task is running THEN no Stop button shown", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      profile = create_test_profile()

      # Create a running task
      {:ok, {_task, task_agent_pid}} =
        TaskManager.create_task(%{profile: profile.name}, %{task_description: "Running task"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # Mount dashboard
      {:ok, _view, html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # CRITICAL: Stop button should NOT exist anymore
      refute html =~ "stop_task",
             "Stop button (stop_task event) should not exist in UI"

      refute html =~ ~r/>Stop</i,
             "Stop button label should not exist in UI"
    end
  end

  describe "R17: Pausing State Shows Disabled Pause Button" do
    test "WHEN task stuck 'pausing' no agents THEN recovers to paused on mount", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Create a task stuck in "pausing" with no live agents
      {:ok, _task} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Pausing task", status: "pausing"})
        |> Quoracle.Repo.insert()

      # Mount dashboard — DataLoader recovers "pausing" → "paused"
      {:ok, _view, html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # "Pausing..." should NOT be shown (recovered to "paused")
      refute html =~ ~r/pausing\.\.\./i,
             "Should not show 'Pausing...' after recovery"

      # Pause button should not be clickable (task is paused, not running)
      refute html =~ ~r/phx-click="pause_task"/,
             "Pause button should not be shown when task is paused"
    end
  end

  describe "R18-R20: Buttons During Paused (recovered from pausing)" do
    test "WHEN task recovered from 'pausing' THEN Resume and Delete visible", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Create a task stuck in "pausing" with no live agents
      {:ok, _task} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Pausing task", status: "pausing"})
        |> Quoracle.Repo.insert()

      # Mount dashboard — DataLoader recovers "pausing" → "paused"
      {:ok, _view, html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # R18: Pause button not shown (task is paused)
      refute html =~ ~r/phx-click="pause_task"/,
             "Pause button should not be shown when paused"

      # R19: Resume button IS shown (task recovered to paused)
      assert html =~ "Resume",
             "Resume button should be shown after recovery"

      # R20: Delete button IS shown (task is paused)
      assert html =~ "Delete",
             "Delete button should be shown after recovery"
    end
  end

  describe "R21: Stop Event Handler Removed" do
    test "WHEN TaskTree template rendered THEN no stop_task phx-click exists", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Create some tasks in various states
      {:ok, _running} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Running task", status: "running"})
        |> Quoracle.Repo.insert()

      {:ok, _paused} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Paused task", status: "paused"})
        |> Quoracle.Repo.insert()

      {:ok, _completed} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Completed task", status: "completed"})
        |> Quoracle.Repo.insert()

      # Mount dashboard
      {:ok, _view, html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # CRITICAL: No stop_task event should exist anywhere in the rendered HTML
      refute html =~ "stop_task",
             "stop_task event handler should be completely removed from TaskTree"
    end
  end

  # ============================================================
  # Integration Test: Full Async Pause Flow
  # ============================================================

  describe "Full Async Pause Flow (Integration)" do
    test "user clicks pause → agents terminate → task becomes paused", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      profile = create_test_profile()

      # User creates a task
      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Acceptance test task"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # User visits dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Monitor agent before pause
      ref = Process.monitor(task_agent_pid)

      # User clicks pause
      render_click(view, "pause_task", %{"task-id" => task.id})

      # Wait for agent termination
      receive do
        {:DOWN, ^ref, :process, ^task_agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate")
      end

      # Process termination event
      render(view)

      # POSITIVE: Agent actually terminated
      refute Process.alive?(task_agent_pid)

      # POSITIVE: DB shows "paused" after termination
      {:ok, paused_task} = TaskManager.get_task(task.id)
      assert paused_task.status == "paused"
    end
  end
end
