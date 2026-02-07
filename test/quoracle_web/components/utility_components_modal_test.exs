defmodule QuoracleWeb.UtilityComponentsModalTest do
  @moduledoc """
  Tests for the modal component in UtilityComponents.

  WorkGroupID: wip-20251011-063244
  Packet 2: Modal Component
  """
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import Phoenix.Component

  alias QuoracleWeb.UtilityComponents

  describe "modal/1" do
    test "renders modal with all required attributes and slots" do
      assigns = %{
        id: "test-modal",
        on_confirm: "confirm_action",
        on_cancel: "cancel_action"
      }

      # Test the modal component renders correctly
      result =
        rendered_to_string(~H"""
        <UtilityComponents.modal id={@id} on_confirm={@on_confirm} on_cancel={@on_cancel}>
          <:title>Test Modal Title</:title>
          This is the modal content
        </UtilityComponents.modal>
        """)

      # Modal should have correct structure
      assert result =~ ~s(id="test-modal")
      assert result =~ "Test Modal Title"
      assert result =~ "This is the modal content"
      assert result =~ ~s(phx-click="confirm_action")
      assert result =~ ~s(phx-click="cancel_action")
    end

    test "uses default on_cancel value when not provided" do
      assigns = %{
        id: "default-cancel-modal",
        on_confirm: "confirm_action"
      }

      result =
        rendered_to_string(~H"""
        <UtilityComponents.modal id={@id} on_confirm={@on_confirm}>
          <:title>Default Cancel Test</:title>
          Testing default cancel
        </UtilityComponents.modal>
        """)

      # Should use hide function as default on_cancel (JS command gets encoded)
      assert result =~ "#default-cancel-modal"
      assert result =~ "hide"
    end

    test "includes task_id attribute when provided" do
      assigns = %{
        id: "task-modal",
        on_confirm: "delete_task",
        task_id: "task-123"
      }

      result =
        rendered_to_string(~H"""
        <UtilityComponents.modal id={@id} on_confirm={@on_confirm} task_id={@task_id}>
          <:title>Delete Task?</:title>
          Are you sure?
        </UtilityComponents.modal>
        """)

      # Should include task_id in confirm button
      assert result =~ ~s(phx-value-task-id="task-123")
    end

    test "modal has hidden class by default" do
      assigns = %{
        id: "hidden-modal",
        on_confirm: "confirm"
      }

      result =
        rendered_to_string(~H"""
        <UtilityComponents.modal id={@id} on_confirm={@on_confirm}>
          <:title>Hidden Modal</:title>
          Should be hidden
        </UtilityComponents.modal>
        """)

      # Modal should have hidden class
      assert result =~ "hidden"
    end

    test "modal has proper backdrop and centering styles" do
      assigns = %{
        id: "styled-modal",
        on_confirm: "confirm"
      }

      result =
        rendered_to_string(~H"""
        <UtilityComponents.modal id={@id} on_confirm={@on_confirm}>
          <:title>Styled Modal</:title>
          Check styles
        </UtilityComponents.modal>
        """)

      # Check for backdrop styles
      assert result =~ "fixed inset-0"
      assert result =~ "z-50"
      assert result =~ "bg-gray-500/75"

      # Check for centering
      assert result =~ "flex min-h-full items-center justify-center"

      # Check for content box
      assert result =~ "bg-white rounded-lg shadow-xl"
      assert result =~ "max-w-md w-full"
    end

    test "modal has click-away dismissal" do
      assigns = %{
        id: "click-away-modal",
        on_confirm: "confirm"
      }

      result =
        rendered_to_string(~H"""
        <UtilityComponents.modal id={@id} on_confirm={@on_confirm}>
          <:title>Click Away Test</:title>
          Click outside to close
        </UtilityComponents.modal>
        """)

      # Should have phx-click handler on backdrop (JS commands get encoded)
      assert result =~ "phx-click"
      assert result =~ "#click-away-modal"
      assert result =~ "hide"

      # Should have phx-click-away on content
      assert result =~ "phx-click-away"
    end

    test "modal has cancel and confirm buttons" do
      assigns = %{
        id: "button-modal",
        on_confirm: "do_confirm"
      }

      result =
        rendered_to_string(~H"""
        <UtilityComponents.modal id={@id} on_confirm={@on_confirm}>
          <:title>Button Test</:title>
          Testing buttons
        </UtilityComponents.modal>
        """)

      # Cancel button
      assert result =~ "Cancel"
      assert result =~ "bg-gray-200"
      assert result =~ "hover:bg-gray-300"

      # Confirm button (Delete)
      assert result =~ "Delete"
      assert result =~ "bg-red-600"
      assert result =~ "text-white"
      assert result =~ "hover:bg-red-700"
    end

    test "modal buttons are in correct flex container" do
      assigns = %{
        id: "flex-modal",
        on_confirm: "confirm"
      }

      result =
        rendered_to_string(~H"""
        <UtilityComponents.modal id={@id} on_confirm={@on_confirm}>
          <:title>Flex Test</:title>
          Button layout
        </UtilityComponents.modal>
        """)

      # Buttons should be in flex container with gap
      assert result =~ "flex gap-3 justify-end"
    end

    test "modal uses hide function for cancel" do
      assigns = %{
        id: "hide-test-modal",
        on_confirm: "confirm"
      }

      result =
        rendered_to_string(~H"""
        <UtilityComponents.modal id={@id} on_confirm={@on_confirm}>
          <:title>Hide Function Test</:title>
          Testing hide
        </UtilityComponents.modal>
        """)

      # Cancel button should use hide function from UtilityComponents (JS gets encoded)
      assert result =~ "phx-click"
      assert result =~ "#hide-test-modal"
      assert result =~ "hide"
    end

    test "modal title is rendered in correct heading element" do
      assigns = %{
        id: "heading-modal",
        on_confirm: "confirm"
      }

      result =
        rendered_to_string(~H"""
        <UtilityComponents.modal id={@id} on_confirm={@on_confirm}>
          <:title>Important Title</:title>
          Content here
        </UtilityComponents.modal>
        """)

      # Title should be in h3 with proper styling (check content and classes separately)
      assert result =~ "<h3"
      assert result =~ "Important Title"
      assert result =~ "</h3>"
      assert result =~ "text-lg"
      assert result =~ "font-semibold"
      assert result =~ "mb-4"
    end

    test "modal inner_block is rendered with proper margin" do
      assigns = %{
        id: "content-modal",
        on_confirm: "confirm"
      }

      result =
        rendered_to_string(~H"""
        <UtilityComponents.modal id={@id} on_confirm={@on_confirm}>
          <:title>Content Test</:title>
          This content should have margin
        </UtilityComponents.modal>
        """)

      # Content should be in div with mb-6 (check separately due to formatting)
      assert result =~ "<div class=\"mb-6\">"
      assert result =~ "This content should have margin"
    end

    test "modal padding and spacing are correct" do
      assigns = %{
        id: "spacing-modal",
        on_confirm: "confirm"
      }

      result =
        rendered_to_string(~H"""
        <UtilityComponents.modal id={@id} on_confirm={@on_confirm}>
          <:title>Spacing Test</:title>
          Check padding
        </UtilityComponents.modal>
        """)

      # Content container should have p-6
      assert result =~ "p-6"

      # Outer container should have p-4
      assert result =~ "p-4"

      # Button container should have correct spacing
      assert result =~ "px-4 py-2"
    end
  end
end
