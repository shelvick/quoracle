defmodule Quoracle.Consensus.ResultTest do
  # Uses Task.async (not Task.async_stream) which works fine with DataCase shared mode
  use Quoracle.DataCase, async: true
  alias Quoracle.Consensus.Manager
  alias Quoracle.Consensus.Result

  # =============================================================================
  # PACKET 1: Enhanced Tie-Breaking Tests (WorkGroupID: tiebreak-20251208-202952)
  # =============================================================================
  # These tests cover R5-R22 from CONSENSUS_Result spec v2.0
  # All tests should FAIL until implementation is complete

  describe "wait_score/1" do
    # R5: Wait Score True (lowest = preferred, true-biased tiebreak)
    test "returns {0, 0} for true" do
      assert Result.wait_score(true) == {0, 0}
    end

    # R6: Wait Score Nil
    test "returns {0, 1} for nil" do
      assert Result.wait_score(nil) == {0, 1}
    end

    # R7: Wait Score Positive Integer
    test "returns {0, 1 + n} for positive integers" do
      assert Result.wait_score(1) == {0, 2}
      assert Result.wait_score(5) == {0, 6}
      assert Result.wait_score(100) == {0, 101}
      assert Result.wait_score(10_000) == {0, 10_001}
    end

    # R8: Wait Score False/Zero (highest = least preferred)
    test "returns {1, 0} for false and 0" do
      assert Result.wait_score(false) == {1, 0}
      assert Result.wait_score(0) == {1, 0}
    end
  end

  describe "auto_complete_score/1" do
    # R9: Auto-Complete Score False
    test "returns {0, 0} for false" do
      assert Result.auto_complete_score(false) == {0, 0}
    end

    # R10: Auto-Complete Score Nil
    test "returns {0, 1} for nil" do
      assert Result.auto_complete_score(nil) == {0, 1}
    end

    # R11: Auto-Complete Score True
    test "returns {1, 0} for true" do
      assert Result.auto_complete_score(true) == {1, 0}
    end
  end

  describe "cluster_wait_score/1" do
    # R12: Cluster Wait Score Sum
    test "sums all action wait scores" do
      cluster = %{
        actions: [
          %{action: :spawn_child, wait: false, params: %{}},
          %{action: :spawn_child, wait: 5, params: %{}},
          %{action: :spawn_child, wait: true, params: %{}}
        ]
      }

      # false → {1,0}, 5 → {0,6}, true → {0,0}
      # Sum: {1+0+0, 0+6+0} = {1, 6}
      assert Result.cluster_wait_score(cluster) == {1, 6}
    end

    # R13: Cluster Wait Score Missing Fields
    test "treats missing wait as nil" do
      cluster = %{
        actions: [
          %{action: :spawn_child, wait: false, params: %{}},
          %{action: :spawn_child, params: %{}}
        ]
      }

      # false → {1,0}, missing(nil) → {0,1}
      # Sum: {1+0, 0+1} = {1, 1}
      assert Result.cluster_wait_score(cluster) == {1, 1}
    end

    test "sums correctly for all-false cluster" do
      cluster = %{
        actions: [
          %{action: :wait, wait: false, params: %{}},
          %{action: :wait, wait: false, params: %{}}
        ]
      }

      # {1,0} + {1,0} = {2, 0}
      assert Result.cluster_wait_score(cluster) == {2, 0}
    end

    test "sums correctly for all-true cluster" do
      cluster = %{
        actions: [
          %{action: :wait, wait: true, params: %{}},
          %{action: :wait, wait: true, params: %{}}
        ]
      }

      # {0,0} + {0,0} = {0, 0}
      assert Result.cluster_wait_score(cluster) == {0, 0}
    end
  end

  describe "cluster_auto_complete_score/1" do
    # R14: Cluster Auto-Complete Score Sum
    test "sums all action scores" do
      cluster = %{
        actions: [
          %{action: :spawn_child, auto_complete_todo: false, params: %{}},
          %{action: :spawn_child, auto_complete_todo: true, params: %{}},
          %{action: :spawn_child, auto_complete_todo: nil, params: %{}}
        ]
      }

      # false → {0,0}, true → {1,0}, nil → {0,1}
      # Sum: {0+1+0, 0+0+1} = {1, 1}
      assert Result.cluster_auto_complete_score(cluster) == {1, 1}
    end

    # R15: Cluster Auto-Complete Score Missing Fields
    test "treats missing field as nil" do
      cluster = %{
        actions: [
          %{action: :spawn_child, auto_complete_todo: false, params: %{}},
          %{action: :spawn_child, params: %{}}
        ]
      }

      # false → {0,0}, missing(nil) → {0,1}
      # Sum: {0+0, 0+1} = {0, 1}
      assert Result.cluster_auto_complete_score(cluster) == {0, 1}
    end

    test "sums correctly for all-false cluster" do
      cluster = %{
        actions: [
          %{action: :orient, auto_complete_todo: false, params: %{}},
          %{action: :orient, auto_complete_todo: false, params: %{}}
        ]
      }

      # {0,0} + {0,0} = {0, 0}
      assert Result.cluster_auto_complete_score(cluster) == {0, 0}
    end
  end

  describe "break_tie/1 enhanced 3-level chain" do
    # R16: Tiebreak Level 1 - Action Priority
    test "selects action with lowest priority" do
      # orient has priority 1, spawn_child has priority 10
      tied_clusters = [
        %{
          representative: %{action: :spawn_child, params: %{}, reasoning: ""},
          actions: [%{action: :spawn_child, wait: false, auto_complete_todo: false, params: %{}}],
          count: 2
        },
        %{
          representative: %{action: :orient, params: %{}, reasoning: ""},
          actions: [%{action: :orient, wait: false, auto_complete_todo: false, params: %{}}],
          count: 2
        }
      ]

      winner = Result.break_tie(tied_clusters)
      assert winner.representative.action == :orient
    end

    # R17: Tiebreak Level 2 - Wait Score (true-biased: true preferred)
    test "uses wait score when priorities equal" do
      # Both are :spawn_child (same priority), but different wait values
      # Put cluster_a FIRST to ensure test fails without proper wait score handling
      cluster_a = %{
        representative: %{action: :spawn_child, params: %{task: "a"}, reasoning: ""},
        actions: [
          %{action: :spawn_child, wait: false, params: %{task: "a"}},
          %{action: :spawn_child, wait: false, params: %{task: "a"}}
        ],
        count: 2
      }

      cluster_b = %{
        representative: %{action: :spawn_child, params: %{task: "b"}, reasoning: ""},
        actions: [
          %{action: :spawn_child, wait: true, params: %{task: "b"}},
          %{action: :spawn_child, wait: true, params: %{task: "b"}}
        ],
        count: 2
      }

      # cluster_a is FIRST - without wait score logic, stable sort would return cluster_a
      winner = Result.break_tie([cluster_a, cluster_b])
      # cluster_a wait score: {1,0} + {1,0} = {2,0}
      # cluster_b wait score: {0,0} + {0,0} = {0,0}
      # {0,0} < {2,0}, so cluster_b should win (not cluster_a)
      assert winner.representative.params.task == "b"
    end

    # R18: Tiebreak Level 3 - Auto-Complete Score
    test "uses auto_complete score as final tiebreaker" do
      # Same priority, same wait scores, different auto_complete_todo
      # Put cluster_b FIRST to ensure test fails without proper auto_complete handling
      cluster_a = %{
        representative: %{action: :spawn_child, params: %{task: "a"}, reasoning: ""},
        actions: [
          %{action: :spawn_child, wait: false, auto_complete_todo: false, params: %{task: "a"}},
          %{action: :spawn_child, wait: false, auto_complete_todo: false, params: %{task: "a"}}
        ],
        count: 2
      }

      cluster_b = %{
        representative: %{action: :spawn_child, params: %{task: "b"}, reasoning: ""},
        actions: [
          %{action: :spawn_child, wait: false, auto_complete_todo: true, params: %{task: "b"}},
          %{action: :spawn_child, wait: false, auto_complete_todo: true, params: %{task: "b"}}
        ],
        count: 2
      }

      # cluster_b is FIRST - without auto_complete logic, stable sort would return cluster_b
      winner = Result.break_tie([cluster_b, cluster_a])
      # Both have wait score {0,0}
      # cluster_a auto_complete: {0,0} + {0,0} = {0,0}
      # cluster_b auto_complete: {1,0} + {1,0} = {2,0}
      # {0,0} < {2,0}, so cluster_a should win (not cluster_b)
      assert winner.representative.params.task == "a"
    end

    # R19: Tiebreak True vs Finite (true-biased: true preferred over finite)
    test "prefers true over finite wait" do
      # Put cluster_finite FIRST to ensure test fails without proper wait score handling
      cluster_finite = %{
        representative: %{action: :spawn_child, params: %{task: "finite"}, reasoning: ""},
        actions: [
          %{action: :spawn_child, wait: 100, params: %{task: "finite"}},
          %{action: :spawn_child, wait: 100, params: %{task: "finite"}}
        ],
        count: 2
      }

      cluster_true = %{
        representative: %{action: :spawn_child, params: %{task: "true"}, reasoning: ""},
        actions: [
          %{action: :spawn_child, wait: true, params: %{task: "true"}},
          %{action: :spawn_child, wait: true, params: %{task: "true"}}
        ],
        count: 2
      }

      # cluster_finite is FIRST - without wait score logic, stable sort would return cluster_finite
      winner = Result.break_tie([cluster_finite, cluster_true])
      # cluster_true: {0,0} + {0,0} = {0, 0}
      # cluster_finite: {0,101} + {0,101} = {0, 202}
      # {0,0} < {0,202}, so cluster_true should win
      assert winner.representative.params.task == "true"
    end

    # R20: Tiebreak True Count (true-biased: more true values preferred)
    test "prefers more true values" do
      # Put cluster_one_true FIRST to ensure test fails without proper wait score handling
      cluster_one_true = %{
        representative: %{action: :spawn_child, params: %{task: "one"}, reasoning: ""},
        actions: [
          %{action: :spawn_child, wait: false, params: %{task: "one"}},
          %{action: :spawn_child, wait: true, params: %{task: "one"}}
        ],
        count: 2
      }

      cluster_two_true = %{
        representative: %{action: :spawn_child, params: %{task: "two"}, reasoning: ""},
        actions: [
          %{action: :spawn_child, wait: true, params: %{task: "two"}},
          %{action: :spawn_child, wait: true, params: %{task: "two"}}
        ],
        count: 2
      }

      # cluster_one_true is FIRST - without wait score logic, stable sort would return cluster_one_true
      winner = Result.break_tie([cluster_one_true, cluster_two_true])
      # cluster_one_true: {1,0} + {0,0} = {1, 0}
      # cluster_two_true: {0,0} + {0,0} = {0, 0}
      # {0,0} < {1,0}, so cluster_two_true should win
      assert winner.representative.params.task == "two"
    end

    # R21: Tiebreak Mixed Cluster (true-biased: all-true preferred over mixed)
    test "handles mixed wait values correctly" do
      # [false, true] vs [true, true]
      # Put cluster_mixed FIRST to ensure test fails without proper wait score handling
      cluster_mixed = %{
        representative: %{action: :spawn_child, params: %{task: "mixed"}, reasoning: ""},
        actions: [
          %{action: :spawn_child, wait: false, params: %{task: "mixed"}},
          %{action: :spawn_child, wait: true, params: %{task: "mixed"}}
        ],
        count: 2
      }

      cluster_all_true = %{
        representative: %{action: :spawn_child, params: %{task: "all_true"}, reasoning: ""},
        actions: [
          %{action: :spawn_child, wait: true, params: %{task: "all_true"}},
          %{action: :spawn_child, wait: true, params: %{task: "all_true"}}
        ],
        count: 2
      }

      # cluster_mixed is FIRST - without wait score logic, stable sort would return cluster_mixed
      winner = Result.break_tie([cluster_mixed, cluster_all_true])
      # cluster_mixed: {1,0} + {0,0} = {1, 0}
      # cluster_all_true: {0,0} + {0,0} = {0, 0}
      # {0,0} < {1,0}, so cluster_all_true should win
      assert winner.representative.params.task == "all_true"
    end

    # R22: Full 3-Level Chain [INTEGRATION] (true-biased wait scoring)
    test "applies full 3-level chain" do
      # Create 4 clusters that require all 3 levels to distinguish
      # Put clusters in "wrong" order to ensure failures without 3-level chain

      # Cluster A: priority 10, wait {1,0} (false), auto {0,0}
      cluster_a = %{
        representative: %{action: :spawn_child, params: %{id: "A"}, reasoning: ""},
        actions: [
          %{action: :spawn_child, wait: false, auto_complete_todo: false, params: %{id: "A"}}
        ],
        count: 2
      }

      # Cluster B: priority 10, wait {1,0} (false), auto {1,0} - loses to A on level 3
      cluster_b = %{
        representative: %{action: :spawn_child, params: %{id: "B"}, reasoning: ""},
        actions: [
          %{action: :spawn_child, wait: false, auto_complete_todo: true, params: %{id: "B"}}
        ],
        count: 2
      }

      # Cluster C: priority 10, wait {0,0} (true), auto {0,0} - wins on level 2
      cluster_c = %{
        representative: %{action: :spawn_child, params: %{id: "C"}, reasoning: ""},
        actions: [
          %{action: :spawn_child, wait: true, auto_complete_todo: false, params: %{id: "C"}}
        ],
        count: 2
      }

      # Cluster D: priority 1 (orient), wait {0,0} (true), auto {1,0} - wins on level 1
      cluster_d = %{
        representative: %{action: :orient, params: %{id: "D"}, reasoning: ""},
        actions: [
          %{action: :orient, wait: true, auto_complete_todo: true, params: %{id: "D"}}
        ],
        count: 2
      }

      # D should win because it has lowest priority (level 1)
      winner = Result.break_tie([cluster_a, cluster_b, cluster_c, cluster_d])
      assert winner.representative.action == :orient

      # Without D: C wins on level 2 (true-biased: wait:true = {0,0} beats wait:false = {1,0})
      winner_without_d = Result.break_tie([cluster_b, cluster_a, cluster_c])
      assert winner_without_d.representative.params.id == "C"

      # Without D and C: A and B both have wait {1,0}, A wins on level 3 (auto_complete)
      winner_ab = Result.break_tie([cluster_b, cluster_a])
      assert winner_ab.representative.params.id == "A"
    end

    # R24: Deterministic (existing test enhanced)
    test "returns first when all scores are the same" do
      cluster1 = %{
        representative: %{action: :orient, params: %{id: "first"}, reasoning: ""},
        actions: [%{action: :orient, wait: false, auto_complete_todo: false, params: %{}}],
        count: 3
      }

      cluster2 = %{
        representative: %{action: :orient, params: %{id: "second"}, reasoning: ""},
        actions: [%{action: :orient, wait: false, auto_complete_todo: false, params: %{}}],
        count: 3
      }

      winner = Result.break_tie([cluster1, cluster2])
      # Same action (same priority), same wait score, same auto_complete score
      # Should return first cluster deterministically
      assert winner.representative.params.id == "first"
    end
  end

  # =============================================================================
  # PACKET 1: Default Wait Handling (WorkGroupID: fix-20251210-175217)
  # =============================================================================
  # These tests cover R31-R35 from CONSENSUS_Result spec v3.0
  # All tests should FAIL until implementation is complete

  describe "merge_cluster_params/1 default wait handling" do
    # R31: Default Wait When All Omit
    test "defaults to wait: false when all LLMs omit wait parameter" do
      # Cluster where ALL actions are missing the :wait field
      cluster = %{
        actions: [
          %{action: :spawn_child, params: %{task: "test"}, reasoning: "r1"},
          %{action: :spawn_child, params: %{task: "test"}, reasoning: "r2"},
          %{action: :spawn_child, params: %{task: "test"}, reasoning: "r3"}
        ],
        representative: %{action: :spawn_child, params: %{task: "test"}, reasoning: "r1"}
      }

      {merged, _acc} = Result.merge_cluster_params(cluster)

      # MUST have :wait field with value false
      assert Map.has_key?(merged, :wait), "Result must have :wait field when all LLMs omit it"
      assert merged.wait == false, "Default wait must be false, not #{inspect(merged.wait)}"
    end

    # R32: See separate describe block below (requires async: false for Logger level change)

    # R33: Explicit Wait Preserved
    test "preserves explicit wait values from LLM responses" do
      cluster = %{
        actions: [
          %{action: :spawn_child, wait: false, params: %{task: "test"}, reasoning: "r1"},
          %{action: :spawn_child, wait: false, params: %{task: "test"}, reasoning: "r2"},
          %{action: :spawn_child, wait: 5, params: %{task: "test"}, reasoning: "r3"}
        ],
        representative: %{action: :spawn_child, params: %{task: "test"}, reasoning: "r1"}
      }

      {merged, _acc} = Result.merge_cluster_params(cluster)

      # Should have :wait field from the explicit values (merged via ConsensusRules)
      assert Map.has_key?(merged, :wait)
      # Merged wait should be from explicit values, not default
      assert merged.wait in [false, 5, 0]
    end

    # R34: Mixed Nil and Values
    test "filters nil values before merging wait parameter" do
      # Mix of explicit values and nil/missing
      cluster = %{
        actions: [
          %{action: :spawn_child, wait: nil, params: %{task: "test"}, reasoning: "r1"},
          %{action: :spawn_child, wait: 10, params: %{task: "test"}, reasoning: "r2"},
          %{action: :spawn_child, params: %{task: "test"}, reasoning: "r3"}
        ],
        representative: %{action: :spawn_child, params: %{task: "test"}, reasoning: "r1"}
      }

      {merged, _acc} = Result.merge_cluster_params(cluster)

      # Should have :wait field from the explicit non-nil value (10)
      assert Map.has_key?(merged, :wait)
      # Only the non-nil value (10) should be used
      assert merged.wait == 10
    end

    test "handles single action with missing wait" do
      cluster = %{
        actions: [
          %{action: :orient, params: %{current_situation: "test"}, reasoning: "r1"}
        ],
        representative: %{action: :orient, params: %{current_situation: "test"}, reasoning: "r1"}
      }

      {merged, _acc} = Result.merge_cluster_params(cluster)

      assert Map.has_key?(merged, :wait),
             "Single action with missing wait should default to false"

      assert merged.wait == false
    end

    test "handles all nil wait values same as all missing" do
      cluster = %{
        actions: [
          %{action: :spawn_child, wait: nil, params: %{task: "test"}, reasoning: "r1"},
          %{action: :spawn_child, wait: nil, params: %{task: "test"}, reasoning: "r2"}
        ],
        representative: %{action: :spawn_child, params: %{task: "test"}, reasoning: "r1"}
      }

      {merged, _acc} = Result.merge_cluster_params(cluster)

      # All nil should be treated same as all missing - default to false
      assert Map.has_key?(merged, :wait)
      assert merged.wait == false
    end

    # R35: Agent Continues When LLMs Omit Wait [SYSTEM]
    # This tests the full flow from format_result through to action result
    test "agent continues when all LLMs omit wait parameter" do
      # Simulate real consensus scenario: 3 LLMs all omit wait parameter
      # This is the majority cluster (consensus case)
      majority_cluster = %{
        count: 3,
        actions: [
          # LLM 1 response - no wait field
          %{
            action: :spawn_child,
            params: %{task: "analyze data"},
            reasoning: "Starting analysis"
          },
          # LLM 2 response - no wait field
          %{action: :spawn_child, params: %{task: "analyze data"}, reasoning: "Need to analyze"},
          # LLM 3 response - no wait field
          %{action: :spawn_child, params: %{task: "analyze data"}, reasoning: "Begin analysis"}
        ],
        representative: %{
          action: :spawn_child,
          params: %{task: "analyze data"},
          reasoning: "Starting analysis"
        }
      }

      # Call format_result which internally calls merge_cluster_params
      result = Result.format_result([majority_cluster], 3, 1)

      # Verify consensus result structure
      assert {:consensus, action, confidence: conf} = result
      assert action.action == :spawn_child
      assert conf > 0.9

      # THE CRITICAL ASSERTION: wait field must exist with false value
      # Without this, ConsensusHandler returns {:error, :missing_wait_parameter}
      # which causes agent stall
      assert Map.has_key?(action, :wait),
             "Consensus action MUST have :wait field to prevent agent stall"

      assert action.wait == false,
             "Default wait must be false so agent continues immediately"
    end

    test "format_result with forced_decision also defaults wait to false" do
      # No majority - forced decision scenario (2-2-1 split, no cluster >50%)
      clusters = [
        %{
          count: 2,
          actions: [
            %{action: :spawn_child, params: %{task: "a"}, reasoning: "r1"},
            %{action: :spawn_child, params: %{task: "a"}, reasoning: "r2"}
          ],
          representative: %{action: :spawn_child, params: %{task: "a"}, reasoning: "r1"}
        },
        %{
          count: 2,
          actions: [
            %{action: :orient, params: %{current_situation: "x"}, reasoning: "r3"},
            %{action: :orient, params: %{current_situation: "x"}, reasoning: "r4"}
          ],
          representative: %{action: :orient, params: %{current_situation: "x"}, reasoning: "r3"}
        },
        %{
          count: 1,
          actions: [
            %{action: :wait, params: %{}, reasoning: "r5"}
          ],
          representative: %{action: :wait, params: %{}, reasoning: "r5"}
        }
      ]

      # 5 total responses, no cluster has >2.5 (majority)
      result = Result.format_result(clusters, 5, 1)

      assert {:forced_decision, action, confidence: _} = result

      # Even in forced_decision, wait must default to false
      assert Map.has_key?(action, :wait),
             "Forced decision action MUST have :wait field"

      assert action.wait == false
    end
  end

  # =============================================================================
  # EXISTING TESTS (R1-R4, R23-R30)
  # =============================================================================

  describe "format_result/3" do
    test "returns consensus when majority cluster exists" do
      majority_cluster = %{
        count: 3,
        actions: [
          %{action: :spawn_child, params: %{task: "analyze"}, reasoning: "r1"},
          %{action: :spawn_child, params: %{task: "analyze"}, reasoning: "r2"},
          %{action: :spawn_child, params: %{task: "analyze"}, reasoning: "r3"}
        ],
        representative: %{action: :spawn_child, params: %{task: "analyze"}, reasoning: "r1"}
      }

      minority_cluster = %{
        count: 2,
        actions: [
          %{action: :wait, params: %{wait: 5000}, reasoning: "w1"},
          %{action: :wait, params: %{wait: 5000}, reasoning: "w2"}
        ],
        representative: %{action: :wait, params: %{wait: 5000}, reasoning: "w1"}
      }

      clusters = [majority_cluster, minority_cluster]

      result = Result.format_result(clusters, 5, 1)
      assert {:consensus, action, confidence: conf} = result
      assert action.action == :spawn_child
      assert conf > 0.5
    end

    test "returns forced_decision when no majority" do
      clusters = [
        %{
          count: 2,
          actions: [%{action: :spawn_child, params: %{task: "a"}, reasoning: "r1"}],
          representative: %{action: :spawn_child, params: %{task: "a"}, reasoning: "r1"}
        },
        %{
          count: 2,
          actions: [%{action: :wait, params: %{}, reasoning: "r2"}],
          representative: %{action: :wait, params: %{}, reasoning: "r2"}
        },
        %{
          count: 1,
          actions: [%{action: :orient, params: %{}, reasoning: "r3"}],
          representative: %{action: :orient, params: %{}, reasoning: "r3"}
        }
      ]

      result = Result.format_result(clusters, 5, 2)
      assert {:forced_decision, action, confidence: conf} = result
      assert is_atom(action.action)
      assert conf <= 0.5
    end

    test "always returns exactly ONE action" do
      clusters = [
        %{
          count: 1,
          actions: [%{action: :spawn_child, params: %{}, reasoning: ""}],
          representative: %{action: :spawn_child, params: %{}, reasoning: ""}
        },
        %{
          count: 1,
          actions: [%{action: :wait, params: %{}, reasoning: ""}],
          representative: %{action: :wait, params: %{}, reasoning: ""}
        },
        %{
          count: 1,
          actions: [%{action: :orient, params: %{}, reasoning: ""}],
          representative: %{action: :orient, params: %{}, reasoning: ""}
        }
      ]

      result = Result.format_result(clusters, 3, 1)
      assert {:forced_decision, action, confidence: _conf} = result
      assert is_map(action)
      assert Map.has_key?(action, :action)
      assert Map.has_key?(action, :params)
    end

    test "merged action has all required parameters per schema" do
      cluster = %{
        count: 3,
        actions: [
          %{action: :send_message, params: %{to: :parent, content: "hello"}, reasoning: "r1"},
          %{action: :send_message, params: %{to: :parent, content: "hi"}, reasoning: "r2"},
          %{action: :send_message, params: %{to: :parent, content: "hey"}, reasoning: "r3"}
        ],
        representative: %{
          action: :send_message,
          params: %{to: :parent, content: "hello"},
          reasoning: "r1"
        }
      }

      result = Result.format_result([cluster], 3, 1)
      assert {:consensus, action, confidence: _} = result
      assert action.action == :send_message
      assert Map.has_key?(action.params, :to)
      assert Map.has_key?(action.params, :content)
    end
  end

  describe "break_tie/1" do
    test "selects action with lowest priority number (most conservative)" do
      tied_clusters = [
        %{representative: %{action: :spawn_child, params: %{}, reasoning: ""}, count: 2},
        %{representative: %{action: :orient, params: %{}, reasoning: ""}, count: 2}
      ]

      winner = Result.break_tie(tied_clusters)
      # orient has priority 1, spawn_child has 10
      assert winner.representative.action == :orient
    end

    test "handles multiple tied clusters" do
      tied_clusters = [
        %{representative: %{action: :execute_shell, params: %{}, reasoning: ""}, count: 2},
        %{representative: %{action: :wait, params: %{}, reasoning: ""}, count: 2},
        %{representative: %{action: :send_message, params: %{}, reasoning: ""}, count: 2}
      ]

      winner = Result.break_tie(tied_clusters)
      # wait has priority 2, lowest of the three
      assert winner.representative.action == :wait
    end

    test "returns first when priorities are the same" do
      # This shouldn't happen in practice, but tests determinism
      cluster1 = %{representative: %{action: :orient, params: %{}, reasoning: ""}, count: 3}
      cluster2 = %{representative: %{action: :orient, params: %{}, reasoning: ""}, count: 3}

      winner = Result.break_tie([cluster1, cluster2])
      assert winner == cluster1
    end
  end

  describe "merge_cluster_params/1" do
    test "applies schema-specific consensus rules" do
      cluster = %{
        actions: [
          %{
            action: :spawn_child,
            params: %{
              task_description: "analyze data",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard"
            },
            reasoning: "need analysis"
          },
          %{
            action: :spawn_child,
            params: %{
              task_description: "analyze the data",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard"
            },
            reasoning: "data work"
          },
          %{
            action: :spawn_child,
            params: %{
              task_description: "analyze user data",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard"
            },
            reasoning: "user analysis"
          }
        ],
        representative: %{
          action: :spawn_child,
          params: %{
            task_description: "analyze data",
            success_criteria: "Complete",
            immediate_context: "Test",
            approach_guidance: "Standard"
          },
          reasoning: ""
        }
      }

      {merged, _acc} = Result.merge_cluster_params(cluster)
      assert merged.action == :spawn_child
      assert is_binary(merged.params.task_description)
      assert merged.params.task_description =~ "analyze"
    end

    test "uses mode as fallback when consensus rule fails" do
      cluster = %{
        actions: [
          %{action: :wait, params: %{wait: 1000}, reasoning: "short wait"},
          %{action: :wait, params: %{wait: 5000}, reasoning: "medium wait"},
          %{action: :wait, params: %{wait: 5000}, reasoning: "medium wait"}
        ],
        representative: %{action: :wait, params: %{wait: 5000}, reasoning: ""}
      }

      {merged, _acc} = Result.merge_cluster_params(cluster)
      assert merged.action == :wait
      # Should use median (50th percentile) or mode if that fails
      assert is_integer(merged.params.wait)
    end

    test "includes non-empty reasoning" do
      cluster = %{
        actions: [
          %{
            action: :orient,
            params: %{current_situation: "analyzing"},
            reasoning: "We need to understand the current state"
          },
          %{action: :orient, params: %{current_situation: "analyzing"}, reasoning: ""},
          %{action: :orient, params: %{current_situation: "analyzing"}, reasoning: "Orient first"}
        ],
        representative: %{
          action: :orient,
          params: %{current_situation: "analyzing"},
          reasoning: ""
        }
      }

      {merged, _acc} = Result.merge_cluster_params(cluster)
      assert is_binary(merged.reasoning)
      assert merged.reasoning != ""
    end
  end

  describe "calculate_confidence/3" do
    test "returns confidence > 0.9 for unanimous agreement" do
      cluster = %{count: 5}
      confidence = Result.calculate_confidence(cluster, 5, 1)
      assert confidence > 0.9
    end

    test "applies penalty for late rounds" do
      cluster = %{count: 3}
      max_rounds = Manager.get_max_refinement_rounds()
      conf_round1 = Result.calculate_confidence(cluster, max_rounds, 1)
      conf_max_round = Result.calculate_confidence(cluster, max_rounds, max_rounds)

      assert conf_round1 > conf_max_round
      # Never below 0.1
      assert conf_max_round >= 0.1
    end

    test "returns value between 0.1 and 1.0" do
      # Test minimum case
      min_cluster = %{count: 1}
      min_conf = Result.calculate_confidence(min_cluster, 10, 5)
      assert min_conf >= 0.1
      assert min_conf <= 1.0

      # Test maximum case
      max_cluster = %{count: 5}
      max_conf = Result.calculate_confidence(max_cluster, 5, 1)
      assert max_conf >= 0.1
      assert max_conf <= 1.0
    end

    test "gives bonus for strong majorities" do
      weak_majority = %{count: 3}
      strong_majority = %{count: 4}

      weak_conf = Result.calculate_confidence(weak_majority, 5, 1)
      strong_conf = Result.calculate_confidence(strong_majority, 5, 1)

      assert strong_conf > weak_conf
    end
  end

  describe "plurality winner with tiebreaking" do
    test "picks plurality winner and breaks ties with priority" do
      clusters = [
        %{
          count: 2,
          actions: [],
          representative: %{action: :spawn_child, params: %{}, reasoning: ""}
        },
        %{count: 2, actions: [], representative: %{action: :wait, params: %{}, reasoning: ""}},
        %{count: 1, actions: [], representative: %{action: :orient, params: %{}, reasoning: ""}}
      ]

      # This would be called internally by format_result when no majority
      # Testing the expected behavior
      result = Result.format_result(clusters, 5, 1)
      assert {:forced_decision, action, confidence: _} = result
      # Should pick wait (priority 2) over spawn_child (priority 10) in the 2-2 tie
      assert action.action == :wait
    end

    test "handles all different actions with no plurality" do
      clusters = [
        %{
          count: 1,
          actions: [%{action: :spawn_child, params: %{}, reasoning: ""}],
          representative: %{action: :spawn_child, params: %{}, reasoning: ""}
        },
        %{
          count: 1,
          actions: [%{action: :execute_shell, params: %{}, reasoning: ""}],
          representative: %{action: :execute_shell, params: %{}, reasoning: ""}
        },
        %{
          count: 1,
          actions: [%{action: :call_api, params: %{}, reasoning: ""}],
          representative: %{action: :call_api, params: %{}, reasoning: ""}
        }
      ]

      result = Result.format_result(clusters, 3, 1)
      assert {:forced_decision, action, confidence: _} = result
      # All have count 1, so should pick most conservative (lowest priority)
      # Between spawn_child(10), execute_shell(8), call_api(7), should pick call_api
      assert action.action == :call_api
    end
  end

  # === v6.0 Cost Context Threading (fix-costs-20260129 audit fix) ===

  # =============================================================================
  # v7.0: Cost Accumulator Threading (WorkGroupID: feat-20260203-194408)
  # =============================================================================

  alias Quoracle.Costs.Accumulator

  describe "R49: accumulator threading to ConsensusRules" do
    # R49: Accumulator Reaches ConsensusRules [INTEGRATION]
    # WHEN format_result called with :cost_accumulator in opts
    # THEN ConsensusRules.apply_rule receives it
    test "format_result threads cost_accumulator to ConsensusRules" do
      test_pid = self()
      acc = Accumulator.new()

      # Mock embedding function that captures opts to verify accumulator threading
      mock_embedding_fn = fn text, opts ->
        send(test_pid, {:embedding_called, text, opts})
        {:ok, %{embedding: Enum.map(1..10, fn i -> :math.sin(i) end)}}
      end

      # Cluster with semantic_similarity params that trigger ConsensusRules
      # orient's current_situation uses semantic_similarity rule
      clusters = [
        %{
          count: 3,
          actions: [
            %{action: :orient, params: %{current_situation: "situation A"}, reasoning: "r1"},
            %{action: :orient, params: %{current_situation: "situation B"}, reasoning: "r2"},
            %{action: :orient, params: %{current_situation: "situation C"}, reasoning: "r3"}
          ],
          representative: %{action: :orient}
        }
      ]

      # Pass accumulator and embedding_fn via opts
      opts = [
        agent_id: "r49_test_agent",
        task_id: 12345,
        pubsub: :test_pubsub,
        cost_accumulator: acc,
        embedding_fn: mock_embedding_fn
      ]

      # format_result should thread accumulator to ConsensusRules.apply_rule
      result = Result.format_result(clusters, 3, 1, opts)

      # Result should still work correctly (now includes accumulator in opts)
      assert {:consensus, action, opts} = result
      assert Keyword.has_key?(opts, :confidence)
      assert action.action == :orient

      # Verify embedding function was called with cost_accumulator in opts
      assert_receive {:embedding_called, _text, embed_opts}, 1000
      assert Map.has_key?(embed_opts, :cost_accumulator)
    end
  end

  describe "[UNIT] format_result/4 cost opts (R60-R63)" do
    # R60: format_result/4 delegates semantic_similarity to ConsensusRules.apply_rule/3
    # instead of using the inline heuristic in apply_consensus_rule/2.
    #
    # The behavioral difference: orient's current_situation has threshold 0.8.
    # With distinct values where mode ≠ median-length:
    # - Inline heuristic: sorts by length, picks middle index → "aa"
    # - ConsensusRules: tries embeddings, fails, returns {:error, :no_consensus}
    #   → merge_params_by_rules falls back to mode_value → "b" (frequency 2)
    test "semantic_similarity uses ConsensusRules, not inline heuristic" do
      # 4 orient responses with current_situation values where mode ≠ median-length
      # "b" appears twice (mode), but "aa" is median-length
      clusters = [
        %{
          count: 4,
          actions: [
            %{action: :orient, params: %{current_situation: "aa"}, reasoning: "r1"},
            %{action: :orient, params: %{current_situation: "b"}, reasoning: "r2"},
            %{action: :orient, params: %{current_situation: "b"}, reasoning: "r3"},
            %{action: :orient, params: %{current_situation: "ccccc"}, reasoning: "r4"}
          ],
          representative: %{action: :orient}
        }
      ]

      cost_opts = [agent_id: "test-agent", task_id: 123, pubsub: :test_pubsub]
      {:consensus, action, confidence: _} = Result.format_result(clusters, 4, 1, cost_opts)

      # ConsensusRules path: embeddings fail → mode_value → "b" (most frequent)
      # Inline heuristic path: sort by length → pick middle → "aa"
      # If this returns "aa", the inline heuristic is still being used.
      assert action.params.current_situation == "b"
    end

    # R61: format_result/3 still works (backward compatible)
    test "format_result/3 remains backward compatible" do
      clusters = [
        %{
          count: 2,
          actions: [
            %{action: :orient, params: %{reflection: "test"}, reasoning: "r1"},
            %{action: :orient, params: %{reflection: "test"}, reasoning: "r2"}
          ],
          representative: %{action: :orient}
        }
      ]

      result = Result.format_result(clusters, 2, 1)
      assert {:consensus, action, confidence: _} = result
      assert action.action == :orient
    end

    # R63: format_result/4 threads cost_opts to ConsensusRules for all
    # semantic_similarity params, not just one. orient has 13 such params.
    # Verify cost_opts don't crash with multiple semantic_similarity fields.
    test "format_result/4 handles multiple semantic_similarity params" do
      clusters = [
        %{
          count: 3,
          actions: [
            %{
              action: :orient,
              params: %{
                current_situation: "same",
                goal_clarity: "same",
                key_challenges: "same"
              },
              reasoning: "r1"
            },
            %{
              action: :orient,
              params: %{
                current_situation: "same",
                goal_clarity: "same",
                key_challenges: "same"
              },
              reasoning: "r2"
            },
            %{
              action: :orient,
              params: %{
                current_situation: "same",
                goal_clarity: "same",
                key_challenges: "same"
              },
              reasoning: "r3"
            }
          ],
          representative: %{action: :orient}
        }
      ]

      cost_opts = [agent_id: "test-agent", task_id: 123, pubsub: :test_pubsub]
      {:consensus, action, confidence: _} = Result.format_result(clusters, 3, 1, cost_opts)
      assert action.params.current_situation == "same"
      assert action.params.goal_clarity == "same"
    end
  end
end

# R32 (Warning Logged on Default) - Deleted as it tested logging output rather than
# behavior. The actual behavior (defaulting wait to false) is tested in
# "merge_cluster_params/1 default wait handling" describe block above.
