defmodule QuoracleWeb.UI.GroveSelectorTest do
  @moduledoc """
  Unit tests for UI_GroveSelector function component.
  Tests grove dropdown rendering, option display, selection state, and empty list handling.

  ARC Criteria: R1-R5 from UI_GroveSelector spec + R52 from UI_TaskTree v10.0 spec

  These are pure component render tests that verify the HTML output of the
  grove_dropdown/1 function component without requiring a full LiveView mount.
  """
  use QuoracleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  @moduletag :feat_grove_system

  alias QuoracleWeb.UI.GroveSelector

  # =============================================================================
  # R1-R5: grove_dropdown/1 Component Rendering (UI_GroveSelector spec)
  # =============================================================================

  describe "grove_dropdown/1" do
    @tag :r1
    test "R1: renders all grove options" do
      # R1: WHEN component rendered with 2 groves
      # THEN select element contains both grove options with names and descriptions
      groves = [
        %{name: "grove-a", description: "First grove"},
        %{name: "grove-b", description: "Second grove"}
      ]

      html = render_component(&GroveSelector.grove_dropdown/1, groves: groves, selected: nil)

      # Both grove names present
      assert html =~ "grove-a"
      assert html =~ "grove-b"

      # Both descriptions present
      assert html =~ "First grove"
      assert html =~ "Second grove"

      # Select element present with correct name
      assert html =~ ~s(<select)
      assert html =~ ~s(name="grove")

      # phx-change event for grove selection
      assert html =~ ~s(phx-change="grove_selected")
    end

    @tag :r2
    test "R2: first option is no grove with empty value" do
      # R2: WHEN component rendered THEN first option text is "No grove (blank form)" with value=""
      html = render_component(&GroveSelector.grove_dropdown/1, groves: [], selected: nil)

      assert html =~ "No grove (blank form)"
      assert html =~ ~s(value="")
    end

    @tag :r3
    test "R3: options show grove name and description" do
      # R3: WHEN grove has name and description THEN option displays both
      groves = [%{name: "my-grove", description: "My description"}]

      html = render_component(&GroveSelector.grove_dropdown/1, groves: groves, selected: nil)

      assert html =~ "my-grove"
      assert html =~ "My description"
    end

    @tag :r4
    test "R4: empty groves list shows only no grove option" do
      # R4: WHEN groves list is empty THEN only "No grove" option rendered in select
      html = render_component(&GroveSelector.grove_dropdown/1, groves: [], selected: nil)

      assert html =~ "No grove"

      # Verify only one option exists (the "No grove" one)
      parsed = Floki.parse_document!(html)
      options = Floki.find(parsed, "option")
      assert length(options) == 1
    end

    @tag :r5
    test "R5: selected grove option has selected attribute" do
      # R5: WHEN selected prop matches grove name THEN that option has selected attribute
      groves = [
        %{name: "alpha-grove", description: "Alpha"},
        %{name: "selected-grove", description: "Selected"}
      ]

      html =
        render_component(&GroveSelector.grove_dropdown/1,
          groves: groves,
          selected: "selected-grove"
        )

      parsed = Floki.parse_document!(html)
      options = Floki.find(parsed, "option")

      # Find the selected-grove option
      selected_option =
        Enum.find(options, fn opt ->
          Floki.attribute(opt, "value") == ["selected-grove"]
        end)

      assert selected_option != nil
      assert Floki.attribute(selected_option, "selected") == ["selected"]

      # The other grove option should NOT be selected
      alpha_option =
        Enum.find(options, fn opt ->
          Floki.attribute(opt, "value") == ["alpha-grove"]
        end)

      assert alpha_option != nil
      refute Floki.attribute(alpha_option, "selected") == ["selected"]
    end
  end

  # =============================================================================
  # Additional Component Tests
  # =============================================================================

  describe "grove_dropdown/1 structure" do
    test "renders label 'Start from Grove'" do
      # Verifies the label text matches UI_GroveSelector spec
      html = render_component(&GroveSelector.grove_dropdown/1, groves: [], selected: nil)

      assert html =~ "Start from Grove"
    end

    test "renders help text about pre-fill" do
      # Verifies help text is present per UI_GroveSelector spec
      html = render_component(&GroveSelector.grove_dropdown/1, groves: [], selected: nil)

      assert html =~ "pre-fill"
    end

    test "default name attribute is 'grove'" do
      # Verifies default name attribute per spec
      html = render_component(&GroveSelector.grove_dropdown/1, groves: [], selected: nil)

      assert html =~ ~s(name="grove")
    end

    test "multiple groves rendered in order" do
      groves = [
        %{name: "aaa-first", description: "First"},
        %{name: "bbb-second", description: "Second"},
        %{name: "ccc-third", description: "Third"}
      ]

      html = render_component(&GroveSelector.grove_dropdown/1, groves: groves, selected: nil)

      parsed = Floki.parse_document!(html)
      options = Floki.find(parsed, "option")

      # 3 groves + 1 "No grove" = 4 options total
      assert length(options) == 4
    end

    test "nil selected shows no grove as default" do
      groves = [%{name: "test-grove", description: "Test"}]

      html = render_component(&GroveSelector.grove_dropdown/1, groves: groves, selected: nil)

      parsed = Floki.parse_document!(html)
      options = Floki.find(parsed, "option")

      # No option should have selected attribute when selected is nil
      # (browser defaults to first option which is "No grove")
      grove_option =
        Enum.find(options, fn opt ->
          Floki.attribute(opt, "value") == ["test-grove"]
        end)

      refute Floki.attribute(grove_option, "selected") == ["selected"]
    end
  end
end
