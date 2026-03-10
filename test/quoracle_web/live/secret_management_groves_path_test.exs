defmodule QuoracleWeb.SecretManagementGrovesPathTest do
  @moduledoc """
  Tests for groves_path configuration in System tab of SecretManagementLive.
  Part of UI_SecretManagement v7.0, wip-20260222-grove-bootstrap Packet 3.

  ARC Criteria:
  - UI_SecretManagement R46: Groves path input renders in System tab
  - UI_SecretManagement R47: Groves path displays current configured value
  - UI_SecretManagement R48: Save system config stores groves_path
  - UI_SecretManagement R49: Clearing groves_path reverts to default
  - UI_SecretManagement R50: Groves path shows default placeholder when not configured
  - UI_SecretManagement R51: End-to-end groves path configuration persists across reload
  """

  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  @moduletag :feat_grove_system

  alias Quoracle.Models.ConfigModelSettings

  setup do
    # Create isolated PubSub for each test (test isolation)
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    %{pubsub: pubsub}
  end

  # Helper to mount LiveView with sandbox access and isolated PubSub
  # Used for integration tests (not acceptance tests which use live/2)
  defp mount_settings_live(conn, sandbox_owner, pubsub) do
    live_isolated(conn, QuoracleWeb.SecretManagementLive,
      session: %{
        "sandbox_owner" => sandbox_owner,
        "pubsub" => pubsub
      }
    )
  end

  # =============================================================
  # UI_SecretManagement v7.0: Groves Path in System Tab (R46-R50)
  # =============================================================

  describe "System tab groves_path" do
    @tag :r46
    test "R46: groves_path input renders in System tab", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # R46: WHEN System tab renders THEN groves_path text input visible
      {:ok, view, _html} = mount_settings_live(conn, sandbox_owner, pubsub)

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      # Positive: groves_path input element must exist
      assert has_element?(view, "input[name='system_config[groves_path]']"),
             "Expected groves_path text input in System tab"

      # Positive: label must be present
      assert render(view) =~ "Groves Directory Path"

      # Negative: no error messages (check specific error patterns, not bare "error"
      # which matches Phoenix built-in client-error/server-error flash divs)
      refute render(view) =~ "Error saving"
      refute render(view) =~ "error-message"
    end

    @tag :r47
    test "R47: groves_path input shows configured value", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # R47: WHEN groves_path configured THEN input shows current value
      {:ok, _} = ConfigModelSettings.set_groves_path("/configured/groves/dir")

      {:ok, view, _html} = mount_settings_live(conn, sandbox_owner, pubsub)

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      html = render(view)
      assert html =~ "/configured/groves/dir"
    end

    @tag :r48
    test "R48: save_system_config stores groves_path", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # R48: WHEN user enters path and saves THEN ConfigModelSettings stores path
      {:ok, view, _html} = mount_settings_live(conn, sandbox_owner, pubsub)

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      view
      |> form("#system-config-form", system_config: %{groves_path: "/my/custom/groves"})
      |> render_submit()

      html = render(view)
      assert html =~ "System configuration saved"

      # Verify persisted to DB
      assert {:ok, "/my/custom/groves"} = ConfigModelSettings.get_groves_path()
    end

    @tag :r49
    test "R49: clearing groves_path reverts to default", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # R49: WHEN user clears path and saves THEN ConfigModelSettings deletes path
      {:ok, _} = ConfigModelSettings.set_groves_path("/some/groves/path")

      {:ok, view, _html} = mount_settings_live(conn, sandbox_owner, pubsub)

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      # Clear the field and submit
      view
      |> form("#system-config-form", system_config: %{groves_path: ""})
      |> render_submit()

      html = render(view)
      # Placeholder should show default path
      assert html =~ "~/.quoracle/groves"
      refute html =~ "/some/groves/path"
    end

    @tag :r50
    test "R50: groves_path shows default placeholder when not configured", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # R50: WHEN groves_path not configured THEN input shows placeholder
      {:ok, view, _html} = mount_settings_live(conn, sandbox_owner, pubsub)

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      html = render(view)
      # Placeholder text should be visible in the input element
      assert html =~ "~/.quoracle/groves (default)"
    end
  end

  # =============================================================
  # SEC-3: Error Flash on Config Save Failures
  # =============================================================

  describe "config save error handling" do
    @tag :sec3
    test "SEC-3a: graceful error on DB failure in groves save", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # SEC-3a: WHEN set_groves_path raises a DB error (e.g. Postgrex.Error)
      # THEN the handler rescues it and shows error flash to the user
      # instead of crashing the LiveView process.
      #
      # Bug: handle_groves_path does not rescue DB errors, so a Postgrex error
      # (e.g. from null bytes in path) crashes the LiveView. Additionally,
      # save_system_config unconditionally flashes success even when the
      # save handler silently swallows non-crash errors.
      #
      # Fix: Wrap DB calls in try/rescue, accumulate errors, flash accordingly.
      import ExUnit.CaptureLog

      {:ok, view, _html} = mount_settings_live(conn, sandbox_owner, pubsub)

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      # Submit null-byte path which triggers Postgrex.Error from PostgreSQL.
      # After fix: handler rescues this and shows error flash.
      # Before fix: LiveView crashes.
      capture_log(fn ->
        view
        |> form("#system-config-form",
          system_config: %{groves_path: "/path\0null"}
        )
        |> render_submit()

        html = render(view)

        # After fix: error flash shown, no false success
        assert html =~ "Error saving"
        refute html =~ "System configuration saved"
      end)
    end
  end

  # =============================================================
  # Acceptance Test (R51) - Real route entry point
  # =============================================================

  describe "acceptance" do
    @tag :acceptance
    @tag :r51
    test "R51: user configures groves path and sees it persisted after reload", %{
      conn: conn
    } do
      # R51: SYSTEM test - Full user journey via real route
      # WHEN user navigates to Settings System tab, enters a groves path, and saves
      # THEN the path persists across page reload AND is reflected in the input value

      # 1. ENTRY POINT - Real route, NOT live_isolated
      {:ok, view, _html} = live(conn, "/settings")

      # 2. USER ACTION - Navigate to System tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      # 3. USER ACTION - Enter custom groves path and save
      view
      |> form("#system-config-form", system_config: %{groves_path: "/custom/groves"})
      |> render_submit()

      # 4. POSITIVE ASSERTION - Success flash and value shown
      html = render(view)
      assert html =~ "System configuration saved"
      assert html =~ "/custom/groves"

      # 5. Simulate page reload by re-navigating to real route
      {:ok, view2, _html2} = live(conn, "/settings")

      # 6. Navigate to System tab again
      view2
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      # 7. POSITIVE ASSERTION - Saved path persisted across reload
      html2 = render(view2)
      assert html2 =~ "/custom/groves"

      # 8. NEGATIVE ASSERTION - No error states
      refute html2 =~ "N/A"
    end
  end
end
