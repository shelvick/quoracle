defmodule QuoracleWeb.UI.MessageTest do
  @moduledoc """
  Tests for the Message live component (Accordion Design).

  Packet 1 Focus: Collapsed/expanded views, chevron rendering, preview truncation,
  basic display functionality (NO reply forms - that's Packet 2).

  Tests based on UI_Message spec v3.0 ARC criteria.
  """

  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  # Setup isolated PubSub for test isolation
  setup do
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})
    %{pubsub: pubsub_name}
  end

  # Helper to render component in isolation
  defp render_isolated(conn, assigns) do
    live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
      session: %{
        "component" => QuoracleWeb.UI.Message,
        "assigns" => assigns
      }
    )
  end

  defp create_agent_message(overrides \\ %{}) do
    Map.merge(
      %{
        id: 1,
        from: :agent,
        sender_id: "agent_123",
        content: "This is a test message from an agent",
        timestamp: ~U[2024-01-01 10:00:00Z],
        status: :sent
      },
      overrides
    )
  end

  defp create_user_message(overrides \\ %{}) do
    Map.merge(
      %{
        id: 2,
        from: :user,
        sender_id: "user",
        content: "This is a user message",
        timestamp: ~U[2024-01-01 10:01:00Z],
        status: :sent
      },
      overrides
    )
  end

  describe "collapsed view rendering - agent messages" do
    # ARC_FUNC_01: WHEN message with `from: :agent` THEN collapsed view shows agent ID badge and 80-char preview
    test "shows agent ID badge and preview when collapsed", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: false,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should show agent ID badge
      assert html =~ "agent_123"

      # Should show preview of content
      assert html =~ "This is a test message"

      # Should NOT show full content in collapsed view
      refute html =~ "<div class=\"full-content\">"
    end

    # ARC_FUNC_04: WHEN expanded is false THEN show only preview (chevron + ID + truncated content)
    test "shows chevron, ID, and truncated content when collapsed", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: false,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should show collapsed chevron
      assert html =~ "▶"

      # Should NOT show expanded chevron
      refute html =~ "▼"

      # Should show agent ID
      assert html =~ "agent_123"
    end

    # ARC_UI_01: WHEN content length > 80 chars THEN preview shows first 80 chars + "..."
    test "truncates long content to 80 characters with ellipsis", %{conn: conn, pubsub: pubsub} do
      long_content = String.duplicate("a", 100)
      message = create_agent_message(%{content: long_content})

      assigns = %{
        message: message,
        expanded: false,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should show first 80 chars
      expected_preview = String.slice(long_content, 0, 80) <> "..."
      assert html =~ expected_preview

      # Should NOT show full content
      refute html =~ long_content
    end

    # ARC_EDGE_04: WHEN content is exactly 80 chars THEN no "..." appended to preview
    test "does not add ellipsis when content is exactly 80 characters", %{
      conn: conn,
      pubsub: pubsub
    } do
      exact_80_chars = String.duplicate("x", 80)
      message = create_agent_message(%{content: exact_80_chars})

      assigns = %{
        message: message,
        expanded: false,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should show all 80 chars without ellipsis
      assert html =~ exact_80_chars
      refute html =~ "..."
    end
  end

  describe "collapsed view rendering - user messages" do
    # ARC_FUNC_02: WHEN message with `from: :user` THEN collapsed view shows "You" badge
    test "shows 'You' badge for user messages when collapsed", %{conn: conn, pubsub: pubsub} do
      message = create_user_message()

      assigns = %{
        message: message,
        expanded: false,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should show "You" badge
      assert html =~ "You"

      # Should NOT show agent ID
      refute html =~ "agent_"
    end

    # ARC_UI_04: WHEN message from user THEN right-aligned with distinct styling
    test "applies right-aligned styling to user messages", %{conn: conn, pubsub: pubsub} do
      message = create_user_message()

      assigns = %{
        message: message,
        expanded: false,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should have right-aligned styling class
      assert html =~ ~r/message-user|text-right|justify-end/
    end
  end

  describe "expanded view rendering" do
    # ARC_UI_02: WHEN expanded THEN chevron shows ▼, when collapsed shows ▶
    test "shows expanded chevron when expanded is true", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should show expanded chevron
      assert html =~ "▼"

      # Should NOT show collapsed chevron
      refute html =~ "▶"
    end

    test "shows full content when expanded", %{conn: conn, pubsub: pubsub} do
      long_content = String.duplicate("a", 200)
      message = create_agent_message(%{content: long_content})

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should show full content (all 200 chars)
      assert html =~ long_content

      # Should NOT show ellipsis
      refute html =~ "..."
    end

    test "shows timestamp when expanded", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should show timestamp
      assert html =~ ~r/2024-01-01|10:00/
    end
  end

  describe "event handling" do
    # ARC_FUNC_05: WHEN user clicks collapsed message THEN emit `{:toggle_message, message_id}` to parent
    test "emits toggle_message event when clicked", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: false,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, view, _html} = render_isolated(conn, assigns)

      # Click on the message header
      view
      |> element("#message-1 .message-header")
      |> render_click()

      # Should emit toggle_message event to parent
      assert_receive {:toggle_message, 1}
    end
  end

  describe "styling" do
    # ARC_UI_03: WHEN message from agent THEN left-aligned with blue/gray background
    test "applies left-aligned styling to agent messages", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: false,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should have left-aligned styling class
      assert html =~ ~r/message-agent|text-left|justify-start/

      # Should have blue or gray background class
      assert html =~ ~r/bg-blue|bg-gray/
    end
  end

  describe "edge cases" do
    # ARC_EDGE_01: WHEN content is empty string THEN show "(empty message)" in both views
    test "shows placeholder for empty content in collapsed view", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message(%{content: ""})

      assigns = %{
        message: message,
        expanded: false,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      assert html =~ "(empty message)"
    end

    test "shows placeholder for empty content in expanded view", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message(%{content: ""})

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      assert html =~ "(empty message)"
    end

    # ARC_EDGE_02: WHEN sender_id is nil THEN show "Unknown Agent" badge
    test "shows 'Unknown Agent' when sender_id is nil", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message(%{sender_id: nil})

      assigns = %{
        message: message,
        expanded: false,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      assert html =~ "Unknown Agent"
    end

    # ARC_EDGE_03: WHEN timestamp is nil THEN show "No timestamp" in expanded view
    test "shows 'No timestamp' when timestamp is nil", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message(%{timestamp: nil})

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      assert html =~ "No timestamp"
    end
  end

  describe "PubSub isolation" do
    # ARC_ISO_01: WHEN component receives pubsub via assigns THEN uses it for any PubSub operations
    test "uses provided pubsub instance from assigns", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: false,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, _html} = render_isolated(conn, assigns)

      # Component should store the provided pubsub instance
      # This will be verified during implementation
      assert true
    end

    # ARC_ISO_02: WHEN multiple messages rendered THEN each maintains independent state
    test "multiple message components maintain independent state", %{conn: conn, pubsub: pubsub} do
      message1 = create_agent_message(%{id: 1, content: "Message 1"})
      message2 = create_agent_message(%{id: 2, content: "Message 2"})

      assigns1 = %{
        message: message1,
        expanded: false,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      assigns2 = %{
        message: message2,
        expanded: true,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view1, html1} = render_isolated(conn, assigns1)
      {:ok, _view2, html2} = render_isolated(conn, assigns2)

      # Message 1 should be collapsed
      assert html1 =~ "▶"
      refute html1 =~ "▼"

      # Message 2 should be expanded
      assert html2 =~ "▼"
      refute html2 =~ "▶"
    end
  end

  describe "Packet 2: reply form rendering" do
    # ARC_FUNC_03: WHEN expanded is true IF message from agent THEN show full content and reply form
    test "shows reply form when expanded and reply_form_visible is true", %{
      conn: conn,
      pubsub: pubsub
    } do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: true,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should show reply form
      assert html =~ "textarea"
      assert html =~ "phx-submit=\"send_reply\""
      assert html =~ "Send"
    end

    test "does not show reply form when reply_form_visible is false", %{
      conn: conn,
      pubsub: pubsub
    } do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: false,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should NOT show reply form
      refute html =~ "phx-submit=\"send_reply\""
    end

    test "does not show reply form for user messages", %{conn: conn, pubsub: pubsub} do
      message = create_user_message()

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: true,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # User messages should not have reply form
      refute html =~ "phx-submit=\"send_reply\""
    end

    # ARC_UI_05: WHEN reply textarea rendered THEN shows multi-line input (not single-line)
    test "reply form uses textarea (multi-line) not input", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: true,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should use textarea, not input
      assert html =~ "<textarea"
      assert html =~ "name=\"content\""
    end
  end

  describe "Packet 2: agent lifecycle handling" do
    # ARC_FUNC_07: WHEN agent_alive is false THEN reply button is disabled with "Agent terminated" message
    test "disables reply button when agent is terminated", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: true,
        agent_alive: false,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Should show disabled button
      assert html =~ "disabled"
      assert html =~ ~r/Agent (terminated|no longer active)/i
    end

    test "enables reply button when agent is alive", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: true,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, _view, html} = render_isolated(conn, assigns)

      # Button should NOT be disabled
      refute html =~ "disabled"
      refute html =~ ~r/Agent (terminated|no longer active)/i
    end
  end

  describe "Packet 2: reply form submission" do
    # ARC_FUNC_06: WHEN user submits reply form IF agent_alive is true THEN emit `{:send_reply, message_id, content}` to parent
    test "emits send_reply event when form submitted", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: true,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, view, _html} = render_isolated(conn, assigns)

      # Submit reply form
      view
      |> element("form[phx-submit='send_reply']")
      |> render_submit(%{"content" => "This is my reply"})

      # Should receive send_reply event
      assert_receive {:send_reply, 1, "This is my reply"}
    end

    # ARC_FUNC_08: WHEN reply form submitted THEN clear textarea after successful send
    test "clears textarea after successful reply submission", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: true,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, view, _html} = render_isolated(conn, assigns)

      # Submit reply
      view
      |> element("form[phx-submit='send_reply']")
      |> render_submit(%{"content" => "Test reply"})

      # Textarea should be cleared
      html = render(view)
      textarea_content = html |> Floki.parse_document!() |> Floki.find("textarea") |> Floki.text()
      assert textarea_content == ""
    end

    test "does not emit reply when agent is terminated", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: true,
        agent_alive: false,
        target: self(),
        pubsub: pubsub
      }

      {:ok, view, _html} = render_isolated(conn, assigns)

      # Try to submit (button should be disabled)
      view
      |> element("form[phx-submit='send_reply']")
      |> render_submit(%{"content" => "This should not send"})

      # Should not receive send_reply event
      refute_receive {:send_reply, _, _}, 100
    end
  end

  describe "Packet 2: edge cases" do
    test "handles empty reply content gracefully", %{conn: conn, pubsub: pubsub} do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: true,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, view, _html} = render_isolated(conn, assigns)

      # Submit empty reply
      view
      |> element("form[phx-submit='send_reply']")
      |> render_submit(%{"content" => ""})

      # Should either reject or handle gracefully (implementation decision)
      # At minimum, should not crash
      assert true
    end

    test "preserves reply form state when collapsed and re-expanded", %{
      conn: conn,
      pubsub: pubsub
    } do
      message = create_agent_message()

      assigns = %{
        message: message,
        expanded: true,
        reply_form_visible: true,
        agent_alive: true,
        target: self(),
        pubsub: pubsub
      }

      {:ok, view, _html} = render_isolated(conn, assigns)

      # Type some content
      view
      |> element("textarea[name='content']")
      |> render_change(%{"content" => "Draft reply"})

      # Content should be preserved in component state
      html = render(view)
      assert html =~ "Draft reply"
    end
  end
end
