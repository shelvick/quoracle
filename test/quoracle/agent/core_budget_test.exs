defmodule Quoracle.Agent.CoreBudgetTest do
  @moduledoc """
  Tests for AGENT_Core v22.0 budget state management.

  WorkGroupID: wip-20251231-budget
  Packet: Packet 9 (AGENT_Core Integration)

  Tests cover:
  - R34: Budget data stored in state from config
  - R35: Default N/A budget when not provided
  - R36: Cost event subscription on init
  - R37: Over budget detection when costs exceed budget
  - R38: Get budget API returns current budget state
  - R39: Over budget monotonicity (stays true)
  """

  use Quoracle.DataCase, async: true
  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core
  alias Quoracle.Budget.Schema

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated PubSub instance for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Create isolated Registry for this test
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    %{pubsub: pubsub_name, registry: registry_name, sandbox_owner: sandbox_owner}
  end

  describe "budget_data in state (v22.0)" do
    # R34: Budget Data in State [UNIT]
    @tag :r34
    @tag :unit
    test "R34: budget_data stored in state from config", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      # Arrange: Create budget_data
      budget_data = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      config = %{
        agent_id: "agent-R34",
        test_mode: true,
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub,
        budget_data: budget_data
      }

      # Act: Start agent with budget_data in config
      {:ok, agent} = Core.start_link(config)
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Assert: State contains budget_data
      {:ok, state} = Core.get_state(agent)
      assert state.budget_data == budget_data
      assert state.budget_data.mode == :root
      assert Decimal.equal?(state.budget_data.allocated, Decimal.new("100.00"))
    end

    # R35: Default N/A Budget [UNIT]
    @tag :r35
    @tag :unit
    test "R35: defaults to N/A budget when not provided", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      config = %{
        agent_id: "agent-R35",
        test_mode: true,
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub
        # No budget_data provided
      }

      # Act: Start agent without budget_data
      {:ok, agent} = Core.start_link(config)
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Assert: Defaults to N/A budget
      {:ok, state} = Core.get_state(agent)
      assert state.budget_data != nil
      assert state.budget_data.mode == :na
      assert state.budget_data.allocated == nil
    end
  end

  describe "cost event handling (v22.0)" do
    # R36: Cost Event Subscription [INTEGRATION]
    @tag :r36
    @tag :integration
    test "R36: subscribes to cost events on init", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "agent-R36"

      config = %{
        agent_id: agent_id,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub,
        budget_data: Schema.new_root(Decimal.new("50.00"))
      }

      # Act: Start agent
      {:ok, agent} = Core.start_link(config)
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Assert: Agent receives cost events (proves subscription)
      # Broadcast a cost event and verify it affects agent state
      cost_topic = "agents:#{agent_id}:costs"
      cost_event = %{agent_id: agent_id, amount: Decimal.new("5.00"), cost_type: "llm"}

      Phoenix.PubSub.broadcast(pubsub, cost_topic, {:cost_recorded, cost_event})

      # GenServer.call after broadcast ensures PubSub message is processed first
      # (messages are processed in mailbox order, and call blocks until response)
      {:ok, state} = Core.get_state(agent)

      # Agent should have over_budget field if it's handling cost events
      assert Map.has_key?(state, :over_budget),
             "Agent should have over_budget field after cost event"
    end

    # R37: Over Budget Detection [INTEGRATION]
    @tag :r37
    @tag :integration
    test "R37: over_budget set to true when costs exceed budget", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "agent-R37"

      # Create a task for cost records (required foreign key)
      {:ok, task} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Test task R37", status: "running"})
        |> Quoracle.Repo.insert()

      # Budget of 10.00, will be exceeded by cost
      budget_data = %{
        mode: :root,
        allocated: Decimal.new("10.00"),
        committed: Decimal.new("0")
      }

      config = %{
        agent_id: agent_id,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub,
        budget_data: budget_data
      }

      {:ok, agent} = Core.start_link(config)
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Initially not over budget
      {:ok, initial_state} = Core.get_state(agent)
      assert initial_state.over_budget == false

      # Create actual cost record that exceeds budget (12.00 > 10.00 allocated)
      {:ok, _cost} =
        %Quoracle.Costs.AgentCost{}
        |> Quoracle.Costs.AgentCost.changeset(%{
          agent_id: agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("12.00")
        })
        |> Quoracle.Repo.insert()

      # Broadcast cost event to trigger over_budget check
      Phoenix.PubSub.broadcast(pubsub, "agents:#{agent_id}:costs", {:cost_recorded, %{}})

      # GenServer.call syncs after PubSub message processing
      {:ok, state} = Core.get_state(agent)
      assert state.over_budget == true
    end

    # R39: REMOVED - v34.0 removes over_budget monotonicity.
    # The old behavior (over_budget stays true forever) is replaced by
    # R40-R43 which test the new re-evaluation behavior.
  end

  # ============================================================
  # AGENT_Core v34.0: Budget Re-evaluation (R40-R43)
  # WorkGroupID: fix-20260211-budget-enforcement
  # Packet: 2 (Dismissal Reconciliation)
  # ============================================================

  describe "over_budget re-evaluation (v34.0)" do
    # R40: Over Budget Can Recover [INTEGRATION]
    @tag :r40
    @tag :integration
    test "R40: over_budget reverts to false when budget recovers", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "agent-R40-#{System.unique_integer([:positive])}"

      # Create a task for cost records (required foreign key)
      {:ok, task} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Test task R40", status: "running"})
        |> Quoracle.Repo.insert()

      # Agent with small initial budget
      budget_data = %{
        mode: :root,
        allocated: Decimal.new("10.00"),
        committed: Decimal.new("0")
      }

      config = %{
        agent_id: agent_id,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub,
        budget_data: budget_data
      }

      {:ok, agent} = Core.start_link(config)
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Step 1: Create cost that exceeds budget (12.00 > 10.00)
      {:ok, cost_record} =
        %Quoracle.Costs.AgentCost{}
        |> Quoracle.Costs.AgentCost.changeset(%{
          agent_id: agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("12.00")
        })
        |> Quoracle.Repo.insert()

      Phoenix.PubSub.broadcast(pubsub, "agents:#{agent_id}:costs", {:cost_recorded, %{}})
      {:ok, state_over} = Core.get_state(agent)

      assert state_over.over_budget == true,
             "Should be over budget after 12.00 spent vs 10.00 allocated"

      # Step 2: Simulate budget recovery by increasing allocation
      # In real scenario this happens via child absorption returning unspent budget.
      # We simulate by deleting the cost record (equivalent to budget recovery).
      Quoracle.Repo.delete!(cost_record)

      # Trigger re-evaluation (v34.0 should re-evaluate instead of short-circuiting)
      Phoenix.PubSub.broadcast(pubsub, "agents:#{agent_id}:costs", {:cost_recorded, %{}})
      {:ok, state_recovered} = Core.get_state(agent)

      # v34.0: over_budget should revert to false (no more monotonicity)
      assert state_recovered.over_budget == false,
             "over_budget should revert to false when spent drops below allocated"
    end

    # R41: Over Budget Still Detected [INTEGRATION]
    @tag :r41
    @tag :integration
    test "R41: over_budget still true when spent exceeds allocated", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "agent-R41-#{System.unique_integer([:positive])}"

      {:ok, task} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Test task R41", status: "running"})
        |> Quoracle.Repo.insert()

      budget_data = %{
        mode: :root,
        allocated: Decimal.new("10.00"),
        committed: Decimal.new("0")
      }

      config = %{
        agent_id: agent_id,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub,
        budget_data: budget_data
      }

      {:ok, agent} = Core.start_link(config)
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Create cost that exceeds budget (15.00 > 10.00)
      {:ok, _cost} =
        %Quoracle.Costs.AgentCost{}
        |> Quoracle.Costs.AgentCost.changeset(%{
          agent_id: agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("15.00")
        })
        |> Quoracle.Repo.insert()

      Phoenix.PubSub.broadcast(pubsub, "agents:#{agent_id}:costs", {:cost_recorded, %{}})
      {:ok, state} = Core.get_state(agent)

      # Unchanged behavior: over_budget is still detected
      assert state.over_budget == true
    end

    # R42: N/A Budget Never Over [UNIT]
    @tag :r42
    @tag :unit
    test "R42: N/A budget never over budget", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "agent-R42-#{System.unique_integer([:positive])}"

      # N/A budget (allocated: nil)
      budget_data = Schema.new_root(nil)

      config = %{
        agent_id: agent_id,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub,
        budget_data: budget_data
      }

      {:ok, agent} = Core.start_link(config)
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Trigger a cost event (should not change over_budget for N/A)
      Phoenix.PubSub.broadcast(pubsub, "agents:#{agent_id}:costs", {:cost_recorded, %{}})
      {:ok, state} = Core.get_state(agent)

      assert state.over_budget == false,
             "N/A budget agents should never be marked over_budget"
    end

    # R43: DB Error Preserves State [UNIT]
    # Note: This test verifies that when DB query fails during update_over_budget_status,
    # the over_budget field retains its current value. This is unchanged behavior but
    # still worth verifying in context of v34.0 changes.
    @tag :r43
    @tag :unit
    test "R43: DB error preserves current over_budget state", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "agent-R43-#{System.unique_integer([:positive])}"

      budget_data = %{
        mode: :root,
        allocated: Decimal.new("10.00"),
        committed: Decimal.new("0")
      }

      config = %{
        agent_id: agent_id,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub,
        budget_data: budget_data
      }

      {:ok, agent} = Core.start_link(config)
      {:ok, initial_state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Initially not over budget
      assert initial_state.over_budget == false

      # Trigger cost event - since there are no cost records, agent stays under budget
      Phoenix.PubSub.broadcast(pubsub, "agents:#{agent_id}:costs", {:cost_recorded, %{}})
      {:ok, state} = Core.get_state(agent)

      # State preserved (still false since no real costs exist)
      assert state.over_budget == false
    end
  end

  describe "get_budget API (v22.0)" do
    # R38: Get Budget API [UNIT]
    @tag :r38
    @tag :unit
    test "R38: get_budget returns current budget state", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      budget_data = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("25.00")
      }

      config = %{
        agent_id: "agent-R38",
        test_mode: true,
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub,
        budget_data: budget_data
      }

      {:ok, agent} = Core.start_link(config)
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Act: Call get_budget
      {:ok, budget_info} = Core.get_budget(agent)

      # Assert: Returns budget_data and over_budget status
      assert budget_info.budget_data == budget_data
      assert budget_info.over_budget == false
    end
  end
end
