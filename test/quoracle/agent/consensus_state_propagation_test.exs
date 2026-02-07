defmodule Quoracle.Agent.ConsensusStatePropagationTest do
  @moduledoc """
  Tests for v12.0 Condensation State Propagation fix.

  WorkGroupID: fix-20260103-condensation-state
  Packet 1: AGENT_Consensus - Return {:ok, result, updated_state}

  Problem: When condense_model_history_with_reflection runs during consensus,
  the updated state (with condensed histories, lessons, model_states) is lost
  because query_models_with_per_model_histories returns {:ok, responses}
  instead of {:ok, responses, updated_state}.

  Fix: Thread state through the consensus pipeline so GenServer can update
  its in-memory state after condensation.
  """

  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Quoracle.Agent.Consensus
  alias Quoracle.Agent.Consensus.PerModelQuery

  # Force ActionList to load - ensures :orient atom exists for String.to_existing_atom/1
  alias Quoracle.Actions.Schema.ActionList
  _ = ActionList.actions()

  # ============================================================================
  # R54: PerModelQuery Returns Updated State
  # ============================================================================

  describe "R54: PerModelQuery Returns Updated State" do
    test "query_models_with_per_model_histories returns 3-tuple with state" do
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "Test message", timestamp: DateTime.utc_now()}
          ]
        },
        context_lessons: %{},
        model_states: %{},
        test_mode: true
      }

      model_pool = ["model-a"]
      opts = [test_mode: true]

      # Current implementation returns {:ok, responses}
      # After fix, should return {:ok, responses, updated_state}
      result = PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      # This assertion will FAIL until implementation is updated
      assert {:ok, responses, returned_state} = result
      assert is_list(responses)
      assert is_map(returned_state)
      assert Map.has_key?(returned_state, :model_histories)
    end

    test "returned state contains model_histories field" do
      state = %{
        model_histories: %{
          "model-a" => [%{type: :user, content: "Test", timestamp: DateTime.utc_now()}]
        },
        context_lessons: %{"model-a" => []},
        model_states: %{"model-a" => nil},
        test_mode: true
      }

      model_pool = ["model-a"]
      opts = [test_mode: true]

      {:ok, _responses, returned_state} =
        PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      assert Map.has_key?(returned_state, :model_histories)
      assert Map.has_key?(returned_state, :context_lessons)
      assert Map.has_key?(returned_state, :model_states)
    end
  end

  # ============================================================================
  # R55: State Accumulates Across Models
  # ============================================================================

  describe "R55: State Accumulates Across Models" do
    test "final state contains all model condensations" do
      # Create state where multiple models have histories that could be condensed
      state = %{
        model_histories: %{
          "model-a" => build_large_history(20),
          "model-b" => build_large_history(20)
        },
        context_lessons: %{"model-a" => [], "model-b" => []},
        model_states: %{"model-a" => nil, "model-b" => nil},
        test_mode: true
      }

      # Mock reflector to return different lessons for each model
      reflector_fn = fn _messages, model_id, _opts ->
        {:ok,
         %{
           lessons: [%{type: :factual, content: "Lesson from #{model_id}", confidence: 1}],
           state: [%{summary: "State from #{model_id}", updated_at: DateTime.utc_now()}]
         }}
      end

      model_pool = ["model-a", "model-b"]
      # force_condense: true bypasses token threshold check for test isolation
      opts = [test_mode: true, force_condense: true, reflector_fn: reflector_fn]

      {:ok, _responses, returned_state} =
        PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      # Both models' condensation updates should be in the final state
      assert Map.has_key?(returned_state.context_lessons, "model-a")
      assert Map.has_key?(returned_state.context_lessons, "model-b")

      # Each model should have its own lessons
      lessons_a = returned_state.context_lessons["model-a"]
      lessons_b = returned_state.context_lessons["model-b"]

      assert Enum.any?(lessons_a, &String.contains?(&1.content, "model-a"))
      assert Enum.any?(lessons_b, &String.contains?(&1.content, "model-b"))
    end
  end

  # ============================================================================
  # R56: Consensus Returns Updated State
  # ============================================================================

  describe "R56: Consensus Returns Updated State" do
    test "get_consensus_with_state returns 3-tuple with state" do
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "What action?", timestamp: DateTime.utc_now()}
          ]
        },
        context_lessons: %{},
        model_states: %{},
        test_mode: true
      }

      opts = [test_mode: true, model_pool: ["model-a"]]

      # Current implementation returns {:ok, result}
      # After fix, should return {:ok, result, updated_state}
      result = Consensus.get_consensus_with_state(state, opts)

      # This assertion will FAIL until implementation is updated
      assert {:ok, consensus_result, returned_state} = result
      # Consensus result is a 3-tuple: {result_type, action, meta}
      assert is_tuple(consensus_result)
      assert tuple_size(consensus_result) == 3
      assert is_map(returned_state)
    end

    test "consensus result structure unchanged" do
      state = %{
        model_histories: %{
          "model-a" => [%{type: :user, content: "Task", timestamp: DateTime.utc_now()}]
        },
        test_mode: true
      }

      opts = [test_mode: true, model_pool: ["model-a"]]

      {:ok, consensus_result, _returned_state} = Consensus.get_consensus_with_state(state, opts)

      # Consensus result should still be the same structure
      assert {:ok, {result_type, _action, _meta}} = {:ok, consensus_result}
      assert result_type in [:consensus, :forced_decision]
    end
  end

  # ============================================================================
  # R57: Context Lessons Propagated
  # ============================================================================

  describe "R57: Context Lessons Propagated" do
    @tag :integration
    test "condensation lessons present in returned state" do
      # Create state with history large enough to trigger condensation
      state = %{
        model_histories: %{
          "model-a" => build_large_history(50)
        },
        context_lessons: %{"model-a" => []},
        model_states: %{"model-a" => nil},
        test_mode: true
      }

      # Mock reflector to return lessons
      reflector_fn = fn _messages, _model_id, _opts ->
        {:ok,
         %{
           lessons: [
             %{type: :factual, content: "Extracted lesson from condensation", confidence: 2}
           ],
           state: []
         }}
      end

      # force_condense: true bypasses token threshold check for test isolation
      opts = [
        test_mode: true,
        force_condense: true,
        model_pool: ["model-a"],
        reflector_fn: reflector_fn
      ]

      {:ok, _result, returned_state} = Consensus.get_consensus_with_state(state, opts)

      # Lessons extracted during condensation should be in returned state
      lessons = returned_state.context_lessons["model-a"]
      assert lessons != []
      assert Enum.any?(lessons, &(&1.content == "Extracted lesson from condensation"))
    end
  end

  # ============================================================================
  # R58: Model States Propagated
  # ============================================================================

  describe "R58: Model States Propagated" do
    @tag :integration
    test "condensation model_states present in returned state" do
      state = %{
        model_histories: %{
          "model-a" => build_large_history(50)
        },
        context_lessons: %{"model-a" => []},
        model_states: %{"model-a" => nil},
        test_mode: true
      }

      # Mock reflector to return model state
      reflector_fn = fn _messages, _model_id, _opts ->
        {:ok,
         %{
           lessons: [],
           state: [
             %{
               summary: "Current working state after condensation",
               updated_at: DateTime.utc_now()
             }
           ]
         }}
      end

      # force_condense: true bypasses token threshold check for test isolation
      opts = [
        test_mode: true,
        force_condense: true,
        model_pool: ["model-a"],
        reflector_fn: reflector_fn
      ]

      {:ok, _result, returned_state} = Consensus.get_consensus_with_state(state, opts)

      # Model state from condensation should be in returned state
      model_state = returned_state.model_states["model-a"]
      assert model_state != nil
      assert model_state.summary == "Current working state after condensation"
    end
  end

  # ============================================================================
  # R59: Model Histories Updated
  # ============================================================================

  describe "R59: Model Histories Updated" do
    @tag :integration
    test "condensation reduces model_histories in returned state" do
      original_history = build_large_history(100)

      state = %{
        model_histories: %{
          # Use a small-context model to ensure condensation triggers
          "openai:gpt-3.5-turbo-0613" => original_history
        },
        context_lessons: %{"openai:gpt-3.5-turbo-0613" => []},
        model_states: %{"openai:gpt-3.5-turbo-0613" => nil},
        test_mode: true
      }

      reflector_fn = fn _messages, _model_id, _opts ->
        {:ok, %{lessons: [], state: []}}
      end

      # force_condense: true bypasses token threshold check for test isolation
      opts = [
        test_mode: true,
        force_condense: true,
        model_pool: ["openai:gpt-3.5-turbo-0613"],
        reflector_fn: reflector_fn
      ]

      {:ok, _result, returned_state} = Consensus.get_consensus_with_state(state, opts)

      # History should be condensed in returned state
      returned_history = returned_state.model_histories["openai:gpt-3.5-turbo-0613"]
      assert length(returned_history) < length(original_history)
    end
  end

  # ============================================================================
  # R60: Error Path Unchanged
  # ============================================================================

  describe "R60: Error Path Unchanged" do
    test "error path returns 2-tuple unchanged" do
      state = %{
        model_histories: %{
          "model-a" => [%{type: :user, content: "Test", timestamp: DateTime.utc_now()}]
        },
        test_mode: true
      }

      # Simulate all models failing
      opts = [test_mode: true, model_pool: ["model-a"], simulate_failure: true]

      result = PerModelQuery.query_models_with_per_model_histories(state, ["model-a"], opts)

      # Error path should still return 2-tuple {:error, reason}
      assert {:error, :all_models_failed} = result
    end

    test "consensus error path returns 2-tuple" do
      state = %{
        model_histories: %{
          "model-a" => [%{type: :user, content: "Test", timestamp: DateTime.utc_now()}]
        },
        test_mode: true
      }

      opts = [test_mode: true, model_pool: ["model-a"], simulate_failure: true]

      result = Consensus.get_consensus_with_state(state, opts)

      # Error should still be 2-tuple
      assert {:error, _reason} = result
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Build a large history that would trigger condensation
  defp build_large_history(count) do
    Enum.map(1..count, fn i ->
      %{
        type: :event,
        content: "Message #{i} with some content to take up tokens and trigger condensation",
        timestamp: DateTime.utc_now()
      }
    end)
  end
end
