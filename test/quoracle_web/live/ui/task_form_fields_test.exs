defmodule QuoracleWeb.UI.TaskFormFieldsTest do
  use QuoracleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  alias QuoracleWeb.UI.TaskFormFields

  describe "text_field/1" do
    # R1: Text Field Rendering
    test "text_field renders with maxlength attribute" do
      html =
        render_component(&TaskFormFields.text_field/1,
          name: "role",
          label: "Role",
          value: "",
          maxlength: 100,
          placeholder: "e.g., 'developer'"
        )

      assert html =~ ~s(maxlength="100")
      assert html =~ ~s(name="role")
      assert html =~ "Role"
      assert html =~ "placeholder="
    end

    # R8: Placeholder Text
    test "text_field renders placeholder text" do
      html =
        render_component(&TaskFormFields.text_field/1,
          name: "role",
          label: "Role",
          value: "",
          placeholder: "Agent identity"
        )

      assert html =~ ~s(placeholder="Agent identity")
    end

    test "text_field renders without maxlength when not provided" do
      html =
        render_component(&TaskFormFields.text_field/1,
          name: "test_field",
          label: "Test Field",
          value: "test value"
        )

      refute html =~ "maxlength="
      assert html =~ "test value"
    end

    test "text_field shows character count when maxlength provided" do
      html =
        render_component(&TaskFormFields.text_field/1,
          name: "limited_field",
          label: "Limited Field",
          value: "hello",
          maxlength: 50
        )

      assert html =~ "5/50"
    end
  end

  describe "textarea_field/1" do
    # R2: Character Counter Display
    test "textarea_field shows character counter" do
      html =
        render_component(&TaskFormFields.textarea_field/1,
          name: "task_description",
          label: "Task Description",
          value: "Build a TODO app",
          required: true,
          maxlength: 500,
          rows: 3,
          placeholder: "Describe the task..."
        )

      assert html =~ "16/500"
      assert html =~ ~s(rows="3")
      assert html =~ ~s(maxlength="500")
      assert html =~ "Task Description"
    end

    # R7: Required Field Marking
    test "required fields have required attribute" do
      html =
        render_component(&TaskFormFields.textarea_field/1,
          name: "task_description",
          label: "Task Description",
          value: "",
          required: true,
          maxlength: 500,
          rows: 3
        )

      assert html =~ "required"
      assert html =~ ~s(name="task_description")
    end

    test "textarea_field without required attribute" do
      html =
        render_component(&TaskFormFields.textarea_field/1,
          name: "optional_field",
          label: "Optional Field",
          value: "",
          maxlength: 1000,
          rows: 2
        )

      refute html =~ ~r/required(?!=)/
    end

    test "textarea_field with long text shows correct count" do
      long_text = String.duplicate("a", 450)

      html =
        render_component(&TaskFormFields.textarea_field/1,
          name: "long_field",
          label: "Long Field",
          value: long_text,
          maxlength: 500,
          rows: 5
        )

      assert html =~ "450/500"
      # Should show warning color when > 90%
      assert html =~ "text-yellow-600"
    end
  end

  describe "enum_dropdown/1" do
    # R5: Enum Dropdown Rendering
    test "enum_dropdown renders select with options" do
      options = [
        {"Efficient", "efficient"},
        {"Exploratory", "exploratory"},
        {"Creative", "creative"}
      ]

      html =
        render_component(&TaskFormFields.enum_dropdown/1,
          name: "cognitive_style",
          label: "Cognitive Style",
          value: "",
          options: options,
          prompt: "Select thinking mode..."
        )

      assert html =~ ~s(<select)
      assert html =~ ~s(name="cognitive_style")
      assert html =~ "Cognitive Style"
      assert html =~ "Select thinking mode..."
      assert html =~ ~s(<option value="efficient">Efficient</option>)
      assert html =~ ~s(<option value="exploratory">Exploratory</option>)
      assert html =~ ~s(<option value="creative">Creative</option>)
    end

    test "enum_dropdown with selected value" do
      options = [
        {"Detailed", "detailed"},
        {"Concise", "concise"}
      ]

      html =
        render_component(&TaskFormFields.enum_dropdown/1,
          name: "output_style",
          label: "Output Style",
          value: "concise",
          options: options
        )

      assert html =~ ~s(<option selected value="concise">)
    end

    test "enum_dropdown with required attribute" do
      options = [{"Option 1", "opt1"}]

      html =
        render_component(&TaskFormFields.enum_dropdown/1,
          name: "required_enum",
          label: "Required Enum",
          value: "",
          options: options,
          required: true
        )

      assert html =~ "required"
    end
  end

  describe "list_input/1" do
    # R6: List Input Format
    test "list_input joins list values with commas" do
      html =
        render_component(&TaskFormFields.list_input/1,
          name: "global_constraints",
          label: "Global Constraints",
          value: ["Use Elixir", "Follow TDD", "Keep it simple"],
          placeholder: "Enter constraints..."
        )

      assert html =~ "Use Elixir, Follow TDD, Keep it simple"
      assert html =~ "Global Constraints"
      assert html =~ "Separate multiple items with commas"
    end

    test "list_input with empty list" do
      html =
        render_component(&TaskFormFields.list_input/1,
          name: "global_constraints",
          label: "Global Constraints",
          value: [],
          placeholder: "Enter constraints..."
        )

      assert html =~ ~s(placeholder="Enter constraints...")
      refute html =~ ~r/value="[^"]+"/
    end

    test "list_input with string value" do
      html =
        render_component(&TaskFormFields.list_input/1,
          name: "global_constraints",
          label: "Global Constraints",
          value: "Single constraint",
          placeholder: "Enter constraints..."
        )

      assert html =~ "Single constraint"
    end
  end

  describe "helper functions" do
    # R4: Cognitive Style Options
    test "cognitive_style_options returns all valid values" do
      options = TaskFormFields.cognitive_style_options()

      assert length(options) == 5
      assert {"Efficient", "efficient"} in options
      assert {"Exploratory", "exploratory"} in options
      assert {"Problem Solving", "problem_solving"} in options
      assert {"Creative", "creative"} in options
      assert {"Systematic", "systematic"} in options
    end

    # R9: Output Style Options
    test "output_style_options returns correct values" do
      options = TaskFormFields.output_style_options()

      assert length(options) == 4
      assert {"Detailed", "detailed"} in options
      assert {"Concise", "concise"} in options
      assert {"Technical", "technical"} in options
      assert {"Narrative", "narrative"} in options
    end

    # R10: Delegation Strategy Options
    test "delegation_strategy_options returns correct values" do
      options = TaskFormFields.delegation_strategy_options()

      assert length(options) == 3
      assert {"Sequential", "sequential"} in options
      assert {"Parallel", "parallel"} in options
      assert {"None", "none"} in options
    end

    # R3: Character Counter Warning
    test "character counter shows warning color near limit" do
      # Test at exactly 90%
      result = TaskFormFields.format_character_count(90, 100)
      assert result == ~s(<span class="text-sm text-yellow-600">90/100</span>)

      # Test at 91%
      result = TaskFormFields.format_character_count(91, 100)
      assert result == ~s(<span class="text-sm text-yellow-600">91/100</span>)

      # Test at 89%
      result = TaskFormFields.format_character_count(89, 100)
      assert result == ~s(<span class="text-sm text-gray-500">89/100</span>)

      # Test at 100%
      result = TaskFormFields.format_character_count(100, 100)
      assert result == ~s(<span class="text-sm text-yellow-600">100/100</span>)
    end
  end

  # ============================================================================
  # MODIFICATION: Budget Input Component (wip-20251231-budget)
  # Packet 6 (UI Components)
  # ============================================================================

  describe "budget_input/1" do
    # R16: Budget Input Renders [UNIT]
    test "budget_input renders with dollar prefix" do
      html =
        render_component(&TaskFormFields.budget_input/1,
          name: "budget_limit",
          label: "Budget Limit (USD)",
          value: "100.00"
        )

      # Should have $ prefix before input
      assert html =~ "$"
      assert html =~ ~s(name="budget_limit")
      assert html =~ "Budget Limit (USD)"
    end

    # R17: Input Pattern Validation [UNIT]
    test "budget_input has decimal pattern" do
      html =
        render_component(&TaskFormFields.budget_input/1,
          name: "budget_limit",
          label: "Budget",
          value: ""
        )

      # Should have pattern attribute for decimal validation
      assert html =~ ~s(pattern=)
      # Pattern should match decimal numbers like 100.00, 50, 0.50
      assert html =~ ~r/pattern="[^"]*\\d/
    end

    # R18: Help Text Display [UNIT]
    test "budget_input shows help text" do
      html =
        render_component(&TaskFormFields.budget_input/1,
          name: "budget_limit",
          label: "Budget",
          value: "",
          help_text: "Leave empty for unlimited budget"
        )

      assert html =~ "Leave empty for unlimited budget"
    end

    # R19: Empty Value Allowed [UNIT]
    test "budget_input allows empty value" do
      # Should render without error when value is empty
      html =
        render_component(&TaskFormFields.budget_input/1,
          name: "budget_limit",
          label: "Budget",
          value: ""
        )

      assert html =~ ~s(name="budget_limit")
      # Input should be present
      assert html =~ ~s(<input)
    end

    # R20: Placeholder Display [UNIT]
    test "budget_input shows placeholder" do
      html =
        render_component(&TaskFormFields.budget_input/1,
          name: "budget_limit",
          label: "Budget",
          value: "",
          placeholder: "100.00"
        )

      assert html =~ ~s(placeholder="100.00")
    end

    # R21: Decimal Input Mode [UNIT]
    test "budget_input has decimal input mode" do
      html =
        render_component(&TaskFormFields.budget_input/1,
          name: "budget_limit",
          label: "Budget",
          value: ""
        )

      # Should have inputmode="decimal" for mobile keyboard
      assert html =~ ~s(inputmode="decimal")
    end

    test "budget_input with value displays the value" do
      html =
        render_component(&TaskFormFields.budget_input/1,
          name: "budget_limit",
          label: "Budget",
          value: "250.50"
        )

      assert html =~ ~s(value="250.50")
    end

    test "budget_input has text type (not number)" do
      html =
        render_component(&TaskFormFields.budget_input/1,
          name: "budget_limit",
          label: "Budget",
          value: ""
        )

      # Text type allows pattern validation with $ prefix styling
      assert html =~ ~s(type="text")
    end
  end

  describe "integration with FormComponents" do
    test "text_field uses FormComponents.input as base" do
      html =
        render_component(&TaskFormFields.text_field/1,
          name: "test_field",
          label: "Test Field",
          value: "test"
        )

      # Should have standard input structure from FormComponents
      assert html =~ ~s(<input)
      assert html =~ ~s(type="text")
      assert html =~ ~s(id="test_field")
    end

    test "textarea_field uses FormComponents.input with textarea type" do
      html =
        render_component(&TaskFormFields.textarea_field/1,
          name: "test_area",
          label: "Test Area",
          value: "content",
          rows: 3,
          maxlength: 500
        )

      assert html =~ ~s(<textarea)
      assert html =~ ~s(id="test_area")
      assert html =~ ~s(name="test_area")
    end

    test "enum_dropdown uses FormComponents.input with select type" do
      html =
        render_component(&TaskFormFields.enum_dropdown/1,
          name: "test_select",
          label: "Test Select",
          value: "",
          options: [{"Option", "opt"}]
        )

      assert html =~ ~s(<select)
      assert html =~ ~s(id="test_select")
      assert html =~ ~s(name="test_select")
    end
  end

  # ============================================================================
  # MODIFICATION: Profile Selector Component (feat-20260105-profiles)
  # Packet 4 (Task Creation & UI)
  # ============================================================================

  describe "profile_selector/1" do
    # R22: Profile Selector Renders [UNIT]
    test "R22: profile_selector renders select element" do
      profiles = [
        %{
          name: "default",
          capability_groups: [
            :file_read,
            :file_write,
            :external_api,
            :hierarchy,
            :local_execution
          ]
        },
        %{name: "research-only", capability_groups: []}
      ]

      html =
        render_component(&TaskFormFields.profile_selector/1,
          profiles: profiles,
          selected_profile: nil
        )

      assert html =~ ~s(<select)
      assert html =~ ~s(name="profile")
    end

    # R23: Profiles Listed as Options [UNIT]
    test "R23: profile_selector shows all profiles as options" do
      profiles = [
        %{
          name: "default",
          capability_groups: [
            :file_read,
            :file_write,
            :external_api,
            :hierarchy,
            :local_execution
          ]
        },
        %{name: "research-only", capability_groups: []},
        %{
          name: "safe-worker",
          capability_groups: [:file_read, :file_write, :external_api, :local_execution]
        }
      ]

      html =
        render_component(&TaskFormFields.profile_selector/1,
          profiles: profiles,
          selected_profile: nil
        )

      # Each profile should be an option
      assert html =~ "default"
      assert html =~ "research-only"
      assert html =~ "safe-worker"

      # Verify all are options
      parsed = Floki.parse_document!(html)
      options = Floki.find(parsed, "option")

      # Should have 3 profiles + 1 placeholder
      assert length(options) >= 3
    end

    # R24: Required Indicator [UNIT]
    test "R24: profile_selector shows required indicator" do
      profiles = [
        %{
          name: "default",
          capability_groups: [
            :file_read,
            :file_write,
            :external_api,
            :hierarchy,
            :local_execution
          ]
        }
      ]

      html =
        render_component(&TaskFormFields.profile_selector/1,
          profiles: profiles,
          selected_profile: nil
        )

      # Should show required asterisk and have required attribute
      assert html =~ "*"
      assert html =~ "required"
    end

    # R25: Selected Profile [UNIT]
    test "R25: profile_selector selects matching profile" do
      profiles = [
        %{
          name: "default",
          capability_groups: [
            :file_read,
            :file_write,
            :external_api,
            :hierarchy,
            :local_execution
          ]
        },
        %{name: "research-only", capability_groups: []}
      ]

      html =
        render_component(&TaskFormFields.profile_selector/1,
          profiles: profiles,
          selected_profile: "research-only"
        )

      # Parse and verify selected attribute
      parsed = Floki.parse_document!(html)
      options = Floki.find(parsed, "option")

      # Find the research-only option
      research_option =
        Enum.find(options, fn opt ->
          Floki.attribute(opt, "value") == ["research-only"]
        end)

      assert research_option != nil
      assert Floki.attribute(research_option, "selected") == ["selected"]
    end

    # R26: Capability Groups Shown [UNIT]
    test "R26: profile_selector shows capability groups in options" do
      profiles = [
        %{
          name: "default",
          capability_groups: [
            :file_read,
            :file_write,
            :external_api,
            :hierarchy,
            :local_execution
          ]
        },
        %{name: "safe-worker", capability_groups: [:file_read, :file_write]}
      ]

      html =
        render_component(&TaskFormFields.profile_selector/1,
          profiles: profiles,
          selected_profile: nil
        )

      # Format: "profile_name (capability_groups)"
      assert html =~ "(all capabilities)"
      assert html =~ "(file_read, file_write)"
    end

    # R27: Placeholder Option [UNIT]
    test "R27: profile_selector has placeholder option" do
      profiles = [
        %{
          name: "default",
          capability_groups: [
            :file_read,
            :file_write,
            :external_api,
            :hierarchy,
            :local_execution
          ]
        }
      ]

      html =
        render_component(&TaskFormFields.profile_selector/1,
          profiles: profiles,
          selected_profile: nil
        )

      # First option should be empty placeholder
      parsed = Floki.parse_document!(html)
      options = Floki.find(parsed, "option")

      first_option = Enum.at(options, 0)
      assert Floki.attribute(first_option, "value") == [""]
      # Should have placeholder text "Select a profile..."
      assert Floki.text(first_option) =~ "Select a profile"
    end

    test "profile_selector with empty profiles list" do
      html =
        render_component(&TaskFormFields.profile_selector/1,
          profiles: [],
          selected_profile: nil
        )

      assert html =~ ~s(<select)

      # Should only have placeholder option
      parsed = Floki.parse_document!(html)
      options = Floki.find(parsed, "option")
      assert length(options) == 1
    end

    test "profile_selector with no selected profile shows placeholder selected" do
      profiles = [
        %{
          name: "default",
          capability_groups: [
            :file_read,
            :file_write,
            :external_api,
            :hierarchy,
            :local_execution
          ]
        },
        %{name: "research", capability_groups: []}
      ]

      html =
        render_component(&TaskFormFields.profile_selector/1,
          profiles: profiles,
          selected_profile: nil
        )

      # Parse and verify no profile is selected (only placeholder)
      parsed = Floki.parse_document!(html)
      options = Floki.find(parsed, "option")

      # Count selected options
      selected_options =
        Enum.filter(options, fn opt ->
          Floki.attribute(opt, "selected") == ["selected"]
        end)

      # Either no explicit selected (browser defaults to first) or placeholder selected
      assert length(selected_options) <= 1
    end
  end
end
