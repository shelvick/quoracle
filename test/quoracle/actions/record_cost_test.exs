defmodule Quoracle.Actions.RecordCostTest do
  @moduledoc """
  Tests for ACTION_RecordCost - Record Cost Action.

  WorkGroupID: wip-20251231-budget
  Packet: Packet 7 (Record Cost Action)
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.RecordCost
  alias Quoracle.Costs.AgentCost
  alias Quoracle.Repo

  # Setup isolated PubSub for each test
  setup do
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    # Create task for cost recording
    {:ok, task} =
      Repo.insert(%Quoracle.Tasks.Task{
        prompt: "Test task for record_cost",
        status: "running"
      })

    {:ok, pubsub: pubsub_name, task_id: task.id}
  end

  describe "execute/3 - UNIT tests" do
    # R1: Record Valid Amount [UNIT]
    test "R1: records positive amount successfully", %{pubsub: pubsub, task_id: task_id} do
      params = %{amount: 10.50, description: "API call cost"}

      result = RecordCost.execute(params, "agent_123", pubsub: pubsub, task_id: task_id)

      assert {:ok, response} = result
      assert response.action == "record_cost"
      assert response.amount == "10.5"
      assert response.message =~ "$10.5"
    end

    # R2: Reject Negative Amount [UNIT]
    test "R2: rejects negative amount", %{pubsub: pubsub, task_id: task_id} do
      params = %{amount: -5.00}

      result = RecordCost.execute(params, "agent_123", pubsub: pubsub, task_id: task_id)

      assert {:error, :invalid_amount} = result
    end

    # R3: Reject Zero Amount [UNIT]
    test "R3: rejects zero amount", %{pubsub: pubsub, task_id: task_id} do
      params = %{amount: 0}

      result = RecordCost.execute(params, "agent_123", pubsub: pubsub, task_id: task_id)

      assert {:error, :invalid_amount} = result
    end

    # R4: Float to Decimal Conversion [UNIT]
    test "R4: converts float to Decimal correctly", %{pubsub: pubsub, task_id: task_id} do
      params = %{amount: 0.99}

      result = RecordCost.execute(params, "agent_123", pubsub: pubsub, task_id: task_id)

      assert {:ok, response} = result
      # Float 0.99 should convert without precision loss
      assert response.amount == "0.99"
    end

    # R5: Integer to Decimal Conversion [UNIT]
    test "R5: converts integer to Decimal correctly", %{pubsub: pubsub, task_id: task_id} do
      params = %{amount: 10}

      result = RecordCost.execute(params, "agent_123", pubsub: pubsub, task_id: task_id)

      assert {:ok, response} = result
      assert response.amount == "10"
    end

    # R11: Return Amount in Response [UNIT]
    test "R11: returns amount in response", %{pubsub: pubsub, task_id: task_id} do
      params = %{amount: 25.75}

      result = RecordCost.execute(params, "agent_123", pubsub: pubsub, task_id: task_id)

      assert {:ok, response} = result
      assert Map.has_key?(response, :amount)
      assert response.amount == "25.75"
    end
  end

  describe "execute/3 - INTEGRATION tests" do
    # R6: Store Description [INTEGRATION]
    test "R6: stores description in metadata", %{pubsub: pubsub, task_id: task_id} do
      params = %{amount: 5.00, description: "OpenAI API call"}

      result = RecordCost.execute(params, "agent_int_1", pubsub: pubsub, task_id: task_id)

      assert {:ok, _response} = result

      # Verify description in database
      cost = Repo.one(from(c in AgentCost, where: c.agent_id == "agent_int_1"))
      assert cost.metadata["description"] == "OpenAI API call"
    end

    # R7: Store Category [INTEGRATION]
    test "R7: stores category in metadata", %{pubsub: pubsub, task_id: task_id} do
      params = %{amount: 3.50, category: "cloud_compute"}

      result = RecordCost.execute(params, "agent_int_2", pubsub: pubsub, task_id: task_id)

      assert {:ok, _response} = result

      # Verify category in database
      cost = Repo.one(from(c in AgentCost, where: c.agent_id == "agent_int_2"))
      assert cost.metadata["category"] == "cloud_compute"
    end

    # R8: Store Reference ID [INTEGRATION]
    test "R8: stores external_reference_id in metadata", %{pubsub: pubsub, task_id: task_id} do
      params = %{amount: 7.25, external_reference_id: "inv-12345"}

      result = RecordCost.execute(params, "agent_int_3", pubsub: pubsub, task_id: task_id)

      assert {:ok, _response} = result

      # Verify reference ID in database
      cost = Repo.one(from(c in AgentCost, where: c.agent_id == "agent_int_3"))
      assert cost.metadata["external_reference_id"] == "inv-12345"
    end

    # R9: Cost Type External [INTEGRATION]
    test "R9: uses external cost_type", %{pubsub: pubsub, task_id: task_id} do
      params = %{amount: 2.00}

      result = RecordCost.execute(params, "agent_int_4", pubsub: pubsub, task_id: task_id)

      assert {:ok, _response} = result

      # Verify cost_type in database
      cost = Repo.one(from(c in AgentCost, where: c.agent_id == "agent_int_4"))
      assert cost.cost_type == "external"
    end

    # R10: PubSub Broadcast [INTEGRATION]
    test "R10: broadcasts cost_recorded event", %{pubsub: pubsub, task_id: task_id} do
      # Subscribe to task costs topic
      Phoenix.PubSub.subscribe(pubsub, "tasks:#{task_id}:costs")

      params = %{amount: 15.00, description: "Test broadcast"}

      result = RecordCost.execute(params, "agent_int_5", pubsub: pubsub, task_id: task_id)

      assert {:ok, _response} = result

      # Should receive broadcast
      assert_receive {:cost_recorded, event}, 30_000
      assert event.agent_id == "agent_int_5"
      assert event.cost_type == "external"
    end
  end
end
