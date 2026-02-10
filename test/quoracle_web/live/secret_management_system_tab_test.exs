defmodule QuoracleWeb.SecretManagementSystemTabTest do
  @moduledoc """
  Tests for System tab in SecretManagementLive (UI_SecretManagement v5.0).
  Part of TEST_SkillsPathConfig spec (feat-20260208-210722, Packet 3).

  ARC Criteria:
  - UI_SecretManagement R29: System tab renders system configuration form
  - UI_SecretManagement R30: skills_path input shown with current value
  - UI_SecretManagement R31: Save shows success flash and persists on reload
  - UI_SecretManagement R32: Clear shows empty input with default placeholder
  - UI_SecretManagement R33: Mount loads configured skills_path
  - UI_SecretManagement R34: Full user journey across page reloads (acceptance)
  - TEST_SkillsPathConfig R10: End-to-end from UI to Loader skill listing (acceptance)
  - TEST_SkillsPathConfig R11: Tilde path from UI expands for Loader skill discovery (acceptance)
  """

  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  alias Quoracle.Models.ConfigModelSettings
  alias Quoracle.Skills.Loader

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
  # UI_SecretManagement v5.0: System Tab (R29-R33) [INTEGRATION]
  # =============================================================

  describe "System tab" do
    @tag :r29
    test "System tab renders system configuration form", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # R29: WHEN System tab clicked THEN system configuration form shown
      {:ok, view, _html} = mount_settings_live(conn, sandbox_owner, pubsub)

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      assert has_element?(view, "#system-config-form")
      assert render(view) =~ "System Configuration"
    end

    @tag :r30
    test "System tab shows skills_path input with current value", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # R30: WHEN System tab active THEN skills_path text input shown with current value
      # Pre-configure a path so we can verify value binding
      {:ok, _} = ConfigModelSettings.set_skills_path("/configured/skills/dir")

      {:ok, view, _html} = mount_settings_live(conn, sandbox_owner, pubsub)

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      # Assert input element exists
      assert has_element?(view, "input[name='system_config[skills_path]']")
      # Assert label is shown
      assert render(view) =~ "Skills Directory Path"
      # Assert current value is bound in the input
      html = render(view)
      assert html =~ "/configured/skills/dir"
    end

    @tag :r31
    test "saving skills_path shows success flash and value persists on reload", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # R31: WHEN user enters skills_path and clicks save THEN flash confirms save
      #      AND value shown in input on reload
      {:ok, view, _html} = mount_settings_live(conn, sandbox_owner, pubsub)

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      view
      |> form("#system-config-form", system_config: %{skills_path: "/my/custom/skills"})
      |> render_submit()

      html = render(view)
      assert html =~ "System configuration saved"
      # Verify persisted to DB
      assert {:ok, "/my/custom/skills"} = ConfigModelSettings.get_skills_path()

      # Verify value shown in input after reload (remount)
      {:ok, view2, _html2} = mount_settings_live(conn, sandbox_owner, pubsub)

      view2
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      html2 = render(view2)
      assert html2 =~ "/my/custom/skills"
    end

    @tag :r32_ui
    test "clearing skills_path shows empty input with default placeholder", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # R32 (UI): WHEN user clears skills_path and saves THEN input shows empty with placeholder
      # First set a value via DB
      {:ok, _} = ConfigModelSettings.set_skills_path("/some/path")

      {:ok, view, _html} = mount_settings_live(conn, sandbox_owner, pubsub)

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      # Clear the field and submit
      view
      |> form("#system-config-form", system_config: %{skills_path: ""})
      |> render_submit()

      html = render(view)
      # Placeholder should show default path
      assert html =~ "~/.quoracle/skills"
      refute html =~ "/some/path"
    end

    @tag :r33_ui
    test "mount loads current skills_path into assigns", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # R33 (UI): WHEN page loads with configured skills_path THEN shown in form
      {:ok, _} = ConfigModelSettings.set_skills_path("/pre-configured/path")

      {:ok, view, _html} = mount_settings_live(conn, sandbox_owner, pubsub)

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      html = render(view)
      assert html =~ "/pre-configured/path"
    end
  end

  # =============================================================
  # Acceptance Tests (R34, R10) - Real route entry point
  # =============================================================

  describe "acceptance" do
    @tag :acceptance
    @tag :r34
    test "user can configure, save, and see skills path across page reloads", %{
      conn: conn
    } do
      # R34: SYSTEM test - Full user journey via real route
      # Entry point MUST be live(conn, "/settings") for acceptance tests

      # 1. ENTRY POINT - Real route, NOT live_isolated
      {:ok, view, _html} = live(conn, "/settings")

      # 2. USER ACTION - Navigate to System tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      # 3. USER ACTION - Enter custom skills path and save
      view
      |> form("#system-config-form", system_config: %{skills_path: "/custom/skills"})
      |> render_submit()

      # 4. POSITIVE ASSERTION - Success flash and value shown
      html = render(view)
      assert html =~ "System configuration saved"
      assert html =~ "/custom/skills"

      # 5. Simulate page reload by re-navigating to real route
      {:ok, view2, _html2} = live(conn, "/settings")

      # 6. Navigate to System tab again
      view2
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      # 7. POSITIVE ASSERTION - Saved path persisted across reload
      html2 = render(view2)
      assert html2 =~ "/custom/skills"

      # 8. NEGATIVE ASSERTION - No error states
      refute html2 =~ "N/A"
    end

    @tag :acceptance
    @tag :r10
    test "user-configured skills path flows from UI to Loader skill listing", %{
      conn: conn
    } do
      # R10: SYSTEM test - Full end-to-end from UI configuration to Loader usage
      # Verifies the complete chain: UI → ConfigModelSettings → Loader

      # Create temp skill directory with a test skill
      # Use base_name pattern so System.tmp_dir!() appears directly in File.* calls
      base_name = "e2e_skills_#{System.unique_integer([:positive])}"
      temp_dir = Path.join(System.tmp_dir!(), base_name)

      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "test-skill"]))

      skill_file = Path.join([System.tmp_dir!(), base_name, "test-skill", "SKILL.md"])

      File.write!(skill_file, """
      ---
      name: test-skill
      description: A test skill for e2e verification
      ---

      # Test Skill Content
      """)

      on_exit(fn -> File.rm_rf!(Path.join(System.tmp_dir!(), base_name)) end)

      # 1. ENTRY POINT - Real route, NOT live_isolated
      {:ok, view, _html} = live(conn, "/settings")

      # 2. USER ACTION - Navigate to System tab and configure skills path
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      view
      |> form("#system-config-form", system_config: %{skills_path: temp_dir})
      |> render_submit()

      # 3. POSITIVE ASSERTION - Loader picks up the configured path (no opts override)
      assert Loader.skills_dir() == temp_dir

      # 4. POSITIVE ASSERTION - Skills listable from the configured path
      {:ok, skills} = Loader.list_skills()
      assert Enum.any?(skills, &(&1.name == "test-skill"))

      # 5. NEGATIVE ASSERTION - Skills list is not empty
      refute Enum.empty?(skills)
    end

    @tag :acceptance
    @tag :r11
    test "user-configured tilde path is expanded by Loader", %{
      conn: conn
    } do
      # R11: SYSTEM test - Tilde path from UI → ConfigModelSettings → Loader expansion
      # Bug: User enters ~/path in UI, Loader uses literal ~ in File.dir?, skills vanish
      # Verifies: Full chain UI save → DB persist → Loader.skills_dir returns expanded path

      unique = System.unique_integer([:positive])
      tilde_path = "~/.quoracle_acceptance_tilde_#{unique}"
      expanded_path = Path.expand(tilde_path)

      # 1. ENTRY POINT - Real route, NOT live_isolated
      {:ok, view, _html} = live(conn, "/settings")

      # 2. USER ACTION - Navigate to System tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='system']")
      |> render_click()

      # 3. USER ACTION - Enter tilde path and save (user types ~/... in input)
      view
      |> form("#system-config-form", system_config: %{skills_path: tilde_path})
      |> render_submit()

      # 4. POSITIVE ASSERTION - Success flash shown
      html = render(view)
      assert html =~ "System configuration saved"

      # 5. POSITIVE ASSERTION - Loader returns expanded absolute path (no tilde)
      result = Loader.skills_dir()
      assert result == expanded_path

      # 6. NEGATIVE ASSERTION - Path must NOT contain literal tilde
      refute String.starts_with?(result, "~")
    end
  end
end
