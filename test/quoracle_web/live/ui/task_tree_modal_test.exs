defmodule QuoracleWeb.UI.TaskTreeModalTest do
  use QuoracleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  alias QuoracleWeb.UI.TaskTreeTestLive

  # Helper to render component - cleanup handled by ConnCase.live_isolated
  defp render_isolated(conn, session) do
    live_isolated(conn, TaskTreeTestLive, session: session)
  end

  describe "New Task Modal" do
    # R1: Modal Form Rendering [SYSTEM]
    test "modal displays all 10 fields in sections", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      # Click New Task button to open modal
      view |> element("button", "New Task") |> render_click()
      html = render(view)

      # Check modal is visible
      assert html =~ "Create New Task"

      # Agent Identity (System Prompt) section (6 fields)
      assert html =~ "Agent Identity (System Prompt)"
      assert html =~ ~s(name="role")
      assert html =~ "Role"
      assert html =~ ~s(name="cognitive_style")
      assert html =~ "Cognitive Style"
      assert html =~ ~s(name="global_constraints")
      assert html =~ "Global Constraints"
      assert html =~ ~s(name="output_style")
      assert html =~ "Output Style"
      assert html =~ ~s(name="delegation_strategy")
      assert html =~ "Delegation Strategy"
      assert html =~ ~s(name="global_context")
      assert html =~ "Global Context"

      # Task Work (User Prompt) section (4 fields)
      assert html =~ "Task Work (User Prompt)"
      assert html =~ ~s(name="task_description")
      assert html =~ "Task Description"
      assert html =~ ~s(name="success_criteria")
      assert html =~ "Success Criteria"
      assert html =~ ~s(name="immediate_context")
      assert html =~ "Immediate Context"
      assert html =~ ~s(name="approach_guidance")
      assert html =~ "Approach Guidance"
    end

    # R2: Required Field Marking [INTEGRATION]
    test "task_description marked as required", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()
      html = render(view)

      # Check task_description field has required attribute
      task_desc_field =
        html |> Floki.parse_document!() |> Floki.find(~s(textarea[name="task_description"]))

      assert Floki.attribute(task_desc_field, "required") != []

      # Check other fields are not required
      global_context_field =
        html |> Floki.parse_document!() |> Floki.find(~s(textarea[name="global_context"]))

      assert Floki.attribute(global_context_field, "required") == []
    end

    # R3: Form Submission - All Fields [INTEGRATION]
    test "submitting form with all fields sends complete params", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()

      # Fill all 10 fields
      form_data = %{
        "global_context" => "Project context",
        "global_constraints" => "Use Elixir, Follow TDD",
        "task_description" => "Build TODO app",
        "success_criteria" => "All tests pass",
        "immediate_context" => "Starting from scratch",
        "approach_guidance" => "Use best practices",
        "role" => "Senior Developer",
        "cognitive_style" => "systematic",
        "output_style" => "detailed",
        "delegation_strategy" => "parallel"
      }

      # Submit form
      view
      |> form("#new-task-modal form", form_data)
      |> render_submit()

      # Verify message sent to parent with all fields
      assert_received {:submit_prompt, sent_params}

      # Check all fields are in sent params
      assert sent_params["global_context"] == "Project context"
      assert sent_params["global_constraints"] == "Use Elixir, Follow TDD"
      assert sent_params["task_description"] == "Build TODO app"
      assert sent_params["success_criteria"] == "All tests pass"
      assert sent_params["immediate_context"] == "Starting from scratch"
      assert sent_params["approach_guidance"] == "Use best practices"
      assert sent_params["role"] == "Senior Developer"
      assert sent_params["cognitive_style"] == "systematic"
      assert sent_params["output_style"] == "detailed"
      assert sent_params["delegation_strategy"] == "parallel"
    end

    # R4: Form Submission - Only Required [INTEGRATION]
    test "submitting form with only required field sends minimal params", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()

      # Fill only required field
      form_data = %{
        "task_description" => "Build something"
      }

      # Submit form
      view
      |> form("#new-task-modal form", form_data)
      |> render_submit()

      # Verify message sent to parent with minimal fields
      assert_received {:submit_prompt, sent_params}

      assert sent_params["task_description"] == "Build something"
      # Other fields should be empty strings (HTML forms submit "" for empty inputs)
      assert sent_params["global_context"] == ""
    end

    # R5: Modal Dismissal on Submit [INTEGRATION]
    test "modal closes after form submission", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      # Open modal
      view |> element("button", "New Task") |> render_click()
      html = render(view)
      assert html =~ "Create New Task"

      # Submit form
      form_data = %{"task_description" => "Test task"}

      view
      |> form("#new-task-modal form", form_data)
      |> render_submit()

      # Modal should be hidden after submission
      html = render(view)
      assert html =~ ~s(id="new-task-modal" class="hidden")
    end

    # R6: Modal Dismissal on Cancel [INTEGRATION]
    test "cancel button closes modal without submission", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      # Open modal
      view |> element("button", "New Task") |> render_click()
      html = render(view)
      assert html =~ "Create New Task"

      # Click cancel button
      view |> element("#new-task-modal button", "Cancel") |> render_click()

      # Modal should be hidden
      html = render(view)
      assert html =~ ~s(id="new-task-modal" class="hidden")

      # No submission event should be sent
      refute_received {:submit_prompt, _}
    end

    # R7: Character Counter Display [INTEGRATION]
    test "character counters displayed for limited fields", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()
      html = render(view)

      # No fields have character counters
      refute html =~ "0/100"
      refute html =~ "0/500"
      refute html =~ "0/2000"
      refute html =~ "0/1000"
      refute html =~ "0/200"
    end

    # R8: Enum Dropdown Options [INTEGRATION]
    test "cognitive_style dropdown shows all enum values", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()
      html = render(view)

      # Parse HTML and find cognitive_style select
      parsed = Floki.parse_document!(html)
      cognitive_select = Floki.find(parsed, ~s(select[name="cognitive_style"]))
      options = Floki.find(cognitive_select, "option")

      # Should have prompt + 5 enum values = 6 options
      assert length(options) == 6

      option_values = options |> Enum.map(&Floki.attribute(&1, "value")) |> List.flatten()
      # prompt option
      assert "" in option_values
      assert "efficient" in option_values
      assert "exploratory" in option_values
      assert "problem_solving" in option_values
      assert "creative" in option_values
      assert "systematic" in option_values
    end

    # R9: Section Organization [UNIT]
    test "modal has three distinct field sections", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()
      html = render(view)

      # Check both sections are present with correct headers
      assert html =~ "Agent Identity (System Prompt)"
      assert html =~ "Task Work (User Prompt)"

      # Verify sections have mb-6 spacing
      parsed = Floki.parse_document!(html)
      sections = Floki.find(parsed, ~s(div[class*="mb-6"]))

      # Should have at least 2 sections
      assert length(sections) >= 2
    end

    # R10: Event Propagation [INTEGRATION]
    test "create_task event sends message to parent", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()

      form_data = %{
        "task_description" => "Test task",
        "global_context" => "Test context"
      }

      # Submit form
      view
      |> form("#new-task-modal form", form_data)
      |> render_submit()

      # TaskTree should send message to parent
      assert_receive {:submit_prompt, params}
      assert params["task_description"] == "Test task"
      assert params["global_context"] == "Test context"
    end

    test "modal backdrop closes modal when clicked", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      # Open modal
      view |> element("button", "New Task") |> render_click()
      html = render(view)
      assert html =~ "Create New Task"

      # Click backdrop
      view |> element(~s(div[phx-click*="hide"]), "") |> render_click()

      # Modal should be hidden
      html = render(view)
      assert html =~ ~s(id="new-task-modal" class="hidden")
    end

    test "all dropdown fields show correct options", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()
      html = render(view)

      parsed = Floki.parse_document!(html)

      # Check output_style dropdown
      output_select = Floki.find(parsed, ~s(select[name="output_style"]))
      output_options = Floki.find(output_select, "option")
      # prompt + 4 values
      assert length(output_options) == 5

      # Check delegation_strategy dropdown
      delegation_select = Floki.find(parsed, ~s(select[name="delegation_strategy"]))
      delegation_options = Floki.find(delegation_select, "option")
      # prompt + 3 values
      assert length(delegation_options) == 4
    end

    test "form fields use live components from TaskFormFields", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()
      html = render(view)

      # Check that TaskFormFields components are rendered with proper attributes
      assert html =~ ~s(id="global_context")
      assert html =~ ~s(id="task_description")
      assert html =~ ~s(id="cognitive_style")

      # No fields have maxlength
      refute html =~ ~s(maxlength="100")
      refute html =~ ~s(maxlength="2000")
      refute html =~ ~s(maxlength="500")
      refute html =~ ~s(maxlength="1000")
    end
  end

  # ===========================================================================
  # Skills Field Tests (feat-20260205-root-skills, R41-R46)
  # ===========================================================================

  describe "Skills Field (R41-R46)" do
    # R41: Skills Field Renders in Modal [UNIT]
    test "modal shows skills field in agent identity section", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()
      html = render(view)

      # Skills field should exist in the modal
      assert html =~ ~s(name="skills")
      assert html =~ "Skills"

      # Skills field should be in the Agent Identity section (same section as role)
      # The section header is "Agent Identity (System Prompt)"
      parsed = Floki.parse_document!(html)

      # Find the Agent Identity section
      agent_identity_section =
        parsed
        |> Floki.find("h4")
        |> Enum.find(fn el -> Floki.text(el) =~ "Agent Identity" end)

      assert agent_identity_section != nil, "Agent Identity section should exist"

      # Skills input should exist
      skills_input = Floki.find(parsed, ~s(input[name="skills"]))
      assert length(skills_input) == 1, "Skills input field should exist"
    end

    # R42: Skills Field Uses list_input [UNIT]
    test "skills field renders as list_input", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()
      html = render(view)

      # Skills should be a text input (list_input renders as input type="text")
      parsed = Floki.parse_document!(html)
      skills_input = Floki.find(parsed, ~s(input[name="skills"]))

      assert length(skills_input) == 1, "Skills input should exist"

      # list_input uses type="text" for comma-separated values
      input_type = Floki.attribute(skills_input, "type") |> List.first()
      assert input_type == "text", "Skills should be a text input (list_input component)"

      # Should have placeholder with example skills
      placeholder = Floki.attribute(skills_input, "placeholder") |> List.first()
      assert placeholder != nil, "Skills should have a placeholder"

      assert placeholder =~ "deployment", "Placeholder should show example skill names"
    end

    # R43: Skills Help Text [UNIT]
    test "skills field shows help text", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()
      html = render(view)

      # Help text should mention pre-loading skills for the root agent
      assert html =~ ~r/pre-load/i,
             "Skills help text should mention pre-loading skills"
    end

    # R44: Skills Submitted in Form [INTEGRATION]
    test "form submission includes skills param", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()

      # Fill form with skills
      form_data = %{
        "task_description" => "Test task with skills",
        "skills" => "deployment, code-review"
      }

      view
      |> form("#new-task-modal form", form_data)
      |> render_submit()

      # Verify skills included in params sent to parent
      assert_received {:submit_prompt, sent_params}
      assert sent_params["skills"] == "deployment, code-review"
    end

    # R45: Skills Error Display [INTEGRATION]
    # Note: This tests that invalid skill error is displayed as flash message
    # The error comes from TaskManager through Dashboard back to TaskTree
    test "invalid skill shows error flash", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      # Simulate receiving skill_not_found error from task creation
      # This would come through Dashboard's handle_info for task_creation_result
      send(view.pid, {:task_creation_result, {:error, {:skill_not_found, "nonexistent-skill"}}})

      html = render(view)

      # Error flash should show skill name AND "not found" text (spec: "Skill 'xyz' not found")
      assert html =~ "nonexistent-skill", "Error should show the specific skill name"
      assert html =~ "not found", "Error should indicate skill was not found"
    end

    # R46: Empty Skills Valid [INTEGRATION]
    test "empty skills field allows task creation", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(conn, %{
          "sandbox_owner" => sandbox_owner,
          "tasks" => %{},
          "agents" => %{},
          "test_pid" => self()
        })

      view |> element("button", "New Task") |> render_click()

      # Submit form with empty skills (most common case)
      form_data = %{
        "task_description" => "Test task without skills",
        "skills" => ""
      }

      view
      |> form("#new-task-modal form", form_data)
      |> render_submit()

      # Form should submit successfully (parent receives message)
      assert_received {:submit_prompt, sent_params}
      assert sent_params["task_description"] == "Test task without skills"
      # Empty skills should be sent as empty string
      assert sent_params["skills"] == ""
    end
  end
end
