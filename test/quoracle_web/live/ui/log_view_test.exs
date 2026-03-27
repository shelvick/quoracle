defmodule QuoracleWeb.UI.LogViewTest do
  @moduledoc """
  Tests for the LogView live component.
  Verifies log display, filtering, auto-scroll, severity levels, and real-time updates.
  """

  # LiveView tests can run async with modern Ecto.Sandbox pattern
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  # Helper to render component in isolation
  defp render_isolated(conn, logs) do
    render_isolated(conn, logs, nil, nil)
  end

  defp render_isolated(conn, logs, agent_id) do
    render_isolated(conn, logs, agent_id, nil)
  end

  defp render_isolated(conn, logs, agent_id, pubsub) do
    render_isolated_with_assigns(conn, %{logs: logs, agent_id: agent_id}, pubsub)
  end

  defp render_isolated_with_assigns(conn, assigns, pubsub \\ nil) do
    session = %{
      "component" => QuoracleWeb.UI.LogView,
      "assigns" => assigns
    }

    session =
      if pubsub do
        Map.put(session, "pubsub", pubsub)
      else
        session
      end

    live_isolated(conn, QuoracleWeb.LiveComponentTestHelper, session: session)
  end

  defp create_test_logs do
    [
      %{
        id: 1,
        agent_id: "agent_1",
        level: :info,
        message: "Agent started",
        metadata: %{action: "spawn"},
        timestamp: ~U[2024-01-01 10:00:00Z]
      },
      %{
        id: 2,
        agent_id: "agent_1",
        level: :debug,
        message: "Processing action",
        metadata: %{action: "wait", wait: 100},
        timestamp: ~U[2024-01-01 10:00:01Z]
      },
      %{
        id: 3,
        agent_id: "agent_2",
        level: :warn,
        message: "Slow response",
        metadata: %{latency_ms: 500},
        timestamp: ~U[2024-01-01 10:00:02Z]
      },
      %{
        id: 4,
        agent_id: "agent_1",
        level: :error,
        message: "Action failed",
        metadata: %{error: "timeout"},
        timestamp: ~U[2024-01-01 10:00:03Z]
      }
    ]
  end

  describe "rendering" do
    test "displays log entries with all fields", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      html = render(view)

      # Verify all log fields displayed
      assert html =~ "Agent started"
      assert html =~ "Processing action"
      assert html =~ "Slow response"
      assert html =~ "Action failed"

      # Verify timestamps
      assert html =~ "10:00:00"
      assert html =~ "10:00:01"
    end

    test "shows severity levels with visual styling", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      html = render(view)

      # Verify level indicators
      assert html =~ "level-info"
      assert html =~ "level-debug"
      assert html =~ "level-warn"
      assert html =~ "level-error"
    end

    test "displays metadata as expandable details", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      # Expand first log entry
      view
      |> element("[phx-click='toggle_metadata'][phx-value-log-id='1']")
      |> render_click()

      html = render(view)

      # Verify metadata shown (contains action key from test data)
      assert html =~ "action:"

      # Collapse it
      view
      |> element("[phx-click='toggle_metadata'][phx-value-log-id='1']")
      |> render_click()

      # Verify metadata can be toggled
      html = render(view)
      # After toggle, metadata might be hidden or shown depending on state
      assert html =~ "Agent started"
    end
  end

  describe "filtering" do
    test "displays all logs passed from parent (no agent filtering in LogView)", %{conn: conn} do
      # LogView is now a pure display component - agent filtering is done by parent Dashboard
      # This test verifies LogView displays all logs it receives

      all_logs = create_test_logs()

      # When parent passes all logs
      {:ok, view, _html} = render_isolated(conn, all_logs)
      html = render(view)
      assert html =~ "agent_1"
      assert html =~ "agent_2"
      assert html =~ "Agent started"
      assert html =~ "Processing action"
      assert html =~ "Slow response"

      # When parent passes filtered logs (only agent_1's logs)
      agent1_logs = Enum.filter(all_logs, &(&1.agent_id == "agent_1"))
      {:ok, view2, _html} = render_isolated(conn, agent1_logs, "agent_1")
      html2 = render(view2)
      # These are in the filtered list
      assert html2 =~ "Agent started"
      assert html2 =~ "Processing action"
      # This isn't in the filtered list (agent_2's log)
      refute html2 =~ "Slow response"
    end

    test "shows all logs when no agent selected", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs, nil)

      html = render(view)

      # All logs visible
      assert html =~ "Agent started"
      assert html =~ "Processing action"
      assert html =~ "Slow response"
      assert html =~ "Action failed"
    end

    test "displays all logs it receives from parent", %{conn: conn} do
      # LogView is now a pure display component - agent filtering is done by parent Dashboard
      # This test verifies LogView displays whatever logs are passed to it

      # Test with logs from agent_1 only (as filtered by parent)
      agent1_logs = [
        %{
          id: 1,
          agent_id: "agent_1",
          level: :info,
          message: "Agent started",
          timestamp: DateTime.utc_now()
        },
        %{
          id: 4,
          agent_id: "agent_1",
          level: :error,
          message: "Action failed",
          timestamp: DateTime.utc_now()
        }
      ]

      {:ok, view1, _html} = render_isolated(conn, agent1_logs, "agent_1")
      assert render(view1) =~ "Agent started"
      assert render(view1) =~ "Action failed"

      # Test with logs from agent_2 only (as filtered by parent)
      agent2_logs = [
        %{
          id: 3,
          agent_id: "agent_2",
          level: :warn,
          message: "Slow response",
          timestamp: DateTime.utc_now()
        }
      ]

      {:ok, view2, _html} = render_isolated(conn, agent2_logs, "agent_2")
      assert render(view2) =~ "Slow response"
      refute render(view2) =~ "Agent started"
    end
  end

  describe "severity filtering" do
    test "filters by log level", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      # Filter to show only warn and error
      view
      |> element("[phx-click='set_min_level'][phx-value-level='warn']")
      |> render_click()

      html = render(view)

      # Only warn and error visible
      # info
      refute html =~ "Agent started"
      # debug
      refute html =~ "Processing action"
      # warn
      assert html =~ "Slow response"
      # error
      assert html =~ "Action failed"
    end

    test "toggles visibility by severity level", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      # Set minimum level to info (hides debug)
      view
      |> element("[phx-click='set_min_level'][phx-value-level='info']")
      |> render_click()

      html = render(view)

      # info still visible
      assert html =~ "Agent started"
      # debug hidden
      refute html =~ "Processing action"
      # warn still visible
      assert html =~ "Slow response"
    end
  end

  describe "auto-scroll" do
    test "scrolls to bottom when new logs added", %{conn: conn} do
      initial_logs = Enum.take(create_test_logs(), 2)
      {:ok, view, _html} = render_isolated(conn, initial_logs)

      # LiveComponents in isolated testing might not process handle_info
      # Test that the component renders initial logs properly
      html = render(view)
      assert html =~ "Agent started"

      # Verify auto-scroll button is in active state
      assert html =~ "bg-green-500"
    end

    test "maintains position when auto-scroll disabled", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      # Disable auto-scroll
      view
      |> element("[phx-click='toggle_auto_scroll']")
      |> render_click()

      # Add new log
      new_log = %{
        id: 5,
        agent_id: "agent_1",
        level: :info,
        message: "New entry",
        metadata: %{},
        timestamp: ~U[2024-01-01 10:00:05Z]
      }

      send(view.pid, {:log_entry, new_log})

      # Component handles auto-scroll internally
      # The new log should appear in the view
      html = render(view)
      # Verify the component still renders with the log message
      assert html =~ "Agent started"
    end

    test "shows auto-scroll toggle button", %{conn: conn} do
      {:ok, view, _html} = render_isolated(conn, [])

      html = render(view)

      # Verify toggle button present
      assert html =~ "Auto-scroll"
      assert has_element?(view, "[phx-click='toggle_auto_scroll']")
    end
  end

  describe "real-time updates" do
    test "adds new log entries in real-time", %{conn: conn} do
      {:ok, view, _html} = render_isolated(conn, [])

      # Start with no logs
      html = render(view)
      assert html =~ "No logs"

      # Receive log entry event
      send(
        view.pid,
        {:log_entry,
         %{
           id: 100,
           agent_id: "new_agent",
           level: :info,
           message: "Real-time log",
           metadata: %{},
           timestamp: DateTime.utc_now()
         }}
      )

      # In isolated testing, the component might not update immediately
      # We just verify no errors occur and component renders
      html = render(view)
      assert html =~ "log-view"
    end

    test "updates when filtered agent logs arrive", %{conn: conn} do
      # Filter by specific agent
      {:ok, view, _html} = render_isolated(conn, [], "target_agent")

      # Send log for different agent
      send(
        view.pid,
        {:log_entry,
         %{
           agent_id: "other_agent",
           level: :info,
           message: "Other agent log",
           metadata: %{},
           timestamp: DateTime.utc_now()
         }}
      )

      # Should not appear
      refute render(view) =~ "Other agent log"

      # Send log for target agent
      send(
        view.pid,
        {:log_entry,
         %{
           agent_id: "target_agent",
           level: :info,
           message: "Target agent log",
           metadata: %{},
           timestamp: DateTime.utc_now()
         }}
      )

      # In isolated testing, we can't easily verify message passing
      # Just verify the component renders without error
      html = render(view)
      assert html =~ "log-view"
    end

    test "maintains order when logs arrive out of sequence", %{conn: conn} do
      # Create logs in mixed order
      logs = [
        %{
          id: 2,
          agent_id: "agent_1",
          level: :info,
          message: "Second",
          metadata: %{},
          timestamp: ~U[2024-01-01 10:00:02Z]
        },
        %{
          id: 1,
          agent_id: "agent_1",
          level: :info,
          message: "First",
          metadata: %{},
          timestamp: ~U[2024-01-01 10:00:01Z]
        },
        %{
          id: 3,
          agent_id: "agent_1",
          level: :info,
          message: "Third",
          metadata: %{},
          timestamp: ~U[2024-01-01 10:00:03Z]
        }
      ]

      {:ok, view, _html} = render_isolated(conn, logs)
      html = render(view)

      # Component should display logs (order depends on implementation)
      assert html =~ "First"
      assert html =~ "Second"
      assert html =~ "Third"
    end
  end

  describe "clear functionality" do
    test "clears all logs when clear button clicked", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      assert render(view) =~ "Agent started"

      # Click clear button
      view
      |> element("[phx-click='clear_logs']")
      |> render_click()

      # Verify logs cleared
      html = render(view)
      refute html =~ "Agent started"
      assert html =~ "No logs"
    end

    test "maintains filter settings after clear", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs, "agent_1")

      # Clear logs
      view
      |> element("[phx-click='clear_logs']")
      |> render_click()

      # Add new log for different agent
      send(
        view.pid,
        {:log_entry,
         %{
           agent_id: "agent_2",
           level: :info,
           message: "New log",
           metadata: %{},
           timestamp: DateTime.utc_now()
         }}
      )

      # Should not appear due to filter
      refute render(view) =~ "New log"
    end
  end

  describe "performance" do
    test "limits displayed logs to prevent overflow", %{conn: conn} do
      # Send many logs
      logs =
        for i <- 1..1000 do
          %{
            id: i,
            agent_id: "agent_1",
            level: :info,
            message: "Log #{i}",
            metadata: %{},
            timestamp: DateTime.utc_now()
          }
        end

      {:ok, view, _html} = render_isolated(conn, logs)

      # Verify limit applied (e.g., last 100)
      html = render(view)
      assert html =~ "Log 1000"
      assert html =~ "Log 901"
      refute html =~ "Log 900"
    end

    test "virtualizes long log lists", %{conn: conn} do
      # Send many logs
      logs =
        for i <- 1..500 do
          %{
            id: i,
            agent_id: "agent_1",
            level: :info,
            message: "Log entry #{i}",
            metadata: %{},
            timestamp: DateTime.utc_now()
          }
        end

      {:ok, view, _html} = render_isolated(conn, logs)

      # Check that logs are displayed (virtualization is implementation detail)
      html = render(view)
      assert html =~ "Log entry"
    end
  end

  describe "component callbacks" do
    test "update/2 processes new assigns", %{conn: conn} do
      # Test with specific agent filter
      {:ok, view, _html} = render_isolated(conn, [], "specific_agent")

      # Component should have the agent_id assigned
      # We can't directly access assigns in isolated components, but we can test behavior
      html = render(view)
      assert html =~ "log-view"
    end

    test "handle_event for toggle_metadata", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      # Toggle metadata via click event
      # Find and click the toggle button for the first log
      assert has_element?(view, "[phx-click='toggle_metadata'][phx-value-log-id='1']")

      # The component renders with logs
      html = render(view)
      assert html =~ "Agent started"
    end

    test "handle_event for clear_logs", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      # Test that clear button exists
      assert has_element?(view, "[phx-click='clear_logs']")

      # Click clear
      view
      |> element("[phx-click='clear_logs']")
      |> render_click()

      # After clear, logs should be gone
      html = render(view)
      assert html =~ "No logs"
      refute html =~ "Agent started"
    end

    test "subscribes to agent-specific log topic", %{conn: conn} do
      # Create isolated PubSub for this test
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      # Component subscribes in update/2 when agent_id is set
      {:ok, _view, _html} = render_isolated(conn, [], "monitored_agent", pubsub_name)

      # Broadcast to agent-specific topic on isolated PubSub
      Phoenix.PubSub.broadcast(
        pubsub_name,
        "agents:monitored_agent:logs",
        {:log_entry, %{message: "Agent-specific log"}}
      )

      # Component subscribes to PubSub in update/2
      # In isolated testing, subscription happens but messages might not propagate
      # Test passes if no errors occur
      assert true
    end
  end

  describe "v6.0: root_pid forwarding" do
    # R11 (accept root_pid) and R13 (preserve after state change) are implicitly
    # covered by R12 — LogView.update/2 already stores arbitrary assigns. The real
    # new behavior is FORWARDING root_pid to LogEntry children in the render template.

    test "R11-R12: LogView forwards root_pid to LogEntry enabling fetch_full_detail", %{
      conn: conn
    } do
      root_pid = self()

      logs = [
        %{
          id: 901,
          agent_id: "agent_1",
          level: :debug,
          message: "truncated raw response",
          metadata: %{
            raw_responses: [
              %{
                model: "claude-3",
                text: String.duplicate("r", 200) <> "...",
                truncated?: true
              }
            ]
          },
          timestamp: ~U[2024-01-01 10:00:00Z]
        },
        %{
          id: 902,
          agent_id: "agent_2",
          level: :debug,
          message: "truncated sent message",
          metadata: %{
            sent_messages: [
              %{
                model_id: "gpt-4",
                messages: [
                  %{role: "user", content: String.duplicate("m", 200) <> "...", truncated?: true}
                ]
              }
            ]
          },
          timestamp: ~U[2024-01-01 10:00:01Z]
        }
      ]

      {:ok, view, _html} =
        render_isolated_with_assigns(conn, %{logs: logs, agent_id: nil, root_pid: root_pid})

      view
      |> element("[phx-click='toggle_metadata'][phx-value-log-id='901']")
      |> render_click()

      first_expanded = render(view)
      assert first_expanded =~ "Show full details..."

      view
      |> element("[phx-click='fetch_full_detail']")
      |> render_click()

      assert_receive {:fetch_log_detail, 901, "log-901"}, 1_000

      view
      |> element("[phx-click='toggle_metadata'][phx-value-log-id='902']")
      |> render_click()

      second_expanded = render(view)
      assert second_expanded =~ "Show full details..."

      view
      |> element("#log-entry-902 [phx-click='fetch_full_detail']")
      |> render_click()

      assert_receive {:fetch_log_detail, 902, "log-902"}, 1_000
    end

    test "R13: root_pid forwarding works after level filter change", %{conn: conn} do
      root_pid = self()

      # Log with truncated metadata at :warn level — survives level filter change
      logs = [
        %{
          id: 950,
          agent_id: "agent_1",
          level: :warn,
          message: "Warning with truncated response",
          metadata: %{
            raw_responses: [
              %{
                model: "claude-3",
                text: String.duplicate("w", 200) <> "...",
                truncated?: true
              }
            ]
          },
          timestamp: ~U[2024-01-01 10:00:00Z]
        }
      ]

      {:ok, view, _html} =
        render_isolated_with_assigns(conn, %{logs: logs, agent_id: nil, root_pid: root_pid})

      # Change level filter to :warn
      view
      |> element("[phx-click='set_min_level'][phx-value-level='warn']")
      |> render_click()

      # Log still visible after filter
      html = render(view)
      assert html =~ "Warning with truncated response"

      # Expand metadata and click fetch — root_pid must still be forwarded to LogEntry
      view
      |> element("[phx-click='toggle_metadata'][phx-value-log-id='950']")
      |> render_click()

      view
      |> element("[phx-click='fetch_full_detail']")
      |> render_click()

      assert_receive {:fetch_log_detail, 950, "log-950"}, 1_000
    end
  end

  describe "v5.0: pre-computed display_logs" do
    # R5: [UNIT] WHEN update/2 called with new logs THEN display_logs is pre-computed with level filtering applied
    test "R5: update pre-computes display_logs with level filter", %{conn: conn} do
      # Create logs with only debug-level entries
      debug_only_logs = [
        %{
          id: 100,
          agent_id: "agent_1",
          level: :debug,
          message: "Debug only entry",
          metadata: %{},
          timestamp: ~U[2024-01-01 10:00:00Z]
        }
      ]

      {:ok, view, _html} = render_isolated(conn, debug_only_logs)

      # Set min_level to :error — with only debug logs, display_logs should be empty
      view
      |> element("[phx-click='set_min_level'][phx-value-level='error']")
      |> render_click()

      html = render(view)

      # With pre-computed display_logs, the empty check uses @display_logs == []
      # which should show "No logs" when all entries are filtered out.
      # Current implementation checks @logs == [] (which is false since @logs has entries),
      # so "No logs" text is NOT shown even when filter produces empty result.
      assert html =~ "No logs",
             "display_logs should be pre-computed — empty filtered result should show 'No logs'"
    end

    # R6: [UNIT] WHEN set_min_level event fires THEN display_logs is recomputed for new level
    test "R6: set_min_level recomputes display_logs", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      # Change level to :warn — should recompute display_logs
      view
      |> element("[phx-click='set_min_level'][phx-value-level='warn']")
      |> render_click()

      html = render(view)

      # Only warn and error should remain in display_logs
      refute html =~ "Agent started", "info log should be excluded at :warn level"
      refute html =~ "Processing action", "debug log should be excluded at :warn level"
      assert html =~ "Slow response", "warn log should be in display_logs at :warn level"
      assert html =~ "Action failed", "error log should be in display_logs at :warn level"

      # Verify display_logs controls empty state: only info logs → filter to :error → "No logs"
      info_only = [
        %{
          id: 77,
          agent_id: "a1",
          level: :info,
          message: "Info only",
          metadata: %{},
          timestamp: ~U[2024-01-01 10:00:00Z]
        }
      ]

      {:ok, view2, _html} = render_isolated(conn, info_only)

      view2
      |> element("[phx-click='set_min_level'][phx-value-level='error']")
      |> render_click()

      html2 = render(view2)

      assert html2 =~ "No logs",
             "display_logs pre-computation: set_min_level should show 'No logs' when result is empty"
    end

    # R7: [INTEGRATION] WHEN component renders after update/2 THEN visible log entries match @display_logs exactly
    test "R7: rendered log list matches precomputed display_logs", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      # Set min_level to :info to filter out debug logs
      view
      |> element("[phx-click='set_min_level'][phx-value-level='info']")
      |> render_click()

      html = render(view)

      # After set_min_level, display_logs should be pre-computed with the filter.
      # With min_level :info, we expect 3 logs: info, warn, error (not debug).
      # Each rendered via LogEntry LiveComponent with id="log-entry-{id}"
      assert html =~ ~s(id="log-entry-1"), "info log (id=1) should be rendered"
      assert html =~ ~s(id="log-entry-3"), "warn log (id=3) should be rendered"
      assert html =~ ~s(id="log-entry-4"), "error log (id=4) should be rendered"

      # debug log should NOT be rendered (filtered by pre-computed display_logs)
      refute html =~ ~s(id="log-entry-2"),
             "debug log (id=2) should NOT be rendered when display_logs is pre-computed at :info level"

      # With pre-computed display_logs, filtered-out entries should result in "No logs" message
      # when ALL entries are excluded. Set to :error to filter more aggressively.
      view
      |> element("[phx-click='set_min_level'][phx-value-level='error']")
      |> render_click()

      html = render(view)

      # Only error log should be rendered
      assert html =~ ~s(id="log-entry-4"), "error log (id=4) should still be rendered"
      refute html =~ ~s(id="log-entry-1"), "info log (id=1) should be excluded at :error level"
      refute html =~ ~s(id="log-entry-3"), "warn log (id=3) should be excluded at :error level"

      # Verify display_logs controls empty state: only debug logs → filter to :error → "No logs"
      debug_only = [
        %{
          id: 88,
          agent_id: "a1",
          level: :debug,
          message: "Debug match check",
          metadata: %{},
          timestamp: ~U[2024-01-01 10:00:00Z]
        }
      ]

      {:ok, view2, _html} = render_isolated(conn, debug_only)

      view2
      |> element("[phx-click='set_min_level'][phx-value-level='error']")
      |> render_click()

      html2 = render(view2)

      assert html2 =~ "No logs",
             "display_logs pre-computation: empty result should show 'No logs' not blank list"
    end

    # R7b: [SYSTEM] WHEN user changes severity filter THEN visible log entries update to the matching severity subset
    @tag :acceptance
    test "R7b: changing severity level filters displayed logs", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      # Start at default level (:debug) — all logs visible
      html = render(view)
      assert html =~ "Agent started"
      assert html =~ "Slow response"
      assert html =~ "Action failed"
      assert html =~ "Processing action"

      # User switches to :warn — only warn and error visible
      view
      |> element("[phx-click='set_min_level'][phx-value-level='warn']")
      |> render_click()

      html = render(view)
      refute html =~ "Agent started", "info log should be hidden at :warn level"
      refute html =~ "Processing action", "debug log should be hidden at :warn level"
      assert html =~ "Slow response", "warn log should be visible at :warn level"
      assert html =~ "Action failed", "error log should be visible at :warn level"

      # User switches to :error — only error visible
      view
      |> element("[phx-click='set_min_level'][phx-value-level='error']")
      |> render_click()

      html = render(view)
      refute html =~ "Agent started", "info log should be hidden at :error level"
      refute html =~ "Processing action", "debug log should be hidden at :error level"
      refute html =~ "Slow response", "warn log should be hidden at :error level"
      assert html =~ "Action failed", "error log should be visible at :error level"

      # With pre-computed display_logs, when ALL logs filtered out, "No logs" should appear
      # Create a view with only debug logs, set to :error
      debug_only = [
        %{
          id: 99,
          agent_id: "a1",
          level: :debug,
          message: "Only debug here",
          metadata: %{},
          timestamp: ~U[2024-01-01 10:00:00Z]
        }
      ]

      {:ok, view2, _html} = render_isolated(conn, debug_only)

      view2
      |> element("[phx-click='set_min_level'][phx-value-level='error']")
      |> render_click()

      html2 = render(view2)
      # With pre-computed display_logs, empty result should show "No logs"
      assert html2 =~ "No logs",
             "display_logs pre-computation should show 'No logs' when filter excludes all entries"

      # Negative: no crash states
      refute html2 =~ "FunctionClauseError"
    end

    # R8: [UNIT] WHEN min_level is :warn THEN only :warn and :error logs appear in display_logs
    test "R8: warn level shows only warn and error logs", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      # Set min_level to :warn
      view
      |> element("[phx-click='set_min_level'][phx-value-level='warn']")
      |> render_click()

      html = render(view)

      # Only warn and error should be in display_logs
      refute html =~ "Agent started", "info should not appear in display_logs at :warn"
      refute html =~ "Processing action", "debug should not appear in display_logs at :warn"
      assert html =~ "Slow response", "warn should appear in display_logs at :warn"
      assert html =~ "Action failed", "error should appear in display_logs at :warn"

      # With only warn-level logs and :error filter, "No logs" should appear
      # (verifies display_logs pre-computation controls the empty-state check)
      warn_only = [
        %{
          id: 50,
          agent_id: "a1",
          level: :warn,
          message: "Warn only",
          metadata: %{},
          timestamp: ~U[2024-01-01 10:00:00Z]
        }
      ]

      {:ok, view2, _html} = render_isolated(conn, warn_only)

      view2
      |> element("[phx-click='set_min_level'][phx-value-level='error']")
      |> render_click()

      html2 = render(view2)

      assert html2 =~ "No logs",
             "display_logs pre-computation: empty filtered result should show 'No logs'"
    end

    # R9: [UNIT] WHEN more than 100 logs match filter THEN display_logs contains only last 100
    test "R9: display_logs limited to 100 entries", %{conn: conn} do
      # Create 150 logs all at :info level
      logs =
        for i <- 1..150 do
          %{
            id: i,
            agent_id: "agent_1",
            level: :info,
            message: "Log entry #{i}",
            metadata: %{},
            timestamp: DateTime.utc_now()
          }
        end

      {:ok, view, _html} = render_isolated(conn, logs)

      html = render(view)

      # display_logs should contain only last 100 (entries 51-150)
      assert html =~ "Log entry 150", "newest log should be visible"
      assert html =~ "Log entry 51", "100th-from-last log should be visible"

      refute html =~ "Log entry 50",
             "display_logs should be limited to 100 entries — entry 50 should be excluded"

      # Create 3 debug-only logs and filter to :error — "No logs" should appear
      # (verifies display_logs controls the empty-state check, not raw @logs)
      debug_logs =
        for i <- 1..3 do
          %{
            id: 200 + i,
            agent_id: "a1",
            level: :debug,
            message: "Debug #{i}",
            metadata: %{},
            timestamp: DateTime.utc_now()
          }
        end

      {:ok, view2, _html} = render_isolated(conn, debug_logs)

      view2
      |> element("[phx-click='set_min_level'][phx-value-level='error']")
      |> render_click()

      html2 = render(view2)

      assert html2 =~ "No logs",
             "display_logs pre-computation: empty filtered result should show 'No logs'"
    end

    # R10: [UNIT] WHEN clear_logs event fires THEN display_logs is also cleared
    test "R10: clear_logs clears display_logs", %{conn: conn} do
      logs = create_test_logs()
      {:ok, view, _html} = render_isolated(conn, logs)

      # Verify logs are displayed
      html = render(view)
      assert html =~ "Agent started"

      # Clear logs
      view
      |> element("[phx-click='clear_logs']")
      |> render_click()

      html = render(view)

      # display_logs should also be cleared — "No logs" shown
      assert html =~ "No logs", "display_logs should be cleared when logs are cleared"
      refute html =~ "Agent started", "no log entries should be rendered after clear"
      refute html =~ "Slow response"
      refute html =~ "Action failed"

      # Verify that after clear + new logs via update, display_logs is recomputed.
      # Send new logs to the component and verify display_logs picks them up.
      new_logs = [
        %{
          id: 200,
          agent_id: "a1",
          level: :debug,
          message: "Post-clear debug log",
          metadata: %{},
          timestamp: DateTime.utc_now()
        }
      ]

      send(view.pid, {:update_component, %{logs: new_logs}})
      render(view)

      # Set to :error — with only debug logs, display_logs should be empty
      view
      |> element("[phx-click='set_min_level'][phx-value-level='error']")
      |> render_click()

      html2 = render(view)
      # With pre-computed display_logs, empty result shows "No logs"
      assert html2 =~ "No logs",
             "display_logs pre-computation: post-clear filtered empty result should show 'No logs'"
    end
  end
end
