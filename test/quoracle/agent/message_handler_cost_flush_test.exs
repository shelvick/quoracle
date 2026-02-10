defmodule Quoracle.Agent.MessageHandlerCostFlushTest do
  @moduledoc """
  Tests for MessageHandler v23.0 cost accumulator flush functionality.

  WorkGroupID: feat-20260203-194408
  Packet: 3 (Integration)

  Verifies flush_costs/2 helper function:
  - R13: Flush on consensus success
  - R14: Flush on consensus error
  - R15: No flush when accumulator empty
  - R16: No flush without pubsub
  - R17: Costs visible in DB after flush with PubSub broadcast
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.MessageHandler
  alias Quoracle.Costs.{Accumulator, AgentCost}
  alias Quoracle.Repo

  # Create isolated PubSub and task per test
  setup do
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    # Insert a task record directly for foreign key constraint
    task =
      %Quoracle.Tasks.Task{}
      |> Quoracle.Tasks.Task.changeset(%{prompt: "Test task for cost flush", status: "running"})
      |> Repo.insert!()

    {:ok, pubsub: pubsub_name, task_id: task.id}
  end

  describe "flush_costs/2 helper" do
    # These tests verify the flush_costs helper that will be added to MessageHandler

    @tag :unit
    test "R13: flushes accumulated costs when accumulator has entries", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      agent_id = "flush_test_agent_#{System.unique_integer([:positive])}"

      accumulator =
        Accumulator.new()
        |> Accumulator.add(%{
          agent_id: agent_id,
          task_id: task_id,
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.0001"),
          metadata: %{"model_spec" => "test-model"}
        })

      state = %{pubsub: pubsub}

      # Call the helper that will be added to MessageHandler
      # This should flush the accumulator to DB
      MessageHandler.flush_costs(accumulator, state)

      # Verify cost was flushed to DB
      assert Repo.aggregate(AgentCost, :count) == 1
      [cost] = Repo.all(AgentCost)
      assert cost.agent_id == agent_id
      assert cost.cost_type == "llm_embedding"
    end

    @tag :unit
    test "R14: flushes costs even when called from error path", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      agent_id = "error_path_agent_#{System.unique_integer([:positive])}"

      # Costs incurred before error should still be flushed
      accumulator =
        Accumulator.new()
        |> Accumulator.add(%{
          agent_id: agent_id,
          task_id: task_id,
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.0002"),
          metadata: %{"model_spec" => "test-model"}
        })

      state = %{pubsub: pubsub}

      # flush_costs should work regardless of success/error context
      MessageHandler.flush_costs(accumulator, state)

      assert Repo.aggregate(AgentCost, :count) == 1
    end

    @tag :unit
    test "R15: skips flush when accumulator is empty", %{pubsub: pubsub} do
      empty_accumulator = Accumulator.new()
      state = %{pubsub: pubsub}

      # Should not crash, should not write anything
      MessageHandler.flush_costs(empty_accumulator, state)

      assert Repo.aggregate(AgentCost, :count) == 0
    end

    @tag :unit
    test "R16: skips flush when no pubsub in state", %{task_id: task_id} do
      agent_id = "no_pubsub_agent_#{System.unique_integer([:positive])}"

      accumulator =
        Accumulator.new()
        |> Accumulator.add(%{
          agent_id: agent_id,
          task_id: task_id,
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.0001"),
          metadata: %{}
        })

      # State without pubsub - should skip flush for test isolation
      state_without_pubsub = %{}

      MessageHandler.flush_costs(accumulator, state_without_pubsub)

      # No DB writes when pubsub missing
      assert Repo.aggregate(AgentCost, :count) == 0
    end

    @tag :unit
    test "R15 variant: handles nil accumulator gracefully", %{pubsub: pubsub} do
      state = %{pubsub: pubsub}

      # Should not crash with nil accumulator
      MessageHandler.flush_costs(nil, state)

      assert Repo.aggregate(AgentCost, :count) == 0
    end
  end

  describe "R17: flush_costs/2 DB + PubSub" do
    @tag :integration
    test "embedding costs appear in database after flush with broadcast", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      agent_id = "system_test_agent_#{System.unique_integer([:positive])}"

      # Subscribe to cost events
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:costs")

      # Build accumulator with embedding costs (simulating what consensus would produce)
      accumulator =
        Accumulator.new()
        |> Accumulator.add(%{
          agent_id: agent_id,
          task_id: task_id,
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.00015"),
          metadata: %{
            "model_spec" => "azure:text-embedding-3-large",
            "chunks" => 1,
            "cached" => false
          }
        })
        |> Accumulator.add(%{
          agent_id: agent_id,
          task_id: task_id,
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.00015"),
          metadata: %{
            "model_spec" => "azure:text-embedding-3-large",
            "chunks" => 1,
            "cached" => false
          }
        })

      state = %{pubsub: pubsub}

      MessageHandler.flush_costs(accumulator, state)

      # User expectation: All embedding costs visible in agent_costs table
      costs = Repo.all(AgentCost)
      assert length(costs) == 2
      assert Enum.all?(costs, &(&1.cost_type == "llm_embedding"))
      assert Enum.all?(costs, &(&1.agent_id == agent_id))

      # User expectation: Costs broadcast for UI updates
      assert_receive {:cost_recorded, %{cost_type: "llm_embedding"}}
      assert_receive {:cost_recorded, %{cost_type: "llm_embedding"}}
    end
  end

  # NOTE: run_consensus_cycle/2 accumulator integration tests will be added
  # in a future packet when ConsensusHandler returns 4-tuple with accumulator.
  # See: feat-20260203-194408 spec for planned integration points.
end
