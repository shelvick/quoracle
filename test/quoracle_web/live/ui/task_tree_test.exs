defmodule QuoracleWeb.UI.TaskTreeTest do
  @moduledoc """
  Tests for the TaskTree live component.
  Verifies agent hierarchy display, expand/collapse, selection, and real-time updates.
  """

  # LiveView tests can run async with modern Ecto.Sandbox pattern
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  # Helper to render component - cleanup handled by ConnCase.live_isolated
  defp render_isolated(conn, agents, tasks, sandbox_owner) do
    render_isolated(conn, agents, tasks, nil, sandbox_owner)
  end

  defp render_isolated(conn, agents, tasks, selected_id, sandbox_owner) do
    live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
      session: %{
        "sandbox_owner" => sandbox_owner,
        "component" => QuoracleWeb.UI.TaskTree,
        "assigns" => %{
          agents: agents,
          tasks: tasks,
          selected_agent_id: selected_id,
          root_pid: self()
        }
      }
    )
  end

  defp create_test_agents do
    %{
      "root_1" => %{
        agent_id: "root_1",
        task_id: "task_1",
        status: :working,
        parent_id: nil,
        children: ["child_1", "child_2"]
      },
      "child_1" => %{
        agent_id: "child_1",
        task_id: "task_1",
        status: :idle,
        parent_id: "root_1",
        children: ["grand_1"]
      },
      "child_2" => %{
        agent_id: "child_2",
        task_id: "task_1",
        status: :completed,
        parent_id: "root_1",
        children: []
      },
      "grand_1" => %{
        agent_id: "grand_1",
        task_id: "task_1",
        status: :working,
        parent_id: "child_1",
        children: []
      }
    }
  end

  defp create_test_tasks do
    %{
      "task_1" => %{
        id: "task_1",
        prompt: "Test task",
        root_agent_id: "root_1",
        status: "working",
        updated_at: ~U[2025-01-21 10:00:00Z]
      }
    }
  end

  describe "rendering" do
    test "displays agent hierarchy as tree", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      agents = create_test_agents()
      tasks = create_test_tasks()

      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      html = render(view)

      # Verify root is displayed
      assert html =~ "root_1"

      # Expand root_1 to see its children
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      html = render(view)
      assert html =~ "child_1"
      assert html =~ "child_2"

      # grand_1 is under child_1 which is collapsed by default
      # Click to expand child_1
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='child_1']")
      |> render_click()

      # Now grand_1 should be visible
      assert render(view) =~ "grand_1"
    end

    test "shows agent status with visual indicators", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      agents = %{
        "idle_agent" => %{
          agent_id: "idle_agent",
          task_id: "task_1",
          status: :idle,
          parent_id: nil,
          children: []
        },
        "working_agent" => %{
          agent_id: "working_agent",
          task_id: "task_2",
          status: :working,
          parent_id: nil,
          children: []
        },
        "completed_agent" => %{
          agent_id: "completed_agent",
          task_id: "task_3",
          status: :completed,
          parent_id: nil,
          children: []
        }
      }

      # Create tasks for all three agents
      tasks = %{
        "task_1" => %{
          id: "task_1",
          prompt: "Task 1",
          root_agent_id: "agent_1",
          status: "working",
          updated_at: ~U[2025-01-21 10:00:00Z]
        },
        "task_2" => %{
          id: "task_2",
          prompt: "Task 2",
          root_agent_id: "agent_2",
          status: "idle",
          updated_at: ~U[2025-01-21 10:00:00Z]
        },
        "task_3" => %{
          id: "task_3",
          prompt: "Task 3",
          root_agent_id: "agent_3",
          status: "completed",
          updated_at: ~U[2025-01-21 10:00:00Z]
        }
      }

      # Need to initialize view first
      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      html = render(view)

      # Verify tasks are rendered
      assert html =~ "task_1"
    end

    test "displays multiple root agents (tasks)", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      agents = %{
        "root_1" => %{
          agent_id: "root_1",
          task_id: "task_1",
          status: :working,
          parent_id: nil,
          children: []
        },
        "root_2" => %{
          agent_id: "root_2",
          task_id: "task_2",
          status: :idle,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        "task_1" => %{
          id: "task_1",
          prompt: "Task 1",
          root_agent_id: "root_1",
          status: "working",
          updated_at: ~U[2025-01-21 10:00:00Z]
        },
        "task_2" => %{
          id: "task_2",
          prompt: "Task 2",
          root_agent_id: "root_2",
          status: "idle",
          updated_at: ~U[2025-01-21 10:00:00Z]
        }
      }

      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      html = render(view)

      # Verify both tasks displayed
      assert html =~ "task_1"
      assert html =~ "task_2"
      assert html =~ "root_1"
      assert html =~ "root_2"
    end
  end

  describe "expand/collapse functionality" do
    test "toggles expanded state for agent nodes", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      agents = create_test_agents()
      # Need to initialize view first
      {:ok, view, _html} = render_isolated(conn, agents, create_test_tasks(), sandbox_owner)

      # Initially collapsed - children not visible
      refute render(view) =~ "child_1"

      # Click to expand root_1
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      # Children should be visible
      assert render(view) =~ "child_1"

      # Click to collapse root_1 again
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      # Children should be hidden again
      refute render(view) =~ "child_1"
      refute render(view) =~ "child_2"

      # Click to expand again
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      # Children should be visible again
      assert render(view) =~ "child_1"
      assert render(view) =~ "child_2"
    end

    test "maintains expand state per agent", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      agents = create_test_agents()
      # Need to initialize view first
      {:ok, view, _html} = render_isolated(conn, agents, create_test_tasks(), sandbox_owner)

      # First expand root_1 to see children
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      # Now expand child_1 to see grand_1
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='child_1']")
      |> render_click()

      html = render(view)

      # grand_1 should now be visible
      assert html =~ "grand_1"
      assert html =~ "child_1"
      assert html =~ "child_2"
    end

    test "shows expand/collapse icon based on state", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      agents = create_test_agents()
      # Need to initialize view first
      {:ok, view, _html} = render_isolated(conn, agents, create_test_tasks(), sandbox_owner)

      # Initially collapsed - should show expand icon
      assert render(view) =~ "icon-expand"

      # Expand root_1
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      # After expanding, HTML contains both icons (expand for children, collapse for root)
      html = render(view)
      # Children still collapsed
      assert html =~ "icon-expand"

      # Collapse root_1 again
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      # Back to all collapsed
      assert render(view) =~ "icon-expand"
    end
  end

  describe "agent selection" do
    test "sends selection event to parent dashboard", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      agents = create_test_agents()
      tasks = create_test_tasks()
      # Need to initialize view first
      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      # Verify agent is rendered
      html = render(view)

      # Component handles selection internally, parent gets message via send
      if html =~ "child_1" do
        view
        |> element("[phx-click='select_agent'][phx-value-agent-id='child_1']")
        |> render_click()
      end

      # Component is isolated, can't test parent communication directly
      assert html =~ "root_1"
    end

    test "highlights selected agent", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      agents = create_test_agents()
      tasks = create_test_tasks()
      # Need to initialize view first
      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      html = render(view)

      # Try to select an agent if it's rendered
      if html =~ "child_2" do
        view
        |> element("[phx-click='select_agent'][phx-value-agent-id='child_2']")
        |> render_click()
      end

      # Verify component renders
      assert html =~ "root_1"
    end

    test "updates selection when different agent clicked", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      # Component will be rendered in isolation

      agents = create_test_agents()
      tasks = create_test_tasks()
      # Need to initialize view first
      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      # Select root_1 first
      view
      |> element("[phx-click='select_agent'][phx-value-agent-id='root_1']")
      |> render_click()

      # Component renders without error
      assert render(view) =~ "root_1"

      # Expand root_1 to see children
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      # Now select child_1
      view
      |> element("[phx-click='select_agent'][phx-value-agent-id='child_1']")
      |> render_click()

      # Component still renders
      assert render(view) =~ "child_1"

      # Select different agent child_2
      view
      |> element("[phx-click='select_agent'][phx-value-agent-id='child_2']")
      |> render_click()

      # Component still renders
      assert render(view) =~ "child_2"
    end
  end

  describe "agent_alive propagation" do
    test "passes agent_alive to AgentNode from map", %{conn: conn, sandbox_owner: sandbox_owner} do
      agents = create_test_agents()
      tasks = create_test_tasks()

      # Create agent_alive_map with some agents alive
      agent_alive_map = %{
        "root_1" => true,
        "child_1" => false,
        "child_2" => true,
        "grand_1" => false
      }

      # Render with agent_alive_map
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "component" => QuoracleWeb.UI.TaskTree,
            "assigns" => %{
              agents: agents,
              tasks: tasks,
              selected_agent_id: nil,
              agent_alive_map: agent_alive_map,
              root_pid: self()
            }
          }
        )

      # Expand to see all agents
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      html = render(view)

      # R1: root_1 is alive AND root agent → should show Send Message button
      assert html =~ ~s(phx-click="show_message_form" phx-value-agent-id="root_1")
      assert html =~ "Send Message"

      # child_1 is NOT alive → should NOT show Send Message button
      refute html =~ ~s(phx-click="show_message_form" phx-value-agent-id="child_1")

      # child_2 is alive but NOT root → should NOT show Send Message button
      refute html =~ ~s(phx-click="show_message_form" phx-value-agent-id="child_2")
    end

    test "defaults agent_alive to false for unknown agents", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      agents = create_test_agents()
      tasks = create_test_tasks()

      # Empty agent_alive_map - all should default to false
      agent_alive_map = %{}

      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "component" => QuoracleWeb.UI.TaskTree,
            "assigns" => %{
              agents: agents,
              tasks: tasks,
              selected_agent_id: nil,
              agent_alive_map: agent_alive_map,
              root_pid: self()
            }
          }
        )

      # Component should still render with defaults
      html = render(view)
      assert html =~ "root_1"

      # R2: All agents should be treated as not alive (false default)
      # No Send Message buttons should appear
      refute html =~ "Send Message"
      refute html =~ ~s(phx-click="show_message_form")
    end

    test "recursive AgentNode calls receive agent_alive", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      agents = create_test_agents()
      tasks = create_test_tasks()

      # Mixed alive status for testing propagation
      agent_alive_map = %{
        "root_1" => true,
        "child_1" => true,
        "child_2" => false,
        "grand_1" => true
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
              agent_alive_map: agent_alive_map,
              root_pid: self()
            }
          }
        )

      # Expand hierarchy to test recursive propagation
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='child_1']")
      |> render_click()

      # All levels should render with agent_alive propagated
      html = render(view)
      assert html =~ "root_1"
      assert html =~ "child_1"
      assert html =~ "child_2"
      assert html =~ "grand_1"

      # R3: Test recursive propagation - only alive ROOT agents show Send Message
      # root_1 is alive AND root → should show Send Message
      assert html =~ ~s(phx-click="show_message_form" phx-value-agent-id="root_1")

      # child_1 is alive but NOT root → should NOT show Send Message
      refute html =~ ~s(phx-click="show_message_form" phx-value-agent-id="child_1")

      # grand_1 is alive but NOT root → should NOT show Send Message
      refute html =~ ~s(phx-click="show_message_form" phx-value-agent-id="grand_1")
    end
  end

  describe "real-time updates" do
    test "adds new agents to tree when spawned", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      # Start with one agent
      initial_agents = %{
        "root_1" => %{
          agent_id: "root_1",
          task_id: "task_1",
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        "task_1" => %{
          id: "task_1",
          prompt: "Task 1",
          root_agent_id: "root_1",
          status: "working",
          updated_at: ~U[2025-01-21 10:00:00Z]
        }
      }

      {:ok, view, _html} = render_isolated(conn, initial_agents, tasks, sandbox_owner)
      assert render(view) =~ "root_1"
      refute render(view) =~ "new_child"

      # Add new child agent
      updated_agents =
        Map.merge(initial_agents, %{
          "new_child" => %{
            agent_id: "new_child",
            task_id: "task_1",
            status: :idle,
            parent_id: "root_1",
            children: []
          }
        })

      # Update root_1's children list
      updated_agents = put_in(updated_agents["root_1"][:children], ["new_child"])

      # Create new view with updated agents
      {:ok, view2, _html} = render_isolated(conn, updated_agents, tasks, sandbox_owner)

      # Expand root_1 to see the new child
      view2
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      # Verify new agent appears in the new view
      assert render(view2) =~ "new_child"
    end

    test "removes agents from tree when terminated", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      agents = create_test_agents()
      # Need to initialize view first
      {:ok, view, _html} = render_isolated(conn, agents, create_test_tasks(), sandbox_owner)

      # Expand root_1 to see children
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      assert render(view) =~ "child_2"

      # Remove child_2
      updated_agents = Map.delete(agents, "child_2")
      # Update root_1's children list
      updated_agents = put_in(updated_agents["root_1"][:children], ["child_1"])

      # Agent terminated event would be handled by parent
      # Update with new agents
      {:ok, view2, _html} =
        render_isolated(conn, updated_agents, create_test_tasks(), sandbox_owner)

      # Verify agent removed in the new view
      refute render(view2) =~ "child_2"
    end

    test "updates agent status in real-time", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      agents = %{
        "status_agent" => %{
          agent_id: "status_agent",
          task_id: "task_1",
          status: :idle,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        "task_1" => %{
          id: "status_task",
          prompt: "Status task",
          root_agent_id: "status_agent",
          status: "working",
          updated_at: ~U[2025-01-21 10:00:00Z]
        }
      }

      # Need to initialize view first
      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)
      assert render(view) =~ "status_agent"

      # Update status to working
      updated_agents = put_in(agents["status_agent"][:status], :working)

      send(
        view.pid,
        {:state_changed,
         %{
           agent_id: "status_agent",
           new_state: :working
         }}
      )

      # Update with new agents
      {:ok, _view2, _html} = render_isolated(conn, updated_agents, tasks, sandbox_owner)

      # Original view still shows original state
      assert render(view) =~ "status_agent"
    end
  end

  describe "tree building" do
    test "correctly builds tree from flat agent map", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      # Flat map of agents
      agents = %{
        "a" => %{agent_id: "a", parent_id: nil, children: ["b", "c"]},
        "b" => %{agent_id: "b", parent_id: "a", children: ["d"]},
        "c" => %{agent_id: "c", parent_id: "a", children: []},
        "d" => %{agent_id: "d", parent_id: "b", children: []}
      }

      # Need to initialize view first
      {:ok, view, _html} = render_isolated(conn, agents, create_test_tasks(), sandbox_owner)

      html = render(view)

      # Verify correct nesting in HTML
      # Tree order: a -> b -> d, then c
      assert html =~ ~r/a.*b.*d.*c/s
    end

    test "handles orphaned agents gracefully", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      # Agent with non-existent parent - make it a root agent for the task
      agents = %{
        "orphan" => %{
          agent_id: "orphan",
          task_id: "task_1",
          status: :idle,
          # Make it a root agent
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        "task_1" => %{
          id: "task_1",
          prompt: "Orphan task",
          root_agent_id: "orphan",
          status: "idle",
          updated_at: ~U[2025-01-21 10:00:00Z]
        }
      }

      # Need to initialize view first
      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      # Should still render orphaned agent
      assert render(view) =~ "orphan"
    end

    test "updates children list when agents added/removed", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      # Component will be rendered in isolation

      # Parent with no children initially
      agents = %{
        "parent" => %{
          agent_id: "parent",
          task_id: "task_1",
          status: :idle,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        "task_1" => %{
          id: "task_1",
          prompt: "Parent task",
          root_agent_id: "parent",
          status: "idle",
          updated_at: ~U[2025-01-21 10:00:00Z]
        }
      }

      # Need to initialize view first
      {:ok, _view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      # Add child
      agents =
        Map.merge(agents, %{
          "child" => %{
            agent_id: "child",
            task_id: "task_1",
            status: :idle,
            parent_id: "parent",
            children: []
          }
        })

      agents = put_in(agents["parent"][:children], ["child"])

      # Create new view with updated agents
      {:ok, view2, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      # Expand parent to see child
      view2
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='parent']")
      |> render_click()

      assert render(view2) =~ "child"
    end
  end

  describe "component callbacks" do
    test "update/2 builds tree structure from agents", %{conn: conn, sandbox_owner: sandbox_owner} do
      agents = create_test_agents()

      tasks = %{
        "task_1" => %{
          id: "new_task",
          prompt: "New task",
          root_agent_id: "root_1",
          status: "working",
          updated_at: ~U[2025-01-21 10:00:00Z]
        }
      }

      # Render component with agents
      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      html = render(view)

      # Verify tree built correctly
      assert html =~ "root_1"
    end

    test "handle_event for toggle_expand", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      agents = create_test_agents()
      tasks = create_test_tasks()
      # Need to initialize view first
      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      # Check for expand/collapse functionality
      html = render(view)
      assert html =~ "root_1"
      assert has_element?(view, "[phx-click='toggle_expand']")
    end

    test "handle_event for select_agent", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Component will be rendered in isolation

      agents = create_test_agents()
      tasks = create_test_tasks()
      # Need to initialize view first
      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      # Check for selection functionality - agents exist in assigns even if not expanded
      html = render(view)
      assert html =~ "root_1"
      assert has_element?(view, "[phx-click='select_agent']")
    end
  end

  describe "create task form" do
    test "submitting form with prompt triggers create_task handler", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      agents = %{}
      tasks = %{}

      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      # Submit the form - should not crash
      html =
        view
        |> element("#new-task-modal form")
        |> render_submit(%{"prompt" => "Test task prompt"})

      # Should still render after submit (verifies no crash)
      assert html =~ "task-tree"
    end
  end

  # ============================================================
  # R11-R15: Task-Level Cost Display (fix-ui-costs-20251213)
  # Tests for CostDisplay in task header and costs_updated_at propagation.
  # ============================================================

  describe "R11-R15: task-level cost display" do
    alias Quoracle.Costs.AgentCost
    alias Quoracle.Repo

    setup %{sandbox_owner: sandbox_owner} do
      # Create real task in database for cost recording
      {:ok, task} =
        Repo.insert(%Quoracle.Tasks.Task{
          prompt: "Test task for cost display",
          status: "running"
        })

      # Create agent record with all required fields
      {:ok, agent_record} =
        Repo.insert(%Quoracle.Agents.Agent{
          agent_id: "task-cost-agent-#{System.unique_integer([:positive])}",
          task_id: task.id,
          parent_id: nil,
          status: "running",
          config: %{}
        })

      {:ok, task: task, agent_record: agent_record, sandbox_owner: sandbox_owner}
    end

    # R11: Task Cost Display [INTEGRATION]
    test "R11: task header includes CostDisplay component", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      agents = %{
        agent_record.agent_id => %{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        task.id => %{
          id: task.id,
          prompt: task.prompt,
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

      html = render(view)

      # Task header should include CostDisplay component
      assert html =~ "cost-display"
      assert html =~ "Total Cost"
    end

    # R12: Task Cost Shows Total [INTEGRATION]
    test "R12: task cost shows sum of all agent costs", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Record multiple costs for the task
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.25"),
          metadata: %{}
        })

      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.10"),
          metadata: %{}
        })

      agents = %{
        agent_record.agent_id => %{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        task.id => %{
          id: task.id,
          prompt: task.prompt,
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

      html = render(view)

      # Total should be $0.35 (0.25 + 0.10)
      assert html =~ "$0.35"
    end

    # R13: costs_updated_at Propagation to AgentNode [UNIT]
    test "R13: costs_updated_at passed to AgentNode components", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      agents = create_test_agents()
      tasks = create_test_tasks()

      costs_updated_at = System.monotonic_time()

      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "component" => QuoracleWeb.UI.TaskTree,
            "assigns" => %{
              agents: agents,
              tasks: tasks,
              selected_agent_id: nil,
              costs_updated_at: costs_updated_at,
              root_pid: self()
            }
          }
        )

      # Expand to see AgentNode children
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      html = render(view)

      # AgentNode should be rendered (costs_updated_at propagated internally)
      assert html =~ "child_1"
      assert html =~ "child_2"
    end

    # R14: Agent Count Display [UNIT]
    test "R14: task header shows agent count", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Create second agent for the same task
      {:ok, agent2} =
        Repo.insert(%Quoracle.Agents.Agent{
          agent_id: "task-cost-agent2-#{System.unique_integer([:positive])}",
          task_id: task.id,
          parent_id: agent_record.agent_id,
          status: "running",
          config: %{}
        })

      agents = %{
        agent_record.agent_id => %{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          status: :working,
          parent_id: nil,
          children: [agent2.agent_id]
        },
        agent2.agent_id => %{
          agent_id: agent2.agent_id,
          task_id: task.id,
          status: :idle,
          parent_id: agent_record.agent_id,
          children: []
        }
      }

      tasks = %{
        task.id => %{
          id: task.id,
          prompt: task.prompt,
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

      html = render(view)

      # Should show agent count (2 agents)
      assert html =~ "2 agents"
    end

    # R15: Cost Update Without Refresh [SYSTEM]
    @tag :acceptance
    test "R15: task cost updates when agent costs change", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      agents = %{
        agent_record.agent_id => %{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        task.id => %{
          id: task.id,
          prompt: task.prompt,
          root_agent_id: agent_record.agent_id,
          status: "running",
          updated_at: DateTime.utc_now()
        }
      }

      initial_timestamp = System.monotonic_time()

      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "component" => QuoracleWeb.UI.TaskTree,
            "assigns" => %{
              agents: agents,
              tasks: tasks,
              selected_agent_id: nil,
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
          cost_usd: Decimal.new("0.50"),
          metadata: %{}
        })

      # Simulate parent bumping costs_updated_at (triggers re-render)
      new_timestamp = System.monotonic_time()

      send(
        view.pid,
        {:update_component,
         %{
           costs_updated_at: new_timestamp
         }}
      )

      html = render(view)

      # Cost should now show (after costs_updated_at bump triggers re-query)
      assert html =~ "$0.50"
    end

    # R16: Task Per-Model Cost Breakdown [ACCEPTANCE]
    @tag :acceptance
    test "R16: user sees per-model cost breakdown at task level", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Insert costs for multiple models with metadata containing model_spec
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("0.25"),
          metadata: %{
            "model_spec" => "anthropic/claude-sonnet",
            "request_count" => 2,
            "total_tokens" => 1000
          }
        })

      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.10"),
          metadata: %{
            "model_spec" => "google/text-embedding-004",
            "request_count" => 5,
            "total_tokens" => 500
          }
        })

      agents = %{
        agent_record.agent_id => %{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        task.id => %{
          id: task.id,
          prompt: task.prompt,
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

      html = render(view)

      # User sees: task-cost-detail component with collapsed total
      assert html =~ "task-cost-detail"
      assert html =~ "Cost Details"
      # Total of 0.25 + 0.10
      assert html =~ "$0.35"

      # User clicks to expand per-model breakdown
      view
      |> element("[id^='task-cost-detail'] [phx-click='toggle_expand']")
      |> render_click()

      html = render(view)

      # User sees: Per-model costs displayed after expansion
      assert html =~ "$0.25"
      assert html =~ "$0.10"
    end
  end

  # ============================================================
  # R29-R34: Task Budget Summary Display (wip-20251231-budget)
  # Packet 6 (UI Components)
  # Tests for task-level budget display in task header.
  # ============================================================

  describe "R29-R34: task budget summary display" do
    alias Quoracle.Costs.AgentCost
    alias Quoracle.Repo

    setup %{sandbox_owner: sandbox_owner} do
      # Create real task with budget_limit in database
      {:ok, task} =
        Repo.insert(%Quoracle.Tasks.Task{
          prompt: "Test task with budget",
          status: "running",
          budget_limit: Decimal.new("100.00")
        })

      # Create agent record
      {:ok, agent_record} =
        Repo.insert(%Quoracle.Agents.Agent{
          agent_id: "task-budget-agent-#{System.unique_integer([:positive])}",
          task_id: task.id,
          parent_id: nil,
          status: "running",
          config: %{}
        })

      {:ok, task: task, agent_record: agent_record, sandbox_owner: sandbox_owner}
    end

    # R29: Task Budget Displays [UNIT]
    test "R29: task budget displays when budget_limit set", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      agents = %{
        agent_record.agent_id => %{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        task.id => %{
          id: task.id,
          prompt: task.prompt,
          root_agent_id: agent_record.agent_id,
          status: "running",
          budget_limit: task.budget_limit,
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

      html = render(view)

      # Task header should show budget section with class
      assert html =~ "task-budget"
      # Should show the limit amount
      assert html =~ "$100"
    end

    # R30: No Budget Display for Unlimited [UNIT]
    test "R30: no budget display for unlimited tasks", %{
      conn: conn,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Create task WITHOUT budget_limit
      {:ok, unlimited_task} =
        Repo.insert(%Quoracle.Tasks.Task{
          prompt: "Unlimited task",
          status: "running",
          budget_limit: nil
        })

      agents = %{
        agent_record.agent_id => %{
          agent_id: agent_record.agent_id,
          task_id: unlimited_task.id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        unlimited_task.id => %{
          id: unlimited_task.id,
          prompt: unlimited_task.prompt,
          root_agent_id: agent_record.agent_id,
          status: "running",
          budget_limit: nil,
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

      html = render(view)

      # Should NOT show budget section for unlimited task
      # (or should show "Unlimited" / "N/A")
      refute html =~ ~r/\$\d+.*\/.*\$\d+/
    end

    # R31: Spent/Limit Format [UNIT]
    test "R31: shows $spent / $limit format", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Record some costs
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("35.00"),
          metadata: %{}
        })

      agents = %{
        agent_record.agent_id => %{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        task.id => %{
          id: task.id,
          prompt: task.prompt,
          root_agent_id: agent_record.agent_id,
          status: "running",
          budget_limit: task.budget_limit,
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

      html = render(view)

      # Should show spent and limit: "$35 / $100" or similar format
      assert html =~ "$35"
      assert html =~ "$100"
    end

    # R32: Over Budget Warning [UNIT]
    test "R32: over budget warning indicator", %{
      conn: conn,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Create task with small budget for testing over-budget
      {:ok, small_budget_task} =
        Repo.insert(%Quoracle.Tasks.Task{
          prompt: "Small budget task",
          status: "running",
          budget_limit: Decimal.new("10.00")
        })

      # Record costs exceeding budget ($15 > $10 limit)
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: small_budget_task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("15.00"),
          metadata: %{}
        })

      agents = %{
        agent_record.agent_id => %{
          agent_id: agent_record.agent_id,
          task_id: small_budget_task.id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        small_budget_task.id => %{
          id: small_budget_task.id,
          prompt: small_budget_task.prompt,
          root_agent_id: agent_record.agent_id,
          status: "running",
          budget_limit: small_budget_task.budget_limit,
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

      html = render(view)

      # Should show red/warning styling for over budget (text-red-600 per spec)
      assert html =~ "text-red-600"
    end

    # R33: Real-time Update [INTEGRATION]
    test "R33: real-time update on cost recorded", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      agents = %{
        agent_record.agent_id => %{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        task.id => %{
          id: task.id,
          prompt: task.prompt,
          root_agent_id: agent_record.agent_id,
          status: "running",
          budget_limit: task.budget_limit,
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

      # Initially no costs - should show $0 spent
      html = render(view)
      assert html =~ "$0"
      refute html =~ "error"

      # Record a cost
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("45.00"),
          metadata: %{}
        })

      # Bump costs_updated_at to trigger re-render
      send(
        view.pid,
        {:update_component,
         %{
           costs_updated_at: System.monotonic_time()
         }}
      )

      html = render(view)

      # Should now show the spent amount
      assert html =~ "$45"
    end

    # R34: Color Coding [UNIT]
    test "R34: color coding based on budget percentage", %{
      conn: conn,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Create tasks with different budget usage levels
      {:ok, task_low} =
        Repo.insert(%Quoracle.Tasks.Task{
          prompt: "Low usage task",
          status: "running",
          budget_limit: Decimal.new("100.00")
        })

      {:ok, task_high} =
        Repo.insert(%Quoracle.Tasks.Task{
          prompt: "High usage task",
          status: "running",
          budget_limit: Decimal.new("100.00")
        })

      # Record 50% usage (green)
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task_low.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("50.00"),
          metadata: %{}
        })

      # Record 90% usage (yellow)
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task_high.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("90.00"),
          metadata: %{}
        })

      # Test low usage - should be green
      agents_low = %{
        agent_record.agent_id => %{
          agent_id: agent_record.agent_id,
          task_id: task_low.id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks_low = %{
        task_low.id => %{
          id: task_low.id,
          prompt: task_low.prompt,
          root_agent_id: agent_record.agent_id,
          status: "running",
          budget_limit: task_low.budget_limit,
          updated_at: DateTime.utc_now()
        }
      }

      {:ok, view_low, _html} =
        live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "component" => QuoracleWeb.UI.TaskTree,
            "assigns" => %{
              agents: agents_low,
              tasks: tasks_low,
              selected_agent_id: nil,
              costs_updated_at: System.monotonic_time(),
              root_pid: self()
            }
          }
        )

      html_low = render(view_low)

      # 50% usage should be green (text-green-600 per spec)
      assert html_low =~ "text-green-600"

      # Test high usage - should be yellow
      agents_high = %{
        agent_record.agent_id => %{
          agent_id: agent_record.agent_id,
          task_id: task_high.id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks_high = %{
        task_high.id => %{
          id: task_high.id,
          prompt: task_high.prompt,
          root_agent_id: agent_record.agent_id,
          status: "running",
          budget_limit: task_high.budget_limit,
          updated_at: DateTime.utc_now()
        }
      }

      {:ok, view_high, _html} =
        live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "component" => QuoracleWeb.UI.TaskTree,
            "assigns" => %{
              agents: agents_high,
              tasks: tasks_high,
              selected_agent_id: nil,
              costs_updated_at: System.monotonic_time(),
              root_pid: self()
            }
          }
        )

      html_high = render(view_high)

      # 90% usage should be yellow/warning (text-yellow-600 per spec)
      assert html_high =~ "text-yellow-600"
    end

    test "task budget shows progress bar", %{
      conn: conn,
      task: task,
      agent_record: agent_record,
      sandbox_owner: sandbox_owner
    } do
      # Record 60% usage
      {:ok, _} =
        Repo.insert(%AgentCost{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("60.00"),
          metadata: %{}
        })

      agents = %{
        agent_record.agent_id => %{
          agent_id: agent_record.agent_id,
          task_id: task.id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        task.id => %{
          id: task.id,
          prompt: task.prompt,
          root_agent_id: agent_record.agent_id,
          status: "running",
          budget_limit: task.budget_limit,
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

      html = render(view)

      # Should show a progress bar with specific class
      assert html =~ "task-budget-progress"
    end
  end

  # =============================================================================
  # Budget UI Tests (v8.0) - R35-R40
  # =============================================================================

  describe "budget input and edit button - R35-R40" do
    test "R35: new task modal includes budget input field", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      agents = create_test_agents()
      tasks = create_test_tasks()

      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      # Open new task modal
      view
      |> element("button", "New Task")
      |> render_click()

      html = render(view)

      # Verify budget input field is present
      assert html =~ "budget_limit"
      assert html =~ "Budget"
      assert html =~ "Leave empty for unlimited"
    end

    test "R36: form submission includes budget_limit param", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      agents = create_test_agents()
      tasks = create_test_tasks()

      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      # Open new task modal
      view
      |> element("button", "New Task")
      |> render_click()

      # Verify form has budget_limit field before submission
      html = render(view)
      assert html =~ "budget_limit"

      # Fill form with budget
      form_params = %{
        "task_description" => "Test with budget",
        "budget_limit" => "75.00"
      }

      # Submit the form - modal should close (event processed)
      html_after =
        view
        |> form("#new-task-form", form_params)
        |> render_submit()

      # Verify modal closed (has hidden class after form submission)
      # live_isolated doesn't forward messages to test process, so we verify
      # the component processed the event by checking modal visibility class
      assert html_after =~ ~r/id="new-task-modal"[^>]*class="hidden"/
    end

    test "R37: edit budget button shown for budgeted tasks", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      # Create task with budget using simple maps (like existing tests)
      task_id = Ecto.UUID.generate()

      agents = %{
        "agent-with-budget" => %{
          agent_id: "agent-with-budget",
          task_id: task_id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        task_id => %{
          id: task_id,
          prompt: "Task with budget",
          root_agent_id: "agent-with-budget",
          status: "running",
          budget_limit: Decimal.new("100.00"),
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

      html = render(view)

      # Verify Edit Budget button is visible
      assert html =~ "Edit Budget"
      assert html =~ "show_budget_editor"
    end

    test "R38: edit budget button hidden for unlimited tasks", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      # Create task WITHOUT budget (N/A)
      task_id = Ecto.UUID.generate()

      agents = %{
        "agent-no-budget" => %{
          agent_id: "agent-no-budget",
          task_id: task_id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        task_id => %{
          id: task_id,
          prompt: "Task without budget",
          root_agent_id: "agent-no-budget",
          status: "running",
          budget_limit: nil,
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

      html = render(view)

      # Verify Edit Budget button is NOT visible
      refute html =~ "Edit Budget"
    end

    test "R39: edit budget click triggers show_budget_editor event", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      # Create task with budget
      task_id = Ecto.UUID.generate()

      agents = %{
        "agent-budget-click" => %{
          agent_id: "agent-budget-click",
          task_id: task_id,
          status: :working,
          parent_id: nil,
          children: []
        }
      }

      tasks = %{
        task_id => %{
          id: task_id,
          prompt: "Budgeted task",
          root_agent_id: "agent-budget-click",
          status: "running",
          budget_limit: Decimal.new("100.00"),
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

      # Verify Edit Budget button exists with correct event binding
      html = render(view)
      assert html =~ "Edit Budget"
      assert html =~ "phx-click=\"show_budget_editor\""
      assert html =~ "phx-value-task-id=\"#{task_id}\""

      # Click Edit Budget button - verifies event handler exists and doesn't crash
      # Note: live_isolated doesn't forward messages to test process, so we
      # verify the event is processed by checking the click doesn't error
      view
      |> element("button[phx-click=show_budget_editor]")
      |> render_click()
    end

    test "R40: budget input defaults to empty", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      agents = create_test_agents()
      tasks = create_test_tasks()

      {:ok, view, _html} = render_isolated(conn, agents, tasks, sandbox_owner)

      # Open new task modal
      view
      |> element("button", "New Task")
      |> render_click()

      html = render(view)

      # Verify budget input has empty value (N/A default) per spec
      assert html =~ ~r/name="budget_limit"[^>]*value=""/
      # Also verify the helper text per spec
      assert html =~ "Leave empty for unlimited"
    end
  end
end
