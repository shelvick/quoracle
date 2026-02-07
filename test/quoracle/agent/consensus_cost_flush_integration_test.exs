defmodule Quoracle.Agent.ConsensusCostFlushIntegrationTest do
  @moduledoc """
  Integration tests for cost accumulator flush during consensus cycle.

  WorkGroupID: feat-20260203-194408
  Packet: 4 (Integration Fix)

  Tests the integration gap found in audit:
  - R18: ConsensusHandler.get_action_consensus/1 returns 4-tuple with accumulator
  - R19: run_consensus_cycle/2 flushes accumulated costs after consensus
  - R20: Costs from semantic similarity during consensus are recorded to DB

  These tests will FAIL until the integration is implemented.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.{ConsensusHandler, MessageHandler}
  alias Quoracle.Costs.{Accumulator, AgentCost}
  alias Quoracle.Repo

  # Create isolated PubSub and task per test
  setup do
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    task =
      %Quoracle.Tasks.Task{}
      |> Quoracle.Tasks.Task.changeset(%{
        prompt: "Test task for consensus flush",
        status: "running"
      })
      |> Repo.insert!()

    {:ok, pubsub: pubsub_name, task_id: task.id}
  end

  describe "R18: ConsensusHandler returns accumulator" do
    @tag :integration
    test "get_action_consensus/1 returns 4-tuple with accumulator when embeddings used", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      agent_id = "consensus_acc_test_#{System.unique_integer([:positive])}"

      # Build minimal state that would trigger semantic similarity
      # (which uses embeddings internally)
      state = build_consensus_state(agent_id, task_id, pubsub)

      # The key assertion: ConsensusHandler should return accumulator as 4th element
      assert {:ok, action, updated_state, %Accumulator{} = accumulator} =
               ConsensusHandler.get_action_consensus(state)

      assert is_map(action)
      assert is_map(updated_state)
      assert %Accumulator{} = accumulator
    end
  end

  describe "R19: run_consensus_cycle flushes costs" do
    @tag :integration
    test "run_consensus_cycle/2 flushes accumulated costs to database", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      agent_id = "cycle_flush_test_#{System.unique_integer([:positive])}"

      # Subscribe to verify broadcasts
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:costs")

      # Build state with pre-populated accumulator (simulating costs from consensus)
      initial_acc =
        Accumulator.new()
        |> Accumulator.add(%{
          agent_id: agent_id,
          task_id: task_id,
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.0001"),
          metadata: %{"model_spec" => "azure:text-embedding-3-large"}
        })

      # Build state that will go through consensus cycle
      state =
        build_consensus_state(agent_id, task_id, pubsub)
        |> Map.put(:cost_accumulator, initial_acc)

      # Mock execute_action_fn that just returns state
      execute_action_fn = fn state, _action -> state end

      # Mock consensus to return immediately with accumulator
      mock_consensus_fn = fn _state ->
        {:ok, %{action_type: :orient, reasoning: "test"}, %{}, initial_acc}
      end

      # Override consensus_fn in state for test isolation
      state_with_mock = Map.put(state, :consensus_fn, mock_consensus_fn)

      # Run consensus cycle - this SHOULD flush the accumulator
      {:noreply, _final_state} =
        MessageHandler.run_consensus_cycle(state_with_mock, execute_action_fn)

      # CRITICAL ASSERTION: Costs should be in DB after cycle
      # This will FAIL because flush_costs is never called in current implementation
      costs = Repo.all(AgentCost)
      assert costs != [], "Expected costs to be flushed to DB after consensus cycle"
      assert Enum.all?(costs, &(&1.cost_type == "llm_embedding"))

      # Should also have received broadcast
      assert_receive {:cost_recorded, %{cost_type: "llm_embedding"}}, 1000
    end

    @tag :integration
    test "run_consensus_cycle/2 flushes costs even on consensus error", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      agent_id = "error_flush_test_#{System.unique_integer([:positive])}"

      # Pre-populated accumulator with costs incurred before error
      initial_acc =
        Accumulator.new()
        |> Accumulator.add(%{
          agent_id: agent_id,
          task_id: task_id,
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.0002"),
          metadata: %{}
        })

      state =
        build_consensus_state(agent_id, task_id, pubsub)
        |> Map.put(:cost_accumulator, initial_acc)

      execute_action_fn = fn state, _action -> state end

      # Mock consensus that returns error with accumulator
      mock_consensus_fn = fn _state ->
        {:error, :all_models_failed, initial_acc}
      end

      state_with_mock = Map.put(state, :consensus_fn, mock_consensus_fn)

      # Run cycle - should still flush costs despite error
      {:noreply, _final_state} =
        MessageHandler.run_consensus_cycle(state_with_mock, execute_action_fn)

      # Costs should still be in DB (work was done before error)
      # This will FAIL because current error path doesn't return accumulator
      costs = Repo.all(AgentCost)
      assert costs != [], "Expected costs to be flushed even on consensus error"
    end
  end

  describe "R20: End-to-end consensus with embeddings" do
    @tag :system
    test "accumulated embedding costs are flushed after consensus cycle", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      agent_id = "e2e_embedding_test_#{System.unique_integer([:positive])}"

      # Subscribe to cost events
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:costs")

      # Pre-populate accumulator with embedding costs (simulating costs from semantic similarity)
      # Full pipeline threading through Consensus.get_consensus_with_state is future work
      initial_acc =
        Accumulator.new()
        |> Accumulator.add(%{
          agent_id: agent_id,
          task_id: task_id,
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.00015"),
          metadata: %{
            "model_spec" => "azure:text-embedding-3-large",
            "source" => "semantic_similarity"
          }
        })
        |> Accumulator.add(%{
          agent_id: agent_id,
          task_id: task_id,
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.00015"),
          metadata: %{
            "model_spec" => "azure:text-embedding-3-large",
            "source" => "semantic_similarity"
          }
        })

      state =
        build_consensus_state(agent_id, task_id, pubsub)
        |> Map.put(:cost_accumulator, initial_acc)

      execute_action_fn = fn state, _action -> state end

      # Run consensus cycle - should flush the pre-populated accumulator
      {:noreply, _final_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

      # CRITICAL: After consensus cycle completes, embedding costs should be in DB
      costs = Repo.all(AgentCost)
      embedding_costs = Enum.filter(costs, &(&1.cost_type == "llm_embedding"))

      assert embedding_costs != [],
             "Expected embedding costs in DB after consensus cycle"

      assert length(embedding_costs) == 2
      assert Enum.all?(embedding_costs, &(&1.agent_id == agent_id))

      # Should have received broadcasts
      assert_receive {:cost_recorded, %{cost_type: "llm_embedding"}}, 1000
      assert_receive {:cost_recorded, %{cost_type: "llm_embedding"}}, 1000
    end
  end

  # Helper to build minimal state for consensus
  defp build_consensus_state(agent_id, task_id, pubsub) do
    %{
      agent_id: agent_id,
      task_id: task_id,
      pubsub: pubsub,
      model_histories: %{},
      pending_actions: %{},
      queued_messages: [],
      consensus_scheduled: false,
      consensus_retry_count: 0,
      state: :idle,
      context_summary: nil,
      prompt_fields: %{
        injected: %{},
        provided: %{task_description: "Test task"},
        transformed: %{}
      },
      # Required for consensus
      test_mode: true,
      skip_consensus: false
    }
  end
end
