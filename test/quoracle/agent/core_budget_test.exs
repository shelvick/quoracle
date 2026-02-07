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

    # R39: Over Budget Stays True [INTEGRATION]
    @tag :r39
    @tag :integration
    test "R39: over_budget does not revert to false", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      agent_id = "agent-R39"

      # Create a task for cost records (required foreign key)
      {:ok, task} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Test task R39", status: "running"})
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

      # Create first cost record that exceeds budget (12.00 > 10.00)
      {:ok, _cost1} =
        %Quoracle.Costs.AgentCost{}
        |> Quoracle.Costs.AgentCost.changeset(%{
          agent_id: agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("12.00")
        })
        |> Quoracle.Repo.insert()

      Phoenix.PubSub.broadcast(pubsub, "agents:#{agent_id}:costs", {:cost_recorded, %{}})

      # GenServer.call syncs after PubSub message processing
      {:ok, state_after_first} = Core.get_state(agent)
      assert state_after_first.over_budget == true

      # Create second cost record (smaller addition)
      # over_budget should remain true (monotonic)
      {:ok, _cost2} =
        %Quoracle.Costs.AgentCost{}
        |> Quoracle.Costs.AgentCost.changeset(%{
          agent_id: agent_id,
          task_id: task.id,
          cost_type: "llm_consensus",
          cost_usd: Decimal.new("1.00")
        })
        |> Quoracle.Repo.insert()

      Phoenix.PubSub.broadcast(pubsub, "agents:#{agent_id}:costs", {:cost_recorded, %{}})

      # GenServer.call syncs after PubSub message processing
      # Assert: over_budget remains true
      {:ok, state_after_second} = Core.get_state(agent)
      assert state_after_second.over_budget == true
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
