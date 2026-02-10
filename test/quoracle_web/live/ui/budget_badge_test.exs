defmodule QuoracleWeb.UI.BudgetBadgeTest do
  @moduledoc """
  Tests for UI_BudgetBadge - visual budget status badge component.

  WorkGroupID: wip-20251231-budget
  Packet: 1 (Foundation - Data Model)

  ARC Verification Criteria:
  - R1: Display OK Status - green badge with amount
  - R2: Display Warning Status - yellow badge
  - R3: Display Over Budget Status - red badge with negative
  - R4: Display N/A Status - gray badge with N/A text
  - R5: Negative Amount Format - displays as -$X.XX
  - R6: Tooltip Shows Breakdown - title shows full breakdown
  - R7: Two Decimal Precision - rounds to 2 decimal places
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias QuoracleWeb.UI.BudgetBadge

  # Helper to render component
  defp render_badge(summary, opts \\ []) do
    class = Keyword.get(opts, :class, "")

    assigns = %{
      summary: summary,
      class: class
    }

    rendered = render_component(&BudgetBadge.budget_badge/1, assigns)
    rendered
  end

  describe "R1: display ok status" do
    # R1: WHEN status is ok THEN shows green badge with amount
    test "budget_badge/1 renders green for ok status" do
      summary = %{
        status: :ok,
        allocated: Decimal.new("100.00"),
        spent: Decimal.new("20.00"),
        committed: Decimal.new("10.00"),
        available: Decimal.new("70.00")
      }

      html = render_badge(summary)

      # Green styling
      assert html =~ "bg-green-100"
      assert html =~ "text-green-800"
      # Shows available amount
      assert html =~ "$70"
      assert html =~ "left"
    end
  end

  describe "R2: display warning status" do
    # R2: WHEN status is warning THEN shows yellow badge
    test "budget_badge/1 renders yellow for warning status" do
      summary = %{
        status: :warning,
        allocated: Decimal.new("100.00"),
        spent: Decimal.new("80.00"),
        committed: Decimal.new("10.00"),
        available: Decimal.new("10.00")
      }

      html = render_badge(summary)

      # Yellow styling
      assert html =~ "bg-yellow-100"
      assert html =~ "text-yellow-800"
    end
  end

  describe "R3: display over budget status" do
    # R3: WHEN status is over_budget THEN shows red badge with negative
    test "budget_badge/1 renders red for over_budget status" do
      summary = %{
        status: :over_budget,
        allocated: Decimal.new("100.00"),
        spent: Decimal.new("120.00"),
        committed: Decimal.new("0"),
        available: Decimal.new("-20.00")
      }

      html = render_badge(summary)

      # Red styling
      assert html =~ "bg-red-100"
      assert html =~ "text-red-800"
      # Shows negative
      assert html =~ "-$"
    end
  end

  describe "R4: display N/A status" do
    # R4: WHEN status is na THEN shows gray badge with N/A text
    test "budget_badge/1 renders gray for N/A status" do
      summary = %{status: :na}

      html = render_badge(summary)

      # Gray styling
      assert html =~ "bg-gray-100"
      assert html =~ "text-gray-500"
      # Shows N/A text
      assert html =~ "N/A"
    end
  end

  describe "R5: negative amount format" do
    # R5: WHEN available negative THEN displays as -$X.XX
    test "format_available/1 shows negative with minus sign" do
      summary = %{
        status: :over_budget,
        allocated: Decimal.new("50.00"),
        spent: Decimal.new("75.00"),
        committed: Decimal.new("0"),
        available: Decimal.new("-25.00")
      }

      html = render_badge(summary)

      # Negative format: -$25.00 (not ($25.00) or -25.00)
      assert html =~ "-$25"
      # Should NOT show "left" for negative
      refute html =~ "-$25" && html =~ "left"
    end

    test "negative amounts show absolute value after minus" do
      summary = %{
        status: :over_budget,
        allocated: Decimal.new("100.00"),
        spent: Decimal.new("150.50"),
        committed: Decimal.new("0"),
        available: Decimal.new("-50.50")
      }

      html = render_badge(summary)

      # -$50.50, not -$-50.50
      assert html =~ "-$50.50"
      refute html =~ "-$-"
    end
  end

  describe "R6: tooltip shows breakdown" do
    # R6: WHEN hovered THEN title shows full budget breakdown
    test "budget_badge/1 includes breakdown in title attribute" do
      summary = %{
        status: :ok,
        allocated: Decimal.new("100.00"),
        spent: Decimal.new("30.00"),
        committed: Decimal.new("20.00"),
        available: Decimal.new("50.00")
      }

      html = render_badge(summary)

      # Title attribute contains breakdown
      assert html =~ "title="
      assert html =~ "Allocated"
      assert html =~ "Spent"
      assert html =~ "Committed"
      assert html =~ "Available"
    end

    test "N/A status shows unlimited in title" do
      summary = %{status: :na}

      html = render_badge(summary)

      assert html =~ "title="
      # Title should contain both N/A and unlimited: "Budget: N/A (unlimited)"
      assert html =~ "N/A"
      assert html =~ "unlimited"
    end
  end

  describe "R7: two decimal precision" do
    # R7: WHEN displaying amounts THEN rounds to 2 decimal places
    test "amounts rounded to 2 decimal places" do
      summary = %{
        status: :ok,
        allocated: Decimal.new("100.00"),
        spent: Decimal.new("33.333"),
        committed: Decimal.new("16.666"),
        available: Decimal.new("50.001")
      }

      html = render_badge(summary)

      # Available should be rounded
      assert html =~ "$50.00"
      # Should not show extra precision
      refute html =~ "50.001"
    end

    test "rounding up works correctly" do
      summary = %{
        status: :ok,
        allocated: Decimal.new("100.00"),
        spent: Decimal.new("0"),
        committed: Decimal.new("0"),
        available: Decimal.new("99.999")
      }

      html = render_badge(summary)

      # 99.999 rounds to 100.00
      assert html =~ "$100"
    end
  end

  describe "custom class" do
    test "accepts custom class attribute" do
      summary = %{status: :na}

      html = render_badge(summary, class: "my-custom-class")

      assert html =~ "my-custom-class"
    end
  end

  describe "badge styling" do
    test "has budget-badge class" do
      summary = %{status: :na}

      html = render_badge(summary)

      assert html =~ "budget-badge"
    end

    test "has compact styling classes" do
      summary = %{
        status: :ok,
        allocated: Decimal.new("100.00"),
        spent: Decimal.new("25.00"),
        committed: Decimal.new("25.00"),
        available: Decimal.new("50.00")
      }

      html = render_badge(summary)

      # Compact badge styling
      assert html =~ "text-xs"
      assert html =~ "px-1.5"
      assert html =~ "py-0.5"
      assert html =~ "rounded"
    end
  end
end
