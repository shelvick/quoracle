defmodule QuoracleWeb.E2ESmokeTest do
  @moduledoc """
  E2E smoke tests for all LiveView routes.

  CRITICAL: These tests use `live(conn, "/path")` WITHOUT session injection,
  which exercises the actual production path through the router.

  This is different from `live_isolated` tests that inject session values -
  those are integration tests, not E2E tests.

  Every LiveView route MUST have at least one smoke test here to ensure
  production doesn't crash on page load.
  """
  use QuoracleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  describe "[E2E] DashboardLive at /" do
    test "loads without crashing in production config", %{conn: conn} do
      # This exercises the actual production path - no session injection
      {:ok, _view, html} = live(conn, "/")

      # Basic smoke test - page renders without error
      assert html =~ "Quoracle"
    end
  end

  describe "[E2E] LogViewLive at /logs" do
    test "loads without crashing in production config", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/logs")

      # Basic smoke test - page renders without error
      assert html =~ ~r/[Ll]og/
    end
  end

  describe "[E2E] MailboxLive at /mailbox" do
    test "loads without crashing in production config", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mailbox")

      # Basic smoke test - page renders without error
      assert html =~ "Quoracle"
    end
  end

  describe "[E2E] SecretManagementLive at /settings" do
    test "loads without crashing in production config", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      # Basic smoke test - page renders without error
      assert html =~ ~r/[Ss]ecret/
    end
  end
end
