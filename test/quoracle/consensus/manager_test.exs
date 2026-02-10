defmodule Quoracle.Consensus.ManagerTest do
  @moduledoc """
  Tests for CONSENSUS_Manager.

  v3.0 adds config-driven model selection via CONFIG_ModelSettings.
  """

  # Changed to DataCase for database access (config-driven tests need DB)
  use Quoracle.DataCase, async: true
  alias Quoracle.Consensus.Manager

  # NOTE: Old tests for get_model_pool/0 with hardcoded defaults removed (v3.0)
  # See "[INTEGRATION] config-driven model pool (R1-R4)" tests below

  # NOTE: get_critical_model_pool/0 function removed in v3.0
  # See R4 test below for verification

  describe "get_consensus_threshold/0" do
    test "returns simple majority threshold of 0.5" do
      threshold = Manager.get_consensus_threshold()
      assert threshold == 0.5
    end

    test "returns a float value" do
      threshold = Manager.get_consensus_threshold()
      assert is_float(threshold)
    end

    test "returns consistent value across calls" do
      threshold1 = Manager.get_consensus_threshold()
      threshold2 = Manager.get_consensus_threshold()
      assert threshold1 == threshold2
    end
  end

  describe "get_sliding_window_size/0" do
    test "returns 2 for sliding window size" do
      size = Manager.get_sliding_window_size()
      assert size == 2
    end

    test "returns an integer value" do
      size = Manager.get_sliding_window_size()
      assert is_integer(size)
    end

    test "returns consistent value across calls" do
      size1 = Manager.get_sliding_window_size()
      size2 = Manager.get_sliding_window_size()
      assert size1 == size2
    end
  end

  describe "build_context/2" do
    test "returns map with goal and history" do
      goal = "Analyze the data and provide insights"
      history = [%{role: :user, content: "Previous message"}]

      context = Manager.build_context(goal, history)

      assert is_map(context)
      assert context.prompt == goal
      assert context.conversation_history == history
    end

    test "includes empty reasoning_history" do
      context = Manager.build_context("test goal", [])
      assert Map.has_key?(context, :reasoning_history)
      assert context.reasoning_history == []
    end

    test "includes empty round_proposals" do
      context = Manager.build_context("test goal", [])
      assert Map.has_key?(context, :round_proposals)
      assert context.round_proposals == []
    end

    test "includes start_time" do
      context = Manager.build_context("test goal", [])
      assert Map.has_key?(context, :start_time)
      assert is_integer(context.start_time)
    end

    test "handles empty conversation history" do
      context = Manager.build_context("goal", [])
      assert context.conversation_history == []
    end

    test "handles complex conversation history" do
      history = [
        %{role: :user, content: "First message"},
        %{role: :assistant, content: "Response"},
        %{role: :user, content: "Follow-up"}
      ]

      context = Manager.build_context("goal", history)
      assert context.conversation_history == history
    end
  end

  describe "update_context_with_round/3" do
    setup do
      initial_context = %{
        prompt: "test goal",
        conversation_history: [],
        reasoning_history: [],
        round_proposals: [],
        start_time: System.monotonic_time(:millisecond)
      }

      {:ok, context: initial_context}
    end

    test "adds reasoning from responses to history", %{context: context} do
      responses = [
        %{action: :spawn_child, params: %{task: "analyze"}, reasoning: "Need analysis"},
        %{action: :wait, params: %{wait: 5000}, reasoning: "Wait for data"}
      ]

      updated = Manager.update_context_with_round(context, 1, responses)

      assert length(updated.reasoning_history) == 1
      # v7.0: reasoning_history now stores maps with action+params+reasoning
      round_history = hd(updated.reasoning_history)
      assert Enum.at(round_history, 0).reasoning == "Need analysis"
      assert Enum.at(round_history, 1).reasoning == "Wait for data"
    end

    test "maintains sliding window of reasoning", %{context: context} do
      # Add 3 rounds of reasoning (window size is 2)
      responses = [%{reasoning: "Round 1"}, %{reasoning: "Round 1b"}]
      context1 = Manager.update_context_with_round(context, 1, responses)

      responses2 = [%{reasoning: "Round 2"}, %{reasoning: "Round 2b"}]
      context2 = Manager.update_context_with_round(context1, 2, responses2)

      responses3 = [%{reasoning: "Round 3"}, %{reasoning: "Round 3b"}]
      context3 = Manager.update_context_with_round(context2, 3, responses3)

      # Should only keep last 2 rounds
      assert length(context3.reasoning_history) == 2
      # v7.0: reasoning_history now stores maps with action+params+reasoning
      r2 = Enum.at(context3.reasoning_history, 0)
      assert Enum.at(r2, 0).reasoning == "Round 2"
      assert Enum.at(r2, 1).reasoning == "Round 2b"
      r3 = Enum.at(context3.reasoning_history, 1)
      assert Enum.at(r3, 0).reasoning == "Round 3"
      assert Enum.at(r3, 1).reasoning == "Round 3b"
    end

    test "tracks round proposals for audit", %{context: context} do
      responses = [
        %{action: :spawn_child, params: %{task: "analyze"}, reasoning: "r1"},
        %{action: :wait, params: %{}, reasoning: "r2"}
      ]

      updated = Manager.update_context_with_round(context, 1, responses)

      assert length(updated.round_proposals) == 1
      {round_num, proposals} = hd(updated.round_proposals)
      assert round_num == 1
      assert length(proposals) == 2
      assert Enum.at(proposals, 0) == %{action: :spawn_child, params: %{task: "analyze"}}
      assert Enum.at(proposals, 1) == %{action: :wait, params: %{}}
    end

    test "accumulates proposals across multiple rounds", %{context: context} do
      responses1 = [%{action: :orient, params: %{}, reasoning: "r1"}]
      context1 = Manager.update_context_with_round(context, 1, responses1)

      responses2 = [%{action: :wait, params: %{}, reasoning: "r2"}]
      context2 = Manager.update_context_with_round(context1, 2, responses2)

      assert length(context2.round_proposals) == 2
      assert elem(Enum.at(context2.round_proposals, 0), 0) == 1
      assert elem(Enum.at(context2.round_proposals, 1), 0) == 2
    end

    test "preserves other context fields", %{context: context} do
      responses = [%{action: :wait, params: %{}, reasoning: "test"}]

      updated = Manager.update_context_with_round(context, 1, responses)

      assert updated.prompt == context.prompt
      assert updated.conversation_history == context.conversation_history
      assert updated.start_time == context.start_time
    end

    test "handles empty responses", %{context: context} do
      updated = Manager.update_context_with_round(context, 1, [])

      assert updated.reasoning_history == [[]]
      assert updated.round_proposals == [{1, []}]
    end

    test "handles responses without reasoning field", %{context: context} do
      responses = [
        %{action: :wait, params: %{}},
        %{action: :orient, params: %{}}
      ]

      updated = Manager.update_context_with_round(context, 1, responses)

      # v7.0: reasoning_history now stores maps with action+params+reasoning
      round_history = hd(updated.reasoning_history)
      assert Enum.at(round_history, 0).reasoning == nil
      assert Enum.at(round_history, 1).reasoning == nil
    end
  end

  describe "configuration consistency" do
    test "all configuration methods are pure functions with no side effects" do
      # Call methods multiple times and ensure no state changes
      # NOTE: get_model_pool requires DB config, tested separately in R1-R4
      threshold1 = Manager.get_consensus_threshold()
      Manager.get_sliding_window_size()

      # Call again and verify same results
      threshold2 = Manager.get_consensus_threshold()
      assert threshold1 == threshold2
    end

    test "configuration values are reasonable" do
      assert Manager.get_consensus_threshold() > 0
      assert Manager.get_consensus_threshold() <= 1.0
      assert Manager.get_sliding_window_size() > 0
      assert Manager.get_sliding_window_size() <= 10
    end
  end

  # =============================================================
  # PROFILE-DRIVEN MODEL SELECTION (v4.0 - profiles required)
  # =============================================================

  describe "[INTEGRATION] profile-driven model pool (R1-R4)" do
    test "get_model_pool returns models from opts (R1)" do
      # R1: WHEN get_model_pool called with model_pool opt THEN returns that list
      test_models = [
        "azure:gpt-4o",
        "google-vertex:gemini-2.5-pro",
        "amazon-bedrock:claude-3-5-sonnet"
      ]

      # model_pool passed via opts (from profile)
      result = Manager.get_model_pool(model_pool: test_models)

      assert result == test_models
    end

    test "get_model_pool raises RuntimeError when model_pool not provided (R2)" do
      # R2: WHEN get_model_pool called without model_pool opt THEN raises RuntimeError
      # Profile is required - model_pool must be provided via opts
      assert_raise RuntimeError, ~r/model_pool not provided/, fn ->
        Manager.get_model_pool()
      end
    end

    test "get_model_pool uses test_model_pool in test_mode (R3)" do
      # R3: WHEN test_mode: true THEN returns test model pool (for test isolation)
      result = Manager.get_model_pool(test_mode: true)

      # Should return the @test_model_pool defined in Manager
      assert is_list(result)
      assert result != []
    end

    # R4: get_critical_model_pool function removed
    # Verification: Compiler enforces removal - any call would fail to compile
    # No runtime test needed (function_exported? discouraged by Credo)
  end

  describe "[UNIT] consensus parameters unchanged (R5, R7)" do
    test "get_consensus_threshold returns 0.5 (R5)" do
      # R5: WHEN get_consensus_threshold called THEN returns 0.5
      assert Manager.get_consensus_threshold() == 0.5
    end

    test "get_sliding_window_size returns 2 (R7)" do
      # R7: WHEN get_sliding_window_size called THEN returns 2
      assert Manager.get_sliding_window_size() == 2
    end
  end

  describe "[UNIT] context management unchanged (R8-R10)" do
    test "build_context returns proper structure (R8)" do
      # R8: WHEN build_context called THEN returns map with goal, history, empty reasoning
      goal = "Analyze data"
      history = [%{role: :user, content: "Hello"}]

      context = Manager.build_context(goal, history)

      assert context.prompt == goal
      assert context.conversation_history == history
      assert context.reasoning_history == []
      assert context.round_proposals == []
      assert is_integer(context.start_time)
    end

    test "update_context_with_round adds reasoning (R9)" do
      # R9: WHEN update_context_with_round called THEN adds reasoning to sliding window
      context = Manager.build_context("goal", [])

      responses = [
        %{action: :wait, params: %{}, reasoning: "Need to wait"},
        %{action: :orient, params: %{}, reasoning: "Need orientation"}
      ]

      updated = Manager.update_context_with_round(context, 1, responses)

      assert length(updated.reasoning_history) == 1
      # v7.0: reasoning_history now stores maps with action+params+reasoning
      round_history = hd(updated.reasoning_history)
      assert Enum.at(round_history, 0).reasoning == "Need to wait"
      assert Enum.at(round_history, 1).reasoning == "Need orientation"
    end

    test "reasoning history respects sliding window size (R10)" do
      # R10: WHEN update_context_with_round called multiple times THEN keeps only last N rounds
      context = Manager.build_context("goal", [])

      # Add 3 rounds (window size is 2)
      context1 =
        Manager.update_context_with_round(context, 1, [%{reasoning: "R1"}])

      context2 =
        Manager.update_context_with_round(context1, 2, [%{reasoning: "R2"}])

      context3 =
        Manager.update_context_with_round(context2, 3, [%{reasoning: "R3"}])

      # Should only keep last 2 rounds
      assert length(context3.reasoning_history) == 2
      # v7.0: reasoning_history now stores maps with action+params+reasoning
      assert hd(Enum.at(context3.reasoning_history, 0)).reasoning == "R2"
      assert hd(Enum.at(context3.reasoning_history, 1)).reasoning == "R3"
    end
  end

  # =============================================================
  # INTEGRATION AUDIT: build_context opts for max_refinement_rounds
  # WorkGroupID: feat-20260208-210722, Audit Fix
  #
  # Audit finding: Manager.build_context/2 doesn't include max_refinement_rounds.
  # Consensus module manually adds via Map.put after calling build_context.
  # This is fragile — build_context should accept opts and include it natively.
  # =============================================================

  describe "[UNIT] build_context with max_refinement_rounds opt (audit fix)" do
    test "build_context/3 includes max_refinement_rounds in context" do
      # WHEN build_context called with max_refinement_rounds opt
      # THEN context map includes max_refinement_rounds key with that value
      context = Manager.build_context("goal", [], max_refinement_rounds: 3)

      assert context.max_refinement_rounds == 3
    end

    test "build_context/3 defaults max_refinement_rounds to 4 when not in opts" do
      # WHEN build_context called with empty opts
      # THEN context map includes max_refinement_rounds with default 4
      context = Manager.build_context("goal", [], [])

      assert context.max_refinement_rounds == 4
    end

    test "build_context/3 preserves all existing fields with opts" do
      # WHEN build_context/3 called with opts
      # THEN all existing context fields (prompt, history, etc.) are preserved
      history = [%{role: :user, content: "hello"}]
      context = Manager.build_context("analyze data", history, max_refinement_rounds: 7)

      assert context.prompt == "analyze data"
      assert context.conversation_history == history
      assert context.reasoning_history == []
      assert context.round_proposals == []
      assert is_integer(context.start_time)
      assert context.max_refinement_rounds == 7
    end
  end

  describe "[UNIT] build_context_with_ace opts propagation (audit fix)" do
    test "build_context_with_ace/5 includes max_refinement_rounds from opts" do
      # WHEN build_context_with_ace called with opts containing max_refinement_rounds
      # THEN context includes max_refinement_rounds from opts
      context =
        Manager.build_context_with_ace("goal", [], [], nil, max_refinement_rounds: 5)

      assert context.max_refinement_rounds == 5
    end

    test "build_context_with_ace/5 preserves lessons and model_state with opts" do
      # WHEN build_context_with_ace called with opts
      # THEN ACE fields (lessons, model_state) are still present alongside opts
      lessons = [%{type: :factual, content: "test", confidence: 1}]
      model_state = %{summary: "state"}

      context =
        Manager.build_context_with_ace("goal", [], lessons, model_state, max_refinement_rounds: 3)

      assert context.lessons == lessons
      assert context.model_state == model_state
      assert context.max_refinement_rounds == 3
    end
  end

  # =============================================================
  # ACE v5.0 - BUILD CONTEXT WITH LESSONS (ace-20251207-140000)
  # =============================================================

  describe "[UNIT] build_context_with_ace (ACE R6-R10)" do
    test "build_context_with_ace includes lessons (R6)" do
      # R6: WHEN build_context_with_ace called THEN includes lessons in context
      goal = "Complete the task"
      history = [%{role: :user, content: "Task message"}]

      lessons = [
        %{type: :factual, content: "API uses bearer auth", confidence: 3},
        %{type: :behavioral, content: "User prefers verbose output", confidence: 2}
      ]

      context = Manager.build_context_with_ace(goal, history, lessons, nil)

      assert Map.has_key?(context, :lessons)
      assert context.lessons == lessons
      assert length(context.lessons) == 2
    end

    test "build_context_with_ace includes model_state (R7)" do
      # R7: WHEN build_context_with_ace called THEN includes model_state in context
      goal = "Process data"
      history = []

      model_state = %{
        summary: "Working on auth implementation",
        updated_at: ~U[2025-12-07 14:00:00Z]
      }

      context = Manager.build_context_with_ace(goal, history, [], model_state)

      assert Map.has_key?(context, :model_state)
      assert context.model_state == model_state
      assert context.model_state.summary == "Working on auth implementation"
    end

    test "build_context_with_ace handles empty lessons (R8)" do
      # R8: WHEN build_context_with_ace called with empty lessons THEN returns valid context
      goal = "Test goal"
      history = [%{role: :user, content: "Hello"}]

      context = Manager.build_context_with_ace(goal, history, [], nil)

      assert Map.has_key?(context, :lessons)
      assert context.lessons == []
      # Should still have base context fields
      assert context.prompt == goal
    end

    test "build_context_with_ace handles nil state (R9)" do
      # R9: WHEN build_context_with_ace called with nil state THEN returns valid context
      goal = "Test goal"
      history = []
      lessons = [%{type: :factual, content: "Some fact", confidence: 1}]

      context = Manager.build_context_with_ace(goal, history, lessons, nil)

      assert Map.has_key?(context, :model_state)
      assert context.model_state == nil
      # Should still have lessons
      assert context.lessons == lessons
    end

    test "build_context_with_ace preserves base context fields (R10)" do
      # R10: WHEN build_context_with_ace called THEN all base context fields preserved
      goal = "Analyze data"
      history = [%{role: :user, content: "Previous message"}]
      lessons = [%{type: :factual, content: "Fact", confidence: 2}]
      model_state = %{summary: "Current state"}

      context = Manager.build_context_with_ace(goal, history, lessons, model_state)

      # Base fields from build_context should all be present
      assert context.prompt == goal
      assert context.conversation_history == history
      assert context.reasoning_history == []
      assert context.round_proposals == []
      assert is_integer(context.start_time)

      # Plus ACE fields
      assert context.lessons == lessons
      assert context.model_state == model_state
    end
  end

  # =============================================================
  # v7.0 - ENHANCED REASONING HISTORY WITH ACTION CONTEXT
  # (feat-20251208-234737)
  # =============================================================

  describe "[UNIT] enhanced reasoning history (v7.0 R11-R15)" do
    setup do
      initial_context = %{
        prompt: "test goal",
        conversation_history: [],
        reasoning_history: [],
        round_proposals: [],
        start_time: System.monotonic_time(:millisecond)
      }

      {:ok, context: initial_context}
    end

    test "update_context_with_round stores action and params with reasoning (R11)", %{
      context: context
    } do
      # R11: WHEN update_context_with_round called THEN reasoning_history contains maps
      # with action, params, and reasoning keys
      responses = [
        %{
          action: :execute_shell,
          params: %{command: "git status"},
          reasoning: "Check repo state"
        },
        %{action: :wait, params: %{wait: 5000}, reasoning: "Give time to process"}
      ]

      updated = Manager.update_context_with_round(context, 1, responses)

      # reasoning_history should now contain maps, not just strings
      assert length(updated.reasoning_history) == 1
      round_1_history = hd(updated.reasoning_history)

      # Each entry should be a map with action, params, and reasoning
      assert length(round_1_history) == 2

      first_entry = Enum.at(round_1_history, 0)
      assert is_map(first_entry)
      assert first_entry.action == :execute_shell
      assert first_entry.params == %{command: "git status"}
      assert first_entry.reasoning == "Check repo state"

      second_entry = Enum.at(round_1_history, 1)
      assert is_map(second_entry)
      assert second_entry.action == :wait
      assert second_entry.params == %{wait: 5000}
      assert second_entry.reasoning == "Give time to process"
    end

    test "reasoning history sliding window works with response maps (R12)", %{context: context} do
      # R12: WHEN update_context_with_round called multiple times THEN keeps only last N rounds
      # of response maps (window size is 2)

      # Round 1
      responses1 = [
        %{action: :orient, params: %{current_situation: "Starting"}, reasoning: "R1 reasoning"}
      ]

      context1 = Manager.update_context_with_round(context, 1, responses1)

      # Round 2
      responses2 = [
        %{action: :wait, params: %{wait: 1000}, reasoning: "R2 reasoning"}
      ]

      context2 = Manager.update_context_with_round(context1, 2, responses2)

      # Round 3 (should push out Round 1)
      responses3 = [
        %{action: :spawn_child, params: %{task_description: "Analyze"}, reasoning: "R3 reasoning"}
      ]

      context3 = Manager.update_context_with_round(context2, 3, responses3)

      # Should only keep last 2 rounds (R2 and R3)
      assert length(context3.reasoning_history) == 2

      # First element should be R2's response map
      r2_entry = hd(Enum.at(context3.reasoning_history, 0))
      assert r2_entry.action == :wait
      assert r2_entry.reasoning == "R2 reasoning"

      # Second element should be R3's response map
      r3_entry = hd(Enum.at(context3.reasoning_history, 1))
      assert r3_entry.action == :spawn_child
      assert r3_entry.reasoning == "R3 reasoning"
    end

    test "handles responses with missing action or params (R13)", %{context: context} do
      # R13: WHEN response has nil action or params THEN stores nil/empty map without crashing
      responses = [
        %{action: nil, params: nil, reasoning: "Missing action"},
        %{action: :wait, params: nil, reasoning: "Missing params"},
        %{reasoning: "No action or params at all"}
      ]

      updated = Manager.update_context_with_round(context, 1, responses)

      assert length(updated.reasoning_history) == 1
      round_history = hd(updated.reasoning_history)
      assert length(round_history) == 3

      # First entry: nil action, nil params stored as empty map
      first = Enum.at(round_history, 0)
      assert first.action == nil
      assert first.params == %{}
      assert first.reasoning == "Missing action"

      # Second entry: valid action, nil params stored as empty map
      second = Enum.at(round_history, 1)
      assert second.action == :wait
      assert second.params == %{}
      assert second.reasoning == "Missing params"

      # Third entry: missing action/params keys
      third = Enum.at(round_history, 2)
      assert third.action == nil
      assert third.params == %{}
      assert third.reasoning == "No action or params at all"
    end

    test "round_proposals format unchanged (R14)", %{context: context} do
      # R14: WHEN update_context_with_round called THEN round_proposals unchanged
      # (still stores action+params only, not reasoning)
      responses = [
        %{action: :execute_shell, params: %{command: "ls -la"}, reasoning: "List files"},
        %{action: :answer_engine, params: %{prompt: "What is X?"}, reasoning: "Need answer"}
      ]

      updated = Manager.update_context_with_round(context, 1, responses)

      # round_proposals should still work the same way (action+params only)
      assert length(updated.round_proposals) == 1
      {round_num, proposals} = hd(updated.round_proposals)
      assert round_num == 1
      assert length(proposals) == 2

      # Proposals should NOT contain reasoning
      first_proposal = Enum.at(proposals, 0)
      assert first_proposal == %{action: :execute_shell, params: %{command: "ls -la"}}
      refute Map.has_key?(first_proposal, :reasoning)

      second_proposal = Enum.at(proposals, 1)
      assert second_proposal == %{action: :answer_engine, params: %{prompt: "What is X?"}}
      refute Map.has_key?(second_proposal, :reasoning)
    end

    test "stores all 14 action types in reasoning_history (R15)", %{context: context} do
      # R15: WHEN responses contain any valid action type THEN stores correctly in reasoning_history
      # Test with all 14 action types to ensure none are mishandled
      all_actions = [
        %{action: :execute_shell, params: %{command: "test"}, reasoning: "shell"},
        %{action: :spawn_child, params: %{task_description: "task"}, reasoning: "spawn"},
        %{action: :answer_engine, params: %{prompt: "query"}, reasoning: "answer"},
        %{action: :fetch_web, params: %{url: "http://test.com"}, reasoning: "fetch"},
        %{action: :send_message, params: %{to: :parent, content: "hi"}, reasoning: "message"},
        %{action: :call_api, params: %{api_type: :rest, url: "http://api"}, reasoning: "api"},
        %{action: :call_mcp, params: %{tool: "read_file"}, reasoning: "mcp"},
        %{action: :wait, params: %{wait: 5000}, reasoning: "wait"},
        %{action: :orient, params: %{current_situation: "analyzing"}, reasoning: "orient"},
        %{action: :todo, params: %{items: []}, reasoning: "todo"},
        %{action: :generate_secret, params: %{name: "key"}, reasoning: "secret"}
      ]

      updated = Manager.update_context_with_round(context, 1, all_actions)

      assert length(updated.reasoning_history) == 1
      round_history = hd(updated.reasoning_history)
      assert length(round_history) == 11

      # Verify each action type was stored correctly
      Enum.each(Enum.with_index(all_actions), fn {original, idx} ->
        stored = Enum.at(round_history, idx)
        assert stored.action == original.action, "Action #{original.action} not stored correctly"

        assert stored.params == original.params,
               "Params for #{original.action} not stored correctly"

        assert stored.reasoning == original.reasoning,
               "Reasoning for #{original.action} not stored correctly"
      end)
    end
  end
end
