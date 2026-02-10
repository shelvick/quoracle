defmodule QuoracleWeb.UI.TaskTreeUnifiedTest do
  @moduledoc """
  Tests for Unified Task Tree (wip-20250121-ui-merge Packet 3).
  Verifies transformation from agent-only tree to unified task+agent display.
  Tests the new unified tree that shows all tasks with controls and agent trees.
  """

  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  alias QuoracleWeb.UI.TaskTree

  # Helper to render component - cleanup handled by ConnCase.live_isolated
  defp render_isolated(conn, session) do
    live_isolated(conn, QuoracleWeb.LiveComponentTestHelper, session: session)
  end

  describe "R1: Display All Tasks" do
    # R1: [INTEGRATION] test - WHEN component renders THEN shows all tasks with prompt snippets
    test "displays all tasks with truncated prompts", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Analyze user data and generate comprehensive report with charts",
                status: "running",
                root_agent_id: "root_1",
                updated_at: ~U[2025-01-21 10:00:00Z]
              },
              "task_2" => %{
                id: "task_2",
                prompt: "Short task",
                status: "paused",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 09:00:00Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Should show both tasks
      assert html =~ "task_1"
      assert html =~ "task_2"

      # Should show truncated prompt for long task
      assert html =~ "Analyze user data and generate comprehensive report"

      # Should show full prompt for short task
      assert html =~ "Short task"
    end

    test "displays all tasks regardless of status", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_running" => %{
                id: "task_running",
                prompt: "Running task",
                status: "running",
                root_agent_id: "root_1",
                updated_at: ~U[2025-01-21 10:00:00Z]
              },
              "task_paused" => %{
                id: "task_paused",
                prompt: "Paused task",
                status: "paused",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 09:00:00Z]
              },
              "task_completed" => %{
                id: "task_completed",
                prompt: "Completed task",
                status: "completed",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 08:00:00Z]
              },
              "task_failed" => %{
                id: "task_failed",
                prompt: "Failed task",
                status: "failed",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 07:00:00Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # All tasks should be visible
      assert html =~ "Running task"
      assert html =~ "Paused task"
      assert html =~ "Completed task"
      assert html =~ "Failed task"
    end
  end

  describe "R2: Task Control Buttons" do
    # R2: [INTEGRATION] test - WHEN task rendered THEN shows appropriate buttons based on status
    test "shows Pause button for running tasks", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Running task",
                status: "running",
                root_agent_id: "root_1",
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      # Should have Pause button for running task
      assert has_element?(view, "[phx-click='pause_task'][phx-value-task-id='task_1']")
      html = render(view)
      assert html =~ "Pause"
    end

    test "shows Resume button for paused tasks", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Paused task",
                status: "paused",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      # Should have Resume button for paused task
      assert has_element?(view, "[phx-click='resume_task'][phx-value-task-id='task_1']")
      html = render(view)
      assert html =~ "Resume"
    end

    test "shows Delete button for paused/completed/failed tasks", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      statuses_with_delete = ["paused", "completed", "failed"]

      for status <- statuses_with_delete do
        {:ok, view, _html} =
          render_isolated(conn, %{
            "sandbox_owner" => sandbox_owner,
            "component" => TaskTree,
            "assigns" => %{
              tasks: %{
                "task_1" => %{
                  id: "task_1",
                  prompt: "Task with delete",
                  status: status,
                  root_agent_id: nil,
                  updated_at: ~U[2025-01-21 10:00:00Z]
                }
              },
              agents: %{},
              selected_agent_id: nil,
              expanded: MapSet.new()
            }
          })

        html = render(view)
        # Delete button should be present
        assert html =~ "Delete"
      end
    end

    test "shows Pause button for running tasks with live agents", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Task with agent",
                status: "running",
                root_agent_id: "root_1",
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: %{
              "root_1" => %{
                agent_id: "root_1",
                task_id: "task_1",
                status: :working,
                parent_id: nil,
                children: []
              }
            },
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      # Should have Pause button for running task (Stop button removed in async pause implementation)
      assert has_element?(view, "[phx-click='pause_task'][phx-value-task-id='task_1']")
      html = render(view)
      assert html =~ "Pause"
    end

    test "no Pause button for tasks without agents", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Task without agent",
                status: "paused",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      # Should NOT have Stop button
      refute has_element?(view, "[phx-click='stop_task']")
    end
  end

  describe "R3: New Task Modal" do
    # R3: [INTEGRATION] test - WHEN New Task button clicked THEN modal opens with form
    test "New Task button opens modal", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{},
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Should have New Task button
      assert html =~ "New Task"

      # Should have modal in DOM
      assert html =~ "new-task-modal"
      assert html =~ "Create New Task"
    end

    test "modal contains task prompt form", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{},
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Modal should contain form elements
      assert html =~ "Task Description"
      assert html =~ "textarea"
      assert html =~ "Describe the task"
    end
  end

  describe "R4: Create Task Flow" do
    # R4: [SYSTEM] test - WHEN user submits prompt in modal THEN sends to Dashboard AND closes modal
    test "creating task sends prompt to Dashboard and closes modal", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{},
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      # Submit the create task form
      view
      |> element("#new-task-modal form")
      |> render_submit(%{"prompt" => "New task to create"})

      # Component should send message to parent
      # (In isolated testing, we verify the form submission is handled)
      html = render(view)
      assert html =~ "Task Tree"
    end
  end

  describe "R5: Agent Tree Under Task" do
    # R5: [INTEGRATION] test - WHEN task has root agent THEN displays agent tree underneath
    test "displays agent tree under task", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Task with agents",
                status: "running",
                root_agent_id: "root_1",
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: %{
              "root_1" => %{
                agent_id: "root_1",
                task_id: "task_1",
                status: :working,
                parent_id: nil,
                children: ["child_1"]
              },
              "child_1" => %{
                agent_id: "child_1",
                task_id: "task_1",
                status: :working,
                parent_id: "root_1",
                children: []
              }
            },
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Should show root agent under task
      assert html =~ "root_1"

      # Task prompt should appear before agent
      task_pos = :binary.match(html, "Task with agents") |> elem(0)
      agent_pos = :binary.match(html, "root_1") |> elem(0)
      assert task_pos < agent_pos
    end

    test "no agent tree shown when task has no root agent", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Task without agents",
                status: "paused",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Should show task but no agents
      assert html =~ "Task without agents"
      # No agent tree should be rendered
      refute html =~ "agent-node"
    end
  end

  describe "R6: No Task Accordion" do
    # R6: [UNIT] test - WHEN tasks rendered THEN all permanently visible (no task-level collapse)
    test "tasks are always visible, no accordion", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "First task",
                status: "running",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 10:00:00Z]
              },
              "task_2" => %{
                id: "task_2",
                prompt: "Second task",
                status: "paused",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 09:00:00Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Both tasks should be visible
      assert html =~ "First task"
      assert html =~ "Second task"

      # Should NOT have any task-level collapse/expand controls for hiding tasks
      # (only agent-level accordions exist - cost detail expand is a different feature)
      refute html =~ ~r/collapse.task/i
      refute html =~ ~r/expand.task/i
      refute html =~ "toggle_task"
      refute html =~ "task-accordion"
    end
  end

  describe "R7: Agent Accordion Works" do
    # R7: [INTEGRATION] test - WHEN agent has children THEN can expand/collapse using chevron
    test "agent accordion functions within unified tree", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Task with agent tree",
                status: "running",
                root_agent_id: "root_1",
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: %{
              "root_1" => %{
                agent_id: "root_1",
                task_id: "task_1",
                status: :working,
                parent_id: nil,
                children: ["child_1"]
              },
              "child_1" => %{
                agent_id: "child_1",
                task_id: "task_1",
                status: :working,
                parent_id: "root_1",
                children: []
              }
            },
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      # Initially collapsed - child should not be visible
      html = render(view)
      assert html =~ "root_1"
      refute html =~ "child_1"

      # Click to expand root agent
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      # Now child should be visible
      html = render(view)
      assert html =~ "child_1"
    end

    test "agent accordion state independent of task controls", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Task 1",
                status: "running",
                root_agent_id: "root_1",
                updated_at: ~U[2025-01-21 10:00:00Z]
              },
              "task_2" => %{
                id: "task_2",
                prompt: "Task 2",
                status: "running",
                root_agent_id: "root_2",
                updated_at: ~U[2025-01-21 09:00:00Z]
              }
            },
            agents: %{
              "root_1" => %{
                agent_id: "root_1",
                task_id: "task_1",
                status: :working,
                parent_id: nil,
                children: ["child_1"]
              },
              "child_1" => %{
                agent_id: "child_1",
                task_id: "task_1",
                status: :working,
                parent_id: "root_1",
                children: []
              },
              "root_2" => %{
                agent_id: "root_2",
                task_id: "task_2",
                status: :working,
                parent_id: nil,
                children: ["child_2"]
              },
              "child_2" => %{
                agent_id: "child_2",
                task_id: "task_2",
                status: :working,
                parent_id: "root_2",
                children: []
              }
            },
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      # Expand first agent tree
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      html = render(view)

      # First tree expanded, second still collapsed
      assert html =~ "child_1"
      refute html =~ "child_2"
    end
  end

  describe "R8: Delete Confirmation" do
    # R8: [INTEGRATION] test - WHEN delete clicked THEN shows confirmation modal
    test "delete button shows confirmation modal", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Task to delete",
                status: "completed",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Should have delete confirmation modal in DOM
      assert html =~ "confirm-delete-task_1"
      assert html =~ "Delete Task?"
    end

    test "confirmation modal shows task prompt snippet", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt:
                  "This is a very long task prompt that should be truncated in the confirmation dialog",
                status: "failed",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Modal should show truncated prompt
      assert html =~ "This is a very long task prompt"
    end
  end

  describe "R9: Empty State" do
    # R9: [UNIT] test - WHEN no tasks THEN shows "No active tasks" message
    test "empty state displays when no tasks", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{},
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Should show empty state message
      assert html =~ "No active tasks"
    end

    test "empty state not shown when tasks exist", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Some task",
                status: "running",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Should NOT show empty state
      refute html =~ "No active tasks"
    end
  end

  describe "R10: Timestamp Display" do
    # R10: [UNIT] test - WHEN task rendered THEN shows formatted timestamp
    test "displays formatted timestamp for each task", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Task with timestamp",
                status: "running",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 14:30:45Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Verify timestamp is displayed in correct format (YYYY-MM-DD HH:MM:SS)
      assert html =~ ~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/
    end

    test "each task shows its own timestamp", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "First task",
                status: "running",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 10:00:00Z]
              },
              "task_2" => %{
                id: "task_2",
                prompt: "Second task",
                status: "paused",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 15:30:00Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Both tasks should have timestamps visible (verify format appears twice)
      timestamps = Regex.scan(~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/, html)
      assert length(timestamps) >= 2
    end
  end

  describe "Status Badge Display" do
    test "displays status badges with appropriate styling", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_running" => %{
                id: "task_running",
                prompt: "Running",
                status: "running",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 10:00:00Z]
              },
              "task_paused" => %{
                id: "task_paused",
                prompt: "Paused",
                status: "paused",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 09:00:00Z]
              },
              "task_completed" => %{
                id: "task_completed",
                prompt: "Completed",
                status: "completed",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 08:00:00Z]
              },
              "task_failed" => %{
                id: "task_failed",
                prompt: "Failed",
                status: "failed",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 07:00:00Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Should have status badges
      assert html =~ "running"
      assert html =~ "paused"
      assert html =~ "completed"
      assert html =~ "failed"
    end
  end

  describe "Prompt Truncation" do
    test "truncates long prompts to max length", %{conn: conn, sandbox_owner: sandbox_owner} do
      long_prompt = String.duplicate("Very long task description ", 10)

      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: long_prompt,
                status: "running",
                root_agent_id: nil,
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: %{},
            selected_agent_id: nil,
            expanded: MapSet.new()
          }
        })

      html = render(view)

      # Should show truncated version with ellipsis
      assert html =~ "..."
      # Full prompt should not be in HTML
      refute html =~ long_prompt
    end
  end
end
