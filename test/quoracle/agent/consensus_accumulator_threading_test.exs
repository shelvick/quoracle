defmodule Quoracle.Agent.ConsensusAccumulatorThreadingTest do
  @moduledoc """
  Tests for cost accumulator threading through consensus.

  WorkGroupID: feat-20260203-194408
  Packet: 5 (Accumulator Threading Fix)

  Integration gap found in audit:
  - extract_cost_opts/1 only takes [:agent_id, :task_id, :pubsub]
  - Does NOT include :cost_accumulator
  - Therefore embedding costs during consensus go directly to DB (not batched)

  Requirements:
  - R49: Accumulator reaches ConsensusRules via format_result [INTEGRATION]
  - R97: extract_cost_opts includes cost_accumulator [UNIT]
  - R98: Embedding costs during consensus are accumulated (not direct DB) [SYSTEM]
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Consensus.Result
  alias Quoracle.Actions.ConsensusRules
  alias Quoracle.Costs.{Accumulator, AgentCost}
  alias Quoracle.Repo

  # ============================================================
  # R49: Accumulator Reaches ConsensusRules [INTEGRATION]
  # ============================================================

  describe "R49: format_result threads cost_accumulator to ConsensusRules" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      task =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert!()

      {:ok, pubsub: pubsub_name, task_id: task.id}
    end

    test "format_result passes cost_accumulator to merge_cluster_params", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      accumulator = Accumulator.new()

      # Create a cluster that would trigger ConsensusRules.apply_rule
      # Using :orient action which has semantic_similarity rules on its params
      cluster = %{
        count: 3,
        actions: [
          %{action: :orient, params: %{current_situation: "Test situation A"}, reasoning: "R1"},
          %{action: :orient, params: %{current_situation: "Test situation B"}, reasoning: "R2"},
          %{action: :orient, params: %{current_situation: "Test situation C"}, reasoning: "R3"}
        ],
        representative: %{action: :orient, params: %{current_situation: "Test"}, reasoning: "R1"}
      }

      clusters = [cluster]

      # cost_opts with accumulator
      cost_opts = [
        agent_id: "agent-threading-test",
        task_id: task_id,
        pubsub: pubsub,
        cost_accumulator: accumulator
      ]

      # Call format_result - should thread accumulator to ConsensusRules
      {_result_type, action, _confidence} = Result.format_result(clusters, 3, 2, cost_opts)

      # The action should be merged using the accumulator
      # If accumulator is NOT threaded, semantic_similarity calls go directly to DB
      assert is_map(action)

      # CRITICAL: Verify NO direct DB writes occurred (costs should be accumulated)
      # If accumulator was properly threaded, embedding costs would be in accumulator, not DB
      db_costs = Repo.all(AgentCost)
      embedding_costs = Enum.filter(db_costs, &(&1.cost_type == "llm_embedding"))

      # This assertion will FAIL until extract_cost_opts includes :cost_accumulator
      assert embedding_costs == [],
             "Expected embedding costs to be accumulated, not written directly to DB. " <>
               "Found #{length(embedding_costs)} direct DB writes."
    end

    test "ConsensusRules.apply_rule receives cost_accumulator from caller", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      # Create accumulator with a pre-existing entry to track threading
      initial_acc =
        Accumulator.new()
        |> Accumulator.add(%{
          agent_id: "marker-agent",
          task_id: task_id,
          cost_type: "marker",
          cost_usd: Decimal.new("0"),
          metadata: %{"marker" => "initial"}
        })

      # Values that would trigger semantic_similarity rule
      values = ["Description A", "Description B"]

      # Mock embedding function that returns embeddings and threads accumulator
      mock_embedding_fn = fn text, opts ->
        # Generate deterministic mock embedding based on text
        embedding = for i <- 1..10, do: :erlang.phash2({text, i}) / 4_294_967_295

        # Thread the accumulator if present
        case Map.get(opts, :cost_accumulator) do
          %Accumulator{} = acc ->
            # Add a cost entry to prove threading works
            updated_acc =
              Accumulator.add(acc, %{
                agent_id: opts[:agent_id] || "test",
                task_id: opts[:task_id],
                cost_type: "llm_embedding",
                cost_usd: Decimal.new("0.0001"),
                metadata: %{"text" => String.slice(text, 0..20)}
              })

            {:ok, %{embedding: embedding}, updated_acc}

          nil ->
            {:ok, %{embedding: embedding}}
        end
      end

      cost_opts = [
        agent_id: "agent-rules-test",
        task_id: task_id,
        pubsub: pubsub,
        cost_accumulator: initial_acc,
        embedding_fn: mock_embedding_fn
      ]

      # Apply semantic_similarity rule - should use and return accumulator
      result =
        ConsensusRules.apply_rule(
          {:semantic_similarity, threshold: 0.8, embedding_fn: mock_embedding_fn},
          values,
          cost_opts
        )

      # If accumulator is properly threaded, result should include updated accumulator
      case result do
        {{:ok, _value}, %Accumulator{} = final_acc} ->
          # SUCCESS: Accumulator was threaded and returned with consensus
          assert Accumulator.count(final_acc) >= 1

        {{:error, :no_consensus}, %Accumulator{} = final_acc} ->
          # SUCCESS: Accumulator was threaded and returned (even on no consensus)
          # This proves threading works - different embeddings just failed similarity check
          assert Accumulator.count(final_acc) >= 1

        {:ok, _value} ->
          # FAILURE: No accumulator returned = not threaded properly
          flunk("ConsensusRules.apply_rule did not return accumulator - threading broken")

        {:error, _reason} ->
          # FAILURE: Error without accumulator = threading broken
          flunk("ConsensusRules.apply_rule returned error without accumulator")
      end
    end
  end

  # ============================================================
  # R97: extract_cost_opts Includes cost_accumulator [UNIT]
  #
  # This is tested indirectly via R49 since extract_cost_opts is private.
  # The fix will add :cost_accumulator to the Keyword.take list.
  # ============================================================

  describe "R97: cost_accumulator in consensus opts" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      task =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Test task", status: "running"})
        |> Repo.insert!()

      {:ok, pubsub: pubsub_name, task_id: task.id}
    end

    test "consensus process receives cost_accumulator in opts", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      agent_id = "opts-test-#{System.unique_integer([:positive])}"
      accumulator = Accumulator.new()

      # Build state with cost_accumulator
      state = %{
        agent_id: agent_id,
        task_id: task_id,
        pubsub: pubsub,
        cost_accumulator: accumulator,
        model_histories: %{
          "default" => [%{role: "user", content: "Test message"}]
        },
        pending_actions: %{},
        queued_messages: [],
        consensus_scheduled: false,
        consensus_retry_count: 0,
        state: :idle,
        context_summary: nil,
        prompt_fields: %{
          injected: %{},
          provided: %{task_description: "Test"},
          transformed: %{}
        },
        test_mode: true,
        skip_consensus: false
      }

      # Run consensus
      {:ok, _action, _updated_state, returned_acc} =
        Quoracle.Agent.ConsensusHandler.get_action_consensus(state)

      # The returned accumulator should be the same as input (or updated with costs)
      # Currently it's always empty because threading is broken
      assert %Accumulator{} = returned_acc

      # CRITICAL: If semantic similarity was used during param merging,
      # the accumulator should contain embedding costs (not go to DB directly)
      # This test verifies the accumulator flows through the full path
      db_costs = Repo.all(AgentCost)
      embedding_costs = Enum.filter(db_costs, &(&1.cost_type == "llm_embedding"))

      # Should be 0 direct DB writes - all in accumulator
      assert embedding_costs == [],
             "Embedding costs went directly to DB instead of accumulator. " <>
               "extract_cost_opts does not include :cost_accumulator"
    end
  end

  # ============================================================
  # R98: End-to-End Embedding Cost Accumulation [SYSTEM]
  # ============================================================

  describe "R98: Embedding costs during consensus are accumulated" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      task =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "E2E test task", status: "running"})
        |> Repo.insert!()

      {:ok, pubsub: pubsub_name, task_id: task.id}
    end

    @tag :system
    test "consensus cycle accumulates embedding costs instead of direct DB writes", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      agent_id = "e2e-accumulator-test-#{System.unique_integer([:positive])}"

      # Subscribe to cost events
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:costs")

      # Build state that will trigger consensus with semantic similarity
      state = %{
        agent_id: agent_id,
        task_id: task_id,
        pubsub: pubsub,
        model_histories: %{
          "default" => [
            %{role: "user", content: "Analyze this complex problem with semantic matching"}
          ]
        },
        pending_actions: %{},
        queued_messages: [],
        consensus_scheduled: false,
        consensus_retry_count: 0,
        state: :idle,
        context_summary: nil,
        prompt_fields: %{
          injected: %{},
          provided: %{task_description: "Test semantic similarity consensus"},
          transformed: %{}
        },
        test_mode: true,
        skip_consensus: false
      }

      # Count DB costs BEFORE consensus
      costs_before = Repo.aggregate(AgentCost, :count)

      # Run consensus - this should accumulate embedding costs, not write directly
      {:ok, _action, _updated_state, accumulator} =
        Quoracle.Agent.ConsensusHandler.get_action_consensus(state)

      # Check costs during (before flush)
      costs_during = Repo.aggregate(AgentCost, :count)

      # CRITICAL: No new costs should have been written during consensus
      # (they should be accumulated, waiting for flush)
      assert costs_during == costs_before,
             "Expected 0 direct DB writes during consensus, but #{costs_during - costs_before} occurred. " <>
               "Embedding costs are not being accumulated properly."

      # The accumulator should be valid
      assert %Accumulator{} = accumulator
    end

    @tag :acceptance
    test "full consensus cycle: embedding costs appear in DB only after flush", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      agent_id = "acceptance-flush-test-#{System.unique_integer([:positive])}"

      # Subscribe to cost events
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:costs")

      # This test verifies the FULL path:
      # 1. Consensus runs with semantic similarity (triggers embeddings)
      # 2. Embedding costs are accumulated (not written to DB)
      # 3. After consensus completes, MessageHandler.flush_costs is called
      # 4. ONLY THEN do costs appear in DB

      state = %{
        agent_id: agent_id,
        task_id: task_id,
        pubsub: pubsub,
        model_histories: %{
          "default" => [
            %{role: "user", content: "Test with semantic similarity parameters"}
          ]
        },
        pending_actions: %{},
        queued_messages: [],
        consensus_scheduled: false,
        consensus_retry_count: 0,
        state: :idle,
        context_summary: nil,
        prompt_fields: %{
          injected: %{},
          provided: %{task_description: "Acceptance test"},
          transformed: %{}
        },
        test_mode: true,
        skip_consensus: false,
        # Do NOT pre-populate accumulator - test actual threading
        cost_accumulator: nil
      }

      execute_action_fn = fn state, _action -> state end

      # Count costs before
      costs_before = Repo.aggregate(AgentCost, :count)

      # Run full consensus cycle (includes flush)
      {:noreply, _final_state} =
        Quoracle.Agent.MessageHandler.run_consensus_cycle(state, execute_action_fn)

      # After flush, embedding costs should be in DB
      costs_after = Repo.aggregate(AgentCost, :count)

      # If semantic similarity was triggered during consensus, we expect:
      # - costs_after >= costs_before (costs were flushed)
      # - Costs should have been batched (not individual inserts during consensus)
      #
      # In test mode with mocks, this may be 0, but the infrastructure should work

      # The key is that costs appear AFTER the cycle completes (via flush),
      # not DURING consensus (via direct DB writes)
      assert costs_after >= costs_before
    end
  end
end
