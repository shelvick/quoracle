defmodule QuoracleWeb.DashboardCreateTaskIntegrationTest do
  @moduledoc """
  Integration tests for task creation functionality in DashboardLive.
  Tests the complete flow: open modal → fill form → submit → verify task created.
  """
  use QuoracleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import Ecto.Query
  import Test.AgentTestHelpers

  alias Quoracle.Tasks.Task
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

    # Create test profile for task creation tests - use unique name to avoid ON CONFLICT contention
    profile = create_test_profile()

    %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner,
      profile: profile
    }
  end

  describe "task creation behavior" do
    test "submitting form creates task in database", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Initial task count
      initial_count = Repo.aggregate(Task, :count)

      # Open the modal
      view |> element("button", "New Task") |> render_click()

      # Submit the form with a prompt
      view
      |> element("#new-task-modal form")
      |> render_submit(%{
        "task_description" => "Build a web scraper",
        "profile" => context.profile.name
      })

      # Process the {:submit_prompt, prompt} message from TaskTree to DashboardLive
      render(view)

      # Verify task was created in DB
      assert Repo.aggregate(Task, :count) == initial_count + 1

      # Verify task has correct prompt
      task = Repo.one(from(t in Task, order_by: [desc: t.id], limit: 1))
      assert task.prompt == "Build a web scraper"
      assert task.status == "running"

      # CRITICAL: Wait for agent and register cleanup (3-step pattern)
      root_agent_id = "root-#{task.id}"

      # Wait for agent to appear in registry
      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      # CRITICAL: Wait for agent initialization to complete (includes DB setup)
      # Without this, test cleanup can race with handle_continue(:complete_db_setup)
      # causing "client exited" Postgrex errors when sandbox_owner dies mid-DB-operation
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)
    end

    test "submitting form does not crash (verifies FunctionClauseError fix)",
         %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      # This used to crash with FunctionClauseError because modal button sent %{"value" => ""}
      # instead of %{"prompt" => "text"}. Now form submit button sends correct params.
      # Open the modal
      view |> element("button", "New Task") |> render_click()

      view
      |> element("#new-task-modal form")
      |> render_submit(%{"task_description" => "Test task", "profile" => context.profile.name})

      # Process the message
      html = render(view)

      # Should not crash and return HTML
      assert html =~ "task-tree"

      # Task should be created
      task = Repo.one(from(t in Task, order_by: [desc: t.id], limit: 1))
      assert task.prompt == "Test task"

      # CRITICAL: Wait for agent and register cleanup (3-step pattern)
      root_agent_id = "root-#{task.id}"

      # Wait for agent to appear in registry
      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      # CRITICAL: Wait for agent initialization to complete (includes DB setup)
      # Without this, test cleanup can race with handle_continue(:complete_db_setup)
      # causing "client exited" Postgrex errors when sandbox_owner dies mid-DB-operation
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)
    end

    test "form submission handles special characters in prompt", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      special_prompt = "Task with \"quotes\" and 'apostrophes' & symbols <>"

      # Open the modal
      view |> element("button", "New Task") |> render_click()

      view
      |> element("#new-task-modal form")
      |> render_submit(%{"task_description" => special_prompt, "profile" => context.profile.name})

      # Process message
      render(view)

      # Verify task created with exact prompt
      task = Repo.one(from(t in Task, order_by: [desc: t.id], limit: 1))
      assert task.prompt == special_prompt

      # CRITICAL: Wait for agent and register cleanup (3-step pattern)
      root_agent_id = "root-#{task.id}"

      # Wait for agent to appear in registry
      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      # CRITICAL: Wait for agent initialization to complete (includes DB setup)
      # Without this, test cleanup can race with handle_continue(:complete_db_setup)
      # causing "client exited" Postgrex errors when sandbox_owner dies mid-DB-operation
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)
    end

    test "can create multiple tasks sequentially", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Create first task
      # Open the modal
      view |> element("button", "New Task") |> render_click()

      view
      |> element("#new-task-modal form")
      |> render_submit(%{"task_description" => "First task", "profile" => context.profile.name})

      render(view)

      # Create second task
      # Open the modal
      view |> element("button", "New Task") |> render_click()

      view
      |> element("#new-task-modal form")
      |> render_submit(%{"task_description" => "Second task", "profile" => context.profile.name})

      render(view)

      # Verify both tasks exist in DB
      tasks = Repo.all(from(t in Task, order_by: [desc: t.id], limit: 2))
      assert length(tasks) == 2

      prompts = Enum.map(tasks, & &1.prompt)
      assert "First task" in prompts
      assert "Second task" in prompts

      # CRITICAL: Wait for agents and ALWAYS register cleanup (3-step pattern)
      Enum.each(["First task", "Second task"], fn prompt ->
        task = Repo.one(from(t in Task, where: t.prompt == ^prompt))
        root_agent_id = "root-#{task.id}"

        # Wait for agent to appear in registry
        {:ok, agent_pid} =
          wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

        # CRITICAL: Wait for agent initialization to complete (includes DB setup)
        assert {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)

        register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)
      end)
    end

    test "handles very long prompt", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Create 10KB prompt
      long_prompt = String.duplicate("a", 10_000)

      # Open the modal
      view |> element("button", "New Task") |> render_click()

      view
      |> element("#new-task-modal form")
      |> render_submit(%{"task_description" => long_prompt, "profile" => context.profile.name})

      render(view)

      # Should create task with full prompt
      task = Repo.one(from(t in Task, order_by: [desc: t.id], limit: 1))
      assert task.prompt == long_prompt
      assert String.length(task.prompt) == 10_000

      # CRITICAL: Wait for agent and register cleanup (3-step pattern)
      root_agent_id = "root-#{task.id}"

      # Wait for agent to appear in registry
      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      # CRITICAL: Wait for agent initialization to complete (includes DB setup)
      # Without this, test cleanup can race with handle_continue(:complete_db_setup)
      # causing "client exited" Postgrex errors when sandbox_owner dies mid-DB-operation
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)
    end

    # R13: Dashboard FieldProcessor Integration - SYSTEM
    test "dashboard uses FieldProcessor for multi-field form submission",
         %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Open modal
      view |> element("button", "New Task") |> render_click()

      # Submit form with multiple fields (new hierarchical field system)
      view
      |> element("#new-task-modal form")
      |> render_submit(%{
        "task_description" => "Build feature",
        "profile" => context.profile.name,
        "role" => "Developer",
        "success_criteria" => "Tests pass",
        "cognitive_style" => "systematic"
      })

      render(view)

      # Verify task was created
      tasks = Repo.all(Task)
      assert length(tasks) == 1
      task = hd(tasks)

      # Verify agent was created with prompt_fields
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)

      # Verify all fields were passed through
      assert state.prompt_fields.provided.task_description == "Build feature"
      assert state.prompt_fields.provided.role == "Developer"
      assert state.prompt_fields.provided.success_criteria == "Tests pass"
      assert state.prompt_fields.provided.cognitive_style == :systematic

      # CRITICAL: Verify prompts were converted (not just fields stored)
      assert state.system_prompt != nil, "system_prompt should be converted from fields"
      assert state.system_prompt =~ "<role>Developer</role>"

      # task_description flows through history, not user_prompt
      assert state.prompt_fields.provided.task_description == "Build feature",
             "task_description should be in prompt_fields.provided"

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)
    end

    # R14: Dashboard Field Validation - SYSTEM
    test "dashboard validates enum fields and shows errors", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Open modal
      view |> element("button", "New Task") |> render_click()

      # Submit form with invalid enum value
      view
      |> element("#new-task-modal form")
      |> render_submit(%{
        "task_description" => "Test",
        "profile" => context.profile.name,
        "cognitive_style" => "invalid_style"
      })

      # Render full view to see flash message
      html = render(view)

      # CRITICAL: Should show FieldProcessor's specific enum validation error
      assert html =~ "Invalid value for cognitive_style",
             "FieldProcessor should validate enum values and show specific error"

      assert html =~ "Valid options:",
             "FieldProcessor should list valid enum values"

      # Task should NOT be created when validation fails
      assert Repo.aggregate(Task, :count) == 0
    end

    # R15: Dashboard Missing Required Field - SYSTEM
    test "dashboard rejects submission with missing required field", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Open modal
      view |> element("button", "New Task") |> render_click()

      # Submit form without task_description (required field)
      view
      |> element("#new-task-modal form")
      |> render_submit(%{
        "profile" => context.profile.name,
        "role" => "Developer"
      })

      # Render full view to see flash message
      html = render(view)

      # CRITICAL: Should show FieldProcessor's specific required field error
      assert html =~ "Missing required field: task_description",
             "FieldProcessor should validate required fields and show specific error"

      # Task should NOT be created
      assert Repo.aggregate(Task, :count) == 0
    end

    # R16: Dashboard Global Fields Integration - SYSTEM
    test "dashboard passes global fields to task record", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Open modal
      view |> element("button", "New Task") |> render_click()

      # Submit form with global fields
      view
      |> element("#new-task-modal form")
      |> render_submit(%{
        "task_description" => "Build microservice",
        "profile" => context.profile.name,
        "global_context" => "E-commerce platform project",
        "global_constraints" => "Use approved libraries, Follow security guidelines"
      })

      render(view)

      # Verify task has global fields
      task = Repo.one(from(t in Task, order_by: [desc: t.id], limit: 1))
      assert task.global_context == "E-commerce platform project"

      assert task.initial_constraints == [
               "Use approved libraries",
               "Follow security guidelines"
             ]

      # Verify agent was created
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)
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
