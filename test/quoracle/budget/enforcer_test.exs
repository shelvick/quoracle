defmodule Quoracle.Budget.EnforcerTest do
  @moduledoc """
  Unit tests for BUDGET_Enforcer module.

  Tests pre-action budget enforcement: classifying actions as costly/free
  and blocking costly actions when budget is exhausted.

  WorkGroupID: wip-20251231-budget
  Packet: 4 (Enforcement)
  """
  use ExUnit.Case, async: true

  alias Quoracle.Budget.Enforcer
  alias Quoracle.Budget.Schema

  # Helper to create budget data
  defp budget_with(allocated, committed) do
    %{
      allocated: allocated,
      committed: committed,
      mode: if(is_nil(allocated), do: :na, else: :root)
    }
  end

  # Over-budget: spent >= available
  defp over_budget_state do
    budget = budget_with(Decimal.new("100.00"), Decimal.new("0"))
    spent = Decimal.new("100.00")
    {budget, spent}
  end

  # Under-budget: spent < available
  defp under_budget_state do
    budget = budget_with(Decimal.new("100.00"), Decimal.new("0"))
    spent = Decimal.new("50.00")
    {budget, spent}
  end

  describe "R1-R4: check_action/4" do
    test "R1: blocks costly actions when over-budget" do
      {budget, spent} = over_budget_state()

      result = Enforcer.check_action(:spawn_child, %{}, budget, spent)

      assert result == {:blocked, :over_budget}
    end

    test "R1: blocks all costly action types when over-budget" do
      {budget, spent} = over_budget_state()

      costly_actions = [
        :spawn_child,
        :call_api,
        :call_mcp,
        :fetch_web,
        :answer_engine,
        :generate_images
      ]

      for action <- costly_actions do
        result = Enforcer.check_action(action, %{}, budget, spent)
        assert result == {:blocked, :over_budget}, "#{action} should be blocked when over-budget"
      end
    end

    test "R2: allows costly actions when budget available" do
      {budget, spent} = under_budget_state()

      result = Enforcer.check_action(:spawn_child, %{}, budget, spent)

      assert result == :allowed
    end

    test "R3: allows free actions even when over-budget" do
      {budget, spent} = over_budget_state()

      free_actions = [
        :orient,
        :send_message,
        :wait,
        :dismiss_child,
        :manage_todo,
        :generate_secret,
        :search_secrets,
        :record_cost
      ]

      for action <- free_actions do
        result = Enforcer.check_action(action, %{}, budget, spent)
        assert result == :allowed, "#{action} should be allowed even when over-budget"
      end
    end

    test "R4: allows all actions for N/A budget" do
      budget = Schema.new_na()
      # Even with high spent, N/A budget is unlimited
      spent = Decimal.new("1000000.00")

      # Both costly and free actions should be allowed
      assert Enforcer.check_action(:spawn_child, %{}, budget, spent) == :allowed
      assert Enforcer.check_action(:call_api, %{}, budget, spent) == :allowed
      assert Enforcer.check_action(:orient, %{}, budget, spent) == :allowed
    end
  end

  describe "R5-R6: execute_shell classification" do
    test "R5: execute_shell with check_id is free" do
      result = Enforcer.classify_action(:execute_shell, %{check_id: "shell-123"})

      assert result == :free
    end

    test "R5: execute_shell with terminate is free" do
      result = Enforcer.classify_action(:execute_shell, %{terminate: "shell-123"})

      assert result == :free
    end

    test "R6: execute_shell with command is costly" do
      result = Enforcer.classify_action(:execute_shell, %{command: "ls -la"})

      assert result == :costly
    end

    test "R6: new execute_shell without check_id/terminate is costly" do
      result = Enforcer.classify_action(:execute_shell, %{})

      assert result == :costly
    end
  end

  describe "R7-R9: specific action classifications" do
    test "R9: spawn_child is costly" do
      assert Enforcer.classify_action(:spawn_child, %{}) == :costly
    end

    test "R10: record_cost is free" do
      # Recording costs is accounting reality, not permission
      assert Enforcer.classify_action(:record_cost, %{}) == :free
    end

    test "R11: send_message is free" do
      assert Enforcer.classify_action(:send_message, %{}) == :free
    end

    test "unknown actions default to free (fail-open)" do
      assert Enforcer.classify_action(:unknown_action, %{}) == :free
    end
  end

  describe "costly_action?/2" do
    test "returns true for costly actions" do
      assert Enforcer.costly_action?(:spawn_child, %{}) == true
      assert Enforcer.costly_action?(:call_api, %{}) == true
      assert Enforcer.costly_action?(:fetch_web, %{}) == true
    end

    test "returns false for free actions" do
      assert Enforcer.costly_action?(:orient, %{}) == false
      assert Enforcer.costly_action?(:send_message, %{}) == false
      assert Enforcer.costly_action?(:wait, %{}) == false
    end

    test "respects param-based classification for shell" do
      assert Enforcer.costly_action?(:execute_shell, %{command: "ls"}) == true
      assert Enforcer.costly_action?(:execute_shell, %{check_id: "123"}) == false
    end
  end

  describe "edge cases" do
    test "exactly at budget limit is over-budget" do
      # 100 allocated, 100 spent, 0 committed = 0 available
      budget = budget_with(Decimal.new("100.00"), Decimal.new("0"))
      spent = Decimal.new("100.00")

      result = Enforcer.check_action(:spawn_child, %{}, budget, spent)

      assert result == {:blocked, :over_budget}
    end

    test "one cent available allows costly actions" do
      # 100 allocated, 99.99 spent = 0.01 available
      budget = budget_with(Decimal.new("100.00"), Decimal.new("0"))
      spent = Decimal.new("99.99")

      result = Enforcer.check_action(:spawn_child, %{}, budget, spent)

      assert result == :allowed
    end

    test "committed amount reduces available" do
      # 100 allocated, 50 committed, 40 spent = 10 available
      budget = budget_with(Decimal.new("100.00"), Decimal.new("50.00"))
      spent = Decimal.new("40.00")

      # Available is 10, so spawn should be allowed
      assert Enforcer.check_action(:spawn_child, %{}, budget, spent) == :allowed

      # But if spent is 50, available is 0, so blocked
      spent_more = Decimal.new("50.00")

      assert Enforcer.check_action(:spawn_child, %{}, budget, spent_more) ==
               {:blocked, :over_budget}
    end
  end
end
