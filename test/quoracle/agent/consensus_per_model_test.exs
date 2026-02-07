defmodule Quoracle.Agent.ConsensusPerModelTest do
  @moduledoc """
  Tests for per-model query flow in AGENT_Consensus.
  WorkGroupID: feat-20251207-022443 (R1-R12), ace-20251207-140000 (R13-R18)

  R1-R8: Building blocks (implemented)
  R9-R12: Production wiring (implemented)
  R13-R18: ACE Reflector/LessonManager integration (Packet 4)
  """

  use ExUnit.Case, async: true
  alias Quoracle.Agent.Consensus

  # Force ActionList to load - ensures :orient atom exists for String.to_existing_atom/1
  # when running tests in isolation (required for ActionParser.parse_json_response/1)
  alias Quoracle.Actions.Schema.ActionList
  _ = ActionList.actions()

  describe "R1: Per-Model Query" do
    test "each model queried with its own history" do
      # State with divergent per-model histories
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "Message for A", timestamp: DateTime.utc_now()},
            %{type: :assistant, content: "Response for A", timestamp: DateTime.utc_now()}
          ],
          "model-b" => [
            %{type: :user, content: "Different message for B", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      model_pool = ["model-a", "model-b"]
      opts = [test_mode: true]

      {:ok, results, _updated_state} =
        Consensus.query_models_with_per_model_histories(state, model_pool, opts)

      # Verify results contain entries for both models
      assert length(results) == 2
      model_ids = Enum.map(results, & &1.model)
      assert "model-a" in model_ids
      assert "model-b" in model_ids
    end
  end

  describe "R2: Pre-Query Condensation Check" do
    test "condenses history before query when over threshold" do
      # Create state with history that exceeds 100% of model's context limit
      # openrouter:openai/gpt-3.5-turbo-0613 has 4095 token limit in LLMDB
      # 100 entries * 50 words each = 5000 words ≈ 5000 tokens (exceeds 4095)
      large_history =
        for _i <- 1..100 do
          %{
            type: :user,
            content: String.duplicate("word ", 50),
            timestamp: DateTime.utc_now()
          }
        end

      state = %{
        model_histories: %{
          # This model has 4095 context, should trigger condensation at 5k tokens
          "openrouter:openai/gpt-3.5-turbo-0613" => large_history
        },
        context_lessons: %{},
        model_states: %{},
        test_mode: true
      }

      opts = [test_mode: true]

      updated_state =
        Consensus.maybe_condense_for_model(state, "openrouter:openai/gpt-3.5-turbo-0613", opts)

      # History should be condensed (fewer entries than original)
      updated_history =
        Map.get(updated_state.model_histories, "openrouter:openai/gpt-3.5-turbo-0613")

      assert length(updated_history) < length(large_history)
    end
  end

  describe "R3: Output Overflow Handling" do
    test "handles output overflow with condense and retry" do
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "Test message", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      # Simulate context overflow that triggers retry
      opts = [test_mode: true, simulate_context_overflow: true]

      result = Consensus.query_single_model_with_retry(state, "model-a", opts)

      # Should succeed after retry (simulate_context_overflow returns mock success)
      assert {:ok, response, _updated_state} = result
      assert response.content == "Mock response after retry"
    end
  end

  describe "R4: Single Retry Limit" do
    test "only retries once on context overflow" do
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "Test message", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      # Simulate persistent context_length_exceeded error (even after condense)
      opts = [test_mode: true, simulate_persistent_overflow: true]

      result = Consensus.query_single_model_with_retry(state, "model-a", opts)

      # Should return error after single retry (no infinite loop)
      assert {:error, :context_length_exceeded, _updated_state} = result
    end
  end

  describe "R5: Independent Condensation" do
    test "condensation affects only target model" do
      # Create state with histories for multiple models
      large_history =
        for i <- 1..50 do
          %{type: :user, content: "Message #{i}", timestamp: DateTime.utc_now()}
        end

      small_history = [
        %{type: :user, content: "Short message", timestamp: DateTime.utc_now()}
      ]

      state = %{
        model_histories: %{
          "model-a" => large_history,
          "model-b" => small_history
        },
        context_lessons: %{},
        model_states: %{},
        test_mode: true
      }

      opts = [test_mode: true]

      updated_state = Consensus.condense_model_history_with_reflection(state, "model-a", opts)

      # Model A should be condensed
      updated_a = Map.get(updated_state.model_histories, "model-a")
      assert length(updated_a) < length(large_history)

      # Model B should be unchanged
      updated_b = Map.get(updated_state.model_histories, "model-b")
      assert updated_b == small_history
    end
  end

  describe "R6: Consensus Result Unchanged" do
    test "consensus aggregation works with per-model queries" do
      # Use existing get_consensus with state containing per-model histories
      messages = [
        %{role: "user", content: "What action should I take?"}
      ]

      # Test mode returns mock responses
      opts = [test_mode: true, model_pool: ["model-a", "model-b", "model-c"]]

      # This should work with existing get_consensus
      result = Consensus.get_consensus(messages, opts)

      # Should return valid consensus result
      assert {:ok, {result_type, _action, _meta}} = result
      assert result_type in [:consensus, :forced_decision]
    end
  end

  # R7 removed: Placeholder summary no longer used - ACE extracts real lessons/state

  describe "R8: 20% Retention" do
    test "condensation keeps newest 20 percent of tokens (80% removed)" do
      # Create 20 messages in newest-first order (Message 20 at head)
      # Production code prepends new entries, so newest is always first
      history =
        for i <- 20..1//-1 do
          %{type: :user, content: "Message #{i}", timestamp: DateTime.utc_now()}
        end

      state = %{
        model_histories: %{
          "model-a" => history
        },
        context_lessons: %{},
        model_states: %{},
        test_mode: true
      }

      opts = [test_mode: true]

      updated_state = Consensus.condense_model_history_with_reflection(state, "model-a", opts)

      updated_history = Map.get(updated_state.model_histories, "model-a")

      # Should keep ~20% of tokens (80% removed, roughly 4 messages of 20)
      # No placeholder summary - ACE extracts real lessons/state instead
      assert length(updated_history) < length(history)
      assert length(updated_history) >= 2

      # Newest messages should be preserved
      contents = Enum.map(updated_history, & &1.content)

      assert "Message 20" in contents
      assert "Message 19" in contents
    end
  end

  # ============================================================================
  # Packet 4b: Production Wiring Tests (R9-R12)
  # These tests verify the integration of per-model histories into the
  # production consensus flow. They will FAIL until IMPLEMENT phase.
  # ============================================================================

  describe "R9: Production Flow Integration" do
    test "get_consensus_with_state uses per-model histories" do
      # Create state with divergent per-model histories
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "Task A specific", timestamp: DateTime.utc_now()}
          ],
          "model-b" => [
            %{type: :user, content: "Task B specific", timestamp: DateTime.utc_now()}
          ],
          "model-c" => [
            %{type: :user, content: "Task C specific", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      model_pool = ["model-a", "model-b", "model-c"]
      opts = [test_mode: true, model_pool: model_pool]

      # This function doesn't exist yet - will fail with UndefinedFunctionError
      # It should use query_models_with_per_model_histories internally
      result = Consensus.get_consensus_with_state(state, opts)

      # Should return valid consensus result (3-tuple with updated_state)
      assert {:ok, {result_type, _action, _meta}, _updated_state} = result
      assert result_type in [:consensus, :forced_decision]
    end
  end

  describe "R10: State-Based Consensus API" do
    test "get_consensus_with_state accepts state parameter" do
      # Minimal state with model_histories field
      state = %{
        model_histories: %{
          "mock-model" => [
            %{type: :user, content: "Hello", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      opts = [test_mode: true, model_pool: ["mock-model"]]

      # This function doesn't exist yet - will fail with UndefinedFunctionError
      result = Consensus.get_consensus_with_state(state, opts)

      # Should accept state and return result (3-tuple with updated_state)
      assert {:ok, _, _updated_state} = result
    end

    test "get_consensus_with_state requires model_histories field" do
      # State missing model_histories should raise or return error
      state = %{
        test_mode: true
        # model_histories is missing
      }

      opts = [test_mode: true, model_pool: ["mock-model"]]

      # This function doesn't exist yet - will fail with UndefinedFunctionError
      # When implemented, should return error for missing model_histories
      result = Consensus.get_consensus_with_state(state, opts)

      assert {:error, :missing_model_histories} = result
    end
  end

  describe "R11: Divergent History Verification" do
    test "production flow queries models with divergent histories" do
      # Create state where models have VERY different histories
      # Model A: Short history
      # Model B: Long history (would need condensation if limits were real)
      # Model C: Empty history

      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "Short A", timestamp: DateTime.utc_now()}
          ],
          "model-b" =>
            for i <- 1..10 do
              %{type: :user, content: "Long B message #{i}", timestamp: DateTime.utc_now()}
            end,
          "model-c" => []
        },
        test_mode: true
      }

      model_pool = ["model-a", "model-b", "model-c"]
      opts = [test_mode: true, model_pool: model_pool, track_queries: true]

      # This function doesn't exist yet - will fail with UndefinedFunctionError
      {:ok, result, _updated_state} = Consensus.get_consensus_with_state(state, opts)

      # The result should include query metadata showing each model got different messages
      # This verifies that per-model histories are actually being used
      {_type, _action, meta} = result
      assert meta[:per_model_queries] == true
    end
  end

  describe "R12: Backward Compatibility" do
    test "get_consensus with messages maintains backward compatibility" do
      # Old API: pass messages directly (not state)
      messages = [
        %{role: "user", content: "What action should I take?"}
      ]

      opts = [test_mode: true, model_pool: ["model-a", "model-b", "model-c"]]

      # This should still work with the old API
      result = Consensus.get_consensus(messages, opts)

      # Should return valid consensus result
      assert {:ok, {result_type, _action, _meta}} = result
      assert result_type in [:consensus, :forced_decision]
    end
  end

  # ============================================================================
  # ACE Integration Tests (R13-R18) - Packet 4 ace-20251207-140000
  # These tests verify Reflector and LessonManager integration into condensation.
  # ============================================================================

  describe "R13: Token-Based Condensation" do
    test "condensation removes tokens not message count" do
      # Create history with varying message sizes
      # Small messages should contribute less to token count
      history = [
        %{type: :user, content: "Short", timestamp: DateTime.utc_now()},
        %{
          type: :assistant,
          content: String.duplicate("Long message content ", 100),
          timestamp: DateTime.utc_now()
        },
        %{type: :user, content: "Another short", timestamp: DateTime.utc_now()},
        %{
          type: :assistant,
          content: String.duplicate("Another long response ", 100),
          timestamp: DateTime.utc_now()
        }
      ]

      state = %{
        model_histories: %{"model-a" => history},
        context_lessons: %{},
        model_states: %{},
        test_mode: true
      }

      opts = [
        test_mode: true,
        reflector_mock: fn _msgs, _model, _opts -> {:ok, %{lessons: [], state: []}} end
      ]

      # condense_model_history_with_reflection will be the new function
      updated_state = Consensus.condense_model_history_with_reflection(state, "model-a", opts)

      updated_history = Map.get(updated_state.model_histories, "model-a")

      # Should keep messages based on token count (80% removed, 20% kept)
      # The long messages should be preferentially removed to reduce tokens
      assert length(updated_history) < length(history)
    end
  end

  describe "R14: Reflector Called" do
    test "calls Reflector before discarding messages" do
      history =
        for i <- 1..20 do
          %{type: :user, content: "Message #{i}", timestamp: DateTime.utc_now()}
        end

      test_pid = self()

      # Track Reflector calls
      reflector_mock = fn messages, model_id, _opts ->
        send(test_pid, {:reflector_called, messages, model_id})
        {:ok, %{lessons: [], state: []}}
      end

      state = %{
        model_histories: %{"model-a" => history},
        context_lessons: %{},
        model_states: %{},
        test_mode: true
      }

      opts = [test_mode: true, reflector_fn: reflector_mock]

      _updated_state = Consensus.condense_model_history_with_reflection(state, "model-a", opts)

      # Reflector should have been called with messages being removed
      assert_receive {:reflector_called, removed_messages, "model-a"}
      assert removed_messages != []
    end
  end

  describe "R15: Lessons Accumulated" do
    test "accumulates extracted lessons" do
      history =
        for i <- 1..20 do
          %{type: :user, content: "Message #{i}", timestamp: DateTime.utc_now()}
        end

      # Reflector returns lessons
      reflector_mock = fn _messages, _model_id, _opts ->
        {:ok,
         %{
           lessons: [
             %{type: :factual, content: "API uses REST", confidence: 1},
             %{type: :behavioral, content: "User prefers concise output", confidence: 1}
           ],
           state: []
         }}
      end

      state = %{
        model_histories: %{"model-a" => history},
        context_lessons: %{"model-a" => []},
        model_states: %{},
        test_mode: true
      }

      opts = [test_mode: true, reflector_fn: reflector_mock]

      updated_state = Consensus.condense_model_history_with_reflection(state, "model-a", opts)

      # Lessons should be accumulated in context_lessons
      lessons = Map.get(updated_state.context_lessons, "model-a", [])
      assert length(lessons) == 2
      assert Enum.any?(lessons, &(&1.content == "API uses REST"))
      assert Enum.any?(lessons, &(&1.content == "User prefers concise output"))
    end

    test "accumulates lessons to existing lessons" do
      history =
        for i <- 1..20 do
          %{type: :user, content: "Message #{i}", timestamp: DateTime.utc_now()}
        end

      existing_lessons = [
        %{type: :factual, content: "Existing fact", confidence: 2}
      ]

      reflector_mock = fn _messages, _model_id, _opts ->
        {:ok,
         %{
           lessons: [%{type: :factual, content: "New fact", confidence: 1}],
           state: []
         }}
      end

      state = %{
        model_histories: %{"model-a" => history},
        context_lessons: %{"model-a" => existing_lessons},
        model_states: %{},
        test_mode: true
      }

      opts = [test_mode: true, reflector_fn: reflector_mock]

      updated_state = Consensus.condense_model_history_with_reflection(state, "model-a", opts)

      lessons = Map.get(updated_state.context_lessons, "model-a", [])
      assert length(lessons) == 2
      assert Enum.any?(lessons, &(&1.content == "Existing fact"))
      assert Enum.any?(lessons, &(&1.content == "New fact"))
    end
  end

  describe "R16: State Updated" do
    test "updates model state from reflection" do
      history =
        for i <- 1..20 do
          %{type: :user, content: "Message #{i}", timestamp: DateTime.utc_now()}
        end

      # Reflector returns state
      reflector_mock = fn _messages, _model_id, _opts ->
        {:ok,
         %{
           lessons: [],
           state: [%{summary: "Working on auth module, 3/5 tasks complete"}]
         }}
      end

      state = %{
        model_histories: %{"model-a" => history},
        context_lessons: %{},
        model_states: %{"model-a" => nil},
        test_mode: true
      }

      opts = [test_mode: true, reflector_fn: reflector_mock]

      updated_state = Consensus.condense_model_history_with_reflection(state, "model-a", opts)

      # Model state should be updated
      model_state = Map.get(updated_state.model_states, "model-a")
      assert model_state != nil
      assert model_state.summary == "Working on auth module, 3/5 tasks complete"
    end

    test "replaces previous model state" do
      history =
        for i <- 1..20 do
          %{type: :user, content: "Message #{i}", timestamp: DateTime.utc_now()}
        end

      old_state = %{summary: "Old context from previous condensation"}

      reflector_mock = fn _messages, _model_id, _opts ->
        {:ok,
         %{
           lessons: [],
           state: [%{summary: "New current context"}]
         }}
      end

      state = %{
        model_histories: %{"model-a" => history},
        context_lessons: %{},
        model_states: %{"model-a" => old_state},
        test_mode: true
      }

      opts = [test_mode: true, reflector_fn: reflector_mock]

      updated_state = Consensus.condense_model_history_with_reflection(state, "model-a", opts)

      model_state = Map.get(updated_state.model_states, "model-a")
      assert model_state.summary == "New current context"
      refute model_state.summary == "Old context from previous condensation"
    end
  end

  describe "R17: Reflection Failure Graceful" do
    test "continues condensation when Reflector fails" do
      history =
        for i <- 1..20 do
          %{type: :user, content: "Message #{i}", timestamp: DateTime.utc_now()}
        end

      # Reflector fails
      reflector_mock = fn _messages, _model_id, _opts ->
        {:error, :reflection_failed}
      end

      state = %{
        model_histories: %{"model-a" => history},
        context_lessons: %{"model-a" => []},
        model_states: %{"model-a" => nil},
        test_mode: true
      }

      opts = [test_mode: true, reflector_fn: reflector_mock]

      # Should not raise, condensation should proceed
      updated_state = Consensus.condense_model_history_with_reflection(state, "model-a", opts)

      # History should still be condensed (messages removed)
      updated_history = Map.get(updated_state.model_histories, "model-a")
      assert length(updated_history) < length(history)

      # Lessons and state should be unchanged
      assert Map.get(updated_state.context_lessons, "model-a") == []
      assert Map.get(updated_state.model_states, "model-a") == nil
    end
  end

  describe "R18: Same Model Reflection" do
    test "uses same model for reflection as being condensed" do
      history =
        for i <- 1..20 do
          %{type: :user, content: "Message #{i}", timestamp: DateTime.utc_now()}
        end

      test_pid = self()

      reflector_mock = fn _messages, model_id, _opts ->
        send(test_pid, {:reflector_model, model_id})
        {:ok, %{lessons: [], state: []}}
      end

      state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => history,
          "google:gemini-2.0-flash" => []
        },
        context_lessons: %{},
        model_states: %{},
        test_mode: true
      }

      opts = [test_mode: true, reflector_fn: reflector_mock]

      # Condense claude's history
      _updated_state =
        Consensus.condense_model_history_with_reflection(state, "anthropic:claude-sonnet-4", opts)

      # Reflector should have been called with claude, not gemini
      assert_receive {:reflector_model, "anthropic:claude-sonnet-4"}
      refute_receive {:reflector_model, "google:gemini-2.0-flash"}
    end
  end

  # ============================================================================
  # Descending Temperature Tests (R19-R24) - Packet 1 feat-20251208-165509
  # These tests verify round-based temperature calculation integration.
  # ============================================================================

  # Temperature module will be used once implemented
  alias Quoracle.Consensus.Temperature
  _ = Temperature

  describe "R19: Round Passed to Query Options" do
    test "passes round number to query options" do
      # State included for context - will be used in production path
      _state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => [
            %{type: :user, content: "Test message", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      # Round should be included in opts and passed through to build_query_options
      opts = [test_mode: true, round: 3]

      # Call the internal function that builds query options
      # This tests that round is accessible during query building
      query_opts = Consensus.build_query_options("anthropic:claude-sonnet-4", opts)

      # Query options should have temperature calculated based on round
      assert is_float(query_opts.temperature)
      # Round 3 for claude (max=1.0): 1.0 - (2 * 0.2) = 0.6
      assert query_opts.temperature == 0.6
    end
  end

  describe "R20: Temperature Calculated Per Model" do
    test "calculates temperature per model and round" do
      # Test that build_query_options uses Temperature module
      opts = [round: 2]

      # Claude (max=1.0): round 2 = 1.0 - 0.2 = 0.8
      claude_opts = Consensus.build_query_options("anthropic:claude-sonnet-4", opts)
      assert claude_opts.temperature == 0.8

      # GPT (max=2.0): round 2 = 2.0 - 0.4 = 1.6
      gpt_opts = Consensus.build_query_options("openai:gpt-4o", opts)
      assert gpt_opts.temperature == 1.6

      # Gemini (max=2.0): round 2 = 2.0 - 0.4 = 1.6
      gemini_opts = Consensus.build_query_options("google:gemini-2.0-flash", opts)
      assert gemini_opts.temperature == 1.6
    end
  end

  describe "R21: Round 1 Uses Max Temperature" do
    test "round 1 uses max temperature" do
      state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => [
            %{type: :user, content: "Initial task", timestamp: DateTime.utc_now()}
          ],
          "openai:gpt-4o" => [
            %{type: :user, content: "Initial task", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      model_pool = ["anthropic:claude-sonnet-4", "openai:gpt-4o"]
      opts = [test_mode: true, model_pool: model_pool, round: 1, track_temperatures: true]

      {:ok, result, _updated_state} = Consensus.get_consensus_with_state(state, opts)

      # Verify temperatures used in round 1
      {_type, _action, meta} = result

      # Claude should get max temp 1.0
      assert meta[:temperatures]["anthropic:claude-sonnet-4"] == 1.0

      # GPT should get max temp 2.0
      assert meta[:temperatures]["openai:gpt-4o"] == 2.0
    end
  end

  describe "R22: Refinement Rounds Use Descending Temperature" do
    test "refinement rounds use descending temperature" do
      # Test that as rounds increase, temperature decreases

      # Round 1
      opts_r1 = [round: 1]
      claude_r1 = Consensus.build_query_options("anthropic:claude-sonnet-4", opts_r1)
      gpt_r1 = Consensus.build_query_options("openai:gpt-4o", opts_r1)

      # Round 3
      opts_r3 = [round: 3]
      claude_r3 = Consensus.build_query_options("anthropic:claude-sonnet-4", opts_r3)
      gpt_r3 = Consensus.build_query_options("openai:gpt-4o", opts_r3)

      # Round 5
      opts_r5 = [round: 5]
      claude_r5 = Consensus.build_query_options("anthropic:claude-sonnet-4", opts_r5)
      gpt_r5 = Consensus.build_query_options("openai:gpt-4o", opts_r5)

      # Claude: 1.0 → 0.6 → 0.2
      assert claude_r1.temperature > claude_r3.temperature
      assert claude_r3.temperature > claude_r5.temperature
      assert claude_r1.temperature == 1.0
      assert claude_r3.temperature == 0.6
      assert claude_r5.temperature == 0.2

      # GPT: 2.0 → 1.2 → 0.4
      assert gpt_r1.temperature > gpt_r3.temperature
      assert gpt_r3.temperature > gpt_r5.temperature
      assert gpt_r1.temperature == 2.0
      assert gpt_r3.temperature == 1.2
      assert gpt_r5.temperature == 0.4
    end
  end

  describe "R23: Mixed Model Pool Temperature" do
    test "mixed model pool gets per-model temperatures" do
      state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => [
            %{type: :user, content: "Task", timestamp: DateTime.utc_now()}
          ],
          "openai:gpt-4o" => [
            %{type: :user, content: "Task", timestamp: DateTime.utc_now()}
          ],
          "google:gemini-2.0-flash" => [
            %{type: :user, content: "Task", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      model_pool = ["anthropic:claude-sonnet-4", "openai:gpt-4o", "google:gemini-2.0-flash"]
      opts = [test_mode: true, model_pool: model_pool, round: 3, track_temperatures: true]

      {:ok, result, _updated_state} = Consensus.get_consensus_with_state(state, opts)
      {_type, _action, meta} = result

      temperatures = meta[:temperatures]

      # Round 3 temperatures by family:
      # Claude (max=1.0): 1.0 - (2 * 0.2) = 0.6
      assert temperatures["anthropic:claude-sonnet-4"] == 0.6

      # GPT (max=2.0): 2.0 - (2 * 0.4) = 1.2
      assert temperatures["openai:gpt-4o"] == 1.2

      # Gemini (max=2.0): 2.0 - (2 * 0.4) = 1.2
      assert temperatures["google:gemini-2.0-flash"] == 1.2

      # High-temp models should have same temperature
      assert temperatures["openai:gpt-4o"] == temperatures["google:gemini-2.0-flash"]

      # Claude should have lower temperature than high-temp models at same round
      assert temperatures["anthropic:claude-sonnet-4"] < temperatures["openai:gpt-4o"]
    end
  end

  describe "R24: Test Mode Temperature Calculation" do
    test "test mode calculates but ignores temperature" do
      state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => [
            %{type: :user, content: "Test", timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      opts = [test_mode: true, round: 3]

      # Temperature should still be calculated (for logging/debugging)
      query_opts = Consensus.build_query_options("anthropic:claude-sonnet-4", opts)

      # Should have calculated temperature
      assert query_opts.temperature == 0.6

      # In test mode, the mock response generator doesn't actually use temperature
      # but the calculation should still happen for verification
      model_pool = ["anthropic:claude-sonnet-4"]
      opts_with_pool = Keyword.put(opts, :model_pool, model_pool)

      {:ok, results, _updated_state} =
        Consensus.query_models_with_per_model_histories(state, model_pool, opts_with_pool)

      # Should return mock results (test mode doesn't call real LLM)
      assert length(results) == 1
      assert hd(results).model == "anthropic:claude-sonnet-4"
    end
  end

  # ============================================================================
  # Production Path Temperature Tests (R25-R27) - feat-20251208-165509
  # These tests verify that the ACTUAL production path uses Temperature module.
  # The previous tests (R19-R24) only tested the public API, not the production path.
  # ============================================================================

  alias Quoracle.Agent.Consensus.PerModelQuery

  describe "R25: PerModelQuery Uses Temperature" do
    test "PerModelQuery.build_query_options/2 accepts model_id and uses Temperature" do
      # This tests that PerModelQuery has a build_query_options/2 function
      # that accepts model_id and calculates temperature based on model family

      opts = [round: 3]

      # Claude (max=1.0): round 3 = 0.6
      claude_opts = PerModelQuery.build_query_options("anthropic:claude-sonnet-4", opts)
      assert claude_opts.temperature == 0.6

      # GPT (max=2.0): round 3 = 1.2
      gpt_opts = PerModelQuery.build_query_options("openai:gpt-4o", opts)
      assert gpt_opts.temperature == 1.2
    end

    test "PerModelQuery defaults to round 1 when not specified" do
      opts = []

      # Claude at round 1 should get max temp 1.0
      claude_opts = PerModelQuery.build_query_options("anthropic:claude-sonnet-4", opts)
      assert claude_opts.temperature == 1.0

      # GPT at round 1 should get max temp 2.0
      gpt_opts = PerModelQuery.build_query_options("openai:gpt-4o", opts)
      assert gpt_opts.temperature == 2.0
    end
  end

  describe "R26: Production Query Uses Per-Model Temperature" do
    test "query_single_model_with_retry uses model-specific temperature" do
      # This test verifies that the production path passes model_id to build_query_options
      # We use a mock to capture what temperature is actually sent to ModelQuery

      test_pid = self()

      # Mock ModelQuery to capture the temperature parameter
      model_query_mock = fn _messages, _models, query_opts ->
        send(test_pid, {:query_opts_received, query_opts})

        {:ok,
         %{
           successful_responses: [%{model: "anthropic:claude-sonnet-4", content: "{}"}],
           failed_models: []
         }}
      end

      state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => [
            %{type: :user, content: "Test", timestamp: DateTime.utc_now()}
          ]
        }
      }

      opts = [round: 3, model_query_fn: model_query_mock]

      # Call through production path
      _result =
        PerModelQuery.query_single_model_with_retry(state, "anthropic:claude-sonnet-4", opts)

      # Verify the temperature sent to ModelQuery was calculated for Claude at round 3
      assert_receive {:query_opts_received, received_opts}
      assert received_opts.temperature == 0.6
    end

    test "different models get different temperatures in same round" do
      test_pid = self()

      model_query_mock = fn _messages, [model_id], query_opts ->
        send(test_pid, {:query_for_model, model_id, query_opts.temperature})
        {:ok, %{successful_responses: [%{model: model_id, content: "{}"}], failed_models: []}}
      end

      state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => [
            %{type: :user, content: "Test", timestamp: DateTime.utc_now()}
          ],
          "openai:gpt-4o" => [%{type: :user, content: "Test", timestamp: DateTime.utc_now()}]
        }
      }

      opts = [round: 2, model_query_fn: model_query_mock]

      # Query Claude
      _result1 =
        PerModelQuery.query_single_model_with_retry(state, "anthropic:claude-sonnet-4", opts)

      # Query GPT
      _result2 = PerModelQuery.query_single_model_with_retry(state, "openai:gpt-4o", opts)

      # Claude at round 2: 1.0 - 0.2 = 0.8
      assert_receive {:query_for_model, "anthropic:claude-sonnet-4", claude_temp}
      assert claude_temp == 0.8

      # GPT at round 2: 2.0 - 0.4 = 1.6
      assert_receive {:query_for_model, "openai:gpt-4o", gpt_temp}
      assert gpt_temp == 1.6
    end
  end

  describe "R27: Full Production Flow Temperature" do
    test "query_models_with_per_model_histories passes correct temperature to each model" do
      test_pid = self()

      # Mock that captures temperature for each model
      model_query_mock = fn _messages, [model_id], query_opts ->
        send(test_pid, {:production_query, model_id, query_opts.temperature})

        response_json =
          Jason.encode!(%{"action" => "orient", "params" => %{}, "reasoning" => "test"})

        {:ok,
         %{successful_responses: [%{model: model_id, content: response_json}], failed_models: []}}
      end

      state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => [
            %{type: :user, content: "Task", timestamp: DateTime.utc_now()}
          ],
          "openai:gpt-4o" => [%{type: :user, content: "Task", timestamp: DateTime.utc_now()}],
          "google:gemini-2.0-flash" => [
            %{type: :user, content: "Task", timestamp: DateTime.utc_now()}
          ]
        }
      }

      model_pool = ["anthropic:claude-sonnet-4", "openai:gpt-4o", "google:gemini-2.0-flash"]
      opts = [round: 4, model_query_fn: model_query_mock]

      # Disable test_mode to exercise production path
      {:ok, _results, _updated_state} =
        PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      # Round 4 temperatures:
      # Claude (max=1.0): 1.0 - (3 * 0.2) = 0.4
      assert_receive {:production_query, "anthropic:claude-sonnet-4", 0.4}

      # GPT (max=2.0): 2.0 - (3 * 0.4) = 0.8
      assert_receive {:production_query, "openai:gpt-4o", 0.8}

      # Gemini (max=2.0): 2.0 - (3 * 0.4) = 0.8
      assert_receive {:production_query, "google:gemini-2.0-flash", 0.8}
    end
  end
end
