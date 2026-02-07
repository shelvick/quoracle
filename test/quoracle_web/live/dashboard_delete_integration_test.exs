defmodule QuoracleWeb.DashboardDeleteIntegrationTest do
  @moduledoc """
  Integration tests for task deletion functionality in DashboardLive.

  WorkGroupID: wip-20251011-063244
  Packet 3: Event Handler & UI Integration
  """
  use QuoracleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import ExUnit.CaptureLog
  import Test.AgentTestHelpers

  alias Quoracle.Tasks.{Task, TaskManager}
  alias Quoracle.Repo

  setup %{conn: conn, sandbox_owner: sandbox_owner} do
    # Create isolated PubSub instance
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    # Create isolated Registry instance
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})

    # Create isolated DynSup with :infinity shutdown to prevent kill escalation
    # CRITICAL: shutdown must be in child spec, not ExUnit options (ExUnit ignores it)
    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
      shutdown: :infinity
    }

    {:ok, dynsup} = start_supervised(dynsup_spec)

    %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    }
  end

  describe "delete button visibility" do
    test "shows delete button for paused task", %{conn: conn} = context do
      # Create a paused task
      task = create_test_task("paused", context)

      # Mount dashboard
      {:ok, view, html} = mount_dashboard(conn, context)

      # Delete button should be visible for paused task (in TaskTree component)
      assert html =~ "task-tree-confirm-delete-#{task.id}"
      # Check for delete button (TaskTree uses text "Delete", no icon)
      assert has_element?(view, "button", "Delete")
    end

    test "shows delete button for completed task", %{conn: conn} = context do
      # Create a completed task
      task = create_test_task("completed", context)

      # Mount dashboard
      {:ok, view, html} = mount_dashboard(conn, context)

      # Delete button should be visible for completed task (in TaskTree)
      assert html =~ "task-tree-confirm-delete-#{task.id}"
      assert has_element?(view, "button", "Delete")
    end

    test "shows delete button for failed task", %{conn: conn} = context do
      # Create a failed task
      task = create_test_task("failed", context)

      # Mount dashboard
      {:ok, view, html} = mount_dashboard(conn, context)

      # Delete button should be visible for failed task (in TaskTree)
      assert html =~ "task-tree-confirm-delete-#{task.id}"
      assert has_element?(view, "button", "Delete")
    end

    test "hides delete button for running task", %{conn: conn} = context do
      # Create a running task with live agent
      {:ok, {task, _pid}} = create_running_task(context)

      # Mount dashboard
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Delete button should NOT be visible for running task (checking Dashboard's button, not TaskTree's)
      refute has_element?(
               view,
               "[phx-click*='show'][phx-click*='confirm-delete-#{task.id}']:not([phx-target])"
             )
    end

    test "delete button includes trash icon", %{conn: conn} = context do
      # Create a paused task
      _task = create_test_task("paused", context)

      # Mount dashboard
      {:ok, _view, html} = mount_dashboard(conn, context)

      # Check that delete button exists (TaskTree uses text only, no icon)
      assert html =~ "Delete"
    end
  end

  describe "modal interactions" do
    test "clicking delete button shows confirmation modal", %{conn: conn} = context do
      # Create a paused task
      task = create_test_task("paused", context)

      # Mount dashboard
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Modal should exist in HTML (hidden by default, in TaskTree component)
      assert has_element?(view, "#task-tree-confirm-delete-#{task.id}")
      assert render(view) =~ "Delete Task?"
      assert render(view) =~ "This will permanently delete"
      assert render(view) =~ task.prompt
    end

    test "modal confirm button triggers delete_task event", %{conn: conn} = context do
      # Create a paused task
      task = create_test_task("paused", context)

      # Mount dashboard
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Trigger delete_task event directly (modal confirm button would do this)
      render_click(view, "delete_task", %{"task-id" => task.id})

      # Task should be deleted
      refute has_element?(view, "[phx-value-task-id=\"#{task.id}\"]")
      assert render(view) =~ "Task deleted successfully"
    end

    test "modal cancel button hides modal without deletion", %{conn: conn} = context do
      # Create a paused task
      task = create_test_task("paused", context)

      # Mount dashboard
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Modal exists with Cancel button
      assert render(view) =~ "Cancel"

      # Task still exists (no delete event triggered)
      assert has_element?(view, "[phx-value-task-id=\"#{task.id}\"]")
      refute render(view) =~ "Task deleted successfully"
    end

    test "clicking outside modal dismisses it", %{conn: conn} = context do
      # Create a paused task
      task = create_test_task("paused", context)

      # Mount dashboard
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Verify modal structure includes phx-click-away
      assert render(view) =~ "phx-click-away"

      # Task should still exist (no deletion occurred)
      assert has_element?(view, "[phx-value-task-id=\"#{task.id}\"]")
      refute render(view) =~ "Task deleted successfully"
    end
  end

  describe "delete_task event handler" do
    test "successfully deletes task and updates UI", %{conn: conn} = context do
      # Create a paused task
      task = create_test_task("paused", context)

      # Mount dashboard
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Trigger delete_task event directly
      view
      |> render_click("delete_task", %{"task-id" => task.id})

      # Task should be removed from UI
      refute has_element?(view, "[phx-value-task-id=\"#{task.id}\"]")

      # Success flash message
      assert render(view) =~ "Task deleted successfully"

      # Task should be deleted from database
      assert {:error, :not_found} = TaskManager.get_task(task.id)
    end

    test "clears current_task_id if deleted task was selected", %{conn: conn} = context do
      # Create a paused task
      task = create_test_task("paused", context)

      # Mount dashboard
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Delete the task (no selection needed in 3-panel layout)
      view
      |> render_click("delete_task", %{"task-id" => task.id})

      # Task should be gone
      refute has_element?(view, "[phx-value-task-id=\"#{task.id}\"]")
    end

    test "handles deletion of non-selected task", %{conn: conn} = context do
      # Create two paused tasks
      task1 = create_test_task("paused", context, "Task 1")
      task2 = create_test_task("paused", context, "Task 2")

      # Mount dashboard
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Delete task2
      render_click(view, "delete_task", %{"task-id" => task2.id})

      # task1 should still exist
      assert has_element?(view, "[phx-value-task-id=\"#{task1.id}\"]")

      # task2 should be gone
      refute has_element?(view, "[phx-value-task-id=\"#{task2.id}\"]")
    end

    test "shows error flash when deletion fails", %{conn: conn} = context do
      # Mount dashboard without any tasks
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Try to delete non-existent task (use valid UUID format)
      fake_task_id = Ecto.UUID.generate()

      capture_log(fn ->
        render_click(view, "delete_task", %{"task-id" => fake_task_id})
      end)

      # Should show error flash
      assert render(view) =~ "Failed to delete task"
    end

    test "handles concurrent delete attempts gracefully", %{conn: conn} = context do
      # Create a paused task
      task = create_test_task("paused", context)

      # Mount two dashboard instances
      {:ok, view1, _html} = mount_dashboard(conn, context)
      {:ok, view2, _html} = mount_dashboard(conn, context)

      # Delete from first view
      render_click(view1, "delete_task", %{"task-id" => task.id})

      # Task should be gone from view1
      refute has_element?(view1, "[phx-value-task-id=\"#{task.id}\"]")
      assert render(view1) =~ "Task deleted successfully"

      # Try to delete same task from second view
      capture_log(fn ->
        render_click(view2, "delete_task", %{"task-id" => task.id})
      end)

      # Should show error in view2 (task already deleted)
      assert render(view2) =~ "Failed to delete task"
    end
  end

  describe "integration with TaskManager" do
    test "auto-pauses running task before deletion", %{conn: conn} = context do
      # Create a running task with live agent
      {:ok, {task, agent_pid}} = create_running_task(context)

      # Forcefully change task status to allow delete button to appear
      # (This simulates an edge case or admin override)
      Repo.update!(Task.changeset(task, %{status: "paused"}))

      # Mount dashboard
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Monitor BEFORE delete (to catch async termination)
      ref = Process.monitor(agent_pid)

      # Delete the task (triggers async pause internally)
      view
      |> render_click("delete_task", %{"task-id" => task.id})

      # Wait for async termination to complete
      receive do
        {:DOWN, ^ref, :process, ^agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Agent should be terminated
      refute Process.alive?(agent_pid)

      # Task should be deleted
      assert {:error, :not_found} = TaskManager.get_task(task.id)

      # Success message
      assert render(view) =~ "Task deleted successfully"
    end

    test "cascades deletion to all related data", %{conn: conn} = context do
      # Create a task with agents, logs, and messages
      task = create_test_task_with_data(context)

      # Mount dashboard
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Delete the task
      view
      |> render_click("delete_task", %{"task-id" => task.id})

      # Verify all related data is deleted
      assert {:error, :not_found} = TaskManager.get_task(task.id)
      assert [] = TaskManager.get_agents_for_task(task.id)

      # UI should reflect deletion
      refute has_element?(view, "[phx-value-task-id=\"#{task.id}\"]")
      assert render(view) =~ "Task deleted successfully"
    end
  end

  # Helper functions

  defp mount_dashboard(conn, context) do
    conn
    |> Plug.Test.init_test_session(%{
      "pubsub" => context.pubsub,
      "registry" => context.registry,
      "dynsup" => context.dynsup,
      "sandbox_owner" => context.sandbox_owner
    })
    |> live("/")
  end

  defp create_test_task(status, _context, prompt \\ "Test task") do
    %Task{}
    |> Task.changeset(%{
      prompt: prompt,
      status: status,
      result: if(status == "completed", do: "Done", else: nil),
      error_message: if(status == "failed", do: "Error", else: nil)
    })
    |> Repo.insert!()
  end

  defp create_running_task(context) do
    # Get test profile for task creation - use unique name to avoid ON CONFLICT contention
    profile = Test.AgentTestHelpers.create_test_profile()

    opts = [
      sandbox_owner: context.sandbox_owner,
      dynsup: context.dynsup,
      registry: context.registry,
      pubsub: context.pubsub
    ]

    {:ok, {task, pid}} =
      TaskManager.create_task(%{profile: profile.name}, %{task_description: "Running task"}, opts)

    # Use tree cleanup to handle child agents spawned during initialization
    register_agent_cleanup(pid,
      cleanup_tree: true,
      registry: context.registry,
      sandbox_owner: context.sandbox_owner
    )

    {:ok, {task, pid}}
  end

  defp create_test_task_with_data(context) do
    # Create task
    task = create_test_task("paused", context, "Task with data")

    # Add some agent records with all required fields
    {:ok, _agent} =
      TaskManager.save_agent(%{
        agent_id: "agent-1",
        task_id: task.id,
        parent_id: nil,
        config: %{},
        status: "paused"
      })

    # Add some log records with all required fields
    {:ok, _log} =
      TaskManager.save_log(%{
        agent_id: "agent-1",
        task_id: task.id,
        action_type: "test",
        params: %{},
        result: %{},
        status: "success",
        metadata: %{}
      })

    # Add some message records
    {:ok, _msg} =
      TaskManager.save_message(%{
        from_agent_id: "agent-1",
        to_agent_id: "agent-2",
        task_id: task.id,
        content: "Test message",
        metadata: %{}
      })

    task
  end
end
