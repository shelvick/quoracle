defmodule QuoracleWeb.UI.AgentNodeAccordionTest do
  @moduledoc """
  Tests for Agent Accordion Enhancement (wip-20250121-ui-merge Packet 2).
  Verifies comprehensive accordion behavior for expanding/collapsing agent nodes.
  Tests the existing accordion implementation in AgentNode and TaskTree components.
  """

  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  alias QuoracleWeb.UI.{AgentNode, TaskTree}

  # Helper to render component - cleanup handled by ConnCase.live_isolated
  defp render_isolated(conn, session) do
    live_isolated(conn, QuoracleWeb.LiveComponentTestHelper, session: session)
  end

  describe "R1: Default Collapsed State" do
    # R1: [UNIT] test - WHEN component mounts THEN all agents collapsed (MapSet.new())
    test "agents start collapsed by default in TaskTree", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      # Test TaskTree component directly
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Test task",
                status: "running",
                root_agent_id: "root_agent",
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: build_test_agent_tree(),
            # Empty MapSet = all collapsed
            expanded: MapSet.new(),
            selected_agent_id: nil,
            current_task_id: "task_1"
          }
        })

      html = render(view)

      # Root should be visible
      assert html =~ "root_agent"

      # Children should NOT be visible (collapsed by default)
      refute html =~ "child_1"
      refute html =~ "child_2"
      refute html =~ "grandchild_1"
    end
  end

  describe "R2: Toggle Single Agent" do
    # R2: [INTEGRATION] test - WHEN chevron clicked IF agent has children THEN toggles that agent only
    test "clicking chevron toggles single agent expansion", %{
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
                prompt: "Test task",
                status: "running",
                root_agent_id: "root_agent",
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: build_test_agent_tree(),
            expanded: MapSet.new(),
            selected_agent_id: nil,
            current_task_id: "task_1"
          }
        })

      # Click root agent's chevron to expand
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_agent']")
      |> render_click()

      html = render(view)

      # Root's children should now be visible
      assert html =~ "child_1"
      assert html =~ "child_2"

      # But grandchildren should still be hidden (only root expanded)
      refute html =~ "grandchild_1"

      # Click root again to collapse
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_agent']")
      |> render_click()

      html = render(view)

      # Children should be hidden again
      refute html =~ "child_1"
      refute html =~ "child_2"
    end
  end

  describe "R3: Independent Expansion" do
    # R3: [INTEGRATION] test - WHEN multiple agents expanded THEN each maintains independent state
    test "multiple agents can be independently expanded", %{
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
                prompt: "Test task 1",
                status: "running",
                root_agent_id: "root_1",
                updated_at: ~U[2025-01-21 10:00:00Z]
              },
              "task_2" => %{
                id: "task_2",
                prompt: "Test task 2",
                status: "running",
                root_agent_id: "root_2",
                updated_at: ~U[2025-01-21 09:00:00Z]
              }
            },
            agents: build_sibling_agent_tree(),
            expanded: MapSet.new(),
            selected_agent_id: nil,
            current_task_id: "task_1"
          }
        })

      # Expand first root
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      html = render(view)
      assert html =~ "root_1_child"
      # Second root still collapsed
      refute html =~ "root_2_child"

      # Expand second root
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_2']")
      |> render_click()

      html = render(view)
      # First root still expanded
      assert html =~ "root_1_child"
      # Second root now expanded too
      assert html =~ "root_2_child"

      # Collapse first root
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_1']")
      |> render_click()

      html = render(view)
      # First root collapsed
      refute html =~ "root_1_child"
      # Second root still expanded
      assert html =~ "root_2_child"
    end
  end

  describe "R4: Deep Hierarchy Navigation" do
    # R4: [INTEGRATION] test - WHEN expanding nested agents THEN each level expands independently
    test "deep hierarchy allows level-by-level expansion", %{
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
                prompt: "Test task",
                status: "running",
                root_agent_id: "level_0",
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: build_deep_hierarchy(),
            expanded: MapSet.new(),
            selected_agent_id: nil,
            current_task_id: "task_1"
          }
        })

      # Initially all collapsed
      html = render(view)
      assert html =~ "level_0"
      refute html =~ "level_1"
      refute html =~ "level_2"
      refute html =~ "level_3"

      # Expand level 0
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='level_0']")
      |> render_click()

      html = render(view)
      assert html =~ "level_1"
      # Still hidden
      refute html =~ "level_2"

      # Expand level 1
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='level_1']")
      |> render_click()

      html = render(view)
      assert html =~ "level_2"
      # Still hidden
      refute html =~ "level_3"

      # Expand level 2
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='level_2']")
      |> render_click()

      html = render(view)
      # All levels now visible
      assert html =~ "level_3"

      # Collapse middle level (level_1)
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='level_1']")
      |> render_click()

      html = render(view)
      assert html =~ "level_0"
      # Still visible (parent expanded)
      assert html =~ "level_1"
      # Hidden (parent collapsed)
      refute html =~ "level_2"
      # Hidden (ancestor collapsed)
      refute html =~ "level_3"
    end
  end

  describe "R5: Chevron Visual Indicator" do
    # R5: [UNIT] test - WHEN agent has children THEN shows ▶ if collapsed, ▼ if expanded
    test "chevron indicates expansion state correctly", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      # Test AgentNode component directly
      assigns = %{
        agent: %{
          agent_id: "test_agent",
          task_id: "task_1",
          status: :working,
          parent_id: nil,
          # Has children
          children: ["child_1", "child_2"]
        },
        depth: 0,
        # Start collapsed
        expanded: false,
        selected: false
      }

      # Render collapsed state
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => AgentNode,
          "assigns" => assigns
        })

      html = render(view)

      # Should show collapsed chevron
      assert html =~ "▶"
      refute html =~ "▼"

      # Test expanded state by remounting with expanded: true
      {:ok, view_expanded, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => AgentNode,
          "assigns" => %{assigns | expanded: true}
        })

      html_expanded = render(view_expanded)

      # Should show expanded chevron for parent
      assert html_expanded =~ ~s(<span class="icon-collapse">▼</span>)
      # Children have invisible chevrons as spacers
      assert html_expanded =~ ~s(<span class="mr-2 invisible">▶</span>)
    end
  end

  describe "R6: No Chevron for Leaf Nodes" do
    # R6: [UNIT] test - WHEN agent has no children THEN no chevron displayed
    test "leaf nodes have no chevron", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Test with parent node (has children)
      parent_assigns = %{
        agent: %{
          agent_id: "parent_agent",
          task_id: "task_1",
          status: :working,
          parent_id: nil,
          # Has children
          children: ["child_1"]
        },
        depth: 0,
        expanded: false,
        selected: false
      }

      {:ok, parent_view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => AgentNode,
          "assigns" => parent_assigns
        })

      parent_html = render(parent_view)

      # Parent should have chevron button
      assert has_element?(parent_view, "[phx-click='toggle_expand']")
      assert parent_html =~ ~r/[▶▼]/

      # Test with leaf node (no children)
      leaf_assigns = %{
        agent: %{
          agent_id: "leaf_node",
          task_id: "task_1",
          status: :working,
          parent_id: "parent_agent",
          # No children = leaf node
          children: []
        },
        depth: 1,
        expanded: false,
        selected: false
      }

      {:ok, leaf_view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => AgentNode,
          "assigns" => leaf_assigns
        })

      leaf_html = render(leaf_view)

      # Leaf should have invisible chevron as spacer (not clickable button)
      refute has_element?(leaf_view, "[phx-click='toggle_expand']")
      # Should have invisible chevron for alignment
      assert leaf_html =~ ~s(<span class="mr-2 invisible">▶</span>)
    end
  end

  describe "R7: Children Render Only When Expanded" do
    # R7: [INTEGRATION] test - WHEN agent collapsed THEN children not in DOM, WHEN expanded THEN children rendered
    test "children only render when parent expanded", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "component" => TaskTree,
          "assigns" => %{
            tasks: %{
              "task_1" => %{
                id: "task_1",
                prompt: "Test task",
                status: "running",
                root_agent_id: "root_agent",
                updated_at: ~U[2025-01-21 10:00:00Z]
              }
            },
            agents: build_test_agent_tree(),
            # All collapsed
            expanded: MapSet.new(),
            selected_agent_id: nil,
            current_task_id: "task_1"
          }
        })

      # Initially collapsed - children not in DOM at all
      html = render(view)
      refute html =~ "child_1"
      refute html =~ "child_2"
      refute html =~ "grandchild_1"

      # Verify children elements don't exist in DOM using Floki
      assert Floki.find(html, "[data-agent-id='child_1']") == []
      assert Floki.find(html, "[data-agent-id='child_2']") == []

      # Expand root
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_agent']")
      |> render_click()

      html = render(view)

      # Now children ARE in DOM
      assert html =~ "child_1"
      assert html =~ "child_2"

      # Check the actual structure - children are rendered via recursion
      # Parse the HTML first, then search
      parsed = Floki.parse_document!(html)
      child_1_nodes = Floki.find(parsed, "[data-agent-id='child_1']")
      child_2_nodes = Floki.find(parsed, "[data-agent-id='child_2']")

      assert child_1_nodes != [], "Expected to find child_1 node after expanding root"
      assert child_2_nodes != [], "Expected to find child_2 node after expanding root"

      # But grandchildren still not in DOM (parent not expanded)
      refute html =~ "grandchild_1"
      assert Floki.find(html, "[data-agent-id='grandchild_1']") == []

      # Collapse root again
      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_agent']")
      |> render_click()

      html = render(view)

      # Children removed from DOM again
      refute html =~ "child_1"
      refute html =~ "child_2"
      assert Floki.find(html, "[data-agent-id='child_1']") == []
      assert Floki.find(html, "[data-agent-id='child_2']") == []
    end
  end

  # Helper functions to build test data structures

  defp build_test_agent_tree do
    %{
      "root_agent" => %{
        agent_id: "root_agent",
        task_id: "task_1",
        status: :working,
        parent_id: nil,
        children: ["child_1", "child_2"]
      },
      "child_1" => %{
        agent_id: "child_1",
        task_id: "task_1",
        status: :working,
        parent_id: "root_agent",
        children: ["grandchild_1"]
      },
      "child_2" => %{
        agent_id: "child_2",
        task_id: "task_1",
        status: :working,
        parent_id: "root_agent",
        children: []
      },
      "grandchild_1" => %{
        agent_id: "grandchild_1",
        task_id: "task_1",
        status: :working,
        parent_id: "child_1",
        children: []
      }
    }
  end

  defp build_sibling_agent_tree do
    %{
      "root_1" => %{
        agent_id: "root_1",
        task_id: "task_1",
        status: :working,
        parent_id: nil,
        children: ["root_1_child"]
      },
      "root_2" => %{
        agent_id: "root_2",
        task_id: "task_1",
        status: :working,
        parent_id: nil,
        children: ["root_2_child"]
      },
      "root_1_child" => %{
        agent_id: "root_1_child",
        task_id: "task_1",
        status: :working,
        parent_id: "root_1",
        children: []
      },
      "root_2_child" => %{
        agent_id: "root_2_child",
        task_id: "task_1",
        status: :working,
        parent_id: "root_2",
        children: []
      }
    }
  end

  defp build_deep_hierarchy do
    %{
      "level_0" => %{
        agent_id: "level_0",
        task_id: "task_1",
        status: :working,
        parent_id: nil,
        children: ["level_1"]
      },
      "level_1" => %{
        agent_id: "level_1",
        task_id: "task_1",
        status: :working,
        parent_id: "level_0",
        children: ["level_2"]
      },
      "level_2" => %{
        agent_id: "level_2",
        task_id: "task_1",
        status: :working,
        parent_id: "level_1",
        children: ["level_3"]
      },
      "level_3" => %{
        agent_id: "level_3",
        task_id: "task_1",
        status: :working,
        parent_id: "level_2",
        children: []
      }
    }
  end
end
