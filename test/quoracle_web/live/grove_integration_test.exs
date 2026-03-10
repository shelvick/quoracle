defmodule QuoracleWeb.GroveIntegrationTest do
  @moduledoc """
  Integration and system tests for grove selection UI flow.
  Tests the full path from Dashboard mount through grove dropdown rendering,
  grove selection, form pre-fill via push_event, and task creation with
  grove-populated fields.

  ARC Criteria tested:
  - TEST_GroveUI: R6-R13 (grove UI integration flow)
  - UI_TaskTree v10.0: R47-R54 (grove selector + pre-fill in TaskTree)
  - UI_Dashboard v13.0: R56-R62 (grove loading and forwarding)

  Cross-references:
  - R6/R56/R57: Dashboard loads groves and renders grove selector
  - R7/R47/R52: Grove dropdown present in modal
  - R8/R48: Grove selection resolves without error
  - R9/R49: No grove resets selection
  - R10/R50: Invalid grove shows error flash
  - R11/R54/R62: End-to-end grove task creation
  - R12: Overridden grove fields accepted
  - R13/R59: Broken grove excluded / empty groves graceful
  - R51/R58: Grove skills path forwarded
  - R53: Profile graceful degradation
  - R60: Session groves_path isolation
  - R61: Task without grove has no grove skills
  """

  use QuoracleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import ExUnit.CaptureLog
  import Test.AgentTestHelpers

  @moduletag :feat_grove_system

  alias Quoracle.Agent.Core
  alias QuoracleWeb.UI.TaskTreeTestLive

  # Helper to create a grove directory with GROVE.md frontmatter.
  # Uses System.tmp_dir!() inline for git hook static analysis compatibility.
  defp create_grove(base_name, grove_name, grove_md_content) do
    grove_dir = Path.join(System.tmp_dir!(), Path.join(base_name, grove_name))
    grove_md = Path.join(grove_dir, "GROVE.md")
    File.mkdir_p!(grove_dir)
    File.write!(grove_md, grove_md_content)
    grove_dir
  end

  # Helper to create a bootstrap file inside a grove directory.
  # Uses System.tmp_dir!() inline for git hook static analysis compatibility.
  defp create_bootstrap_file(base_name, grove_name, filename, content) do
    bootstrap_dir = Path.join(System.tmp_dir!(), Path.join([base_name, grove_name, "bootstrap"]))
    bootstrap_file = Path.join(bootstrap_dir, filename)
    File.mkdir_p!(bootstrap_dir)
    File.write!(bootstrap_file, content)
  end

  # Helper to create the skills directory inside a grove.
  # Uses System.tmp_dir!() inline for git hook static analysis compatibility.
  defp create_skills_dir(base_name, grove_name) do
    skills_dir = Path.join(System.tmp_dir!(), Path.join([base_name, grove_name, "skills"]))
    File.mkdir_p!(skills_dir)
  end

  # Helper to create a skill file inside a grove's skills directory.
  # Uses System.tmp_dir!() inline for git hook static analysis compatibility.
  defp create_skill_file(base_name, grove_name, skill_name, skill_content) do
    skill_dir =
      Path.join(System.tmp_dir!(), Path.join([base_name, grove_name, "skills", skill_name]))

    skill_file = Path.join(skill_dir, "SKILL.md")
    File.mkdir_p!(skill_dir)
    File.write!(skill_file, skill_content)
  end

  # Helper for integration-audit regression where governance file is missing.
  defp create_broken_governance_grove(base_name, grove_name, profile_name) do
    create_bootstrap_file(base_name, grove_name, "task.md", "Broken governance task")

    create_skill_file(base_name, grove_name, "venture-management", """
    ---
    name: venture-management
    description: Governance fixture skill
    ---
    Execute venture-management workflow.
    """)

    grove_md = """
    ---
    name: #{grove_name}
    description: Broken governance fixture grove
    version: "1.0"
    bootstrap:
      task_description_file: bootstrap/task.md
      skills:
        - venture-management
      profile: #{profile_name}
    governance:
      injections:
        - source: governance/missing-doctrine.md
          priority: high
          inject_into:
            - venture-management
      hard_rules:
        - type: shell_pattern_block
          pattern: "rm\\s+-rf|pkill|killall"
          message: "Always obtain explicit approval before destructive actions."
          scope: all
    ---
    """

    create_grove(base_name, grove_name, grove_md)
  end

  # Helper for regression: grove with governance but no skills/ directory.
  defp create_governance_only_grove_without_skills_dir(base_name, grove_name, profile_name) do
    create_bootstrap_file(base_name, grove_name, "task.md", "Governance-only dashboard task")

    grove_md = """
    ---
    name: #{grove_name}
    description: Governance-only fixture grove
    version: "1.0"
    bootstrap:
      task_description_file: bootstrap/task.md
      profile: #{profile_name}
    governance:
      hard_rules:
        - type: shell_pattern_block
          pattern: "rm\\s+-rf|pkill|killall"
          message: "Always obtain explicit approval before destructive actions."
          scope: all
    ---
    """

    create_grove(base_name, grove_name, grove_md)
  end

  defp capturing_model_query_fn(test_pid) do
    fn messages, [model_id], _opts ->
      send(test_pid, {:grove_r29_model_query_messages, model_id, messages})

      {:ok,
       %{
         successful_responses: [%{model: model_id, content: orient_response()}],
         failed_models: []
       }}
    end
  end

  defp orient_response do
    Jason.encode!(%{
      "action" => "orient",
      "params" => %{
        "current_situation" => "Governance prompt capture",
        "goal_clarity" => "Verify model-facing prompt",
        "available_resources" => "test harness",
        "key_challenges" => "none",
        "delegation_consideration" => "not needed"
      },
      "reasoning" => "governance capture response",
      "wait" => true
    })
  end

  setup %{conn: conn, sandbox_owner: sandbox_owner} do
    # Create isolated dependencies for test isolation
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    {:ok, _dynsup} =
      start_supervised({Quoracle.Agent.DynSup, name: dynsup_name}, shutdown: :infinity)

    # Create test profile for task creation
    profile = create_test_profile()

    # Create unique temp grove directory with complete bootstrap
    # Uses System.tmp_dir!() inline for git hook static analysis compatibility
    base_name = "test_groves_ui/#{System.unique_integer([:positive])}"
    groves_path = Path.join(System.tmp_dir!(), base_name)
    File.mkdir_p!(Path.join(System.tmp_dir!(), base_name))

    # Create test grove with all bootstrap fields via helpers
    create_bootstrap_file(base_name, "test-grove", "context.md", "Test project context")
    create_bootstrap_file(base_name, "test-grove", "task.md", "Build the feature")
    create_skills_dir(base_name, "test-grove")

    # Create a valid "testing" skill file inside the grove's skills directory
    # Required by SkillLoader to resolve the skill reference in bootstrap.skills
    create_skill_file(base_name, "test-grove", "testing", """
    ---
    name: testing
    description: Testing skill for grove tests
    ---
    Run tests.
    """)

    grove_md = """
    ---
    name: test-grove
    description: Test grove for UI tests
    version: "1.0"
    bootstrap:
      global_context_file: bootstrap/context.md
      task_description_file: bootstrap/task.md
      role: "Test Engineer"
      cognitive_style: systematic
      skills:
        - testing
      profile: #{profile.name}
    ---
    """

    create_grove(base_name, "test-grove", grove_md)

    on_exit(fn -> File.rm_rf!(groves_path) end)

    %{
      conn: conn,
      pubsub: pubsub_name,
      registry: registry_name,
      dynsup: dynsup_name,
      sandbox_owner: sandbox_owner,
      groves_path: groves_path,
      base_name: base_name,
      profile: profile
    }
  end

  # Helper to mount dashboard with grove path via session injection (real route)
  defp mount_dashboard_with_groves(conn, context, extra_session \\ %{}) do
    session =
      Map.merge(
        %{
          "pubsub" => context.pubsub,
          "registry" => context.registry,
          "dynsup" => context.dynsup,
          "sandbox_owner" => context.sandbox_owner,
          "groves_path" => context.groves_path
        },
        extra_session
      )

    conn
    |> Plug.Test.init_test_session(session)
    |> live("/")
  end

  # Helper to mount dashboard without groves (empty groves scenario).
  # Uses System.tmp_dir!() inline for git hook static analysis compatibility.
  defp mount_dashboard_no_groves(conn, context) do
    empty_base = "empty_groves_#{System.unique_integer([:positive])}"
    empty_groves_path = Path.join(System.tmp_dir!(), empty_base)
    File.mkdir_p!(Path.join(System.tmp_dir!(), empty_base))
    on_exit(fn -> File.rm_rf!(Path.join(System.tmp_dir!(), empty_base)) end)

    conn
    |> Plug.Test.init_test_session(%{
      "pubsub" => context.pubsub,
      "registry" => context.registry,
      "dynsup" => context.dynsup,
      "sandbox_owner" => context.sandbox_owner,
      "groves_path" => empty_groves_path
    })
    |> live("/")
  end

  # Helper to mount TaskTree test harness with groves
  defp mount_task_tree_with_groves(conn, context) do
    live_isolated(conn, TaskTreeTestLive,
      session: %{
        "sandbox_owner" => context.sandbox_owner,
        "tasks" => %{},
        "agents" => %{},
        "test_pid" => self(),
        "groves_path" => context.groves_path
      }
    )
  end

  # =============================================================================
  # R6/R56: Dashboard Loads Groves on Mount
  # =============================================================================

  describe "dashboard grove loading" do
    @tag :r6
    @tag :r56
    test "R6/R56: dashboard renders grove selector label on mount", %{conn: conn} = context do
      # R6: WHEN Dashboard mounts with groves directory containing valid grove
      # THEN rendered HTML contains grove selector label "Start from Grove"
      # R56: WHEN Dashboard mounts THEN groves are visible in grove selector dropdown
      capture_log(fn ->
        {:ok, _view, html} = mount_dashboard_with_groves(conn, context)

        # Grove selector label must be present
        assert html =~ "Start from Grove"
      end)
    end

    @tag :r7
    @tag :r57
    test "R7/R57: grove dropdown select element present in DOM", %{conn: conn} = context do
      # R7: WHEN Dashboard mounts with groves THEN grove dropdown select element
      # with name="grove" is present in DOM
      # R57: WHEN Dashboard renders with groves THEN grove dropdown select element present
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        # The select element for grove selection must exist
        assert has_element?(view, "select[name=grove]")
      end)
    end

    @tag :r60
    test "R60: mount uses groves_path from session to find groves", %{conn: conn} = context do
      # R60: WHEN session contains groves_path pointing to test directory
      # THEN groves from that directory appear in the grove selector
      capture_log(fn ->
        {:ok, _view, html} = mount_dashboard_with_groves(conn, context)

        # The test-grove from our temp directory should appear
        assert html =~ "test-grove"
        assert html =~ "Test grove for UI tests"
      end)
    end

    @tag :r59
    @tag :r13_empty
    test "R59: mount with empty groves directory shows no grove options",
         %{conn: conn} = context do
      # R59: WHEN groves directory is empty or missing
      # THEN grove selector shows only "No grove (blank form)" option AND no error occurs
      capture_log(fn ->
        {:ok, view, html} = mount_dashboard_no_groves(conn, context)

        # Only "No grove" option, no specific grove names
        assert html =~ "No grove (blank form)"
        # No error flash (check specific error patterns, not bare "error"
        # which matches Phoenix built-in client-error/server-error flash divs)
        refute html =~ "Failed to load grove"
        refute html =~ "Error saving"

        # Select element still present and functional
        assert has_element?(view, "select[name=grove]")
      end)
    end
  end

  # =============================================================================
  # R47/R52: TaskTree-Level Grove Dropdown Tests
  # =============================================================================

  describe "TaskTree grove dropdown" do
    @tag :r47
    test "R47: modal shows grove selector dropdown above form sections",
         %{conn: conn} = context do
      # R47: WHEN New Task modal opens THEN grove selector dropdown visible above form sections
      capture_log(fn ->
        {:ok, view, _html} = mount_task_tree_with_groves(conn, context)

        # Open the modal
        view |> element("button", "New Task") |> render_click()
        html = render(view)

        # Grove selector present in modal
        assert html =~ "Start from Grove"
        assert html =~ ~s(name="grove")
        assert html =~ "test-grove"
      end)
    end

    @tag :r52
    test "R52: TaskTree with no groves shows only default option", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      # R52: WHEN TaskTree receives empty groves list
      # THEN grove selector shows only "No grove (blank form)" option
      capture_log(fn ->
        {:ok, view, _html} =
          live_isolated(conn, TaskTreeTestLive,
            session: %{
              "sandbox_owner" => sandbox_owner,
              "tasks" => %{},
              "agents" => %{},
              "test_pid" => self(),
              "groves" => []
            }
          )

        view |> element("button", "New Task") |> render_click()
        html = render(view)

        # Only "No grove" option in the dropdown
        assert html =~ "No grove (blank form)"

        # Parse and count options
        parsed = Floki.parse_document!(html)
        grove_select = Floki.find(parsed, "select[name=grove]")

        assert grove_select != [],
               "Expected select[name=grove] element in modal"

        grove_options = Floki.find(grove_select, "option")
        # Only the default "No grove" option
        assert length(grove_options) == 1
      end)
    end
  end

  # =============================================================================
  # R8/R48: Grove Selection Resolves Without Error
  # =============================================================================

  describe "grove selection flow" do
    @tag :r8
    @tag :r48
    test "R8/R48: selecting grove resolves fields without error", %{conn: conn} = context do
      # R8: WHEN user selects grove THEN server resolves bootstrap fields without error
      # AND the selected grove name appears in the rendered HTML AND no error flash shown
      # R48: Same requirement from UI_TaskTree v10.0 perspective
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        # Open modal and select the grove
        view |> element("button", "New Task") |> render_click()

        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "test-grove"})

        html = render(view)

        # Server-side resolution succeeded: no error flash
        refute html =~ "Failed to load grove"
        # The selected grove name is reflected in the rendered dropdown
        assert html =~ "test-grove"
        # Grove selector remains functional
        assert has_element?(view, "select[name=grove]")
      end)
    end

    @tag :r9
    @tag :r49
    test "R9/R49: selecting no grove resets selection without error", %{conn: conn} = context do
      # R9: WHEN user selects "No grove" after a grove was selected
      # THEN no error flash shown AND grove selector remains functional
      # R49: Same requirement from UI_TaskTree v10.0 perspective
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        # Open modal
        view |> element("button", "New Task") |> render_click()

        # First select a grove
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "test-grove"})

        # Then deselect by choosing "No grove"
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => ""})

        html = render(view)

        # No error from clearing selection
        refute html =~ "Failed to load grove"
        # Selector still functional and present
        assert has_element?(view, "select[name=grove]")
        # "No grove (blank form)" is still a visible option
        assert html =~ "No grove (blank form)"
      end)
    end

    @tag :r10
    @tag :r50
    test "R10/R50: invalid grove shows error flash with message", %{conn: conn} = context do
      # R10: WHEN user selects nonexistent grove THEN flash error contains "Failed to load grove"
      # R50: Same requirement from UI_TaskTree v10.0 perspective
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        # Open modal
        view |> element("button", "New Task") |> render_click()

        # Select a grove that doesn't exist in temp directory
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "nonexistent-grove"})

        html = render(view)

        # Error message should mention the failure
        assert html =~ "Failed to load grove"
      end)
    end
  end

  # =============================================================================
  # R11/R54/R62: Task Creation with Grove Pre-fill
  # =============================================================================

  describe "task creation with grove" do
    @tag :acceptance
    @tag :r11
    @tag :r54
    @tag :r62
    test "R11/R54/R62: grove-prefilled task creation succeeds with grove values in params",
         %{conn: conn} = context do
      # R11: WHEN user submits form with grove-resolved values THEN task is created
      # AND the task description appears in the rendered task list AND no error flash shown
      # R54/R62: End-to-end grove task creation from UI_TaskTree and UI_Dashboard perspectives
      # Boundary: Test submits form with values matching what the JS hook would populate
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        # Open modal
        view |> element("button", "New Task") |> render_click()

        # Select grove (triggers server-side resolution + push_event to JS hook)
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "test-grove"})

        # In LiveView test, simulate form submission with the values
        # that JS hook would have populated from the push_event
        view
        |> form("#new-task-form", %{
          "task_description" => "Build the feature",
          "global_context" => "Test project context",
          "role" => "Test Engineer",
          "cognitive_style" => "systematic",
          "skills" => "testing",
          "profile" => context.profile.name
        })
        |> render_submit()

        html = render(view)

        # Task creation should succeed: grove-derived description appears in task list
        assert html =~ "Build the feature"
        # No error flash
        refute html =~ "Failed to create task"
        refute html =~ "Missing required fields"
      end)
    end

    @tag :r12
    test "R12: overridden grove fields accepted in task creation", %{conn: conn} = context do
      # R12: WHEN user overrides grove-prefilled values with custom values and submits
      # THEN task is created with the custom description
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        # Open modal
        view |> element("button", "New Task") |> render_click()

        # Select grove (provides default values)
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "test-grove"})

        # Override grove-prefilled values with custom ones
        view
        |> form("#new-task-form", %{
          "task_description" => "Custom description overriding grove",
          "role" => "Custom Role",
          "profile" => context.profile.name
        })
        |> render_submit()

        html = render(view)

        # Task created with overridden description (not grove default)
        assert html =~ "Custom description overriding grove"
        # No error -- custom values accepted
        refute html =~ "Failed to create task"
        refute html =~ "Missing required fields"
      end)
    end

    @tag :r61
    test "R61: task created without grove selection uses global skills only",
         %{conn: conn} = context do
      # R61: WHEN user creates task without selecting a grove
      # THEN task uses only global skills (no grove-local skill path)
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        # Open modal - verify grove selector IS present (groves were loaded)
        view |> element("button", "New Task") |> render_click()

        # The grove selector must exist even though we won't select a grove
        # (this ensures the grove-aware Dashboard path is active)
        assert has_element?(view, "select[name=grove]")

        # Submit with just task description (no grove selected)
        view
        |> form("#new-task-form", %{
          "task_description" => "Task without grove",
          "profile" => context.profile.name
        })
        |> render_submit()

        html = render(view)

        # Task creation succeeds
        assert html =~ "Task without grove"
        refute html =~ "Failed to create task"
      end)
    end
  end

  # =============================================================================
  # R51/R58: Grove Skills Path Forwarded
  # =============================================================================

  describe "grove skills forwarding" do
    @tag :r51
    @tag :r58
    test "R51/R58: create_task from grove forwards grove_skills_path",
         %{conn: conn} = context do
      # R51: WHEN task created from grove with skills directory
      # THEN grove-local skills are available to the created task
      # R58: grove_skills_path forwarded through creation chain
      # Strategy: Use TaskTree test harness to intercept {:submit_prompt, params}
      # and verify grove_skills_path is present
      capture_log(fn ->
        {:ok, view, _html} = mount_task_tree_with_groves(conn, context)

        # Open modal and select grove
        view |> element("button", "New Task") |> render_click()

        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "test-grove"})

        # Submit form with grove values
        view
        |> form("#new-task-form", %{
          "task_description" => "Build the feature",
          "profile" => context.profile.name
        })
        |> render_submit()

        # Verify that the submit_prompt message includes grove_skills_path
        assert_receive {:submit_prompt, params}, 5000

        # grove_skills_path should point to the test grove's skills directory
        assert Map.has_key?(params, "grove_skills_path"),
               "Expected grove_skills_path in submitted params, got: #{inspect(Map.keys(params))}"

        assert params["grove_skills_path"] =~ "skills"
      end)
    end
  end

  # =============================================================================
  # SEC-2: grove_skills_path Must Be Server-Derived, Not Client-Injectable
  # =============================================================================

  describe "grove_skills_path server derivation" do
    @tag :sec2
    test "SEC-2a: injected grove_skills_path is not used",
         %{conn: conn} = context do
      # SEC-2a: WHEN dashboard receives {:submit_prompt, params} with a
      # client-injected grove_skills_path AND a skills reference
      # THEN the injected path must be IGNORED (not used to load skills).
      #
      # Bug: EventHandlers.handle_submit_prompt reads params["grove_skills_path"]
      # directly and passes it as skills_path to TaskManager. A crafted
      # submission can inject an arbitrary directory for skill loading.
      #
      # Fix: Dashboard should read grove_skills_path from socket.assigns
      # (server-derived from grove selection), not from params.
      #
      # Strategy: Mount dashboard without selecting a grove, send a raw
      # {:submit_prompt, ...} with injected grove_skills_path pointing to
      # our test grove's skills dir AND a skills reference. If the injected
      # path is used, the skill loads successfully. If the fix works
      # (path ignored), the skill is not found (only global skills checked).
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        # Do NOT select a grove (server-side grove_skills_path = nil)

        # The injected path points to the test grove's skills directory.
        # If the path is used, the "testing" skill loads successfully.
        # If the fix ignores the injected path, SkillLoader only checks
        # global paths and won't find "testing" -> shows error flash.
        injected_path =
          Path.join([context.groves_path, "test-grove", "skills"])

        send(
          view.pid,
          {:submit_prompt,
           %{
             "task_description" => "Injected path exploit",
             "profile" => context.profile.name,
             "skills" => "testing",
             "grove_skills_path" => injected_path
           }}
        )

        html = render(view)

        # After fix: The skill "testing" is NOT found because the injected
        # grove_skills_path is ignored (server has nil since no grove selected).
        # The task creation should fail with "Skill 'testing' not found".
        assert html =~ "Skill" and html =~ "not found",
               "Expected skill not found error when grove_skills_path is " <>
                 "injected without server-side grove selection. " <>
                 "Got: #{String.slice(html, 0..200)}"
      end)
    end
  end

  # =============================================================================
  # R53: Profile Graceful Degradation
  # =============================================================================

  describe "grove profile handling" do
    @tag :r53
    test "R53: non-existent profile leaves field unselected", %{conn: conn} = context do
      # R53: WHEN grove specifies profile that doesn't exist
      # THEN profile field left unselected (no error)
      # Create a grove with a nonexistent profile name via helper
      # (uses System.tmp_dir!() inline for git hook static analysis compatibility)
      bad_profile_grove_md = """
      ---
      name: bad-profile-grove
      description: Grove with nonexistent profile
      version: "1.0"
      bootstrap:
        role: "Test Role"
        profile: this-profile-does-not-exist-anywhere
      ---
      """

      create_grove(context.base_name, "bad-profile-grove", bad_profile_grove_md)

      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        # Open modal
        view |> element("button", "New Task") |> render_click()

        # Select the grove with nonexistent profile
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "bad-profile-grove"})

        html = render(view)

        # No error flash - graceful degradation (check specific error patterns,
        # not bare "error" which matches Phoenix built-in flash divs)
        refute html =~ "Failed to load grove"
        refute html =~ "Error saving"

        # The grove selection should still succeed
        assert html =~ "bad-profile-grove"
      end)
    end
  end

  # =============================================================================
  # R13: Broken Grove Excluded From List
  # =============================================================================

  describe "grove error handling" do
    @tag :r13
    test "R13: broken grove not offered in list", %{conn: conn} = context do
      # R13: WHEN groves directory has a broken grove (malformed GROVE.md)
      # THEN broken grove does NOT appear in selector AND valid grove still appears
      # Create broken grove via helper
      # (uses System.tmp_dir!() inline for git hook static analysis compatibility)
      create_grove(context.base_name, "broken-grove", "not yaml at all - broken content")

      capture_log(fn ->
        {:ok, _view, html} = mount_dashboard_with_groves(conn, context)

        # Broken grove must NOT appear in selector
        refute html =~ "broken-grove"
        # Valid grove still listed
        assert html =~ "test-grove"
      end)
    end
  end

  # =============================================================================
  # R58b: Grove skill opt key forwarding (extends R51/R58)
  # =============================================================================
  #
  # Integration audit found that EventHandlers.handle_submit_prompt builds opts
  # with :skills_path instead of :grove_skills_path (line 34). This means
  # TaskManager.resolve_skills/2 gets the grove path as the GLOBAL override,
  # replacing global skill lookup entirely instead of grove-first-then-global.
  #
  # Impact: When a grove has skills that exist only globally, they won't be found
  # because the grove path replaces global rather than prepending to it.

  describe "grove skill opt key (R58b)" do
    @tag :r58b
    @tag :integration
    test "task from grove with global-only skill succeeds via grove_skills_path forwarding",
         %{conn: conn} = context do
      # R58b: WHEN user creates a task from a grove that references a skill
      # AND that skill exists ONLY in the global skills directory (not in grove)
      # THEN task creation should succeed because grove_skills_path enables
      # grove-first-then-global fallback in SkillLoader.
      #
      # This test fails if EventHandlers uses :skills_path instead of
      # :grove_skills_path, because :skills_path REPLACES the global path
      # with the grove path, so globally-available skills become invisible.

      # Create a global skills directory with a skill
      # Uses System.tmp_dir!() inline in every File.* call for git hook static analysis
      global_skills_base = "gap1_global_skills_#{System.unique_integer([:positive])}"
      global_skills_path = Path.join(System.tmp_dir!(), global_skills_base)
      File.mkdir_p!(Path.join(System.tmp_dir!(), global_skills_base))

      # Create a global-only skill (NOT in the grove)
      File.mkdir_p!(Path.join([System.tmp_dir!(), global_skills_base, "global-deploy"]))

      skill_file = Path.join([System.tmp_dir!(), global_skills_base, "global-deploy", "SKILL.md"])

      File.write!(skill_file, """
      ---
      name: global-deploy
      description: Global deployment skill
      ---
      # Deploy
      Global deployment instructions.
      """)

      on_exit(fn -> File.rm_rf!(Path.join(System.tmp_dir!(), global_skills_base)) end)

      # Create a grove that references the global-only skill
      grove_md = """
      ---
      name: gap1-grove
      description: Grove referencing global skill
      version: "1.0"
      bootstrap:
        task_description_file: bootstrap/task.md
        skills:
          - global-deploy
        profile: #{context.profile.name}
      ---
      """

      create_grove(context.base_name, "gap1-grove", grove_md)
      create_bootstrap_file(context.base_name, "gap1-grove", "task.md", "Deploy the application")

      # Mount dashboard. The grove path has skills/ dir but global-deploy
      # is NOT there -- it only exists in the global skills dir.
      # If :grove_skills_path is correctly forwarded, SkillLoader does:
      #   1. Check grove skills dir → not found
      #   2. Check global skills dir → found!
      # If :skills_path is used (bug), SkillLoader does:
      #   1. Check grove path AS global → not found → error!
      capture_log(fn ->
        {:ok, view, _html} =
          conn
          |> Plug.Test.init_test_session(%{
            "pubsub" => context.pubsub,
            "registry" => context.registry,
            "dynsup" => context.dynsup,
            "sandbox_owner" => context.sandbox_owner,
            "groves_path" => context.groves_path,
            "skills_path" => global_skills_path
          })
          |> live("/")

        # Open modal and select the grove
        view |> element("button", "New Task") |> render_click()

        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "gap1-grove"})

        # Submit the form with grove-resolved values
        view
        |> form("#new-task-form", %{
          "task_description" => "Deploy the application",
          "skills" => "global-deploy",
          "profile" => context.profile.name
        })
        |> render_submit()

        html = render(view)

        # Task creation should succeed -- the global skill should be found
        # via grove-first-then-global fallback
        assert html =~ "Deploy the application",
               "Expected task to appear in tree after creation, " <>
                 "but skill may not have been found due to wrong opt key. HTML: #{String.slice(html, 0..300)}"

        # No skill-not-found error
        refute html =~ "not found",
               "Got 'not found' error -- likely :skills_path used instead of :grove_skills_path"
      end)
    end
  end

  # =============================================================================
  # R8b: Grove prefill JS hook wiring (extends R8)
  # =============================================================================
  #
  # Integration audit found that push_event("grove_prefill", fields) is sent
  # from grove_handlers.ex:47 but there is NO client-side JS handler in
  # assets/js/app.js to receive it and populate the form fields.
  #
  # The form uses phx-update="ignore" so LiveView server-side assigns cannot
  # control field values after first render. The JS hook is required to
  # translate the push_event payload into actual DOM field value updates.

  describe "grove prefill JS hook (R8b)" do
    @tag :r8b
    @tag :acceptance
    test "R8b: selecting grove pushes prefill event and form has JS hook",
         %{conn: conn} = context do
      # R8b: WHEN user selects a grove from the dropdown
      # THEN form fields should be pre-filled with the grove's bootstrap values
      # so the user can see them before submitting.
      #
      # Since the form uses phx-update="ignore", field population requires:
      # 1. Server sends push_event("grove_prefill", fields) ← works
      # 2. Form element has phx-hook="GrovePrefill" to receive the event ← MISSING
      # 3. JS hook handler sets field .value properties ← MISSING
      #
      # This test verifies BOTH the server contract AND the hook wiring:
      # - assert_push_event confirms the event is dispatched with correct payload
      # - has_element? confirms the form has a phx-hook for receiving the event

      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        # Open modal
        view |> element("button", "New Task") |> render_click()

        # Select the grove -- this triggers BootstrapResolver.resolve
        # and push_event("grove_prefill", fields)
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "test-grove"})

        # Verify: Server pushes grove_prefill event with resolved fields.
        # assert_push_event catches events at the channel level regardless of hooks.
        assert_push_event(view, "grove_prefill", %{
          global_context: "Test project context",
          task_description: "Build the feature",
          role: "Test Engineer",
          cognitive_style: "systematic"
        })

        # Verify: The form has phx-hook="GrovePrefill" so the JS handler
        # can receive the push_event and populate field values.
        # Without this hook, the event is dispatched but never handled client-side.
        assert has_element?(view, "#new-task-form[phx-hook=GrovePrefill]"),
               "Expected phx-hook=\"GrovePrefill\" on #new-task-form. " <>
                 "Without it, push_event('grove_prefill') is dispatched but fields remain empty."
      end)
    end
  end

  # =============================================================================
  # R9b: "No grove" dispatches clear event (extends R9)
  # =============================================================================
  #
  # Integration audit found that the clear path at grove_handlers.ex:21
  # resets socket assigns (selected_grove, grove_skills_path) but does NOT
  # push a grove_prefill clear event to JS. Since the form uses
  # phx-update="ignore", field values are client-side only and require
  # a push_event to the JS hook to clear them.

  describe "no grove clear event (R9b)" do
    @tag :r9b
    @tag :integration
    test "R9b: selecting no grove dispatches clear event to JS",
         %{conn: conn} = context do
      # R9b: WHEN user selects a grove (populating fields) then selects "No grove"
      # THEN the server must dispatch a push_event to clear the form field values.
      #
      # Current behavior:
      # - handle_grove_cleared resets assigns (selected_grove, grove_skills_path) ← works
      # - But does NOT push a "grove_prefill" clear event to JS ← MISSING
      #
      # Without the clear event, the form fields (under phx-update="ignore")
      # retain the previously-populated grove values even though the server
      # reset its assigns. The user sees stale data.
      #
      # This test verifies:
      # 1. Grove selection dispatches prefill event (baseline)
      # 2. "No grove" selection dispatches a clear event (currently missing)

      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        # Open modal
        view |> element("button", "New Task") |> render_click()

        # Step 1: Select a grove -- this pushes grove_prefill with field values
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "test-grove"})

        # Consume the prefill event from the mailbox (baseline confirmation)
        assert_push_event(view, "grove_prefill", %{role: "Test Engineer"}, 1000)

        html_after_select = render(view)
        assert html_after_select =~ "test-grove"
        refute html_after_select =~ "Failed to load grove"

        # Step 2: Select "No grove" -- this SHOULD push a clear event
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => ""})

        html_after_clear = render(view)

        # Server-side state cleared (no error, selector back to default)
        refute html_after_clear =~ "Failed to load grove"
        assert html_after_clear =~ "No grove (blank form)"

        # CRITICAL ASSERTION: A grove_prefill clear event must be dispatched
        # so the JS hook can reset field values in the DOM.
        # handle_grove_cleared currently only resets assigns but does NOT
        # call push_event, so this assertion WILL FAIL until implemented.
        assert_push_event(view, "grove_prefill", %{clear: true}, 1000)
      end)
    end
  end

  # =============================================================================
  # R11b: Acceptance test for grove prefill (extends R11)
  # =============================================================================
  #
  # The existing R11 test submits values directly rather than asserting that
  # the prefill event/JS application actually works. This acceptance test
  # goes from grove selection through to verifying the COMPLETE flow.

  describe "packet 4 governance flow" do
    @tag :r29
    @tag :acceptance
    test "R29: governance-only grove without skills directory still applies governance",
         %{conn: conn} = context do
      # Acceptance path: user selects a governance-only grove that has no skills/
      # directory, submits a task, and governance still reaches the model-facing prompt.
      capture_log(fn ->
        create_governance_only_grove_without_skills_dir(
          context.base_name,
          "governance-only-grove",
          context.profile.name
        )

        test_pid = self()

        {:ok, view, _html} =
          mount_dashboard_with_groves(conn, context, %{
            "task_manager_test_opts" => [model_query_fn: capturing_model_query_fn(test_pid)],
            "test_mode" => false,
            "model_pool" => ["mock:grove-r29"]
          })

        view |> element("button", "New Task") |> render_click()

        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "governance-only-grove"})

        assert_push_event(view, "grove_prefill", %{
          task_description: "Governance-only dashboard task"
        })

        view
        |> form("#new-task-form", %{
          "task_description" => "Governance-only dashboard task",
          "profile" => context.profile.name
        })
        |> render_submit()

        html = render(view)
        assert html =~ "Governance-only dashboard task"
        refute html =~ "Failed to create task"

        task =
          Quoracle.Tasks.TaskManager.list_tasks()
          |> Enum.find(&(&1.prompt == "Governance-only dashboard task"))

        assert task

        root_agent_id = "root-#{task.id}"
        [{root_pid, _meta}] = Registry.lookup(context.registry, {:agent, root_agent_id})
        register_agent_cleanup(root_pid, cleanup_tree: true, registry: context.registry)

        Quoracle.Agent.Core.handle_message(
          root_pid,
          {self(), "trigger governance prompt capture"}
        )

        assert_receive {:grove_r29_model_query_messages, _model_id, messages}, 10_000

        system_prompt =
          messages
          |> Enum.find(&(&1.role == "system"))
          |> case do
            nil -> nil
            message -> message.content
          end

        assert is_binary(system_prompt)
        assert system_prompt =~ "## Governance Rules"

        assert system_prompt =~
                 "SYSTEM RULE: Always obtain explicit approval before destructive actions."

        refute system_prompt =~ "Failed to load grove"
      end)
    end

    @tag :acceptance
    test "governance resolution errors do not block task creation", %{conn: conn} = context do
      capture_log(fn ->
        create_broken_governance_grove(
          context.base_name,
          "broken-governed-grove",
          context.profile.name
        )

        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        view |> element("button", "New Task") |> render_click()

        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "broken-governed-grove"})

        view
        |> form("#new-task-form", %{
          "task_description" => "broken governance task",
          "skills" => "venture-management",
          "profile" => context.profile.name
        })
        |> render_submit()

        html = render(view)
        assert html =~ "broken governance task"
        refute html =~ "Validation failed"
        refute html =~ "Failed to create task"

        task =
          Quoracle.Tasks.TaskManager.list_tasks()
          |> Enum.find(&(&1.prompt == "broken governance task"))

        assert task

        root_agent_id = "root-#{task.id}"
        [{root_pid, _meta}] = Registry.lookup(context.registry, {:agent, root_agent_id})
        register_agent_cleanup(root_pid, cleanup_tree: true, registry: context.registry)

        assert {:ok, root_state} = Core.get_state(root_pid)
        assert is_nil(root_state.governance_rules)
        assert is_nil(root_state.governance_config)
      end)
    end
  end

  describe "grove prefill acceptance (R11b)" do
    @tag :r11b
    @tag :acceptance
    test "R11b: full grove flow with push_event and JS hook",
         %{conn: conn} = context do
      # R11b: Full acceptance test covering the complete grove selection flow.
      #
      # Entry point: real route (/)
      # User actions: open modal, select grove, submit form
      # User outcome: push_event dispatched with all field values, task visible
      #
      # This test verifies the COMPLETE contract:
      # 1. Dashboard loads and shows grove selector
      # 2. Grove selection resolves bootstrap fields
      # 3. Server pushes grove_prefill event with ALL resolved field values
      # 4. Form has JS hook to receive the event (for actual field population)
      # 5. Task created successfully with grove-derived values
      #
      # Steps 3 and 4 verify the prefill path that the existing tests skip.

      capture_log(fn ->
        # 1. ENTRY POINT - Real route
        {:ok, view, html} = mount_dashboard_with_groves(conn, context)

        # Positive: Grove selector rendered on mount
        assert html =~ "Start from Grove"
        assert html =~ "test-grove"

        # 2. USER ACTION - Open modal
        view |> element("button", "New Task") |> render_click()

        # 3. USER ACTION - Select grove from dropdown
        grove_html =
          view
          |> element("select[name=grove]")
          |> render_change(%{"grove" => "test-grove"})

        # 4. POSITIVE ASSERTION - Server resolved bootstrap (no error)
        refute grove_html =~ "Failed to load grove"
        assert grove_html =~ "test-grove"

        # 5. CRITICAL: Verify push_event("grove_prefill") dispatched with
        # all resolved bootstrap field values. This is the server-side contract
        # that the JS hook depends on.
        assert_push_event(view, "grove_prefill", %{
          global_context: "Test project context",
          task_description: "Build the feature",
          role: "Test Engineer",
          cognitive_style: "systematic",
          skills: "testing"
        })

        # 6. CRITICAL: Verify the form has phx-hook="GrovePrefill" so the
        # JS handler can receive the push_event and populate field values.
        assert has_element?(view, "#new-task-form[phx-hook=GrovePrefill]"),
               "Expected phx-hook=\"GrovePrefill\" on #new-task-form. " <>
                 "Without it, push_event dispatches but fields remain empty."

        # 7. USER ACTION - Submit form with grove-resolved values
        # (In production, JS hook would auto-fill these from push_event)
        view
        |> form("#new-task-form", %{
          "task_description" => "Build the feature",
          "global_context" => "Test project context",
          "role" => "Test Engineer",
          "cognitive_style" => "systematic",
          "skills" => "testing",
          "profile" => context.profile.name
        })
        |> render_submit()

        final_html = render(view)

        # 8. POSITIVE ASSERTION - Task created and visible
        assert final_html =~ "Build the feature"

        # 9. NEGATIVE ASSERTIONS - No error states
        refute final_html =~ "Failed to create task"
        refute final_html =~ "Missing required"
        refute final_html =~ "not found"
      end)
    end

    @tag :r11b
    @tag :acceptance
    test "R11b: grove push_event contains all 13 form field keys",
         %{conn: conn} = context do
      # Verify that the push_event payload contains ALL expected field keys
      # from the BootstrapResolver form_fields type, even when values are nil.
      # This ensures the JS hook has a complete map to iterate over.

      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        # Open modal and select grove
        view |> element("button", "New Task") |> render_click()

        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "test-grove"})

        # Verify the push_event contains all 13 form field keys.
        # The test grove only populates some fields, so others should be nil.
        # The important thing is that ALL keys are present in the payload.
        assert_push_event(view, "grove_prefill", payload, 1000)

        expected_keys =
          MapSet.new([
            :global_context,
            :task_description,
            :success_criteria,
            :immediate_context,
            :global_constraints,
            :approach_guidance,
            :output_style,
            :cognitive_style,
            :delegation_strategy,
            :role,
            :skills,
            :profile,
            :budget_limit
          ])

        actual_keys = payload |> Map.keys() |> MapSet.new()

        missing_keys = MapSet.difference(expected_keys, actual_keys)

        assert MapSet.size(missing_keys) == 0,
               "grove_prefill push_event is missing form field keys: #{inspect(MapSet.to_list(missing_keys))}. " <>
                 "JS hook needs all 13 keys to populate/clear all form fields."
      end)
    end
  end

  # =============================================================================
  # GAP-1: Grove A→B Stale Field Carryover (HIGH)
  # =============================================================================
  #
  # Integration audit found that the GrovePrefill JS hook in assets/js/app.js:64
  # only writes fields when payload value is non-null:
  #   if (value != null) { field.value = value }
  #
  # When switching from grove A (which sets e.g. role="Engineer") to grove B
  # (which has role=nil), the old value persists in the DOM because the JS hook
  # skips the null value. The fix requires EITHER:
  #   a) The push_event payload always contains ALL 13 field keys with explicit
  #      nil for unset fields (so JS can clear them), OR
  #   b) The JS hook iterates all mapped fields and clears any not in the payload.
  #
  # These tests verify the server-side contract: when switching groves, the
  # push_event payload must send empty strings ("") for fields that the new
  # grove does NOT define, so the JS hook sets field.value = "" (clearing it).
  #
  # Current behavior: BootstrapResolver sends nil for unset fields, but the
  # JS hook at app.js:64 does `if (value != null)` which SKIPS nil values,
  # leaving stale values from the previous grove in the DOM.
  #
  # Fix: GroveHandlers must convert nil values to "" in the push_event payload
  # before sending to the client. This way the existing JS hook naturally
  # clears fields (setting field.value = "").

  # =============================================================================
  # R63-R65: Topology/grove_path forwarding from loaded_grove through submit
  # =============================================================================
  #
  # Spec: UI_Dashboard v15.0
  #
  # R63: handle_submit_prompt extracts grove_topology from loaded_grove and
  #      passes it to TaskManager opts so root agent receives it in state.
  # R64: handle_submit_prompt extracts grove_path from loaded_grove and
  #      passes it to TaskManager opts so root agent receives it in state.
  # R65: When no grove selected (loaded_grove nil), opts do not include
  #      grove_topology or grove_path.
  #
  # All tests use the task_manager_test_opts injection pattern to observe what
  # TaskManager.create_task opts were forwarded without running real LLM calls.

  describe "topology forwarding from loaded_grove (R63-R65)" do
    setup %{base_name: base_name, profile: profile} do
      # Create a grove with topology section so GroveHandlers populates
      # loaded_grove with a topology map.
      topology_grove_md = """
      ---
      name: topology-grove
      description: Grove with topology for R63-R65 tests
      version: "1.0"
      bootstrap:
        task_description_file: bootstrap/task.md
        profile: #{profile.name}
      topology:
        edges:
          - parent: venture-management
            child: analysis
            auto_inject:
              skills:
                - analysis
              profile: analyst-profile
      ---
      """

      create_grove(base_name, "topology-grove", topology_grove_md)
      create_bootstrap_file(base_name, "topology-grove", "task.md", "Topology task")

      :ok
    end

    @tag :r63
    @tag :integration
    @tag :acceptance
    test "R63: handle_submit_prompt extracts topology from loaded grove",
         %{conn: conn} = context do
      # R63 INTEGRATION: WHEN task submitted from grove with topology THEN
      # opts include grove_topology extracted from the loaded grove struct.
      #
      # Entry point: handle_submit_prompt (via form submit)
      # Observable user outcome: root agent state contains grove_topology
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        view |> element("button", "New Task") |> render_click()

        # Select grove — this causes GroveHandlers to populate loaded_grove assign
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "topology-grove"})

        assert_push_event(view, "grove_prefill", _fields, 2000)

        # Submit form with grove selected (loaded_grove is now set on socket)
        view
        |> form("#new-task-form", %{
          "task_description" => "Topology task",
          "profile" => context.profile.name
        })
        |> render_submit()

        html = render(view)
        assert html =~ "Topology task"
        refute html =~ "Failed to create task"

        task =
          Quoracle.Tasks.TaskManager.list_tasks()
          |> Enum.find(&(&1.prompt == "Topology task"))

        assert task, "Task should have been created"

        root_agent_id = "root-#{task.id}"
        [{root_pid, _meta}] = Registry.lookup(context.registry, {:agent, root_agent_id})
        register_agent_cleanup(root_pid, cleanup_tree: true, registry: context.registry)

        {:ok, root_state} = Core.get_state(root_pid)

        expected_topology = %{
          "edges" => [
            %{
              "parent" => "venture-management",
              "child" => "analysis",
              "auto_inject" => %{
                "skills" => ["analysis"],
                "profile" => "analyst-profile"
              }
            }
          ]
        }

        # CRITICAL ASSERTION: exact topology content forwarded from loaded_grove
        assert root_state.grove_topology == expected_topology,
               "Expected exact grove_topology from selected grove in root state, got: " <>
                 inspect(root_state.grove_topology)
      end)
    end

    @tag :r64
    @tag :integration
    test "R64: handle_submit_prompt forwards grove_path from loaded grove",
         %{conn: conn} = context do
      # R64 INTEGRATION: WHEN task submitted from grove THEN opts include grove_path
      # extracted from loaded grove struct (used for constraint file resolution).
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        view |> element("button", "New Task") |> render_click()

        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "topology-grove"})

        assert_push_event(view, "grove_prefill", _fields, 2000)

        view
        |> form("#new-task-form", %{
          "task_description" => "Topology task",
          "profile" => context.profile.name
        })
        |> render_submit()

        html = render(view)
        assert html =~ "Topology task"
        refute html =~ "Failed to create task"

        task =
          Quoracle.Tasks.TaskManager.list_tasks()
          |> Enum.find(&(&1.prompt == "Topology task"))

        assert task, "Task should have been created"

        root_agent_id = "root-#{task.id}"
        [{root_pid, _meta}] = Registry.lookup(context.registry, {:agent, root_agent_id})
        register_agent_cleanup(root_pid, cleanup_tree: true, registry: context.registry)

        {:ok, root_state} = Core.get_state(root_pid)

        # CRITICAL ASSERTION: grove_path forwarded from loaded_grove through submit
        assert is_binary(root_state.grove_path),
               "Expected grove_path (string) in root agent state. " <>
                 "EventHandlers.handle_submit_prompt must extract grove.path from loaded_grove."

        # The path should point into the test grove directory
        assert root_state.grove_path =~ "topology-grove"
      end)
    end

    @tag :r65
    @tag :unit
    test "R65: no grove selected — opts do not include grove_topology or grove_path",
         %{conn: conn} = context do
      # R65 UNIT: verify omission semantics at submit boundary by checking
      # root agent config keys persisted in DB state JSON.
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        view |> element("button", "New Task") |> render_click()

        # Do NOT select a grove — loaded_grove remains nil.
        view
        |> form("#new-task-form", %{
          "task_description" => "No grove task",
          "profile" => context.profile.name
        })
        |> render_submit()

        html = render(view)
        assert html =~ "No grove task"
        refute html =~ "Failed to create task"

        task =
          Quoracle.Tasks.TaskManager.list_tasks()
          |> Enum.find(&(&1.prompt == "No grove task"))

        assert task, "Task should have been created"

        root_agent_id = "root-#{task.id}"

        {:ok, root_agent} = Quoracle.Tasks.TaskManager.get_agent(root_agent_id)

        # REQUIRED R65 ASSERTION: keys are omitted, not present-with-nil.
        refute Map.has_key?(root_agent.config || %{}, "grove_topology"),
               "Expected root config to omit grove_topology key when no grove selected"

        refute Map.has_key?(root_agent.config || %{}, "grove_path"),
               "Expected root config to omit grove_path key when no grove selected"

        # Also assert runtime state remains nil for user-visible behavior.
        [{root_pid, _meta}] = Registry.lookup(context.registry, {:agent, root_agent_id})
        register_agent_cleanup(root_pid, cleanup_tree: true, registry: context.registry)

        {:ok, root_state} = Core.get_state(root_pid)
        assert is_nil(root_state.grove_topology)
        assert is_nil(root_state.grove_path)
      end)
    end
  end

  describe "schema/workspace forwarding (R66-R68)" do
    setup %{base_name: base_name, profile: profile} do
      schema_grove_md = """
      ---
      name: schema-grove
      description: Grove with schemas and workspace for R66-R68 tests
      version: "1.0"
      workspace: ~/grove_schema_workspace_#{System.unique_integer([:positive])}
      bootstrap:
        task_description_file: bootstrap/task.md
        profile: #{profile.name}
      schemas:
        - name: output-schema
          definition: schemas/output.json
          validate_on: file_write
          path_pattern: "data/**/*.json"
      ---
      """

      create_grove(base_name, "schema-grove", schema_grove_md)
      create_bootstrap_file(base_name, "schema-grove", "task.md", "Schema task")

      :ok
    end

    @tag :r66
    @tag :integration
    test "R66: handle_submit_prompt extracts schemas from loaded grove",
         %{conn: conn} = context do
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        view |> element("button", "New Task") |> render_click()

        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "schema-grove"})

        assert_push_event(view, "grove_prefill", _fields, 2000)

        view
        |> form("#new-task-form", %{
          "task_description" => "Schema task",
          "profile" => context.profile.name
        })
        |> render_submit()

        html = render(view)
        assert html =~ "Schema task"
        refute html =~ "Failed to create task"

        task =
          Quoracle.Tasks.TaskManager.list_tasks()
          |> Enum.find(&(&1.prompt == "Schema task"))

        assert task, "Task should have been created"

        root_agent_id = "root-#{task.id}"
        [{root_pid, _meta}] = Registry.lookup(context.registry, {:agent, root_agent_id})
        register_agent_cleanup(root_pid, cleanup_tree: true, registry: context.registry)

        {:ok, root_state} = Core.get_state(root_pid)

        assert is_list(root_state.grove_schemas)

        assert Enum.any?(root_state.grove_schemas, fn schema ->
                 schema["name"] == "output-schema" and
                   schema["definition"] == "schemas/output.json" and
                   schema["validate_on"] == "file_write" and
                   schema["path_pattern"] == "data/**/*.json"
               end)
      end)
    end

    @tag :r67
    @tag :integration
    test "R67: handle_submit_prompt extracts workspace from loaded grove",
         %{conn: conn} = context do
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        view |> element("button", "New Task") |> render_click()

        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "schema-grove"})

        assert_push_event(view, "grove_prefill", _fields, 2000)

        view
        |> form("#new-task-form", %{
          "task_description" => "Schema task",
          "profile" => context.profile.name
        })
        |> render_submit()

        html = render(view)
        assert html =~ "Schema task"
        refute html =~ "Failed to create task"

        task =
          Quoracle.Tasks.TaskManager.list_tasks()
          |> Enum.find(&(&1.prompt == "Schema task"))

        assert task, "Task should have been created"

        root_agent_id = "root-#{task.id}"
        [{root_pid, _meta}] = Registry.lookup(context.registry, {:agent, root_agent_id})
        register_agent_cleanup(root_pid, cleanup_tree: true, registry: context.registry)

        {:ok, root_state} = Core.get_state(root_pid)

        workspace = root_state.grove_workspace
        assert is_binary(workspace)
        refute String.starts_with?(workspace, "~")
        assert String.starts_with?(workspace, "/")
        assert workspace =~ "grove_schema_workspace_"
      end)
    end

    @tag :r68
    @tag :unit
    test "R68: no grove selected omits schema/workspace opts", %{conn: conn} = context do
      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        view |> element("button", "New Task") |> render_click()

        # Do not select grove - loaded_grove remains nil
        view
        |> form("#new-task-form", %{
          "task_description" => "No schema grove task",
          "profile" => context.profile.name
        })
        |> render_submit()

        html = render(view)
        assert html =~ "No schema grove task"
        refute html =~ "Failed to create task"

        task =
          Quoracle.Tasks.TaskManager.list_tasks()
          |> Enum.find(&(&1.prompt == "No schema grove task"))

        assert task, "Task should have been created"

        root_agent_id = "root-#{task.id}"

        {:ok, root_agent} = Quoracle.Tasks.TaskManager.get_agent(root_agent_id)

        refute Map.has_key?(root_agent.config || %{}, "grove_schemas"),
               "Expected root config to omit grove_schemas key when no grove selected"

        refute Map.has_key?(root_agent.config || %{}, "grove_workspace"),
               "Expected root config to omit grove_workspace key when no grove selected"

        [{root_pid, _meta}] = Registry.lookup(context.registry, {:agent, root_agent_id})
        register_agent_cleanup(root_pid, cleanup_tree: true, registry: context.registry)

        {:ok, root_state} = Core.get_state(root_pid)
        assert is_nil(root_state.grove_schemas)
        assert is_nil(root_state.grove_workspace)
      end)
    end
  end

  describe "confinement forwarding from loaded_grove (R69)" do
    setup %{base_name: base_name, profile: profile} do
      confinement_grove_md = """
      ---
      name: confinement-grove
      description: Grove with confinement for R69 tests
      version: "1.0"
      bootstrap:
        task_description_file: bootstrap/task.md
        profile: #{profile.name}
      confinement:
        agentic-coding:
          paths:
            - ~/workspace/allowed
          read_only_paths:
            - ~/workspace/reference
      ---
      """

      create_grove(base_name, "confinement-grove", confinement_grove_md)
      create_bootstrap_file(base_name, "confinement-grove", "task.md", "Confinement task")

      :ok
    end

    @tag :r69
    @tag :integration
    @tag :acceptance
    test "R69: submit with confinement grove forwards grove_confinement to root state",
         %{conn: conn} = context do
      prompt = "Confinement threading task #{System.unique_integer([:positive])}"

      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        view |> element("button", "New Task") |> render_click()

        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "confinement-grove"})

        assert_push_event(view, "grove_prefill", _fields, 2000)

        view
        |> form("#new-task-form", %{
          "task_description" => prompt,
          "profile" => context.profile.name
        })
        |> render_submit()

        html = render(view)
        assert html =~ prompt
        refute html =~ "Failed to create task"

        task =
          Quoracle.Tasks.TaskManager.list_tasks()
          |> Enum.find(&(&1.prompt == prompt))

        assert task, "Task should have been created"

        root_agent_id = "root-#{task.id}"
        [{root_pid, _meta}] = Registry.lookup(context.registry, {:agent, root_agent_id})
        register_agent_cleanup(root_pid, cleanup_tree: true, registry: context.registry)

        {:ok, root_state} = Core.get_state(root_pid)

        home = System.user_home!()

        expected_confinement = %{
          "agentic-coding" => %{
            "paths" => [Path.join(home, "workspace/allowed")],
            "read_only_paths" => [Path.join(home, "workspace/reference")]
          }
        }

        assert root_state.grove_confinement == expected_confinement
      end)
    end
  end

  describe "grove A→B stale field carryover (GAP-1)" do
    setup %{base_name: base_name, profile: profile} do
      # Create grove A: sets role, cognitive_style, approach_guidance
      grove_a_md = """
      ---
      name: grove-a
      description: Grove A with role and cognitive_style
      version: "1.0"
      bootstrap:
        role: "Senior Engineer"
        cognitive_style: systematic
        approach_guidance_file: bootstrap/approach.md
        task_description_file: bootstrap/task.md
        profile: #{profile.name}
      ---
      """

      create_grove(base_name, "grove-a", grove_a_md)
      create_bootstrap_file(base_name, "grove-a", "task.md", "Grove A task")
      create_bootstrap_file(base_name, "grove-a", "approach.md", "Use TDD approach")

      # Create grove B: sets delegation_strategy and output_style, but NOT
      # role, cognitive_style, or approach_guidance (these must become "")
      grove_b_md = """
      ---
      name: grove-b
      description: Grove B with different fields than A
      version: "1.0"
      bootstrap:
        delegation_strategy: parallel
        output_style: detailed
        task_description_file: bootstrap/task.md
        profile: #{profile.name}
      ---
      """

      create_grove(base_name, "grove-b", grove_b_md)
      create_bootstrap_file(base_name, "grove-b", "task.md", "Grove B task")

      :ok
    end

    @tag :gap1
    @tag :integration
    test "GAP-1a: A→B switching sends empty string for cleared fields",
         %{conn: conn} = context do
      # GAP-1a: WHEN user selects grove A then switches to grove B
      # THEN the push_event for grove B must send "" (empty string)
      # for fields that grove B doesn't define, so the JS hook
      # clears them via field.value = "".
      #
      # Currently fails because BootstrapResolver sends nil, and
      # GroveHandlers passes nil through without conversion to "".

      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        view |> element("button", "New Task") |> render_click()

        # Step 1: Select grove A (populates role, cognitive_style)
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "grove-a"})

        assert_push_event(view, "grove_prefill", %{
          role: "Senior Engineer",
          cognitive_style: "systematic",
          approach_guidance: "Use TDD approach",
          task_description: "Grove A task"
        })

        # Step 2: Switch to grove B
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "grove-b"})

        assert_push_event(view, "grove_prefill", grove_b_payload, 1000)

        # Fields grove B doesn't define must be "" (not nil)
        # so JS hook processes them and clears the DOM field
        assert grove_b_payload.role == "",
               "Expected role=\"\" in grove B payload to clear stale value, " <>
                 "got: #{inspect(grove_b_payload.role)}"

        assert grove_b_payload.cognitive_style == "",
               "Expected cognitive_style=\"\" in grove B payload, " <>
                 "got: #{inspect(grove_b_payload.cognitive_style)}"

        assert grove_b_payload.approach_guidance == "",
               "Expected approach_guidance=\"\" in grove B payload, " <>
                 "got: #{inspect(grove_b_payload.approach_guidance)}"

        # Fields grove B DOES set must have correct values
        assert grove_b_payload.delegation_strategy == "parallel"
        assert grove_b_payload.output_style == "detailed"
        assert grove_b_payload.task_description == "Grove B task"
      end)
    end

    @tag :gap1
    @tag :acceptance
    test "GAP-1b: A→B switching clears stale fields in form",
         %{conn: conn} = context do
      # GAP-1b [ACCEPTANCE]: Full user journey through grove switching.
      #
      # Entry point: live("/") (real route)
      # User actions: open modal, select grove A, switch to grove B, submit
      # Expectation: push_event contains "" for cleared fields,
      #   form has hook wiring, task created with grove B values

      capture_log(fn ->
        # 1. ENTRY POINT - Real route
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        # 2. Open modal and select grove A
        view |> element("button", "New Task") |> render_click()

        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "grove-a"})

        assert_push_event(view, "grove_prefill", %{role: "Senior Engineer"}, 1000)

        # 3. Switch to grove B
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "grove-b"})

        # Verify cleared fields are "" not nil
        assert_push_event(view, "grove_prefill", grove_b_payload, 1000)

        assert grove_b_payload.role == "",
               "role must be \"\" so JS clears it, got: #{inspect(grove_b_payload.role)}"

        # 4. Verify hook wiring
        assert has_element?(view, "#new-task-form[phx-hook=GrovePrefill]"),
               "Form must have phx-hook=GrovePrefill"

        # 5. Submit form with grove B values
        view
        |> form("#new-task-form", %{
          "task_description" => "Grove B task",
          "delegation_strategy" => "parallel",
          "output_style" => "detailed",
          "profile" => context.profile.name
        })
        |> render_submit()

        final_html = render(view)

        # 6. POSITIVE - Task created
        assert final_html =~ "Grove B task"

        # 7. NEGATIVE - No errors
        refute final_html =~ "Failed to create task"
        refute final_html =~ "Missing required"
      end)
    end

    @tag :gap2
    @tag :acceptance
    test "GAP-2: A→B payload sends \"\" for all unset fields",
         %{conn: conn} = context do
      # GAP-2 [ACCEPTANCE]: Verify ALL 13 keys present and unset
      # fields are "" (not nil) so JS hook processes them.

      capture_log(fn ->
        {:ok, view, _html} = mount_dashboard_with_groves(conn, context)

        view |> element("button", "New Task") |> render_click()

        # Select grove A then switch to grove B
        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "grove-a"})

        assert_push_event(view, "grove_prefill", _grove_a_payload, 1000)

        view
        |> element("select[name=grove]")
        |> render_change(%{"grove" => "grove-b"})

        assert_push_event(view, "grove_prefill", grove_b_payload, 1000)

        # ALL 13 keys must be present
        expected_keys =
          MapSet.new([
            :global_context,
            :task_description,
            :success_criteria,
            :immediate_context,
            :global_constraints,
            :approach_guidance,
            :output_style,
            :cognitive_style,
            :delegation_strategy,
            :role,
            :skills,
            :profile,
            :budget_limit
          ])

        actual_keys = grove_b_payload |> Map.keys() |> MapSet.new()
        missing_keys = MapSet.difference(expected_keys, actual_keys)

        assert MapSet.size(missing_keys) == 0,
               "grove B push_event missing keys: #{inspect(MapSet.to_list(missing_keys))}"

        # Unset fields must be "" (not nil) for JS hook compatibility
        assert grove_b_payload.role == "",
               "role must be \"\" (not nil), got: #{inspect(grove_b_payload.role)}"

        assert grove_b_payload.cognitive_style == "",
               "cognitive_style must be \"\", got: #{inspect(grove_b_payload.cognitive_style)}"

        assert grove_b_payload.approach_guidance == "",
               "approach_guidance must be \"\", got: #{inspect(grove_b_payload.approach_guidance)}"

        # Set fields must have correct values
        assert grove_b_payload.delegation_strategy == "parallel"
        assert grove_b_payload.output_style == "detailed"
        assert grove_b_payload.task_description == "Grove B task"
      end)
    end
  end
end
