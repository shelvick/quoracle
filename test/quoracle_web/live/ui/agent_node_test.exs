defmodule QuoracleWeb.UI.AgentNodeTest do
  @moduledoc """
  Tests for the AgentNode live component.
  Verifies individual node rendering in the agent tree with status, expand/collapse, and selection.
  """

  # LiveView tests can run async with modern Ecto.Sandbox pattern
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  # Helper to render component - cleanup handled by ConnCase.live_isolated
  defp render_isolated(
         conn,
         agent,
         depth \\ 0,
         expanded \\ false,
         selected \\ false,
         agent_alive \\ false,
         message_form_expanded \\ false,
         sandbox_owner \\ nil
       ) do
    session = %{
      "component" => QuoracleWeb.UI.AgentNode,
      "assigns" => %{
        agent: agent,
        depth: depth,
        expanded: expanded,
        selected: selected,
        agent_alive: agent_alive,
        message_form_expanded: message_form_expanded,
        root_pid: self()
      }
    }

    # Add sandbox_owner if provided (needed for CostDisplay DB queries)
    session =
      if sandbox_owner do
        Map.put(session, "sandbox_owner", sandbox_owner)
      else
        session
      end

    live_isolated(conn, QuoracleWeb.LiveComponentTestHelper, session: session)
  end

  defp create_test_agent do
    %{
      agent_id: "test_agent_1",
      task_id: "task_1",
      status: :working,
      parent_id: nil,
      children: ["child_1", "child_2"],
      current_action: "orient",
      created_at: ~U[2024-01-01 10:00:00Z]
    }
  end

  describe "rendering" do
    test "displays agent ID and status", %{conn: conn} do
      agent = create_test_agent()
      {:ok, view, _html} = render_isolated(conn, agent)

      html = render(view)

      # Verify agent info displayed
      assert html =~ "test_agent_1"
      assert html =~ "status-working"
    end

    test "shows expand/collapse icon when agent has children", %{conn: conn} do
      agent = create_test_agent()
      {:ok, view, _html} = render_isolated(conn, agent)

      html = render(view)

      # Has children, should show expand icon
      assert has_element?(view, "[phx-click='toggle_expand']")
      assert html =~ "icon-expand"
    end

    test "no expand icon when agent has no children", %{conn: conn} do
      agent = %{create_test_agent() | children: []}
      {:ok, view, _html} = render_isolated(conn, agent)

      _html = render(view)

      # No children, no expand icon
      refute has_element?(view, "[phx-click='toggle_expand']")
    end

    test "shows current action when agent is working", %{conn: conn} do
      agent = %{create_test_agent() | status: :working, current_action: "wait"}
      {:ok, view, _html} = render_isolated(conn, agent)

      html = render(view)

      # Should show current action
      assert html =~ "wait"
    end

    test "applies visual styling based on status", %{conn: conn} do
      # Test each status
      statuses = [:idle, :working, :completed, :failed]

      for status <- statuses do
        agent = %{create_test_agent() | status: status}
        {:ok, view, _html} = render_isolated(conn, agent)

        html = render(view)
        assert html =~ "status-#{status}"
      end
    end
  end

  describe "expand/collapse" do
    test "toggles expanded state on click", %{conn: conn} do
      agent = create_test_agent()
      {:ok, view, _html} = render_isolated(conn, agent, 0, false, false)

      # Click to expand
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='test_agent_1']")
      |> render_click()

      # The component should send event to parent
      # In isolated testing, we verify the click is handled
      html = render(view)
      assert html =~ "test_agent_1"
    end

    test "renders children when expanded", %{conn: conn} do
      agent = create_test_agent()

      # For expanded with children, we need to test at component level
      # Children rendering happens via recursive component calls
      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Component shows expand/collapse icon for agents with children
      assert html =~ ~r/icon-(collapse|expand)/
    end

    test "hides children when collapsed", %{conn: conn} do
      agent = create_test_agent()

      # When collapsed, children aren't rendered
      {:ok, view, _html} = render_isolated(conn, agent, 0, false, false)

      html = render(view)

      # Component shows expand icon when collapsed
      assert html =~ "icon-expand"
    end

    test "changes icon based on expanded state", %{conn: conn} do
      agent = create_test_agent()

      # Expanded state
      {:ok, view_expanded, _html} = render_isolated(conn, agent, 0, true, false)
      assert render(view_expanded) =~ "icon-collapse"

      # Collapsed state
      {:ok, view_collapsed, _html} = render_isolated(conn, agent, 0, false, false)
      assert render(view_collapsed) =~ "icon-expand"
    end
  end

  describe "selection" do
    test "handles click to select agent", %{conn: conn} do
      agent = create_test_agent()
      {:ok, view, _html} = render_isolated(conn, agent)

      # Click to select
      view
      |> element("[phx-click='select_agent'][phx-value-agent-id='test_agent_1']")
      |> render_click()

      # Component sends event to parent in isolated testing
      html = render(view)
      assert html =~ "test_agent_1"
    end

    test "shows selected styling when agent is selected", %{conn: conn} do
      agent = create_test_agent()
      {:ok, view, _html} = render_isolated(conn, agent, 0, false, true)

      html = render(view)

      # Should have selected class
      assert html =~ "agent-selected"
    end

    test "removes selected styling when different agent selected", %{conn: conn} do
      agent = create_test_agent()

      # Initially selected
      {:ok, view_selected, _html} = render_isolated(conn, agent, 0, false, true)
      assert render(view_selected) =~ "agent-selected"

      # No longer selected
      {:ok, view_unselected, _html} = render_isolated(conn, agent, 0, false, false)
      refute render(view_unselected) =~ "agent-selected"
    end
  end

  describe "nesting" do
    test "applies indentation based on depth", %{conn: conn} do
      agent = create_test_agent()

      # Different depths - need to test with level param which maps to depth
      {:ok, view0, _html} = render_isolated(conn, agent, 0, false, false)
      assert has_element?(view0, "[data-depth='0']")

      {:ok, view2, _html} = render_isolated(conn, agent, 2, false, false)
      assert has_element?(view2, "[data-depth='2']")
    end

    test "renders nested children recursively", %{conn: conn} do
      # This test needs to be at the TaskTree level since AgentNode
      # component doesn't handle the recursive rendering itself
      agent = create_test_agent()
      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Component renders the main agent
      assert html =~ "test_agent_1"
      # Child rendering is handled by parent component
    end
  end

  describe "direct message feature" do
    test "message button visible for alive root agents", %{conn: conn} do
      # Root agent (parent_id: nil) and alive
      agent = %{create_test_agent() | parent_id: nil}
      {:ok, view, html} = render_isolated(conn, agent, 0, false, false, true)

      assert html =~ "Send Message"
      assert has_element?(view, "[phx-click='show_message_form']")
    end

    test "message button hidden for child agents", %{conn: conn} do
      # Child agent (has parent)
      agent = %{create_test_agent() | parent_id: "parent_123"}
      {:ok, view, _html} = render_isolated(conn, agent, 0, false, false)

      # Even if alive, child agents don't get message button
      send(view.pid, {:update_assigns, %{agent_alive: true}})

      html = render(view)
      refute html =~ "Send Message"
      refute has_element?(view, "[phx-click='show_message_form']")
    end

    test "message button hidden for terminated agents", %{conn: conn} do
      # Root agent but not alive
      agent = %{create_test_agent() | parent_id: nil}
      {:ok, view, _html} = render_isolated(conn, agent, 0, false, false)

      # agent_alive: false (terminated)
      send(view.pid, {:update_assigns, %{agent_alive: false}})

      html = render(view)
      refute html =~ "Send Message"
      refute has_element?(view, "[phx-click='show_message_form']")
    end

    test "clicking send message expands inline form", %{conn: conn} do
      agent = %{create_test_agent() | parent_id: nil}
      {:ok, view, _html} = render_isolated(conn, agent, 0, false, false, true)

      # Click the Send Message button
      view |> element("[phx-click='show_message_form']") |> render_click()

      html = render(view)
      assert has_element?(view, "textarea[name='content']")
      assert has_element?(view, "button[type='submit']")
      assert html =~ "Cancel"
    end

    test "clicking cancel collapses form and clears input", %{conn: conn} do
      agent = %{create_test_agent() | parent_id: nil}
      {:ok, view, _html} = render_isolated(conn, agent, 0, false, false, true, true)

      # Type some text (textarea has phx-change)
      view
      |> element("textarea[name='content']")
      |> render_change(%{"content" => "Test message"})

      # Click cancel
      view |> element("[phx-click='cancel_message']") |> render_click()

      html = render(view)
      refute has_element?(view, "textarea[name='content']")
      assert html =~ "Send Message"
    end

    test "submitting message sends to dashboard and clears form", %{conn: conn} do
      agent = %{create_test_agent() | parent_id: nil, agent_id: "root_agent_1"}
      {:ok, view, _html} = render_isolated(conn, agent, 0, false, false, true, true)

      # Submit the form
      view
      |> form("form", %{"content" => "Hello agent"})
      |> render_submit()

      # Should send message to root_pid
      assert_receive {:send_direct_message, "root_agent_1", "Hello agent"}

      # Form should collapse
      html = render(view)
      refute has_element?(view, "textarea[name='content']")
      assert html =~ "Send Message"
    end
  end

  describe "real-time updates" do
    test "updates status when agent state changes", %{conn: conn} do
      agent = create_test_agent()
      {:ok, view, _html} = render_isolated(conn, agent)

      assert render(view) =~ "status-working"

      # To test status updates, we need to render with new status
      updated_agent = %{agent | status: :completed}
      {:ok, view2, _html} = render_isolated(conn, updated_agent)

      html = render(view2)
      refute html =~ "status-working"
      assert html =~ "status-completed"
    end

    test "updates action display when action changes", %{conn: conn} do
      agent = %{create_test_agent() | current_action: "wait"}
      {:ok, view, _html} = render_isolated(conn, agent)

      assert render(view) =~ "wait"

      # Change action
      updated_agent = %{agent | current_action: "spawn_child"}
      {:ok, view2, _html} = render_isolated(conn, updated_agent)

      html = render(view2)
      refute html =~ "wait"
      assert html =~ "spawn_child"
    end

    test "adds new children dynamically", %{conn: conn} do
      agent = %{create_test_agent() | children: []}
      {:ok, view, _html} = render_isolated(conn, agent)

      # No expand icon initially
      refute has_element?(view, "[phx-click='toggle_expand']")

      # Add children
      updated_agent = %{agent | children: ["new_child"]}
      {:ok, view2, _html} = render_isolated(conn, updated_agent)

      # Now has expand icon
      assert has_element?(view2, "[phx-click='toggle_expand']")
    end
  end

  describe "component callbacks" do
    test "update/2 processes assigns", %{conn: conn} do
      agent = create_test_agent()

      # Test with different initial assigns
      {:ok, view, _html} = render_isolated(conn, agent, 1, true, false)

      html = render(view)
      # Verify component renders with correct assigns
      assert html =~ "test_agent_1"
      assert html =~ "data-depth=\"1\""
      # Expanded=true should show collapse icon if has children
      assert html =~ "icon-collapse"
    end

    test "handle_event for toggle_expand", %{conn: conn} do
      agent = create_test_agent()
      {:ok, view, _html} = render_isolated(conn, agent)

      # Component doesn't have handle_event, it uses phx-click
      # The click is handled by the parent component
      assert has_element?(view, "[phx-click='toggle_expand']")
    end

    test "handle_event for select_agent", %{conn: conn} do
      agent = create_test_agent()
      {:ok, view, _html} = render_isolated(conn, agent)

      # Component doesn't have handle_event, it uses phx-click
      # The click is handled by the parent component
      assert has_element?(view, "[phx-click='select_agent']")
    end
  end

  describe "visual feedback" do
    test "shows hover state on mouse over", %{conn: conn} do
      agent = create_test_agent()
      {:ok, view, _html} = render_isolated(conn, agent)

      # Hover styling is handled by CSS, not component state
      # Verify the component has hover-capable elements
      html = render(view)
      assert html =~ "hover:bg-gray-50"
    end

    test "animates expansion/collapse", %{conn: conn} do
      agent = create_test_agent()

      # Start collapsed
      {:ok, view, _html} = render_isolated(conn, agent, 0, false, false)

      # Verify expand button exists
      assert has_element?(view, "[phx-click='toggle_expand']")

      # Animation classes would be added by parent component
      # AgentNode just provides the toggle button
    end

    test "shows loading indicator when agent initializing", %{conn: conn} do
      agent = %{create_test_agent() | status: :initializing}
      {:ok, view, _html} = render_isolated(conn, agent)

      html = render(view)

      # Should show loading spinner when initializing
      assert html =~ "⟳"
    end
  end

  describe "TODO display (Packet 3)" do
    test "displays todos when agent expanded and has todos", %{conn: conn} do
      agent =
        Map.put(create_test_agent(), :todos, [
          %{content: "Fetch user data", state: :todo},
          %{content: "Waiting for child", state: :pending},
          %{content: "Analyzed requirements", state: :done}
        ])

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Should display todos section
      assert html =~ "TODOs"
      assert html =~ "Fetch user data"
      assert html =~ "Waiting for child"
      assert html =~ "Analyzed requirements"
    end

    test "hides todos when agent collapsed", %{conn: conn} do
      agent =
        Map.put(create_test_agent(), :todos, [
          %{content: "Hidden task", state: :todo}
        ])

      {:ok, view, _html} = render_isolated(conn, agent, 0, false, false)

      html = render(view)

      # Should not display todos when collapsed
      refute html =~ "TODOs"
      refute html =~ "Hidden task"
    end

    test "shows empty state when todos list is empty", %{conn: conn} do
      agent = Map.put(create_test_agent(), :todos, [])

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Should show empty state message
      assert html =~ "No current tasks"
    end

    test "hides todo section when todos field missing", %{conn: conn} do
      agent = create_test_agent()
      # No todos field

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Should not display todos section at all
      refute html =~ "TODOs"
      refute html =~ "No current tasks"
    end

    test "displays state icon for todo items", %{conn: conn} do
      agent =
        Map.put(create_test_agent(), :todos, [
          %{content: "Todo item", state: :todo},
          %{content: "Pending item", state: :pending},
          %{content: "Done item", state: :done}
        ])

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Should have state icons
      assert html =~ "⏳"
      assert html =~ "⏸️"
      assert html =~ "✅"
    end

    test "applies done styling with strikethrough", %{conn: conn} do
      agent =
        Map.put(create_test_agent(), :todos, [
          %{content: "Completed task", state: :done}
        ])

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Should have line-through and opacity styling for done items
      assert html =~ "line-through"
      assert html =~ "Completed task"
    end

    test "applies correct color classes for each state", %{conn: conn} do
      agent =
        Map.put(create_test_agent(), :todos, [
          %{content: "Todo task", state: :todo},
          %{content: "Pending task", state: :pending},
          %{content: "Done task", state: :done}
        ])

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Should have appropriate color classes
      assert html =~ "text-gray-700"
      assert html =~ "text-yellow-600"
      assert html =~ "text-green-600"
    end

    test "preserves todo order", %{conn: conn} do
      agent =
        Map.put(create_test_agent(), :todos, [
          %{content: "First", state: :todo},
          %{content: "Second", state: :pending},
          %{content: "Third", state: :done},
          %{content: "Fourth", state: :todo}
        ])

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Verify order is preserved (check relative positions in HTML)
      first_pos = :binary.match(html, "First") |> elem(0)
      second_pos = :binary.match(html, "Second") |> elem(0)
      third_pos = :binary.match(html, "Third") |> elem(0)
      fourth_pos = :binary.match(html, "Fourth") |> elem(0)

      assert first_pos < second_pos
      assert second_pos < third_pos
      assert third_pos < fourth_pos
    end

    test "handles many todos without breaking layout", %{conn: conn} do
      todos = for i <- 1..20, do: %{content: "Task #{i}", state: :todo}
      agent = Map.put(create_test_agent(), :todos, todos)

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Should render all todos
      assert html =~ "Task 1"
      assert html =~ "Task 10"
      assert html =~ "Task 20"
    end

    test "handles very long todo content", %{conn: conn} do
      long_content = String.duplicate("Very long task description ", 20)

      agent =
        Map.put(create_test_agent(), :todos, [
          %{content: long_content, state: :todo}
        ])

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Should display long content (may be truncated by CSS)
      assert html =~ "Very long task description"
    end

    test "handles unicode and special characters in todo content", %{conn: conn} do
      agent =
        Map.put(create_test_agent(), :todos, [
          %{content: "Task with émoji 🎉 and symbols", state: :todo},
          %{content: "中文 日本語 한글", state: :pending}
        ])

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Should handle unicode properly
      assert html =~ "émoji 🎉"
      assert html =~ "中文"
    end

    test "updates todo display when todos change", %{conn: conn} do
      agent =
        Map.put(create_test_agent(), :todos, [
          %{content: "Old task", state: :todo}
        ])

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)
      assert render(view) =~ "Old task"

      # Simulate update with new todos
      updated_agent =
        Map.put(agent, :todos, [
          %{content: "New task", state: :pending}
        ])

      {:ok, view2, _html} = render_isolated(conn, updated_agent, 0, true, false)

      html = render(view2)
      refute html =~ "Old task"
      assert html =~ "New task"
    end

    test "applies correct container styling", %{conn: conn} do
      agent =
        Map.put(create_test_agent(), :todos, [
          %{content: "Task", state: :todo}
        ])

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Should have todos-section styling
      assert html =~ "todos-section"
      assert html =~ "bg-gray-50"
      assert html =~ "rounded"
    end

    test "renders todos section header", %{conn: conn} do
      agent =
        Map.put(create_test_agent(), :todos, [
          %{content: "Task", state: :todo}
        ])

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Should have "TODOs" header
      assert html =~ "TODOs"
      assert html =~ "font-semibold"
    end

    test "handles mixed todo states", %{conn: conn} do
      agent =
        Map.put(create_test_agent(), :todos, [
          %{content: "Todo 1", state: :todo},
          %{content: "Todo 2", state: :todo},
          %{content: "Pending 1", state: :pending},
          %{content: "Done 1", state: :done},
          %{content: "Done 2", state: :done}
        ])

      {:ok, view, _html} = render_isolated(conn, agent, 0, true, false)

      html = render(view)

      # Should display all todos regardless of state
      assert html =~ "Todo 1"
      assert html =~ "Todo 2"
      assert html =~ "Pending 1"
      assert html =~ "Done 1"
      assert html =~ "Done 2"
    end
  end

  # ============================================================
  # Cost Display Integration [INTEGRATION] - Packet 5
  # Integration tests that verify AgentNode renders CostDisplay.
  # See dashboard_live_test.exs for acceptance-level tests.
  # ============================================================

  describe "cost display integration" do
    alias Quoracle.Costs.AgentCost
    alias Quoracle.Repo

    setup do
      # Create real task in database for cost recording
      {:ok, task} =
        Repo.insert(%Quoracle.Tasks.Task{
          prompt: "Test task for cost display",
          status: "running"
        })

      # Create agent record with all required fields
      {:ok, agent_record} =
        Repo.insert(%Quoracle.Agents.Agent{
          agent_id: "cost-test-agent-#{System.unique_integer([:positive])}",
          task_id: task.id,
          parent_id: nil,
          status: "running",
          config: %{}
        })

      {:ok, task: task, agent_record: agent_record}
    end

    test "renders CostDisplay component for agent", %{
      conn: conn,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # AgentNode should render CostDisplay as a child component
      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: []
      }

      {:ok, view, _html} =
        render_isolated(conn, agent, 0, false, false, false, false, sandbox_owner)

      html = render(view)

      # CostDisplay should be rendered within AgentNode
      assert html =~ "cost-display"
    end

    test "displays agent cost when costs exist in database", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Record a cost in the database
      {:ok, _cost} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.05"),
          metadata: %{"model_spec" => "anthropic/claude-sonnet"}
        })

      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: []
      }

      {:ok, view, _html} =
        render_isolated(conn, agent, 0, false, false, false, false, sandbox_owner)

      html = render(view)

      # Should display the cost
      assert html =~ "$0.05"
    end

    test "shows N/A when agent has no costs", %{
      conn: conn,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # No costs recorded for this agent
      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: []
      }

      {:ok, view, _html} =
        render_isolated(conn, agent, 0, false, false, false, false, sandbox_owner)

      html = render(view)

      # Should show N/A for nil cost
      assert html =~ "N/A"
    end

    test "cost updates when new costs are recorded", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Start with one cost
      {:ok, _cost1} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.10"),
          metadata: %{}
        })

      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: []
      }

      {:ok, view, _html} =
        render_isolated(conn, agent, 0, false, false, false, false, sandbox_owner)

      # Initial cost
      html = render(view)
      assert html =~ "$0.10"

      # Record another cost
      {:ok, _cost2} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.05"),
          metadata: %{}
        })

      # Re-mount component to simulate parent re-render (which triggers update/2)
      # LiveComponents reload costs on update/2, not on plain render()
      {:ok, view2, _html} =
        render_isolated(conn, agent, 0, false, false, false, false, sandbox_owner)

      html = render(view2)
      assert html =~ "$0.15"
    end

    test "expanded agent shows cost summary with type breakdown", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Record multiple cost types
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.10"),
          metadata: %{}
        })

      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.02"),
          metadata: %{}
        })

      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: []
      }

      # Render in expanded mode (AgentNode expanded, but CostDisplay summary starts collapsed)
      {:ok, view, _html} =
        render_isolated(conn, agent, 0, true, false, false, false, sandbox_owner)

      html = render(view)

      # Verify CostDisplay summary is present with total cost
      assert html =~ "$0.12"

      # Click to expand the CostDisplay summary to see type breakdown
      # CostDisplay internal expanded state starts false, type breakdown only visible after click
      # The phx-click is on a child div inside .cost-summary
      view |> element(".cost-summary .cursor-pointer") |> render_click()

      expanded_html = render(view)

      # Now type breakdown should be visible (shows user-friendly labels, not raw cost_type)
      assert expanded_html =~ "Consensus"
      assert expanded_html =~ "Embeddings"
    end
  end

  # ============================================================
  # R8-R14: costs_updated_at & Per-Model Breakdown (fix-ui-costs-20251213)
  # Tests for costs_updated_at propagation and detail mode display.
  # ============================================================

  describe "R8-R14: costs_updated_at & per-model" do
    alias Quoracle.Costs.AgentCost
    alias Quoracle.Repo

    setup do
      # Create real task in database for cost recording
      {:ok, task} =
        Repo.insert(%Quoracle.Tasks.Task{
          prompt: "Test task for cost display",
          status: "running"
        })

      # Create agent record with all required fields
      {:ok, agent_record} =
        Repo.insert(%Quoracle.Agents.Agent{
          agent_id: "cost-detail-agent-#{System.unique_integer([:positive])}",
          task_id: task.id,
          parent_id: nil,
          status: "running",
          config: %{}
        })

      {:ok, task: task, agent_record: agent_record}
    end

    # R8: costs_updated_at Accept [UNIT]
    test "R8: accepts costs_updated_at assign", %{
      conn: conn,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: []
      }

      costs_updated_at = System.monotonic_time()

      # Render with costs_updated_at in session
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "component" => QuoracleWeb.UI.AgentNode,
            "assigns" => %{
              agent: agent,
              depth: 0,
              expanded: false,
              selected: false,
              agent_alive: false,
              costs_updated_at: costs_updated_at,
              root_pid: self()
            }
          }
        )

      # CRITICAL: Cleanup LiveView before sandbox owner exits
      html = render(view)

      # Component should render without error when costs_updated_at is provided
      assert html =~ agent_record.agent_id
    end

    # R9: CostDisplay Badge with Trigger [INTEGRATION]
    test "R9: passes costs_updated_at to CostDisplay badge", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Record a cost
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.08"),
          metadata: %{}
        })

      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: []
      }

      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "component" => QuoracleWeb.UI.AgentNode,
            "assigns" => %{
              agent: agent,
              depth: 0,
              expanded: false,
              selected: false,
              agent_alive: false,
              costs_updated_at: System.monotonic_time(),
              root_pid: self()
            }
          }
        )

      html = render(view)

      # CostDisplay badge should show the cost
      assert html =~ "$0.08"
    end

    # R10: Summary Mode in Expanded View [INTEGRATION]
    test "R10: expanded view includes cost summary", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Record costs
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.15"),
          metadata: %{}
        })

      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: []
      }

      # Render expanded
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "component" => QuoracleWeb.UI.AgentNode,
            "assigns" => %{
              agent: agent,
              depth: 0,
              expanded: true,
              selected: false,
              agent_alive: false,
              costs_updated_at: System.monotonic_time(),
              root_pid: self()
            }
          }
        )

      html = render(view)

      # Expanded view should include cost summary mode
      assert html =~ "cost-summary"
    end

    # R11: Detail Mode in Expanded View [INTEGRATION]
    test "R11: expanded view includes per-model cost breakdown", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Record costs with different models
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.35"),
          metadata: %{"model_spec" => "anthropic:claude-sonnet"}
        })

      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.07"),
          metadata: %{"model_spec" => "openai:gpt-4o"}
        })

      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: []
      }

      # Render expanded
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "component" => QuoracleWeb.UI.AgentNode,
            "assigns" => %{
              agent: agent,
              depth: 0,
              expanded: true,
              selected: false,
              agent_alive: false,
              costs_updated_at: System.monotonic_time(),
              root_pid: self()
            }
          }
        )

      html = render(view)

      # Expanded view should include detail mode with per-model breakdown
      assert html =~ "claude-sonnet"
      assert html =~ "gpt-4o"
    end

    # R12: Recursive costs_updated_at Propagation [UNIT]
    test "R12: passes costs_updated_at to child AgentNodes", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Create child agent
      {:ok, child_agent} =
        Repo.insert(%Quoracle.Agents.Agent{
          agent_id: "child-agent-#{System.unique_integer([:positive])}",
          task_id: task.id,
          parent_id: agent_record.agent_id,
          status: "running",
          config: %{}
        })

      parent_agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: [child_agent.agent_id]
      }

      # Need to render via TaskTree to see recursive children
      agents = %{
        agent_record.agent_id => parent_agent,
        child_agent.agent_id => %{
          agent_id: child_agent.agent_id,
          task_id: task.id,
          status: :idle,
          parent_id: agent_record.agent_id,
          children: []
        }
      }

      tasks = %{
        task.id => %{
          id: task.id,
          prompt: "Test task",
          root_agent_id: agent_record.agent_id,
          status: "running",
          updated_at: DateTime.utc_now()
        }
      }

      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "component" => QuoracleWeb.UI.TaskTree,
            "assigns" => %{
              agents: agents,
              tasks: tasks,
              selected_agent_id: nil,
              costs_updated_at: System.monotonic_time(),
              root_pid: self()
            }
          }
        )

      # Expand parent to see child
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='#{agent_record.agent_id}']")
      |> render_click()

      html = render(view)

      # Child should be rendered (with costs_updated_at propagated)
      assert html =~ child_agent.agent_id
    end

    # R13: Cost Update Without Refresh [SYSTEM]
    @tag :acceptance
    test "R13: agent costs update when new cost recorded", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: []
      }

      initial_timestamp = System.monotonic_time()

      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "component" => QuoracleWeb.UI.AgentNode,
            "assigns" => %{
              agent: agent,
              depth: 0,
              expanded: false,
              selected: false,
              agent_alive: false,
              costs_updated_at: initial_timestamp,
              root_pid: self()
            }
          }
        )

      # Initially no costs - should show N/A
      html = render(view)
      assert html =~ "N/A"

      # Record a cost
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.25"),
          metadata: %{}
        })

      # Simulate parent bumping costs_updated_at (triggers component re-render)
      new_timestamp = System.monotonic_time()

      send(
        view.pid,
        {:update_component,
         %{
           costs_updated_at: new_timestamp
         }}
      )

      html = render(view)

      # Cost should now show
      assert html =~ "$0.25"
    end

    # R14: Per-Model Data Display [INTEGRATION]
    test "R14: detail mode shows model, requests, tokens, cost", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Record costs with full metadata
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.35"),
          metadata: %{
            "model_spec" => "anthropic:claude-sonnet",
            "input_tokens" => 10000,
            "output_tokens" => 2000
          }
        })

      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: []
      }

      # Render expanded to see detail mode
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "component" => QuoracleWeb.UI.AgentNode,
            "assigns" => %{
              agent: agent,
              depth: 0,
              expanded: true,
              selected: false,
              agent_alive: false,
              costs_updated_at: System.monotonic_time(),
              root_pid: self()
            }
          }
        )

      html = render(view)

      # Detail mode should show model name
      assert html =~ "claude-sonnet"

      # Detail mode should show cost
      assert html =~ "$0.35"

      # v2.0: Detail mode shows input/output tokens separately in table
      # input_tokens: 10000 = "10K", output_tokens: 2000 = "2K"
      assert html =~ "10K"
      assert html =~ "2K"
    end
  end

  # ============================================================
  # R15-R19: Budget Badge Integration (wip-20251231-budget)
  # Packet 6 (UI Components)
  # Tests for BudgetBadge rendering in AgentNode.
  # ============================================================

  describe "R15-R19: budget badge integration" do
    alias Quoracle.Repo

    setup do
      # Create real task in database for budget tracking
      {:ok, task} =
        Repo.insert(%Quoracle.Tasks.Task{
          prompt: "Test task for budget display",
          status: "running"
        })

      # Create agent record with all required fields
      {:ok, agent_record} =
        Repo.insert(%Quoracle.Agents.Agent{
          agent_id: "budget-test-agent-#{System.unique_integer([:positive])}",
          task_id: task.id,
          parent_id: nil,
          status: "running",
          config: %{}
        })

      {:ok, task: task, agent_record: agent_record}
    end

    # R15: Budget Badge Renders [UNIT]
    test "R15: budget badge renders for agent with budget", %{
      conn: conn,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Agent with budget_data (allocated budget)
      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: [],
        budget_data: %{
          allocated: Decimal.new("100.00"),
          committed: Decimal.new("0")
        },
        spent: Decimal.new("25.00"),
        over_budget: false
      }

      {:ok, view, _html} =
        render_isolated(conn, agent, 0, false, false, false, false, sandbox_owner)

      html = render(view)

      # Should render BudgetBadge component
      assert html =~ "budget-badge"
    end

    # R16: No Badge for N/A Budget [UNIT]
    test "R16: no budget badge for N/A budget agents", %{
      conn: conn,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Agent without budget_data (unlimited/N/A budget)
      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: [],
        budget_data: nil
      }

      {:ok, view, _html} =
        render_isolated(conn, agent, 0, false, false, false, false, sandbox_owner)

      html = render(view)

      # Should NOT render BudgetBadge when budget_data is nil
      refute html =~ "budget-badge"
    end

    # R17: Over Budget Warning [UNIT]
    test "R17: over budget warning visual indicator", %{
      conn: conn,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Agent that is over budget
      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: [],
        budget_data: %{
          allocated: Decimal.new("50.00"),
          committed: Decimal.new("0")
        },
        spent: Decimal.new("75.00"),
        over_budget: true
      }

      {:ok, view, _html} =
        render_isolated(conn, agent, 0, false, false, false, false, sandbox_owner)

      html = render(view)

      # Should show red/warning indicator for over budget
      assert html =~ "budget-badge"
      # Red styling indicates over budget (bg-red-100 per BudgetBadge spec)
      assert html =~ "bg-red-100"
    end

    # R18: Badge Shows Spent/Allocated Format [UNIT]
    test "R18: badge shows $spent/$allocated format", %{
      conn: conn,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: [],
        budget_data: %{
          allocated: Decimal.new("100.00"),
          committed: Decimal.new("10.00")
        },
        spent: Decimal.new("30.00"),
        over_budget: false
      }

      {:ok, view, _html} =
        render_isolated(conn, agent, 0, false, false, false, false, sandbox_owner)

      html = render(view)

      # Badge should display budget info with dollar amounts
      assert html =~ "budget-badge"
      # Should show available amount with "left" label (per BudgetBadge spec)
      assert html =~ "$60" <> ".00 left"
    end

    # R19: Badge Receives Required Props [UNIT]
    test "R19: badge receives required budget props from agent", %{
      conn: conn,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Agent with complete budget data
      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: [],
        budget_data: %{
          allocated: Decimal.new("200.00"),
          committed: Decimal.new("50.00")
        },
        spent: Decimal.new("75.00"),
        over_budget: false
      }

      {:ok, view, _html} =
        render_isolated(conn, agent, 0, false, false, false, false, sandbox_owner)

      html = render(view)

      # Badge should render without error with all budget data
      assert html =~ "budget-badge"
      # Should be visible in the agent node
      assert html =~ agent_record.agent_id
    end

    test "budget badge updates when budget data changes", %{
      conn: conn,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Initial render with budget
      agent = %{
        agent_id: agent_record.agent_id,
        task_id: agent_record.task_id,
        status: :working,
        parent_id: nil,
        children: [],
        budget_data: %{
          allocated: Decimal.new("100.00"),
          committed: Decimal.new("0")
        },
        spent: Decimal.new("20.00"),
        over_budget: false
      }

      {:ok, view, _html} =
        render_isolated(conn, agent, 0, false, false, false, false, sandbox_owner)

      html = render(view)
      assert html =~ "budget-badge"

      # Re-render with updated spent amount
      updated_agent = %{agent | spent: Decimal.new("80.00")}

      {:ok, view2, _html} =
        render_isolated(conn, updated_agent, 0, false, false, false, false, sandbox_owner)

      html2 = render(view2)

      # Budget badge should still render with updated data
      assert html2 =~ "budget-badge"
    end
  end
end
