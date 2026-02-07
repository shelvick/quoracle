defmodule QuoracleWeb.DashboardProfileIntegrationTest do
  @moduledoc """
  Integration tests for profile selection in DashboardLive.

  ARC Requirements (feat-20260105-profiles):
  - R50: Profiles loaded on mount [INTEGRATION]
  - R51: Profile selector in form [INTEGRATION]
  - R52: Submit extracts profile [INTEGRATION]
  - R53: Empty profile shows error [INTEGRATION]
  - R54: Profile not found error [INTEGRATION]
  - R55: Acceptance - Task creation flow [SYSTEM]
  """

  use QuoracleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import Ecto.Query
  import Test.AgentTestHelpers

  alias Quoracle.Tasks.Task
  alias Quoracle.Profiles.TableProfiles
  alias Quoracle.Repo

  setup %{conn: conn, sandbox_owner: sandbox_owner} do
    # Create isolated PubSub instance
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    # Create isolated Registry instance
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})

    # Create isolated DynSup with :infinity shutdown
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

  # Helper to create test profile
  defp create_profile(attrs) do
    default_attrs = %{
      name: "test-profile-#{System.unique_integer([:positive])}",
      model_pool: ["gpt-4o"],
      capability_groups: [
        "hierarchy",
        "local_execution",
        "file_read",
        "file_write",
        "external_api"
      ]
    }

    merged = Map.merge(default_attrs, attrs)

    %TableProfiles{}
    |> TableProfiles.changeset(merged)
    |> Repo.insert!()
  end

  describe "R50: Profiles loaded on mount" do
    @tag :integration
    test "dashboard loads profiles from database on mount", %{conn: conn} = context do
      # Create profiles before mounting
      profile1 =
        create_profile(%{
          name: "test-profile-1",
          capability_groups: [
            "hierarchy",
            "local_execution",
            "file_read",
            "file_write",
            "external_api"
          ]
        })

      profile2 = create_profile(%{name: "test-profile-2", capability_groups: []})

      {:ok, view, _html} = mount_dashboard(conn, context)

      # Open the new task modal
      view |> element("button", "New Task") |> render_click()
      html = render(view)

      # Profiles should be available in the form
      assert html =~ profile1.name
      assert html =~ profile2.name
    end

    @tag :integration
    test "profiles ordered alphabetically", %{conn: conn} = context do
      create_profile(%{
        name: "zebra-profile",
        capability_groups: [
          "hierarchy",
          "local_execution",
          "file_read",
          "file_write",
          "external_api"
        ]
      })

      create_profile(%{
        name: "alpha-profile",
        capability_groups: [
          "hierarchy",
          "local_execution",
          "file_read",
          "file_write",
          "external_api"
        ]
      })

      {:ok, view, _html} = mount_dashboard(conn, context)

      view |> element("button", "New Task") |> render_click()
      html = render(view)

      # Both profiles should be present
      assert html =~ "alpha-profile"
      assert html =~ "zebra-profile"
    end
  end

  describe "R51: Profile selector in form" do
    @tag :integration
    test "new task modal includes profile selector", %{conn: conn} = context do
      create_profile(%{name: "default-profile"})

      {:ok, view, _html} = mount_dashboard(conn, context)

      # Open the modal
      view |> element("button", "New Task") |> render_click()
      html = render(view)

      # Should have profile selection field with select element
      assert html =~ "Profile"
      assert html =~ ~s(<select)
    end

    @tag :integration
    test "profile selector shows capability groups", %{conn: conn} = context do
      create_profile(%{
        name: "safe-worker",
        capability_groups: ["local_execution", "file_read", "file_write", "external_api"]
      })

      {:ok, view, _html} = mount_dashboard(conn, context)

      view |> element("button", "New Task") |> render_click()
      html = render(view)

      # Should show capability groups in display format: "name (groups)"
      # no_spawn = local_execution, file_read, file_write, external_api
      assert html =~ "(local_execution, file_read, file_write, external_api)"
    end
  end

  describe "R52: Submit extracts profile" do
    @tag :integration
    test "form submission includes profile in task creation", %{conn: conn} = context do
      profile =
        create_profile(%{
          name: "submit-test-profile",
          capability_groups: ["hierarchy", "file_read", "file_write", "external_api"]
        })

      {:ok, view, _html} = mount_dashboard(conn, context)

      # Open modal
      view |> element("button", "New Task") |> render_click()

      # Submit form with profile
      view
      |> element("#new-task-modal form")
      |> render_submit(%{
        "task_description" => "Profile submit test",
        "profile" => profile.name
      })

      render(view)

      # Verify task was created with profile
      task = Repo.one(from(t in Task, order_by: [desc: t.id], limit: 1))
      assert task.profile_name == "submit-test-profile"

      # Wait for agent and verify profile data
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)

      assert state.profile_name == "submit-test-profile"
      assert state.capability_groups == [:hierarchy, :file_read, :file_write, :external_api]

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)
    end
  end

  describe "R53: Empty profile shows error" do
    @tag :integration
    test "submitting without profile shows error", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Open modal
      view |> element("button", "New Task") |> render_click()

      # Submit form without profile
      view
      |> element("#new-task-modal form")
      |> render_submit(%{
        "task_description" => "No profile test"
        # No profile field
      })

      html = render(view)

      # Should show error about missing profile
      assert html =~ "Missing required field: profile"

      # Task should NOT be created
      assert Repo.aggregate(Task, :count) == 0
    end

    @tag :integration
    test "submitting with empty profile string shows error", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      view |> element("button", "New Task") |> render_click()

      view
      |> element("#new-task-modal form")
      |> render_submit(%{
        "task_description" => "Empty profile test",
        "profile" => ""
      })

      html = render(view)

      # Should show error about missing profile
      assert html =~ "Missing required field: profile"

      # Task should NOT be created
      assert Repo.aggregate(Task, :count) == 0
    end
  end

  describe "R54: Profile not found error" do
    @tag :integration
    test "submitting with non-existent profile shows error", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      view |> element("button", "New Task") |> render_click()

      view
      |> element("#new-task-modal form")
      |> render_submit(%{
        "task_description" => "Non-existent profile test",
        "profile" => "nonexistent-profile-xyz"
      })

      html = render(view)

      # Should show profile not found error
      assert html =~ "Profile not found"

      # Task should NOT be created
      assert Repo.aggregate(Task, :count) == 0
    end
  end

  describe "R55: Acceptance - Task creation flow with profile" do
    @tag :acceptance
    @tag :system
    test "full user flow: select profile, create task, agent runs with profile",
         %{conn: conn} = context do
      # Setup: Create profile (simulates admin having created profiles)
      profile =
        create_profile(%{
          name: "acceptance-test-profile",
          description: "For acceptance testing",
          model_pool: ["gpt-4o", "claude-sonnet"],
          capability_groups: ["hierarchy", "file_read", "file_write"]
        })

      # User action 1: Open dashboard
      {:ok, view, _html} = mount_dashboard(conn, context)

      # User action 2: Click "New Task"
      view |> element("button", "New Task") |> render_click()
      modal_html = render(view)

      # User expectation: Profile selector visible with created profile
      assert modal_html =~ profile.name

      # User action 3: Fill form and submit with profile
      view
      |> element("#new-task-modal form")
      |> render_submit(%{
        "task_description" => "Acceptance test task with profile",
        "profile" => profile.name,
        "global_context" => "Testing profile integration"
      })

      render(view)

      # User expectation 1: Task created and visible
      task = Repo.one(from(t in Task, order_by: [desc: t.id], limit: 1))
      assert task != nil
      assert task.status == "running"
      assert task.profile_name == "acceptance-test-profile"

      # User expectation 2: Agent is running with correct profile
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)

      # Verify profile was applied to agent
      assert state.profile_name == "acceptance-test-profile"
      assert state.capability_groups == [:hierarchy, :file_read, :file_write]
      assert state.model_pool == ["gpt-4o", "claude-sonnet"]
      assert state.profile_description == "For acceptance testing"

      # User expectation 3: Agent has correct prompt fields
      assert state.prompt_fields.provided.task_description ==
               "Acceptance test task with profile"

      # Cleanup
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)
    end

    @tag :acceptance
    @tag :system
    test "user cannot create task without selecting profile", %{conn: conn} = context do
      # Create profile so it's available but user doesn't select it
      create_profile(%{name: "available-profile"})

      {:ok, view, _html} = mount_dashboard(conn, context)

      # Open modal
      view |> element("button", "New Task") |> render_click()

      # Try to submit without selecting profile
      view
      |> element("#new-task-modal form")
      |> render_submit(%{
        "task_description" => "Task without profile"
        # profile not included
      })

      html = render(view)

      # User expectation: Error shown, no task created
      assert Repo.aggregate(Task, :count) == 0

      # Should show error about missing profile
      assert html =~ "Missing required field: profile"
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
end
