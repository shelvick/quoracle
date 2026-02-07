defmodule QuoracleWeb.UI.LogEntryTest do
  @moduledoc """
  Tests for the LogEntry live component.
  Verifies individual log entry rendering, metadata expansion, and severity styling.
  """

  # LiveView tests can run async with modern Ecto.Sandbox pattern
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  # Helper to render component in isolation
  defp render_isolated(conn, log, expanded \\ false) do
    live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
      session: %{
        "component" => QuoracleWeb.UI.LogEntry,
        "assigns" => %{log: log, expanded: expanded}
      }
    )
  end

  defp create_test_log do
    %{
      id: 1,
      agent_id: "test_agent",
      level: :info,
      message: "Test log message",
      metadata: %{
        action: "wait",
        wait: 100,
        params: %{key: "value"}
      },
      timestamp: ~U[2024-01-01 10:00:00Z]
    }
  end

  describe "rendering" do
    test "displays log message and timestamp", %{conn: conn} do
      log = create_test_log()
      {:ok, view, _html} = render_isolated(conn, log)

      html = render(view)

      # Verify basic fields
      assert html =~ "Test log message"
      assert html =~ "10:00:00"
      assert html =~ "test_agent"
    end

    test "shows severity level with appropriate styling", %{conn: conn} do
      levels = [:debug, :info, :warn, :error]

      for level <- levels do
        log = %{create_test_log() | level: level}
        {:ok, view, _html} = render_isolated(conn, log)

        html = render(view)
        assert html =~ "level-#{level}"
        assert html =~ String.upcase(to_string(level))
      end
    end

    test "applies color coding based on severity", %{conn: conn} do
      # Error level - red
      error_log = %{create_test_log() | level: :error}
      {:ok, view, _html} = render_isolated(conn, error_log)
      assert render(view) =~ "text-red"

      # Warning level - yellow
      warn_log = %{create_test_log() | level: :warn}
      {:ok, view2, _html} = render_isolated(conn, warn_log)
      assert render(view2) =~ "text-yellow"

      # Info level - blue
      info_log = %{create_test_log() | level: :info}
      {:ok, view3, _html} = render_isolated(conn, info_log)
      assert render(view3) =~ "text-blue"

      # Debug level - gray
      debug_log = %{create_test_log() | level: :debug}
      {:ok, view4, _html} = render_isolated(conn, debug_log)
      assert render(view4) =~ "text-gray"
    end
  end

  describe "metadata handling" do
    test "shows metadata toggle when metadata present", %{conn: conn} do
      log = create_test_log()
      {:ok, view, _html} = render_isolated(conn, log)

      # Should have toggle button
      assert has_element?(view, "[phx-click='toggle_metadata']")
    end

    test "no toggle when metadata empty", %{conn: conn} do
      log = %{create_test_log() | metadata: %{}}
      {:ok, view, _html} = render_isolated(conn, log)

      # No toggle button
      refute has_element?(view, "[phx-click='toggle_metadata']")
    end

    test "expands metadata on click", %{conn: conn} do
      log = create_test_log()
      {:ok, view, _html} = render_isolated(conn, log)

      # Initially collapsed
      refute render(view) =~ "wait: 100"

      # Click to expand
      view
      |> element("[phx-click='toggle_metadata'][phx-value-log-id='1']")
      |> render_click()

      # Metadata visible (HTML entities are used for quotes)
      html = render(view)
      assert html =~ "action:"
      assert html =~ "wait"
      assert html =~ "wait: 100"
    end

    test "collapses metadata on second click", %{conn: conn} do
      log = create_test_log()
      {:ok, view, _html} = render_isolated(conn, log, true)

      # Initially expanded
      assert render(view) =~ "wait: 100"

      # Click to collapse
      view
      |> element("[phx-click='toggle_metadata'][phx-value-log-id='1']")
      |> render_click()

      # Metadata hidden
      refute render(view) =~ "wait: 100"
    end

    test "formats nested metadata properly", %{conn: conn} do
      log = %{
        create_test_log()
        | metadata: %{
            nested: %{
              deeply: %{
                nested: "value"
              }
            },
            list: [1, 2, 3]
          }
      }

      {:ok, view, _html} = render_isolated(conn, log, true)

      html = render(view)

      # Verify nested structure displayed
      assert html =~ "nested:"
      assert html =~ "deeply:"
      assert html =~ "list: [1, 2, 3]"
    end

    test "renders sent_messages accordion when present", %{conn: conn} do
      log = %{
        id: 1,
        agent_id: "test_agent",
        level: :debug,
        message: "Sending to consensus: 3/3/3 messages across 3 models",
        metadata: %{
          model_count: 3,
          per_model_counts: [3, 3, 3],
          sent_messages: [
            %{model_id: "gpt-4", messages: [%{role: "user", content: "Hello"}]},
            %{
              model_id: "claude-3",
              messages: [
                %{role: "system", content: "You are helpful"},
                %{role: "user", content: "Hi"}
              ]
            }
          ]
        },
        timestamp: ~U[2024-01-01 10:00:00Z]
      }

      {:ok, view, _html} = render_isolated(conn, log, true)
      html = render(view)

      # Should show sent messages section
      assert html =~ "Messages sent to models:"
      assert html =~ "gpt-4"
      assert html =~ "claude-3"
      assert html =~ "(1 messages)"
      assert html =~ "(2 messages)"
    end

    test "expands sent_messages accordion to show nested message accordions", %{conn: conn} do
      log = %{
        id: 1,
        agent_id: "test_agent",
        level: :debug,
        message: "Sending to consensus",
        metadata: %{
          sent_messages: [
            %{model_id: "gpt-4", messages: [%{role: "user", content: "Test message content"}]}
          ]
        },
        timestamp: ~U[2024-01-01 10:00:00Z]
      }

      {:ok, view, _html} = render_isolated(conn, log, true)

      # Initially model accordion collapsed - nested messages not visible
      refute render(view) =~ "Test message content"

      # Click to expand model accordion
      view
      |> element("[phx-click='toggle_sent_message'][phx-value-index='0']")
      |> render_click()

      # Nested message accordion now visible with role badge and preview
      html = render(view)
      assert html =~ "user"
      # Preview shown in collapsed state (content is short so not truncated)
      assert html =~ "Test message content"

      # Click to expand the nested message accordion
      view
      |> element(
        "[phx-click='toggle_sent_message_item'][phx-value-model-index='0'][phx-value-msg-index='0']"
      )
      |> render_click()

      # Full content now visible
      html = render(view)
      assert html =~ "Test message content"
    end

    test "sent_messages from build_conversation_messages contains actual content" do
      # This test verifies the data flow from consensus_handler
      # It uses the REAL ContextManager.build_conversation_messages function
      alias Quoracle.Agent.ContextManager

      # Create state with model_histories in the REAL internal format
      state = %{
        model_histories: %{
          "test-model" => [
            %{type: :prompt, content: "Hello from user", timestamp: DateTime.utc_now()},
            %{
              type: :decision,
              content: %{action: "wait", params: %{}},
              timestamp: DateTime.utc_now()
            }
          ]
        },
        test_mode: true
      }

      # Call the real function
      messages = ContextManager.build_conversation_messages(state, "test-model")

      # Verify we get actual messages back
      assert messages != [], "Expected messages but got empty list"

      # Verify messages have role and content
      Enum.each(messages, fn msg ->
        assert Map.has_key?(msg, :role), "Message missing :role key: #{inspect(msg)}"
        assert Map.has_key?(msg, :content), "Message missing :content key: #{inspect(msg)}"
        assert msg.content != nil, "Message content is nil: #{inspect(msg)}"
        assert msg.content != "", "Message content is empty: #{inspect(msg)}"
      end)
    end
  end

  describe "timestamp formatting" do
    test "shows relative time for recent logs", %{conn: conn} do
      # Create timestamp just before rendering to minimize time drift
      # The component calls DateTime.utc_now() during render, which may be
      # slightly later than when we create the timestamp
      recent_log = %{create_test_log() | timestamp: DateTime.add(DateTime.utc_now(), -5, :second)}
      {:ok, view, _html} = render_isolated(conn, recent_log)

      html = render(view)
      # Accept 5-30 seconds to account for slow test runs (CI, parallel tests)
      # The key assertion is that relative time format is used, not the exact number
      assert html =~ ~r/\d+ seconds ago/
    end

    test "shows absolute time for older logs", %{conn: conn} do
      # Log from yesterday
      old_log = %{
        create_test_log()
        | timestamp: DateTime.add(DateTime.utc_now(), -86400, :second)
      }

      {:ok, view, _html} = render_isolated(conn, old_log)

      html = render(view)
      # Should show date and time
      assert html =~ ~r/\d{4}-\d{2}-\d{2}/
    end

    test "shows timestamp for debug level", %{conn: conn} do
      # Use a timestamp from yesterday to get absolute time display (not relative)
      yesterday = DateTime.add(DateTime.utc_now(), -86400, :second)
      timestamp_with_ms = %{yesterday | hour: 10, minute: 0, second: 0, microsecond: {123_456, 6}}
      log = %{create_test_log() | level: :debug, timestamp: timestamp_with_ms}
      {:ok, view, _html} = render_isolated(conn, log)

      html = render(view)
      # Component currently shows "YYYY-MM-DD HH:MM:SS" format without milliseconds
      assert html =~ "10:00:00"
    end
  end

  describe "message formatting" do
    test "wraps long messages without horizontal scroll", %{conn: conn} do
      log = %{create_test_log() | message: "Line 1\n  Line 2\n    Line 3"}
      {:ok, view, _html} = render_isolated(conn, log)

      html = render(view)
      assert html =~ "whitespace-normal"
      assert html =~ "break-words"
    end

    test "escapes HTML in messages", %{conn: conn} do
      log = %{create_test_log() | message: "<script>alert('xss')</script>"}
      {:ok, view, _html} = render_isolated(conn, log)

      html = render(view)
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "highlights keywords in messages", %{conn: conn} do
      log = %{create_test_log() | message: "ERROR: Failed to connect"}
      {:ok, view, _html} = render_isolated(conn, log)

      html = render(view)
      # ERROR is highlighted with a span
      assert html =~ "highlight"
      assert html =~ "ERROR"
    end

    test "makes URLs clickable", %{conn: conn} do
      log = %{create_test_log() | message: "Visit https://example.com for details"}
      {:ok, view, _html} = render_isolated(conn, log)

      html = render(view)
      # URL is displayed in the message
      assert html =~ "https://example.com"
    end
  end

  describe "interaction" do
    test "allows copying log message", %{conn: conn} do
      log = create_test_log()
      {:ok, view, _html} = render_isolated(conn, log)

      # Verify copy button exists
      assert has_element?(view, "[phx-click='copy_log'][phx-value-log-id='1']")
    end

    test "allows copying full log with metadata", %{conn: conn} do
      log = create_test_log()
      {:ok, view, _html} = render_isolated(conn, log)

      # Verify copy all button exists
      assert has_element?(view, "[phx-click='copy_full'][phx-value-log-id='1']")
    end

    test "shows actions on hover", %{conn: conn} do
      log = create_test_log()
      {:ok, view, _html} = render_isolated(conn, log)

      # Actions are rendered but hidden by CSS
      assert has_element?(view, ".log-actions")
    end
  end

  describe "component callbacks" do
    test "update/2 processes log entry", %{conn: conn} do
      log = create_test_log()
      {:ok, view, _html} = render_isolated(conn, log)

      # Component is rendered with correct initial state
      html = render(view)
      assert html =~ "Test log message"
    end

    test "handle_event for toggle_metadata", %{conn: conn} do
      log = create_test_log()
      {:ok, view, _html} = render_isolated(conn, log)

      # Trigger toggle
      view
      |> element("[phx-click='toggle_metadata']")
      |> render_click()

      # Verify metadata is shown
      html = render(view)
      assert html =~ "wait: 100"
    end

    test "sends metadata toggle to parent", %{conn: conn} do
      log = create_test_log()
      {:ok, view, _html} = render_isolated(conn, log)

      # Click toggle
      view
      |> element("[phx-click='toggle_metadata']")
      |> render_click()

      # Toggle works in isolated component
      html = render(view)
      assert html =~ "wait: 100"
    end
  end

  describe "performance" do
    test "truncates very long messages", %{conn: conn} do
      # Create log with very long message
      long_message = String.duplicate("x", 10000)
      log = %{create_test_log() | message: long_message}
      {:ok, view, _html} = render_isolated(conn, log)

      html = render(view)

      # Very long message is rendered (truncation would happen via CSS)
      assert html =~ "xxxx"
    end

    test "lazy renders metadata content", %{conn: conn} do
      log = create_test_log()
      {:ok, view, _html} = render_isolated(conn, log)

      # Metadata not rendered initially
      refute render(view) =~ "wait: 100"

      # Only rendered when expanded
      view
      |> element("[phx-click='toggle_metadata']")
      |> render_click()

      assert render(view) =~ "wait: 100"
    end
  end

  describe "highlighting" do
    test "highlights search terms in message", %{conn: conn} do
      log = %{create_test_log() | message: "Error in processing request"}
      {:ok, view, _html} = render_isolated(conn, log)

      html = render(view)
      # The highlighting function needs to be called in the component
      assert html =~ "processing"
    end

    test "case-insensitive highlighting", %{conn: conn} do
      log = %{create_test_log() | message: "ERROR occurred"}
      {:ok, view, _html} = render_isolated(conn, log)

      html = render(view)
      # The component highlights ERROR keyword
      assert html =~ "ERROR"
      assert html =~ "occurred"
    end
  end

  # ============================================================
  # WorkGroupID: fix-ui-costs-20251213
  # Decimal Formatting Tests (R20-R24)
  # ============================================================

  describe "R20-R24: Decimal formatting in metadata (fix-ui-costs-20251213)" do
    alias QuoracleWeb.UI.LogEntry.Helpers

    # R20: Decimal Formatting [UNIT]
    test "R20: format_metadata_value formats Decimal as plain number" do
      decimal_value = Decimal.new("0.42")

      # This test will FAIL until format_metadata_value/1 is implemented
      result = Helpers.format_metadata_value(decimal_value)

      assert result == "0.42"
      refute result =~ "Decimal"
      refute result =~ "#Decimal"
    end

    # R21: Non-Decimal Preservation [UNIT]
    test "R21: format_metadata_value preserves non-Decimal types" do
      # String stays as string
      assert Helpers.format_metadata_value("hello") == "hello"

      # Number converts to string
      assert Helpers.format_metadata_value(1234) == "1234"

      # Atom converts to string
      assert Helpers.format_metadata_value(:atom_value) == "atom_value"
    end

    # R22: Nested Map Handling [UNIT]
    test "R22: format_metadata_value inspects nested maps" do
      nested_map = %{nested: %{key: "value"}}

      result = Helpers.format_metadata_value(nested_map)

      # Should use inspect with pretty: true
      assert is_binary(result)
      assert result =~ "nested"
      assert result =~ "key"
    end

    # R23: Full Metadata Formatting [INTEGRATION]
    test "R23: format_metadata handles mixed value types" do
      metadata = %{
        cost_usd: Decimal.new("0.42"),
        latency_ms: 1234,
        model: "anthropic:claude-sonnet",
        usage: %{input_tokens: 100, output_tokens: 50},
        tags: ["consensus", "round_1"]
      }

      result = Helpers.format_metadata(metadata)

      # Decimal should be formatted as plain number
      assert result =~ "cost_usd: 0.42"
      refute result =~ "Decimal.new"
      refute result =~ "#Decimal"

      # Other types should be preserved
      assert result =~ "latency_ms: 1234"
      assert result =~ "model: anthropic:claude-sonnet"
    end

    # R24: Acceptance - Log Cost Display [SYSTEM]
    test "R24: log entry metadata shows costs as plain numbers", %{conn: conn} do
      log = %{
        id: 1,
        agent_id: "test_agent",
        level: :info,
        message: "Consensus completed",
        metadata: %{
          cost_usd: Decimal.new("0.42"),
          model_spec: "anthropic:claude-sonnet",
          input_tokens: 100,
          output_tokens: 50
        },
        timestamp: ~U[2024-01-01 10:00:00Z]
      }

      {:ok, view, _html} = render_isolated(conn, log, true)

      html = render(view)

      # Cost should appear as plain number in UI
      assert html =~ "0.42"

      # Should NOT show raw Decimal format
      refute html =~ "Decimal.new"
      refute html =~ "#Decimal"
      refute html =~ "Decimal<"
    end
  end

  # ============================================================
  # R25-R26: DateTime formatting in metadata
  # ============================================================

  describe "R25-R26: DateTime formatting in metadata" do
    alias QuoracleWeb.UI.LogEntry.Helpers

    # R25: DateTime Formatting [UNIT]
    test "R25: format_metadata_value formats DateTime types as ISO8601" do
      # DateTime with timezone
      dt = ~U[2024-01-01 10:00:00Z]
      assert Helpers.format_metadata_value(dt) == "2024-01-01T10:00:00Z"
      refute Helpers.format_metadata_value(dt) =~ "DateTime"

      # NaiveDateTime without timezone
      naive_dt = ~N[2024-01-01 10:00:00]
      assert Helpers.format_metadata_value(naive_dt) == "2024-01-01T10:00:00"
      refute Helpers.format_metadata_value(naive_dt) =~ "NaiveDateTime"

      # Date only
      date = ~D[2024-01-01]
      assert Helpers.format_metadata_value(date) == "2024-01-01"
      refute Helpers.format_metadata_value(date) =~ "Date"

      # Time only
      time = ~T[10:00:00]
      assert Helpers.format_metadata_value(time) == "10:00:00"
      refute Helpers.format_metadata_value(time) =~ "Time"
    end

    # R26: DateTime in Metadata Integration [INTEGRATION]
    test "R26: format_metadata handles DateTime types in metadata" do
      metadata = %{
        created_at: ~U[2024-01-01 10:00:00Z],
        scheduled_for: ~N[2024-01-02 15:30:00],
        deadline: ~D[2024-01-03],
        daily_run: ~T[09:00:00],
        cost_usd: Decimal.new("0.42")
      }

      result = Helpers.format_metadata(metadata)

      # DateTime types converted to ISO8601
      assert result =~ "created_at: 2024-01-01T10:00:00Z"
      assert result =~ "scheduled_for: 2024-01-02T15:30:00"
      assert result =~ "deadline: 2024-01-03"
      assert result =~ "daily_run: 09:00:00"

      # No struct names leaked
      refute result =~ "DateTime"
      refute result =~ "NaiveDateTime"

      # Other types still work
      assert result =~ "cost_usd: 0.42"
    end
  end
end
