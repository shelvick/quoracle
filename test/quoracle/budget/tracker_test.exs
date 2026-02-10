defmodule Quoracle.Budget.TrackerTest do
  @moduledoc """
  Tests for BUDGET_Tracker - budget calculation and status tracking.

  WorkGroupID: wip-20251231-budget
  Packet: 2 (Tracker Integration)

  ARC Verification Criteria:
  - R1: Get Spent from Aggregator [INTEGRATION]
  - R2: Calculate Available [UNIT]
  - R3: Available with N/A Budget [UNIT]
  - R4: Status OK [UNIT]
  - R5: Status Warning [UNIT]
  - R6: Status Over Budget [UNIT]
  - R7: Status N/A [UNIT]
  - R8: Summary Aggregation [INTEGRATION]
  - R9: Is Over Budget Check [UNIT]
  - R10: Has Available Check [UNIT]
  - R11: N/A Budget Always Has Available [UNIT]
  - P1: Available Invariant [PROPERTY]
  - P2: Status Consistency [PROPERTY]
  """

  use Quoracle.DataCase, async: true
  use ExUnitProperties

  alias Quoracle.Budget.Tracker
  alias Quoracle.Budget.Schema
  alias Quoracle.Costs.AgentCost
  alias Quoracle.Tasks.Task
  alias Quoracle.Repo

  # Helper to create a task and agent for integration tests
  defp create_task_with_agent do
    {:ok, task} =
      Repo.insert(Task.changeset(%Task{}, %{prompt: "Test task", status: "running"}))

    agent_id = Ecto.UUID.generate()
    {task, agent_id}
  end

  # Helper to record a cost
  defp record_cost(agent_id, task_id, amount) do
    %AgentCost{}
    |> AgentCost.changeset(%{
      agent_id: agent_id,
      task_id: task_id,
      cost_type: "llm_consensus",
      cost_usd: amount
    })
    |> Repo.insert!()
  end

  describe "R1: get spent from aggregator" do
    # R1: WHEN get_spent called THEN returns total from agent_costs table
    @tag :integration
    test "get_spent/1 returns aggregated cost from database" do
      {task, agent_id} = create_task_with_agent()

      # Record multiple costs
      record_cost(agent_id, task.id, Decimal.new("10.00"))
      record_cost(agent_id, task.id, Decimal.new("5.50"))
      record_cost(agent_id, task.id, Decimal.new("2.25"))

      spent = Tracker.get_spent(agent_id)

      assert Decimal.equal?(spent, Decimal.new("17.75"))
    end

    @tag :integration
    test "get_spent/1 returns zero for agent with no costs" do
      agent_id = Ecto.UUID.generate()

      spent = Tracker.get_spent(agent_id)

      assert Decimal.equal?(spent, Decimal.new(0))
    end
  end

  describe "R2: calculate available" do
    # R2: WHEN calculate_available called THEN returns allocated - spent - committed
    test "calculate_available/2 computes correct value" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("20.00"),
        mode: :root
      }

      spent = Decimal.new("30.00")

      available = Tracker.calculate_available(budget, spent)

      # 100 - 30 - 20 = 50
      assert Decimal.equal?(available, Decimal.new("50.00"))
    end

    test "calculate_available/2 with zero spent and committed" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0"),
        mode: :root
      }

      available = Tracker.calculate_available(budget, Decimal.new(0))

      assert Decimal.equal?(available, Decimal.new("100.00"))
    end

    test "calculate_available/2 can return negative when over budget" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("50.00"),
        mode: :root
      }

      spent = Decimal.new("60.00")

      available = Tracker.calculate_available(budget, spent)

      # 100 - 60 - 50 = -10
      assert Decimal.equal?(available, Decimal.new("-10.00"))
    end
  end

  describe "R3: available with N/A budget" do
    # R3: WHEN allocated is nil THEN available returns nil
    test "calculate_available/2 returns nil for N/A budget" do
      budget = Schema.new_na()

      available = Tracker.calculate_available(budget, Decimal.new("100.00"))

      assert available == nil
    end
  end

  describe "R4: status OK" do
    # R4: WHEN available > 20% of allocated THEN status is :ok
    test "get_status/2 returns :ok when budget healthy" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0"),
        mode: :root
      }

      # Spent 50, available 50 (50% remaining > 20%)
      spent = Decimal.new("50.00")

      status = Tracker.get_status(budget, spent)

      assert status == :ok
    end

    test "get_status/2 returns :ok when exactly above 20% threshold" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0"),
        mode: :root
      }

      # Spent 79, available 21 (21% remaining > 20%)
      spent = Decimal.new("79.00")

      status = Tracker.get_status(budget, spent)

      assert status == :ok
    end
  end

  describe "R5: status warning" do
    # R5: WHEN available <= 20% and > 0 THEN status is :warning
    test "get_status/2 returns :warning when below threshold" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0"),
        mode: :root
      }

      # Spent 85, available 15 (15% remaining <= 20%)
      spent = Decimal.new("85.00")

      status = Tracker.get_status(budget, spent)

      assert status == :warning
    end

    test "get_status/2 returns :warning at exactly 20% threshold" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0"),
        mode: :root
      }

      # Spent 80, available 20 (exactly 20%)
      spent = Decimal.new("80.00")

      status = Tracker.get_status(budget, spent)

      assert status == :warning
    end

    test "get_status/2 returns :warning when 1 cent remaining" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0"),
        mode: :root
      }

      # Spent 99.99, available 0.01
      spent = Decimal.new("99.99")

      status = Tracker.get_status(budget, spent)

      assert status == :warning
    end
  end

  describe "R6: status over budget" do
    # R6: WHEN available <= 0 THEN status is :over_budget
    test "get_status/2 returns :over_budget when exhausted" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0"),
        mode: :root
      }

      # Spent exactly 100
      spent = Decimal.new("100.00")

      status = Tracker.get_status(budget, spent)

      assert status == :over_budget
    end

    test "get_status/2 returns :over_budget when negative available" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0"),
        mode: :root
      }

      # Spent 150 (over budget)
      spent = Decimal.new("150.00")

      status = Tracker.get_status(budget, spent)

      assert status == :over_budget
    end

    test "get_status/2 returns :over_budget with committed included" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("50.00"),
        mode: :root
      }

      # Spent 50, committed 50 = 100 used, available = 0
      spent = Decimal.new("50.00")

      status = Tracker.get_status(budget, spent)

      assert status == :over_budget
    end
  end

  describe "R7: status N/A" do
    # R7: WHEN allocated is nil THEN status is :na
    test "get_status/2 returns :na for unlimited budget" do
      budget = Schema.new_na()

      # Any spent amount, still N/A
      status = Tracker.get_status(budget, Decimal.new("1000.00"))

      assert status == :na
    end
  end

  describe "R8: summary aggregation" do
    # R8: WHEN get_summary called THEN returns complete budget state
    @tag :integration
    test "get_summary/2 aggregates all budget fields" do
      {task, agent_id} = create_task_with_agent()

      # Record some costs
      record_cost(agent_id, task.id, Decimal.new("25.00"))
      record_cost(agent_id, task.id, Decimal.new("10.00"))

      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("15.00"),
        mode: :root
      }

      summary = Tracker.get_summary(agent_id, budget)

      assert Decimal.equal?(summary.allocated, Decimal.new("100.00"))
      assert Decimal.equal?(summary.spent, Decimal.new("35.00"))
      assert Decimal.equal?(summary.committed, Decimal.new("15.00"))
      # available = 100 - 35 - 15 = 50
      assert Decimal.equal?(summary.available, Decimal.new("50.00"))
      assert summary.status == :ok
      assert summary.mode == :root
    end

    @tag :integration
    test "get_summary/2 with N/A budget" do
      agent_id = Ecto.UUID.generate()
      budget = Schema.new_na()

      summary = Tracker.get_summary(agent_id, budget)

      assert summary.allocated == nil
      assert Decimal.equal?(summary.spent, Decimal.new(0))
      assert summary.available == nil
      assert summary.status == :na
      assert summary.mode == :na
    end
  end

  describe "R9: over budget check" do
    # R9: WHEN spent >= allocated - committed THEN over_budget? returns true
    test "over_budget?/2 detects exhausted budget" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0"),
        mode: :root
      }

      # Exactly at limit
      assert Tracker.over_budget?(budget, Decimal.new("100.00")) == true
      # Over limit
      assert Tracker.over_budget?(budget, Decimal.new("100.01")) == true
    end

    test "over_budget?/2 returns false when under budget" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0"),
        mode: :root
      }

      assert Tracker.over_budget?(budget, Decimal.new("99.99")) == false
    end

    test "over_budget?/2 considers committed amount" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("40.00"),
        mode: :root
      }

      # 60 spent + 40 committed = 100, at limit
      assert Tracker.over_budget?(budget, Decimal.new("60.00")) == true
    end

    test "over_budget?/2 returns false for N/A budget" do
      budget = Schema.new_na()

      assert Tracker.over_budget?(budget, Decimal.new("1000000.00")) == false
    end
  end

  describe "R10: has available check" do
    # R10: WHEN available >= required THEN has_available? returns true
    test "has_available?/3 validates sufficient funds" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("20.00"),
        mode: :root
      }

      spent = Decimal.new("30.00")
      # Available = 100 - 30 - 20 = 50

      # Requesting exactly 50
      assert Tracker.has_available?(budget, spent, Decimal.new("50.00")) == true
      # Requesting less than available
      assert Tracker.has_available?(budget, spent, Decimal.new("25.00")) == true
    end

    test "has_available?/3 returns false when insufficient funds" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("20.00"),
        mode: :root
      }

      spent = Decimal.new("30.00")
      # Available = 50

      # Requesting more than available
      assert Tracker.has_available?(budget, spent, Decimal.new("50.01")) == false
      assert Tracker.has_available?(budget, spent, Decimal.new("100.00")) == false
    end
  end

  describe "R11: N/A budget always has available" do
    # R11: WHEN allocated is nil THEN has_available? returns true for any amount
    test "has_available?/3 returns true for N/A budget" do
      budget = Schema.new_na()

      # Any amount should be available
      assert Tracker.has_available?(budget, Decimal.new("0"), Decimal.new("1000000.00")) == true
      assert Tracker.has_available?(budget, Decimal.new("999999.00"), Decimal.new("1.00")) == true
    end
  end

  describe "P1: available invariant" do
    # P1: FORALL allocated, spent, committed: available = allocated - spent - committed
    property "available equals allocated minus spent minus committed" do
      check all(
              allocated <- positive_decimal(),
              spent <- non_negative_decimal(),
              committed <- non_negative_decimal()
            ) do
        budget = %{
          allocated: allocated,
          committed: committed,
          mode: :root
        }

        available = Tracker.calculate_available(budget, spent)
        expected = allocated |> Decimal.sub(spent) |> Decimal.sub(committed)

        assert Decimal.equal?(available, expected)
      end
    end
  end

  describe "P2: status consistency" do
    # P2: FORALL budget: status matches available thresholds
    property "status reflects available amount correctly" do
      check all(
              allocated <- positive_decimal(),
              spent <- non_negative_decimal(),
              committed <- non_negative_decimal()
            ) do
        budget = %{
          allocated: allocated,
          committed: committed,
          mode: :root
        }

        status = Tracker.get_status(budget, spent)
        available = Tracker.calculate_available(budget, spent)
        threshold = Decimal.mult(allocated, Decimal.new("0.2"))

        cond do
          Decimal.compare(available, Decimal.new(0)) in [:lt, :eq] ->
            assert status == :over_budget

          Decimal.compare(available, threshold) == :lt ->
            assert status == :warning

          true ->
            assert status == :ok
        end
      end
    end
  end

  # ============================================================================
  # MODIFICATION: validate_budget_decrease/3 (feat-20251231-191717)
  # Packet 2 (Budget Logic Extensions)
  # ============================================================================

  describe "R12-R15: validate_budget_decrease/3" do
    # R12: WHEN new_allocated >= spent + committed THEN returns :ok
    test "R12: succeeds when new_allocated above minimum" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("20.00"),
        mode: :root
      }

      spent = Decimal.new("30.00")
      # Minimum = 30 + 20 = 50, requesting 60 (above minimum)
      new_allocated = Decimal.new("60.00")

      assert Tracker.validate_budget_decrease(budget, spent, new_allocated) == :ok
    end

    test "R12: succeeds when exactly at minimum" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("25.00"),
        mode: :root
      }

      spent = Decimal.new("25.00")
      # Minimum = 25 + 25 = 50, requesting exactly 50
      new_allocated = Decimal.new("50.00")

      assert Tracker.validate_budget_decrease(budget, spent, new_allocated) == :ok
    end

    # R13: WHEN new_allocated < spent + committed THEN returns structured error
    test "R13: returns error with details when below minimum" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("30.00"),
        mode: :root
      }

      spent = Decimal.new("40.00")
      # Minimum = 40 + 30 = 70, requesting 50 (below minimum)
      new_allocated = Decimal.new("50.00")

      result = Tracker.validate_budget_decrease(budget, spent, new_allocated)

      assert {:error, error_map} = result
      assert error_map.reason == :would_violate_escrow
    end

    # R14: WHEN allocated is nil THEN returns :ok
    test "R14: succeeds for N/A budget" do
      budget = Schema.new_na()
      spent = Decimal.new("1000.00")
      new_allocated = Decimal.new("1.00")

      assert Tracker.validate_budget_decrease(budget, spent, new_allocated) == :ok
    end

    # R15: WHEN error returned THEN contains spent, committed, minimum, requested
    test "R15: error map contains all required fields" do
      budget = %{
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("35.00"),
        mode: :root
      }

      spent = Decimal.new("45.00")
      # Minimum = 45 + 35 = 80
      new_allocated = Decimal.new("70.00")

      {:error, error_map} = Tracker.validate_budget_decrease(budget, spent, new_allocated)

      assert Map.has_key?(error_map, :spent)
      assert Map.has_key?(error_map, :committed)
      assert Map.has_key?(error_map, :minimum)
      assert Map.has_key?(error_map, :requested)
      assert Map.has_key?(error_map, :reason)

      assert Decimal.equal?(error_map.spent, Decimal.new("45.00"))
      assert Decimal.equal?(error_map.committed, Decimal.new("35.00"))
      assert Decimal.equal?(error_map.minimum, Decimal.new("80.00"))
      assert Decimal.equal?(error_map.requested, Decimal.new("70.00"))
    end
  end

  # StreamData generators for property tests
  defp positive_decimal do
    gen all(
          integer <- integer(1..1_000_000),
          cents <- integer(0..99)
        ) do
      Decimal.new("#{integer}.#{String.pad_leading("#{cents}", 2, "0")}")
    end
  end

  defp non_negative_decimal do
    gen all(
          integer <- integer(0..1_000_000),
          cents <- integer(0..99)
        ) do
      Decimal.new("#{integer}.#{String.pad_leading("#{cents}", 2, "0")}")
    end
  end
end
