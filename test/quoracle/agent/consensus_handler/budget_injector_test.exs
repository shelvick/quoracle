defmodule Quoracle.Agent.ConsensusHandler.BudgetInjectorTest do
  @moduledoc """
  Tests for budget context injection into user messages.
  Moved from system prompt to user messages for KV cache preservation.

  ARC Verification Criteria:
  - R1: Budget section shows allocated, spent, available when budget is allocated
  - R2: No injection for N/A budget (nil allocated)
  - R3: Over budget warning with free action list
  - R4: Available = allocated - spent - committed
  - R5: Decimal formatting as currency ($X.XX)
  - R6: Budget wrapped in <budget> XML tags
  - R7: Injected at start of last message content
  - R8: Messages unchanged when no budget
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.ConsensusHandler.BudgetInjector

  describe "format_budget/1" do
    # R1: Budget section shows allocated, spent, available when budget is allocated
    test "shows budget table when allocated budget provided" do
      state = %{
        budget_data: %{allocated: Decimal.new("100.00"), committed: Decimal.new("10.00")},
        spent: Decimal.new("25.50"),
        over_budget: false
      }

      result = BudgetInjector.format_budget(state)

      assert result =~ "<budget>"
      assert result =~ "</budget>"
      assert result =~ "## Budget Status"
      assert result =~ "Allocated"
      assert result =~ "$100.00"
      assert result =~ "Spent"
      assert result =~ "$25.50"
      assert result =~ "Available"
    end

    # R2: No injection for N/A budget (nil allocated)
    test "returns empty string for nil allocated budget" do
      state = %{
        budget_data: %{allocated: nil, committed: Decimal.new("0")},
        spent: Decimal.new("0"),
        over_budget: false
      }

      result = BudgetInjector.format_budget(state)

      assert result == ""
    end

    test "returns empty string for nil budget_data" do
      state = %{
        budget_data: nil,
        spent: Decimal.new("0"),
        over_budget: false
      }

      result = BudgetInjector.format_budget(state)

      assert result == ""
    end

    # R3: Over budget warning with free action list
    test "includes warning when over_budget is true" do
      state = %{
        budget_data: %{allocated: Decimal.new("100.00"), committed: Decimal.new("5.00")},
        spent: Decimal.new("98.50"),
        over_budget: true
      }

      result = BudgetInjector.format_budget(state)

      assert result =~ "OVER BUDGET"
      assert result =~ "Only free actions are allowed"
      assert result =~ "orient"
      assert result =~ "wait"
      assert result =~ "send_message"
      assert result =~ "todo"
      assert result =~ "dismiss_child"
      assert result =~ "recovers unspent child budget"
    end

    test "shows within budget status when not over budget" do
      state = %{
        budget_data: %{allocated: Decimal.new("100.00"), committed: Decimal.new("10.00")},
        spent: Decimal.new("25.50"),
        over_budget: false
      }

      result = BudgetInjector.format_budget(state)

      assert result =~ "Within budget"
      refute result =~ "OVER BUDGET"
      refute result =~ "Only free actions are allowed"
    end

    # R4: Available = allocated - spent - committed
    test "calculates available correctly from allocated, spent, committed" do
      # allocated: 100, spent: 45.23, committed: 20 -> available: 34.77
      state = %{
        budget_data: %{allocated: Decimal.new("100.00"), committed: Decimal.new("20.00")},
        spent: Decimal.new("45.23"),
        over_budget: false
      }

      result = BudgetInjector.format_budget(state)

      assert result =~ "$34.77"
    end

    test "shows negative available when over budget" do
      # allocated: 100, spent: 98.50, committed: 5 -> available: -3.50
      state = %{
        budget_data: %{allocated: Decimal.new("100.00"), committed: Decimal.new("5.00")},
        spent: Decimal.new("98.50"),
        over_budget: true
      }

      result = BudgetInjector.format_budget(state)

      assert result =~ "$-3.50"
    end

    # R5: Decimal formatting as currency ($X.XX)
    test "formats amounts as currency with dollar sign and 2 decimals" do
      state = %{
        budget_data: %{allocated: Decimal.new("1234.5"), committed: Decimal.new("0")},
        spent: Decimal.new("567.8"),
        over_budget: false
      }

      result = BudgetInjector.format_budget(state)

      # Should round to 2 decimal places
      assert result =~ "$1234.50"
      assert result =~ "$567.80"
    end

    test "shows committed to children amount" do
      state = %{
        budget_data: %{allocated: Decimal.new("100.00"), committed: Decimal.new("20.00")},
        spent: Decimal.new("30.00"),
        over_budget: false
      }

      result = BudgetInjector.format_budget(state)

      assert result =~ "Committed"
      assert result =~ "$20.00"
    end

    # R6: Budget wrapped in <budget> XML tags
    test "wraps content in budget XML tags" do
      state = %{
        budget_data: %{allocated: Decimal.new("100.00"), committed: Decimal.new("0")},
        spent: Decimal.new("0"),
        over_budget: false
      }

      result = BudgetInjector.format_budget(state)

      assert String.starts_with?(result, "<budget>\n")
      assert String.ends_with?(result, "</budget>\n")
    end
  end

  describe "inject_budget_context/2" do
    # R7: Injected at start of last message content
    test "injects budget at start of last message" do
      state = %{
        budget_data: %{allocated: Decimal.new("100.00"), committed: Decimal.new("0")},
        spent: Decimal.new("25.00"),
        over_budget: false
      }

      messages = [
        %{role: "user", content: "First message"},
        %{role: "assistant", content: "Response"},
        %{role: "user", content: "Second message"}
      ]

      result = BudgetInjector.inject_budget_context(state, messages)

      # First two messages unchanged
      assert Enum.at(result, 0).content == "First message"
      assert Enum.at(result, 1).content == "Response"

      # Last message has budget prepended
      last_content = Enum.at(result, 2).content
      assert String.starts_with?(last_content, "<budget>")
      assert last_content =~ "Second message"
    end

    # R8: Messages unchanged when no budget
    test "returns messages unchanged when budget_data is nil" do
      state = %{budget_data: nil}

      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi"}
      ]

      result = BudgetInjector.inject_budget_context(state, messages)

      assert result == messages
    end

    test "returns messages unchanged when allocated is nil" do
      state = %{
        budget_data: %{allocated: nil, committed: Decimal.new("0")},
        spent: Decimal.new("0"),
        over_budget: false
      }

      messages = [%{role: "user", content: "Hello"}]

      result = BudgetInjector.inject_budget_context(state, messages)

      assert result == messages
    end

    test "returns empty list unchanged" do
      state = %{
        budget_data: %{allocated: Decimal.new("100.00"), committed: Decimal.new("0")},
        spent: Decimal.new("0"),
        over_budget: false
      }

      result = BudgetInjector.inject_budget_context(state, [])

      assert result == []
    end

    test "works with single message" do
      state = %{
        budget_data: %{allocated: Decimal.new("50.00"), committed: Decimal.new("5.00")},
        spent: Decimal.new("10.00"),
        over_budget: false
      }

      messages = [%{role: "user", content: "Only message"}]

      result = BudgetInjector.inject_budget_context(state, messages)

      assert length(result) == 1
      assert Enum.at(result, 0).content =~ "<budget>"
      assert Enum.at(result, 0).content =~ "Only message"
    end
  end

  describe "integration with ConsensusHandler delegation" do
    test "accessible via ConsensusHandler.inject_budget_context/2" do
      alias Quoracle.Agent.ConsensusHandler

      state = %{
        budget_data: %{allocated: Decimal.new("100.00"), committed: Decimal.new("0")},
        spent: Decimal.new("0"),
        over_budget: false
      }

      messages = [%{role: "user", content: "Test"}]

      result = ConsensusHandler.inject_budget_context(state, messages)

      assert Enum.at(result, 0).content =~ "<budget>"
    end

    test "accessible via ConsensusHandler.format_budget/1" do
      alias Quoracle.Agent.ConsensusHandler

      state = %{
        budget_data: %{allocated: Decimal.new("100.00"), committed: Decimal.new("0")},
        spent: Decimal.new("0"),
        over_budget: false
      }

      result = ConsensusHandler.format_budget(state)

      assert result =~ "<budget>"
      assert result =~ "## Budget Status"
    end
  end
end
