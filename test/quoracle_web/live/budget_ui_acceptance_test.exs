defmodule QuoracleWeb.BudgetUIAcceptanceTest do
  @moduledoc """
  Acceptance tests for Budget UI feature.

  All tests start from "/" route and verify via DOM assertions.
  Uses real components with isolated dependencies.
  Sequential execution for deterministic E2E behavior.

  WorkGroupID: feat-20251231-191717
  Packet: Packet 6 (Acceptance Testing)
  """

  # Isolated PubSub/Registry/DynSup per test - safe for async
  use QuoracleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import Ecto.Query
  import Test.AgentTestHelpers

  alias Quoracle.Tasks.Task
  alias Quoracle.Repo

  @moduletag :acceptance

  setup %{conn: conn, sandbox_owner: sandbox_owner} do
    # Create isolated PubSub instance
    pubsub = :"acceptance_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    # Create isolated Registry instance
    registry = :"acceptance_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})

    # Create isolated DynSup manually and unlink so we control shutdown order
    {:ok, dynsup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    Process.unlink(dynsup)

    # Get test profile for task creation - use unique name to avoid ON CONFLICT contention
    profile = create_test_profile()

    # Stop all agents BEFORE sandbox owner dies to prevent DB errors
    # (OTP termination errors are filtered by test_helper.exs Logger filter)
    on_exit(fn ->
      try do
        # First stop all children with :infinity timeout to let them finish DB work
        for {_, pid, _, _} <- DynamicSupervisor.which_children(dynsup) do
          if is_pid(pid) and Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end

        # Then stop the dynsup itself
        DynamicSupervisor.stop(dynsup, :normal, :infinity)
      catch
        # DynSup may already be dead if test process exited
        :exit, _ -> :ok
      end
    end)

    %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner,
      profile: profile
    }
  end

  # Helper to mount dashboard with isolated dependencies
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

  # Helper to create task with budget via UI
  defp create_task_with_budget_via_ui(view, prompt, budget, profile_name) do
    # Open new task modal
    view |> element("button", "New Task") |> render_click()

    # Submit form with budget and profile
    view
    |> form("#new-task-form", %{
      "task_description" => prompt,
      "budget_limit" => budget,
      "profile" => profile_name
    })
    |> render_submit()

    # Process the message
    render(view)
  end

  # Helper to create task without budget via UI
  defp create_task_without_budget_via_ui(view, prompt, profile_name) do
    # Open new task modal
    view |> element("button", "New Task") |> render_click()

    # Submit form without budget but with profile
    view
    |> form("#new-task-form", %{
      "task_description" => prompt,
      "budget_limit" => "",
      "profile" => profile_name
    })
    |> render_submit()

    # Process the message
    render(view)
  end

  # ============================================================
  # R1-R5: Task Creation with Budget
  # ============================================================

  describe "task creation with budget - R1-R5" do
    @tag :r1
    test "R1: new task modal shows budget input field", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # USER ACTION: Open new task modal
      view |> element("button", "New Task") |> render_click()

      # POSITIVE ASSERTION: Budget input field visible
      html = render(view)
      assert html =~ "budget_limit", "Budget input field should be present"
      assert html =~ "Budget", "Budget label should be visible"

      # NEGATIVE ASSERTION: No visible error message (ignore hidden flash containers)
      refute html =~ "Budget Error"
      refute html =~ "Invalid budget"
    end

    @tag :r2
    test "R2: creating task with budget shows budget in task tree", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # USER ACTION: Create task with budget
      create_task_with_budget_via_ui(view, "Test task with budget", "50.00", context.profile.name)

      # Wait for agent and register cleanup
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)

      # POSITIVE ASSERTION: Task shows with budget display
      html = render(view)
      assert html =~ "Test task with budget"
      assert html =~ "$50.00", "Budget should be displayed with dollar sign"
      assert html =~ "task-budget", "Budget display element should exist"

      # NEGATIVE ASSERTION: No error states
      refute html =~ "Budget: N/A"
    end

    @tag :r3
    test "R3: creating task without budget shows no budget limit", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # USER ACTION: Create task without budget
      create_task_without_budget_via_ui(view, "Test task without budget", context.profile.name)

      # Wait for agent and register cleanup
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)

      # POSITIVE ASSERTION: Task shows without budget restriction
      html = render(view)
      assert html =~ "Test task without budget"

      # NEGATIVE ASSERTION: Should show N/A or unlimited, not a dollar amount
      # The task section should not have a specific budget limit displayed
      refute html =~ ~r/\$\d+\.\d+.*Test task without budget/
    end

    @tag :r4
    test "R4: invalid budget format shows error", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # USER ACTION: Try to create task with invalid budget
      view |> element("button", "New Task") |> render_click()

      view
      |> form("#new-task-form", %{
        "task_description" => "Task with invalid budget",
        "profile" => context.profile.name,
        "budget_limit" => "not-a-number"
      })
      |> render_submit()

      # POSITIVE ASSERTION: Error message shown
      html = render(view)

      assert html =~ "Invalid budget format",
             "Should show validation error for invalid budget format"

      # NEGATIVE ASSERTION: Task should NOT be created
      refute Repo.exists?(from(t in Task, where: t.prompt == "Task with invalid budget"))
    end

    @tag :r5
    test "R5: task budget persists to database", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # USER ACTION: Create task with specific budget
      create_task_with_budget_via_ui(
        view,
        "Persistent budget task",
        "75.50",
        context.profile.name
      )

      # Wait for agent and register cleanup
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)

      # POSITIVE ASSERTION: Budget persisted in database
      task = Repo.one(from(t in Task, where: t.prompt == "Persistent budget task"))
      assert task != nil, "Task should exist in database"
      assert task.budget_limit == Decimal.new("75.50"), "Budget should be persisted correctly"

      # NEGATIVE ASSERTION: Budget should not be nil
      refute is_nil(task.budget_limit)
    end
  end

  # ============================================================
  # R6-R9: Budget Display
  # ============================================================

  describe "budget display - R6-R9" do
    @tag :r6
    test "R6: task shows budget summary with progress bar", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # USER ACTION: Create task with budget
      create_task_with_budget_via_ui(
        view,
        "Task for budget display",
        "100.00",
        context.profile.name
      )

      # Wait for agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)

      # POSITIVE ASSERTION: Budget summary visible with progress elements
      html = render(view)

      assert html =~ "task-budget-summary",
             "Budget summary should be visible"

      assert html =~ "$100.00", "Budget limit should be displayed"

      # NEGATIVE ASSERTION: No error states
      refute html =~ "Budget Error"
    end

    @tag :r7
    test "R7: agent shows budget badge in tree", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # USER ACTION: Create task with budget (agent will inherit budget)
      create_task_with_budget_via_ui(view, "Task for agent badge", "80.00", context.profile.name)

      # Wait for agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)

      # POSITIVE ASSERTION: Agent shows budget badge
      html = render(view)

      assert html =~ "budget-badge",
             "Agent should have budget badge"

      # NEGATIVE ASSERTION: No invalid budget display
      refute html =~ "Budget: undefined"
    end

    @tag :r8
    test "R8: budget display updates when cost recorded", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # USER ACTION: Create task with budget
      create_task_with_budget_via_ui(view, "Task for cost update", "50.00", context.profile.name)

      # Wait for agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)

      # Record a cost via the Recorder (use valid cost_type from enum)
      {:ok, _cost} =
        Quoracle.Costs.Recorder.record(
          %{
            task_id: task.id,
            agent_id: root_agent_id,
            cost_usd: Decimal.new("10.00"),
            cost_type: "llm_consensus"
          },
          pubsub: context.pubsub
        )

      # First render processes the cost_recorded PubSub message
      render(view)

      # POSITIVE ASSERTION: Cost should be reflected in display
      html = render(view)

      assert html =~ "$10.00",
             "Recorded cost should appear in budget display"

      # NEGATIVE ASSERTION: Task budget display should not show $0.00 spent
      # (Note: Agent badge title may still show "Spent: $0.00" since that's internal tracking)
      refute html =~ "$0.00 / $50.00",
             "Task budget should not show $0.00 spent"
    end

    @tag :r9
    test "R9: over-budget status shows visual warning", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # USER ACTION: Create task with small budget
      create_task_with_budget_via_ui(view, "Task for over-budget", "20.00", context.profile.name)

      # Wait for agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)

      # Record cost exceeding budget (use valid cost_type from enum)
      {:ok, _cost} =
        Quoracle.Costs.Recorder.record(
          %{
            task_id: task.id,
            agent_id: root_agent_id,
            cost_usd: Decimal.new("25.00"),
            cost_type: "llm_consensus"
          },
          pubsub: context.pubsub
        )

      # POSITIVE ASSERTION: Over-budget warning visible
      html = render(view)

      assert html =~ "over-budget",
             "Over-budget visual indicator should be shown"

      # NEGATIVE ASSERTION: Should not show normal/ok status
      refute html =~ "budget-ok"
    end
  end

  # ============================================================
  # R10-R14: User Budget Editing
  # ============================================================

  describe "user budget editing - R10-R14" do
    @tag :r10
    test "R10: edit budget button visible for budgeted task", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # USER ACTION: Create task with budget
      create_task_with_budget_via_ui(view, "Task for edit button", "100.00", context.profile.name)

      # Wait for agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)

      # POSITIVE ASSERTION: Edit Budget button visible
      html = render(view)
      assert html =~ "Edit Budget", "Edit Budget button should be visible"

      # NEGATIVE ASSERTION: Button should be interactive (not disabled)
      refute html =~ ~r/Edit Budget.*disabled/
    end

    @tag :r11
    test "R11: clicking edit budget opens modal with current values", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Create task with budget
      create_task_with_budget_via_ui(view, "Task for edit modal", "85.00", context.profile.name)

      # Wait for agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)

      # USER ACTION: Click Edit Budget button
      view |> element("button", "Edit Budget") |> render_click()

      # POSITIVE ASSERTION: Modal opens with current budget value
      html = render(view)
      assert html =~ "budget-editor-modal", "Budget editor modal should be visible"
      assert html =~ "85.00", "Current budget value should be shown"

      # NEGATIVE ASSERTION: No error in modal
      refute html =~ "modal-error"
    end

    @tag :r12
    test "R12: submitting valid budget updates task", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Create task with budget
      create_task_with_budget_via_ui(
        view,
        "Task for budget update",
        "60.00",
        context.profile.name
      )

      # Wait for agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)

      # USER ACTION: Open budget editor and submit new budget
      view |> element("button", "Edit Budget") |> render_click()

      view
      |> form("#budget-editor-form", %{"new_budget" => "90.00"})
      |> render_submit()

      # POSITIVE ASSERTION: Budget updated in display and database
      html = render(view)
      assert html =~ "90.00", "New budget should be displayed"

      updated_task = Repo.get!(Task, task.id)
      assert updated_task.budget_limit == Decimal.new("90.00")

      # NEGATIVE ASSERTION: Modal should be closed
      refute html =~ "budget-editor-modal"
    end

    @tag :r13
    test "R13: budget below spent shows error", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Create task with budget
      create_task_with_budget_via_ui(
        view,
        "Task for below-spent test",
        "50.00",
        context.profile.name
      )

      # Wait for agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)

      # Record some spending (use valid cost_type from enum)
      {:ok, _cost} =
        Quoracle.Costs.Recorder.record(
          %{
            task_id: task.id,
            agent_id: root_agent_id,
            cost_usd: Decimal.new("30.00"),
            cost_type: "llm_consensus"
          },
          pubsub: context.pubsub
        )

      render(view)

      # USER ACTION: Try to set budget below spent
      view |> element("button", "Edit Budget") |> render_click()

      view
      |> form("#budget-editor-form", %{"new_budget" => "25.00"})
      |> render_submit()

      # POSITIVE ASSERTION: Error message shown
      html = render(view)

      assert html =~ "cannot be less than spent",
             "Should show error when budget < spent"

      # NEGATIVE ASSERTION: Budget should NOT be updated
      unchanged_task = Repo.get!(Task, task.id)
      assert unchanged_task.budget_limit == Decimal.new("50.00")
    end

    @tag :r14
    test "R14: budget edit updates running agent state", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Create task with budget
      create_task_with_budget_via_ui(
        view,
        "Task for agent budget update",
        "70.00",
        context.profile.name
      )

      # Wait for agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      root_agent_id = "root-#{task.id}"

      {:ok, agent_pid} =
        wait_for_agent_in_registry(root_agent_id, context.registry, timeout: 2000)

      {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)

      # USER ACTION: Edit budget
      view |> element("button", "Edit Budget") |> render_click()

      view
      |> form("#budget-editor-form", %{"new_budget" => "100.00"})
      |> render_submit()

      render(view)

      # POSITIVE ASSERTION: Agent state is updated (no notification message sent)
      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)
      assert state.budget_data.allocated == Decimal.new("100.00")

      # POSITIVE ASSERTION: Task in DB is updated
      updated_task = Repo.get!(Task, task.id)
      assert updated_task.budget_limit == Decimal.new("100.00")
    end
  end

  # ============================================================
  # R15-R19: Agent Budget Adjustment
  # ============================================================

  describe "agent budget adjustment - R15-R19" do
    @tag :r15
    test "R15: agent can increase child budget via action", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Create parent task with budget
      create_task_with_budget_via_ui(
        view,
        "Parent task for child budget",
        "100.00",
        context.profile.name
      )

      # Wait for parent agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      parent_agent_id = "root-#{task.id}"

      {:ok, parent_pid} =
        wait_for_agent_in_registry(parent_agent_id, context.registry, timeout: 2000)

      {:ok, _parent_state} = Quoracle.Agent.Core.get_state(parent_pid)
      register_agent_cleanup(parent_pid, cleanup_tree: true, registry: context.registry)

      # Spawn a child agent with budget
      child_config = %{
        agent_id: "child-budget-test-#{System.unique_integer([:positive])}",
        task_id: task.id,
        parent_id: parent_agent_id,
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: context.sandbox_owner,
        pubsub: context.pubsub,
        budget_data: %{mode: :child, allocated: Decimal.new("20.00"), committed: Decimal.new("0")},
        prompt_fields: %{
          provided: %{task_description: "Child task"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: []
      }

      {:ok, child_pid} =
        spawn_agent_with_cleanup(context.dynsup, child_config,
          registry: context.registry,
          pubsub: context.pubsub,
          sandbox_owner: context.sandbox_owner
        )

      {:ok, child_state} = Quoracle.Agent.Core.get_state(child_pid)

      # Register child with parent
      GenServer.cast(
        parent_pid,
        {:child_spawned,
         %{
           agent_id: child_state.agent_id,
           spawned_at: DateTime.utc_now(),
           budget_allocated: Decimal.new("20.00")
         }}
      )

      # Allow cast to process
      _ = Quoracle.Agent.Core.get_state(parent_pid)

      # USER ACTION (simulated): Parent adjusts child budget via action
      result =
        Quoracle.Agent.Core.adjust_child_budget(
          parent_agent_id,
          child_state.agent_id,
          Decimal.new("40.00"),
          registry: context.registry,
          pubsub: context.pubsub
        )

      # POSITIVE ASSERTION: Adjustment succeeded
      assert result == :ok, "Budget adjustment should succeed"

      # Verify child budget was updated
      {:ok, updated_child_state} = Quoracle.Agent.Core.get_state(child_pid)
      assert updated_child_state.budget_data.allocated == Decimal.new("40.00")

      # NEGATIVE ASSERTION: No error
      refute match?({:error, _}, result)
    end

    @tag :r16
    test "R16: agent can decrease child budget when valid", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Create parent task with budget
      create_task_with_budget_via_ui(
        view,
        "Parent for decrease test",
        "100.00",
        context.profile.name
      )

      # Wait for parent agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      parent_agent_id = "root-#{task.id}"

      {:ok, parent_pid} =
        wait_for_agent_in_registry(parent_agent_id, context.registry, timeout: 2000)

      {:ok, _parent_state} = Quoracle.Agent.Core.get_state(parent_pid)
      register_agent_cleanup(parent_pid, cleanup_tree: true, registry: context.registry)

      # Spawn child with budget
      child_config = %{
        agent_id: "child-decrease-#{System.unique_integer([:positive])}",
        task_id: task.id,
        parent_id: parent_agent_id,
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: context.sandbox_owner,
        pubsub: context.pubsub,
        budget_data: %{mode: :child, allocated: Decimal.new("50.00"), committed: Decimal.new("0")},
        prompt_fields: %{
          provided: %{task_description: "Child for decrease"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: []
      }

      {:ok, child_pid} =
        spawn_agent_with_cleanup(context.dynsup, child_config,
          registry: context.registry,
          pubsub: context.pubsub,
          sandbox_owner: context.sandbox_owner
        )

      {:ok, child_state} = Quoracle.Agent.Core.get_state(child_pid)

      # Register child with parent
      GenServer.cast(
        parent_pid,
        {:child_spawned,
         %{
           agent_id: child_state.agent_id,
           spawned_at: DateTime.utc_now(),
           budget_allocated: Decimal.new("50.00")
         }}
      )

      _ = Quoracle.Agent.Core.get_state(parent_pid)

      # USER ACTION (simulated): Decrease child budget
      result =
        Quoracle.Agent.Core.adjust_child_budget(
          parent_agent_id,
          child_state.agent_id,
          Decimal.new("30.00"),
          registry: context.registry,
          pubsub: context.pubsub
        )

      # POSITIVE ASSERTION: Decrease succeeded
      assert result == :ok

      {:ok, updated_child_state} = Quoracle.Agent.Core.get_state(child_pid)
      assert updated_child_state.budget_data.allocated == Decimal.new("30.00")

      # NEGATIVE ASSERTION: No error
      refute match?({:error, _}, result)
    end

    @tag :r17
    test "R17: agent cannot decrease child budget below minimum", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Create parent task
      create_task_with_budget_via_ui(view, "Parent for min test", "100.00", context.profile.name)

      # Wait for parent agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      parent_agent_id = "root-#{task.id}"

      {:ok, parent_pid} =
        wait_for_agent_in_registry(parent_agent_id, context.registry, timeout: 2000)

      {:ok, _parent_state} = Quoracle.Agent.Core.get_state(parent_pid)
      register_agent_cleanup(parent_pid, cleanup_tree: true, registry: context.registry)

      # Spawn child with budget and some committed
      child_config = %{
        agent_id: "child-min-#{System.unique_integer([:positive])}",
        task_id: task.id,
        parent_id: parent_agent_id,
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: context.sandbox_owner,
        pubsub: context.pubsub,
        budget_data: %{
          mode: :child,
          allocated: Decimal.new("40.00"),
          committed: Decimal.new("25.00")
        },
        prompt_fields: %{
          provided: %{task_description: "Child with committed"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: []
      }

      {:ok, child_pid} =
        spawn_agent_with_cleanup(context.dynsup, child_config,
          registry: context.registry,
          pubsub: context.pubsub,
          sandbox_owner: context.sandbox_owner
        )

      {:ok, child_state} = Quoracle.Agent.Core.get_state(child_pid)

      # Register child with parent
      GenServer.cast(
        parent_pid,
        {:child_spawned,
         %{
           agent_id: child_state.agent_id,
           spawned_at: DateTime.utc_now(),
           budget_allocated: Decimal.new("40.00")
         }}
      )

      _ = Quoracle.Agent.Core.get_state(parent_pid)

      # USER ACTION (simulated): Try to decrease below committed
      result =
        Quoracle.Agent.Core.adjust_child_budget(
          parent_agent_id,
          child_state.agent_id,
          Decimal.new("20.00"),
          registry: context.registry,
          pubsub: context.pubsub
        )

      # POSITIVE ASSERTION: Should fail with appropriate error
      assert match?({:error, _}, result), "Should reject decrease below minimum"

      # Verify child budget unchanged
      {:ok, unchanged_child_state} = Quoracle.Agent.Core.get_state(child_pid)
      assert unchanged_child_state.budget_data.allocated == Decimal.new("40.00")

      # NEGATIVE ASSERTION: Should not succeed
      refute result == :ok
    end

    @tag :r18
    test "R18: parent escrow updates on child budget adjustment", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Create parent task
      create_task_with_budget_via_ui(
        view,
        "Parent for escrow test",
        "100.00",
        context.profile.name
      )

      # Wait for parent agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      parent_agent_id = "root-#{task.id}"

      {:ok, parent_pid} =
        wait_for_agent_in_registry(parent_agent_id, context.registry, timeout: 2000)

      {:ok, initial_parent_state} = Quoracle.Agent.Core.get_state(parent_pid)
      register_agent_cleanup(parent_pid, cleanup_tree: true, registry: context.registry)

      initial_committed = initial_parent_state.budget_data.committed

      # Spawn child with budget
      child_config = %{
        agent_id: "child-escrow-#{System.unique_integer([:positive])}",
        task_id: task.id,
        parent_id: parent_agent_id,
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: context.sandbox_owner,
        pubsub: context.pubsub,
        budget_data: %{mode: :child, allocated: Decimal.new("30.00"), committed: Decimal.new("0")},
        prompt_fields: %{
          provided: %{task_description: "Child for escrow"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: []
      }

      {:ok, child_pid} =
        spawn_agent_with_cleanup(context.dynsup, child_config,
          registry: context.registry,
          pubsub: context.pubsub,
          sandbox_owner: context.sandbox_owner
        )

      {:ok, child_state} = Quoracle.Agent.Core.get_state(child_pid)

      # Register child with parent
      GenServer.cast(
        parent_pid,
        {:child_spawned,
         %{
           agent_id: child_state.agent_id,
           spawned_at: DateTime.utc_now(),
           budget_allocated: Decimal.new("30.00")
         }}
      )

      _ = Quoracle.Agent.Core.get_state(parent_pid)

      # USER ACTION: Increase child budget
      Quoracle.Agent.Core.adjust_child_budget(
        parent_agent_id,
        child_state.agent_id,
        Decimal.new("50.00"),
        registry: context.registry,
        pubsub: context.pubsub
      )

      # POSITIVE ASSERTION: Parent committed increased atomically
      {:ok, updated_parent_state} = Quoracle.Agent.Core.get_state(parent_pid)
      expected_committed = Decimal.add(initial_committed, Decimal.new("20.00"))

      assert updated_parent_state.budget_data.committed == expected_committed,
             "Parent committed should increase by delta"

      # NEGATIVE ASSERTION: Committed should not be unchanged
      refute updated_parent_state.budget_data.committed == initial_committed
    end

    @tag :r19
    test "R19: N/A parent allows any child budget", %{conn: conn} = context do
      # ENTRY POINT: Real route
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Create parent task WITHOUT budget (N/A)
      create_task_without_budget_via_ui(view, "Parent with N/A budget", context.profile.name)

      # Wait for parent agent
      task = Repo.one(from(t in Task, order_by: [desc: t.inserted_at], limit: 1))
      parent_agent_id = "root-#{task.id}"

      {:ok, parent_pid} =
        wait_for_agent_in_registry(parent_agent_id, context.registry, timeout: 2000)

      {:ok, _parent_state} = Quoracle.Agent.Core.get_state(parent_pid)
      register_agent_cleanup(parent_pid, cleanup_tree: true, registry: context.registry)

      # Spawn child with any budget
      child_config = %{
        agent_id: "child-na-#{System.unique_integer([:positive])}",
        task_id: task.id,
        parent_id: parent_agent_id,
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: context.sandbox_owner,
        pubsub: context.pubsub,
        budget_data: %{
          mode: :child,
          allocated: Decimal.new("500.00"),
          committed: Decimal.new("0")
        },
        prompt_fields: %{
          provided: %{task_description: "Child with large budget"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: []
      }

      {:ok, child_pid} =
        spawn_agent_with_cleanup(context.dynsup, child_config,
          registry: context.registry,
          pubsub: context.pubsub,
          sandbox_owner: context.sandbox_owner
        )

      {:ok, child_state} = Quoracle.Agent.Core.get_state(child_pid)

      # Register child with parent
      GenServer.cast(
        parent_pid,
        {:child_spawned,
         %{
           agent_id: child_state.agent_id,
           spawned_at: DateTime.utc_now(),
           budget_allocated: Decimal.new("500.00")
         }}
      )

      _ = Quoracle.Agent.Core.get_state(parent_pid)

      # USER ACTION: Adjust to even larger budget
      result =
        Quoracle.Agent.Core.adjust_child_budget(
          parent_agent_id,
          child_state.agent_id,
          Decimal.new("1000.00"),
          registry: context.registry,
          pubsub: context.pubsub
        )

      # POSITIVE ASSERTION: Should succeed (N/A parent has no limit)
      assert result == :ok, "N/A parent should allow any child budget"

      {:ok, updated_child_state} = Quoracle.Agent.Core.get_state(child_pid)
      assert updated_child_state.budget_data.allocated == Decimal.new("1000.00")

      # NEGATIVE ASSERTION: Should not fail
      refute match?({:error, _}, result)
    end
  end
end
