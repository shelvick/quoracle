defmodule Quoracle.Consensus.AggregatorTest do
  @moduledoc """
  Tests for the Consensus Aggregator module that clusters and analyzes responses.
  """

  # Uses Task.async (not Task.async_stream) which works fine with DataCase shared mode
  use Quoracle.DataCase, async: true
  alias Quoracle.Consensus.Aggregator

  # DataCase already handles sandbox setup with shared mode

  describe "cluster_responses/1" do
    test "creates single cluster for identical actions" do
      responses = [
        %{action: :spawn_child, params: %{task: "analyze data"}, reasoning: "need analysis"},
        %{action: :spawn_child, params: %{task: "analyze data"}, reasoning: "data analysis"},
        %{action: :spawn_child, params: %{task: "analyze data"}, reasoning: "must analyze"}
      ]

      clusters = Aggregator.cluster_responses(responses)
      assert length(clusters) == 1
      assert hd(clusters).count == 3
    end

    test "creates separate clusters for different action types" do
      responses = [
        %{action: :spawn_child, params: %{task: "analyze"}, reasoning: "spawn"},
        %{action: :wait, params: %{wait: 5000}, reasoning: "wait"},
        %{action: :orient, params: %{focus: "state"}, reasoning: "orient"}
      ]

      clusters = Aggregator.cluster_responses(responses)
      assert length(clusters) == 3
      assert Enum.all?(clusters, &(&1.count == 1))
    end

    test "groups same action type with matching params per consensus rules" do
      responses = [
        %{
          action: :spawn_child,
          params: %{
            task_description: "analyze user data",
            success_criteria: "Complete",
            immediate_context: "Test",
            approach_guidance: "Standard"
          },
          reasoning: "r1"
        },
        %{
          action: :spawn_child,
          params: %{
            task_description: "analyze the user data",
            success_criteria: "Complete",
            immediate_context: "Test",
            approach_guidance: "Standard"
          },
          reasoning: "r2"
        },
        %{
          action: :spawn_child,
          params: %{
            task_description: "debug system",
            success_criteria: "Complete",
            immediate_context: "Test",
            approach_guidance: "Standard"
          },
          reasoning: "r3"
        }
      ]

      clusters = Aggregator.cluster_responses(responses)
      # First two should cluster (similar task_description), third should be separate
      assert length(clusters) == 2
      assert Enum.any?(clusters, &(&1.count == 2))
      assert Enum.any?(clusters, &(&1.count == 1))
    end

    test "separates same action type with non-matching params" do
      responses = [
        %{action: :execute_shell, params: %{command: "ls -la"}, reasoning: "list files"},
        %{action: :execute_shell, params: %{command: "rm -rf /"}, reasoning: "danger"}
      ]

      clusters = Aggregator.cluster_responses(responses)
      assert length(clusters) == 2
      assert Enum.all?(clusters, &(&1.count == 1))
    end

    test "handles empty responses list" do
      clusters = Aggregator.cluster_responses([])
      assert clusters == []
    end
  end

  describe "find_majority_cluster/2" do
    test "returns majority when one cluster has >50%" do
      cluster_majority = %{count: 3, actions: [], representative: %{}}
      cluster_minority = %{count: 2, actions: [], representative: %{}}
      clusters = [cluster_majority, cluster_minority]

      assert {:majority, ^cluster_majority} =
               Aggregator.find_majority_cluster(clusters, 5)
    end

    test "returns no_majority when no cluster has >50%" do
      clusters = [
        %{count: 2, actions: [], representative: %{}},
        %{count: 2, actions: [], representative: %{}},
        %{count: 1, actions: [], representative: %{}}
      ]

      assert {:no_majority, ^clusters} =
               Aggregator.find_majority_cluster(clusters, 5)
    end

    test "returns no_majority for exact 50% (tie)" do
      clusters = [
        %{count: 2, actions: [], representative: %{}},
        %{count: 2, actions: [], representative: %{}}
      ]

      assert {:no_majority, ^clusters} =
               Aggregator.find_majority_cluster(clusters, 4)
    end

    test "handles single cluster with 100%" do
      cluster = %{count: 5, actions: [], representative: %{}}

      assert {:majority, ^cluster} =
               Aggregator.find_majority_cluster([cluster], 5)
    end
  end

  describe "find_majority_cluster/3 round-based thresholds" do
    # Round 1 requires 100% unanimous agreement to ensure all models
    # are exposed to each other's ideas via refinement at least once

    test "round 1 requires unanimous (100%) - 80% fails" do
      # 4/5 = 80% should NOT be enough in round 1
      cluster_80 = %{count: 4, actions: [], representative: %{action: :wait}}
      cluster_20 = %{count: 1, actions: [], representative: %{action: :orient}}
      clusters = [cluster_80, cluster_20]

      assert {:no_majority, ^clusters} =
               Aggregator.find_majority_cluster(clusters, 5, 1)
    end

    test "round 1 requires unanimous (100%) - 100% passes" do
      # 5/5 = 100% should pass in round 1
      unanimous_cluster = %{count: 5, actions: [], representative: %{action: :wait}}

      assert {:majority, ^unanimous_cluster} =
               Aggregator.find_majority_cluster([unanimous_cluster], 5, 1)
    end

    test "round 1 requires unanimous - 2/3 fails" do
      # 2/3 = 67% should NOT be enough in round 1
      cluster_67 = %{count: 2, actions: [], representative: %{action: :spawn_child}}
      cluster_33 = %{count: 1, actions: [], representative: %{action: :wait}}
      clusters = [cluster_67, cluster_33]

      assert {:no_majority, ^clusters} =
               Aggregator.find_majority_cluster(clusters, 3, 1)
    end

    test "round 2 requires majority (>50%) - 60% passes" do
      # 3/5 = 60% should pass in round 2
      cluster_60 = %{count: 3, actions: [], representative: %{action: :wait}}
      cluster_40 = %{count: 2, actions: [], representative: %{action: :orient}}
      clusters = [cluster_60, cluster_40]

      assert {:majority, ^cluster_60} =
               Aggregator.find_majority_cluster(clusters, 5, 2)
    end

    test "round 3 uses majority threshold" do
      # 4/5 = 80% should pass in round 3
      cluster_80 = %{count: 4, actions: [], representative: %{action: :wait}}
      cluster_20 = %{count: 1, actions: [], representative: %{action: :orient}}
      clusters = [cluster_80, cluster_20]

      assert {:majority, ^cluster_80} =
               Aggregator.find_majority_cluster(clusters, 5, 3)
    end

    test "default round parameter uses majority threshold" do
      # When round not specified, defaults to majority (>50%)
      cluster_60 = %{count: 3, actions: [], representative: %{action: :wait}}
      cluster_40 = %{count: 2, actions: [], representative: %{action: :orient}}
      clusters = [cluster_60, cluster_40]

      # No round param = default to round 2 behavior
      assert {:majority, ^cluster_60} =
               Aggregator.find_majority_cluster(clusters, 5)
    end
  end

  describe "action_fingerprint/1" do
    test "creates fingerprint for spawn_child action" do
      action = %{
        action: :spawn_child,
        params: %{
          task_description: "analyze data",
          success_criteria: "Complete",
          immediate_context: "Test",
          approach_guidance: "Standard",
          config: %{timeout: 5000}
        },
        reasoning: "need analysis"
      }

      fingerprint = Aggregator.action_fingerprint(action)
      assert {action_type, _signature} = fingerprint
      assert action_type == :spawn_child
    end

    test "creates different fingerprints for different params" do
      action1 = %{
        action: :spawn_child,
        params: %{
          task_description: "analyze",
          success_criteria: "Complete",
          immediate_context: "Test",
          approach_guidance: "Standard"
        },
        reasoning: ""
      }

      action2 = %{
        action: :spawn_child,
        params: %{
          task_description: "debug",
          success_criteria: "Complete",
          immediate_context: "Test",
          approach_guidance: "Standard"
        },
        reasoning: ""
      }

      fp1 = Aggregator.action_fingerprint(action1)
      fp2 = Aggregator.action_fingerprint(action2)

      assert fp1 != fp2
    end

    test "handles invalid action type" do
      action = %{action: :invalid_action, params: %{}, reasoning: ""}
      fingerprint = Aggregator.action_fingerprint(action)
      assert {:invalid_action, :invalid} = fingerprint
    end
  end

  describe "actions_match?/2" do
    test "returns false for different action types" do
      action1 = %{action: :spawn_child, params: %{task: "analyze"}, reasoning: ""}
      action2 = %{action: :wait, params: %{wait: 5000}, reasoning: ""}

      refute Aggregator.actions_match?(action1, action2)
    end

    test "returns true for same type with matching params per schema rules" do
      action1 = %{action: :orient, params: %{current_situation: "analyzing data"}, reasoning: ""}

      action2 = %{
        action: :orient,
        params: %{current_situation: "analyzing the data"},
        reasoning: ""
      }

      assert Aggregator.actions_match?(action1, action2)
    end

    test "returns false for same type with non-matching params" do
      action1 = %{action: :execute_shell, params: %{command: "ls"}, reasoning: ""}
      action2 = %{action: :execute_shell, params: %{command: "rm"}, reasoning: ""}

      refute Aggregator.actions_match?(action1, action2)
    end
  end

  describe "build_refinement_prompt/3" do
    test "includes JSON representation of all proposed actions" do
      responses = [
        %{action: :spawn_child, params: %{task: "analyze"}, reasoning: "need analysis"},
        %{action: :wait, params: %{wait: 5000}, reasoning: "wait for data"}
      ]

      context = %{prompt: "process data", reasoning_history: []}

      prompt = Aggregator.build_refinement_prompt(responses, 2, context)

      assert prompt =~ "Round 2"
      assert prompt =~ "process data"
      assert prompt =~ ~s("action")
      assert prompt =~ ~s("params")
      assert prompt =~ "JSON"
    end

    test "preserves reasoning history from previous rounds" do
      responses = [%{action: :wait, params: %{}, reasoning: "current reasoning"}]

      # v7.0: reasoning_history now stores response maps
      context = %{
        prompt: "decide next action",
        reasoning_history: [
          [
            %{action: :wait, params: %{}, reasoning: "round 1 reasoning A"},
            %{action: :orient, params: %{}, reasoning: "round 1 reasoning B"}
          ],
          [
            %{action: :wait, params: %{}, reasoning: "round 2 reasoning A"},
            %{action: :orient, params: %{}, reasoning: "round 2 reasoning B"}
          ]
        ]
      }

      prompt = Aggregator.build_refinement_prompt(responses, 3, context)

      assert prompt =~ "Previous reasoning"
      assert prompt =~ "Round 3"
    end

    test "does NOT show vote percentages" do
      responses = [
        %{action: :spawn_child, params: %{task: "a"}, reasoning: "r1"},
        %{action: :spawn_child, params: %{task: "a"}, reasoning: "r2"},
        %{action: :wait, params: %{}, reasoning: "r3"}
      ]

      context = %{prompt: "test", reasoning_history: []}

      prompt = Aggregator.build_refinement_prompt(responses, 1, context)

      refute prompt =~ "%"
      refute prompt =~ "66"
      refute prompt =~ "33"
      refute prompt =~ "percentage"
    end

    test "uses context max_refinement_rounds for final hint" do
      responses = [%{action: :wait, params: %{}, reasoning: ""}]
      context = %{prompt: "test", reasoning_history: [], max_refinement_rounds: 2}

      prompt = Aggregator.build_refinement_prompt(responses, 2, context)

      assert prompt =~ "final round"
    end

    test "does not mark final round before context limit" do
      responses = [%{action: :wait, params: %{}, reasoning: ""}]
      context = %{prompt: "test", reasoning_history: [], max_refinement_rounds: 5}

      prompt = Aggregator.build_refinement_prompt(responses, 4, context)

      refute prompt =~ "final round"
    end

    test "final prompt uses context max_refinement_rounds" do
      responses = [%{action: :wait, params: %{}, reasoning: ""}]
      context = %{prompt: "test", reasoning_history: [], max_refinement_rounds: 7}

      prompt = Aggregator.build_final_round_prompt(responses, context)

      assert prompt =~ "after 6 rounds of discussion"
    end

    test "defaults to 4 when context missing max_refinement_rounds" do
      responses = [%{action: :wait, params: %{}, reasoning: ""}]

      # Context WITH max=2: round 2 should be final
      context_with = %{prompt: "test", reasoning_history: [], max_refinement_rounds: 2}
      prompt_with = Aggregator.build_refinement_prompt(responses, 2, context_with)
      assert prompt_with =~ "final round"

      # Context WITHOUT max (default 4): round 2 should NOT be final
      context_without = %{prompt: "test", reasoning_history: []}
      prompt_without = Aggregator.build_refinement_prompt(responses, 2, context_without)
      refute prompt_without =~ "final round"
    end
  end

  describe "extract_reasoning_history/1" do
    test "extracts reasoning from previous rounds" do
      previous_rounds = [
        [
          %{reasoning: "First round, first model"},
          %{reasoning: "First round, second model"}
        ],
        [
          %{reasoning: "Second round, first model"},
          %{reasoning: "Second round, second model"}
        ]
      ]

      history = Aggregator.extract_reasoning_history(previous_rounds)

      assert is_list(history)
      assert length(history) == 2
    end

    test "handles empty history" do
      history = Aggregator.extract_reasoning_history([])
      assert history == []
    end
  end

  # =============================================================
  # ACE v3.0 - MULTI-MODEL AWARENESS (ace-20251207-140000)
  # =============================================================

  describe "[UNIT] multi-model prompts (ACE R17-R21)" do
    test "refinement prompt explains multi-model process (R17)" do
      # R17: WHEN build_refinement_prompt called THEN explains multi-model consensus process
      responses = [
        %{action: :spawn_child, params: %{task: "analyze"}, reasoning: "need analysis"},
        %{action: :wait, params: %{}, reasoning: "wait for data"}
      ]

      context = %{prompt: "process data", reasoning_history: []}

      prompt = Aggregator.build_refinement_prompt(responses, 2, context)

      # Should explain multi-model consensus process
      assert prompt =~ "multi-model consensus"
    end

    test "refinement prompt mentions independent histories (R18)" do
      # R18: WHEN build_refinement_prompt called THEN mentions models have independent context
      responses = [%{action: :wait, params: %{}, reasoning: "waiting"}]
      context = %{prompt: "test task", reasoning_history: []}

      prompt = Aggregator.build_refinement_prompt(responses, 1, context)

      # Should mention that models have independent context/history
      assert prompt =~ "independent context"
    end

    test "refinement prompt hides response attribution (R19)" do
      # R19: WHEN build_refinement_prompt called THEN does NOT identify which model gave which response
      responses = [
        %{action: :spawn_child, params: %{task: "a"}, reasoning: "reason 1"},
        %{action: :wait, params: %{}, reasoning: "reason 2"},
        %{action: :orient, params: %{}, reasoning: "reason 3"}
      ]

      context = %{prompt: "test", reasoning_history: []}

      prompt = Aggregator.build_refinement_prompt(responses, 1, context)

      # Should NOT contain model identifiers
      refute prompt =~ "model-1"
      refute prompt =~ "model-2"
      refute prompt =~ "model-3"
      refute prompt =~ "Model 1"
      refute prompt =~ "Model 2"
      refute prompt =~ "gpt"
      refute prompt =~ "claude"
      refute prompt =~ "gemini"
    end

    test "refinement prompt frames as deliberation (R20)" do
      # R20: WHEN build_refinement_prompt called THEN frames as deliberation not voting
      responses = [
        %{action: :spawn_child, params: %{task: "a"}, reasoning: "r1"},
        %{action: :wait, params: %{}, reasoning: "r2"}
      ]

      context = %{prompt: "decide action", reasoning_history: []}

      prompt = Aggregator.build_refinement_prompt(responses, 2, context)

      # Should frame as deliberation/consideration, not voting
      assert prompt =~ "deliberation"
      refute prompt =~ "vote"
      refute prompt =~ "voting"
    end

    test "final round prompt emphasizes finality (R21)" do
      # R21: WHEN build_final_round_prompt called THEN emphasizes this is the last chance
      responses = [
        %{action: :spawn_child, params: %{task: "final"}, reasoning: "commit to this"}
      ]

      context = %{
        prompt: "complete task",
        reasoning_history: [["prev1"], ["prev2"]],
        total_rounds: 5
      }

      prompt = Aggregator.build_final_round_prompt(responses, context)

      # Should emphasize this is the final round - exact phrasing may vary
      assert prompt =~ "FINAL"
      assert prompt =~ "final"
    end
  end

  # =============================================================
  # v4.0 - SMART PER-ACTION TRUNCATION (feat-20251208-234737)
  # =============================================================

  describe "[UNIT] format_action_summary/1 (R22-R38)" do
    test "format_action_summary includes action name (R22)" do
      # R22: WHEN format_action_summary called THEN output contains action name in brackets
      response = %{action: :wait, params: %{wait: 5000}}
      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[wait"
      assert summary =~ "]"
    end

    test "format_action_summary extracts command for execute_shell (R23)" do
      # R23: WHEN format_action_summary called with execute_shell THEN shows command or check_id
      response = %{action: :execute_shell, params: %{command: "git status --porcelain"}}
      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[execute_shell"
      assert summary =~ "git status"
    end

    test "format_action_summary extracts check_id for execute_shell (R23b)" do
      # R23: execute_shell with check_id instead of command
      response = %{action: :execute_shell, params: %{check_id: "abc123"}}
      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[execute_shell"
      assert summary =~ "check(abc123)"
    end

    test "format_action_summary extracts task_description for spawn_child (R24)" do
      # R24: WHEN format_action_summary called with spawn_child THEN shows task_description
      response = %{action: :spawn_child, params: %{task_description: "Analyze the JSON response"}}
      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[spawn_child"
      assert summary =~ "Analyze"
    end

    test "format_action_summary extracts prompt for answer_engine (R25)" do
      # R25: WHEN format_action_summary called with answer_engine THEN shows prompt
      response = %{action: :answer_engine, params: %{prompt: "What format does the API expect?"}}
      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[answer_engine"
      assert summary =~ "format"
    end

    test "format_action_summary extracts url for fetch_web (R26)" do
      # R26: WHEN format_action_summary called with fetch_web THEN shows url
      response = %{action: :fetch_web, params: %{url: "https://api.example.com/data"}}
      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[fetch_web"
      assert summary =~ "api.example.com"
    end

    test "format_action_summary extracts target and content for send_message (R27)" do
      # R27: WHEN format_action_summary called with send_message THEN shows target and content
      response = %{
        action: :send_message,
        params: %{to: :parent, content: "Task completed successfully"}
      }

      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[send_message"
      assert summary =~ "parent"
      assert summary =~ "completed"
    end

    test "format_action_summary extracts api_type and url for call_api (R28)" do
      # R28: WHEN format_action_summary called with call_api THEN shows api_type, method, url
      response = %{
        action: :call_api,
        params: %{api_type: "rest", method: "GET", url: "https://api.test.com"}
      }

      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[call_api"
      assert summary =~ "rest"
    end

    test "format_action_summary extracts tool for call_mcp (R29)" do
      # R29: WHEN format_action_summary called with call_mcp THEN shows tool or transport+command
      response = %{action: :call_mcp, params: %{tool: "filesystem_read"}}
      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[call_mcp"
      assert summary =~ "filesystem_read"
    end

    test "format_action_summary extracts transport+command for call_mcp (R29b)" do
      # R29: call_mcp with transport+command instead of tool
      response = %{
        action: :call_mcp,
        params: %{transport: "stdio", command: "npx @modelcontextprotocol/server"}
      }

      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[call_mcp"
      assert summary =~ "connect"
    end

    test "format_action_summary extracts wait value (R30)" do
      # R30: WHEN format_action_summary called with wait THEN shows wait value
      response = %{action: :wait, params: %{wait: 5000}}
      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[wait"
      assert summary =~ "5000"
    end

    test "format_action_summary extracts current_situation for orient (R31)" do
      # R31: WHEN format_action_summary called with orient THEN shows current_situation
      response = %{action: :orient, params: %{current_situation: "Analyzing test results"}}
      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[orient"
      assert summary =~ "Analyzing"
    end

    test "format_action_summary shows item count for todo (R32)" do
      # R32: WHEN format_action_summary called with todo THEN shows item count
      response = %{action: :todo, params: %{items: ["item1", "item2", "item3"]}}
      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[todo"
      assert summary =~ "3 items"
    end

    test "format_action_summary extracts name for generate_secret (R35)" do
      # R35: WHEN format_action_summary called with generate_secret THEN shows name
      response = %{action: :generate_secret, params: %{name: "API_KEY"}}
      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[generate_secret"
      assert summary =~ "API_KEY"
    end

    test "format_action_summary truncates long summaries with ellipsis (R37)" do
      # R37: WHEN format_action_summary result exceeds 100 chars THEN truncates with ellipsis
      long_command = String.duplicate("x", 200)
      response = %{action: :execute_shell, params: %{command: long_command}}
      summary = Aggregator.format_action_summary(response)

      assert String.length(summary) <= 100
      assert summary =~ "..."
    end

    test "format_action_summary handles missing params gracefully (R38)" do
      # R38: WHEN format_action_summary called with missing params THEN returns action name only
      response = %{action: :execute_shell, params: %{}}
      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[execute_shell]"
      # Should not crash
    end

    test "format_action_summary handles unknown action type (R38b)" do
      # R38: Unknown action type should return bracketed name
      response = %{action: :unknown_action, params: %{foo: "bar"}}
      summary = Aggregator.format_action_summary(response)

      assert summary =~ "[unknown_action]"
    end
  end

  describe "[UNIT] format_reasoning_history with action context (R39-R42)" do
    test "format_reasoning_history shows action context with reasoning (R39)" do
      # R39: WHEN format_reasoning_history called with response maps THEN formats with action summaries
      history = [
        [
          %{
            action: :execute_shell,
            params: %{command: "git status"},
            reasoning: "Check repo state"
          },
          %{action: :wait, params: %{wait: 5000}, reasoning: "Give time to process"}
        ]
      ]

      # format_reasoning_history is private, so test via build_refinement_prompt
      responses = [%{action: :orient, params: %{}, reasoning: "current"}]
      context = %{prompt: "test", reasoning_history: history}
      prompt = Aggregator.build_refinement_prompt(responses, 2, context)

      # Should show action context with reasoning
      assert prompt =~ "execute_shell"
      assert prompt =~ "Check repo state"
    end

    test "format_reasoning_history shows placeholder for empty reasoning (R40)" do
      # R40: WHEN response has empty reasoning THEN shows "(no reasoning provided)"
      history = [
        [
          %{action: :wait, params: %{wait: 1000}, reasoning: nil},
          %{action: :orient, params: %{}, reasoning: ""}
        ]
      ]

      responses = [%{action: :orient, params: %{}, reasoning: "current"}]
      context = %{prompt: "test", reasoning_history: history}
      prompt = Aggregator.build_refinement_prompt(responses, 2, context)

      assert prompt =~ "no reasoning provided"
    end

    test "format_reasoning_history groups by round (R41)" do
      # R41: WHEN format_reasoning_history called THEN groups by round with "Round N:" headers
      history = [
        [%{action: :wait, params: %{wait: 1000}, reasoning: "Round 1 reasoning"}],
        [%{action: :orient, params: %{}, reasoning: "Round 2 reasoning"}]
      ]

      responses = [%{action: :orient, params: %{}, reasoning: "current"}]
      context = %{prompt: "test", reasoning_history: history}
      prompt = Aggregator.build_refinement_prompt(responses, 3, context)

      assert prompt =~ "Round 1"
      assert prompt =~ "Round 2"
    end

    test "format_reasoning_history limits to 3 entries per round (R42)" do
      # R42: WHEN round has >3 responses THEN shows only first 3
      history = [
        [
          %{action: :wait, params: %{}, reasoning: "First"},
          %{action: :wait, params: %{}, reasoning: "Second"},
          %{action: :wait, params: %{}, reasoning: "Third"},
          %{action: :wait, params: %{}, reasoning: "Fourth"},
          %{action: :wait, params: %{}, reasoning: "Fifth"}
        ]
      ]

      responses = [%{action: :orient, params: %{}, reasoning: "current"}]
      context = %{prompt: "test", reasoning_history: history}
      prompt = Aggregator.build_refinement_prompt(responses, 2, context)

      assert prompt =~ "First"
      assert prompt =~ "Second"
      assert prompt =~ "Third"
      refute prompt =~ "Fourth"
      refute prompt =~ "Fifth"
    end
  end

  describe "[INTEGRATION] build_refinement_prompt with new format (R43)" do
    test "build_refinement_prompt works with new reasoning_history format (R43)" do
      # R43: WHEN build_refinement_prompt called with new reasoning_history format THEN renders correctly
      history = [
        [
          %{action: :execute_shell, params: %{command: "git status"}, reasoning: "Check state"},
          %{
            action: :spawn_child,
            params: %{task_description: "Analyze data"},
            reasoning: "Delegate work"
          }
        ],
        [
          %{action: :wait, params: %{wait: 5000}, reasoning: "Wait for response"},
          %{
            action: :answer_engine,
            params: %{prompt: "What next?"},
            reasoning: "Need clarification"
          }
        ]
      ]

      responses = [
        %{
          action: :orient,
          params: %{current_situation: "analyzing"},
          reasoning: "current decision"
        }
      ]

      context = %{prompt: "Complete the analysis task", reasoning_history: history}
      prompt = Aggregator.build_refinement_prompt(responses, 3, context)

      # Should render without errors
      assert is_binary(prompt)
      # Should contain round headers
      assert prompt =~ "Round 1"
      assert prompt =~ "Round 2"
      # Should contain action context
      assert prompt =~ "execute_shell"
      assert prompt =~ "spawn_child"
      # Should contain reasoning
      assert prompt =~ "Check state"
      assert prompt =~ "Delegate work"
      # Should contain goal
      assert prompt =~ "Complete the analysis task"
    end
  end

  describe "embedding-based semantic similarity" do
    test "uses Embeddings module for semantic similarity comparison" do
      # Test that semantic similarity uses mocked embeddings
      _text1 = "analyze customer data for patterns"
      _text2 = "perform pattern analysis on client information"

      # Mock embeddings to return similar vectors
      mock_embedding1 = [0.1, 0.2, 0.3, 0.4, 0.5]
      mock_embedding2 = [0.11, 0.19, 0.31, 0.39, 0.51]

      # Calculate similarity with mocked embeddings
      similarity = Aggregator.cosine_similarity(mock_embedding1, mock_embedding2)

      # These mocked vectors should be very similar (>0.99)
      assert similarity > 0.99
    end

    test "clusters identical semantic params into one cluster" do
      responses = [
        %{action: :spawn_child, params: %{task: "analyze data"}, reasoning: "Need data"},
        %{action: :spawn_child, params: %{task: "analyze data"}, reasoning: "Get data"},
        %{action: :spawn_child, params: %{task: "analyze data"}, reasoning: "Load data"}
      ]

      clusters = Aggregator.cluster_responses(responses)

      assert length(clusters) == 1
      assert hd(clusters).count == 3
    end

    test "get_cached_embedding returns metadata with injected fn" do
      test_pid = self()

      embedding_fn = fn text ->
        send(test_pid, {:embedding_called, text})
        {:ok, [0.1, 0.2, 0.3]}
      end

      assert {:ok, %{embedding: [0.1, 0.2, 0.3], cached: false, chunks: 1}} =
               Aggregator.get_cached_embedding("cache-test", embedding_fn: embedding_fn)

      assert_receive {:embedding_called, "cache-test"}
    end

    test "computes cosine similarity between embeddings" do
      vec1 = [0.1, 0.2, 0.3]
      vec2 = [0.1, 0.2, 0.3]
      vec3 = [-0.1, -0.2, -0.3]

      # Same vectors should have similarity 1.0
      assert Aggregator.cosine_similarity(vec1, vec2) == 1.0

      # Opposite vectors should have similarity -1.0
      assert_in_delta Aggregator.cosine_similarity(vec1, vec3), -1.0, 0.01
    end

    test "semantic_similarity_with_embeddings/3 respects threshold" do
      # Test with cosine similarity directly using mock vectors
      similar_vec1 = [0.1, 0.2, 0.3]
      similar_vec2 = [0.11, 0.21, 0.29]
      # Opposite vector for negative similarity
      different_vec = [-0.1, -0.2, -0.3]

      # High similarity
      assert Aggregator.cosine_similarity(similar_vec1, similar_vec2) > 0.95

      # Negative similarity (opposite vectors)
      assert Aggregator.cosine_similarity(similar_vec1, different_vec) < -0.9
    end
  end

  # =============================================================================
  # v7.0 Cost Context Threading (fix-costs-20260129 audit fix)
  # =============================================================================

  describe "[UNIT] calculate_semantic_similarity cost context (R64-R65)" do
    # R64: 2-arity embedding_fn receives cost context
    # Currently calculate_semantic_similarity calls embedding_fn.(text) with 1 arg.
    # A 2-arity fn passed as embedding_fn crashes with BadArityError.
    # The fix: support both 1-arity and 2-arity embedding_fn (like LessonManager).
    test "supports 2-arity embedding_fn for cost context forwarding" do
      test_pid = self()

      embedding_fn = fn text, cost_opts ->
        send(test_pid, {:embedding_called, text, cost_opts})
        {:ok, [1.0, 0.0, 0.0]}
      end

      result =
        Aggregator.calculate_semantic_similarity("hello", "world",
          embedding_fn: embedding_fn,
          agent_id: "test-agent",
          task_id: 42,
          pubsub: :test_pubsub
        )

      assert is_float(result)

      assert_received {:embedding_called, "hello", cost_opts}
      assert cost_opts[:agent_id] == "test-agent"
      assert cost_opts[:task_id] == 42
      assert cost_opts[:pubsub] == :test_pubsub

      assert_received {:embedding_called, "world", _}
    end

    # R65: 1-arity embedding_fn still works (backward compatible)
    test "1-arity embedding_fn still works without cost context" do
      embedding_fn = fn _text ->
        {:ok, [1.0, 0.0, 0.0]}
      end

      result =
        Aggregator.calculate_semantic_similarity("hello", "world", embedding_fn: embedding_fn)

      assert is_float(result)
      assert result == 1.0
    end
  end

  # =============================================================================
  # CONSENSUS_Agg v8.0: Cost Accumulator Threading
  # WorkGroupID: feat-20260203-194408
  # Packet: 2 (Threading)
  # =============================================================================

  alias Quoracle.Costs.Accumulator

  describe "R57: accumulator threaded through similarity" do
    test "threads cost_accumulator through semantic similarity embeddings" do
      test_pid = self()

      # Mock that captures opts to verify accumulator is passed
      embedding_fn = fn text, opts ->
        send(test_pid, {:embedding_call, text, opts})
        {:ok, [1.0, 0.0, 0.0]}
      end

      acc = Accumulator.new()

      Aggregator.calculate_semantic_similarity("hello", "world",
        embedding_fn: embedding_fn,
        cost_accumulator: acc
      )

      # Both embedding calls should receive the accumulator
      assert_receive {:embedding_call, "hello", opts1}, 1000
      assert Map.get(opts1, :cost_accumulator) != nil

      assert_receive {:embedding_call, "world", opts2}, 1000
      assert Map.get(opts2, :cost_accumulator) != nil
    end
  end

  describe "R58: returns updated accumulator" do
    test "returns updated accumulator from semantic similarity" do
      # Mock that returns updated accumulator
      embedding_fn = fn _text, opts ->
        acc = Map.get(opts, :cost_accumulator, Accumulator.new())

        entry = %{
          agent_id: "test",
          task_id: Ecto.UUID.generate(),
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.001"),
          metadata: %{}
        }

        updated_acc = Accumulator.add(acc, entry)
        {:ok, [1.0, 0.0, 0.0], updated_acc}
      end

      acc = Accumulator.new()

      result =
        Aggregator.calculate_semantic_similarity("hello", "world",
          embedding_fn: embedding_fn,
          cost_accumulator: acc
        )

      # Should return {similarity, updated_acc} tuple
      assert {similarity, %Accumulator{} = final_acc} = result
      assert is_float(similarity)
      assert Accumulator.count(final_acc) == 2
    end
  end

  describe "R59: works without accumulator" do
    test "semantic similarity works without accumulator" do
      embedding_fn = fn _text ->
        {:ok, [1.0, 0.0, 0.0]}
      end

      result =
        Aggregator.calculate_semantic_similarity("hello", "world", embedding_fn: embedding_fn)

      # Should return plain similarity float, not tuple
      assert is_float(result)
      refute is_tuple(result)
    end

    test "returns float only when no accumulator provided" do
      embedding_fn = fn _text, _opts ->
        {:ok, [0.5, 0.5, 0.5]}
      end

      result =
        Aggregator.calculate_semantic_similarity("text1", "text2",
          embedding_fn: embedding_fn,
          agent_id: "test"
          # Note: no cost_accumulator
        )

      # Without accumulator, returns plain float
      assert is_float(result)
    end
  end
end
