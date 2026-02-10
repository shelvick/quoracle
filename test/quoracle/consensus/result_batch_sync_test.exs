defmodule Quoracle.Consensus.ResultBatchSyncTest do
  @moduledoc """
  Tests for CONSENSUS_Result v4.0 - batch_sync tie-breaking and merging.
  WorkGroupID: feat-20260123-batch-sync
  Packet: 2 (Consensus Logic)
  """

  use Quoracle.DataCase, async: true
  alias Quoracle.Consensus.Result

  # =============================================================================
  # PACKET 2: batch_sync Tie-Breaking & Merging (feat-20260123-batch-sync)
  # =============================================================================
  # Tests R36-R41 from CONSENSUS_Result v4.0

  describe "break_tie/1 batch_sync handling" do
    # R36: batch_sync Tie-Break Uses Max Priority
    test "batch_sync tie-break uses max priority of sequence" do
      # [UNIT] - WHEN break_tie called with batch_sync clusters THEN uses max priority of action sequence
      # spawn_child has priority 10, file_read has priority 4
      # Max priority of [:spawn_child, :file_read] = 10
      # batch_sync's own priority is 3, but should use 10 from sequence
      batch_cluster = %{
        representative: %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :spawn_child, params: %{task_description: "test"}},
              %{action: :file_read, params: %{path: "/tmp/a.txt"}}
            ]
          },
          reasoning: ""
        },
        actions: [
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :spawn_child, params: %{task_description: "test"}},
                %{action: :file_read, params: %{path: "/tmp/a.txt"}}
              ]
            },
            wait: false,
            auto_complete_todo: false
          }
        ],
        count: 2
      }

      # todo has priority 6
      # Without max priority logic: batch_sync (3) < todo (6), batch wins
      # With max priority logic: batch_sync (10) > todo (6), todo wins
      todo_cluster = %{
        representative: %{action: :todo, params: %{items: []}, reasoning: ""},
        actions: [%{action: :todo, wait: false, auto_complete_todo: false, params: %{items: []}}],
        count: 2
      }

      # Put batch_cluster first - without max priority, batch_sync (3) wins
      # With max priority, todo (6) should win over batch_sync (10)
      winner = Result.break_tie([batch_cluster, todo_cluster])
      assert winner.representative.action == :todo
    end

    # R37: min(max) Wins
    test "batch_sync with lower max priority wins tie" do
      # [UNIT] - WHEN batch_sync clusters tied THEN lowest max priority wins
      # Cluster A: batch_sync([:file_read, :todo]) -> priorities [4, 6] -> max = 6
      cluster_a = %{
        representative: %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :file_read, params: %{path: "/tmp/a.txt"}},
              %{action: :todo, params: %{items: []}}
            ]
          },
          reasoning: ""
        },
        actions: [
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/a.txt"}},
                %{action: :todo, params: %{items: []}}
              ]
            },
            wait: false,
            auto_complete_todo: false
          }
        ],
        count: 2
      }

      # Cluster B: batch_sync([:file_read, :spawn_child]) -> priorities [4, 10] -> max = 10
      cluster_b = %{
        representative: %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :file_read, params: %{path: "/tmp/b.txt"}},
              %{action: :spawn_child, params: %{task_description: "test"}}
            ]
          },
          reasoning: ""
        },
        actions: [
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/b.txt"}},
                %{action: :spawn_child, params: %{task_description: "test"}}
              ]
            },
            wait: false,
            auto_complete_todo: false
          }
        ],
        count: 2
      }

      # Cluster A (max 6) should beat Cluster B (max 10)
      # Put B first to ensure correct sorting, not just stable sort
      winner = Result.break_tie([cluster_b, cluster_a])

      assert winner.representative.params.actions |> hd() |> Map.get(:params) |> Map.get(:path) ==
               "/tmp/a.txt"
    end

    # R41: batch_sync with Non-Batch Clusters
    test "batch_sync cluster competes with non-batch clusters" do
      # [INTEGRATION] - WHEN batch_sync cluster compared to non-batch THEN priority comparison still works
      # batch_sync with [:spawn_child, :file_read] -> max priorities [10, 4] -> max = 10
      # Without max priority: batch_sync uses priority 3
      # With max priority: batch_sync uses priority 10
      batch_cluster = %{
        representative: %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :spawn_child, params: %{task_description: "test"}},
              %{action: :file_read, params: %{path: "/tmp/a.txt"}}
            ]
          },
          reasoning: ""
        },
        actions: [
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :spawn_child, params: %{task_description: "test"}},
                %{action: :file_read, params: %{path: "/tmp/a.txt"}}
              ]
            },
            wait: false,
            auto_complete_todo: false
          }
        ],
        count: 2
      }

      # call_api has priority 7
      # Without max priority: batch_sync (3) < call_api (7), batch wins
      # With max priority: batch_sync (10) > call_api (7), call_api wins
      api_cluster = %{
        representative: %{action: :call_api, params: %{url: "http://test"}, reasoning: ""},
        actions: [%{action: :call_api, wait: false, auto_complete_todo: false, params: %{}}],
        count: 2
      }

      # Put batch_cluster first - without max priority, batch wins
      winner = Result.break_tie([batch_cluster, api_cluster])
      # With max priority, call_api (7) should win over batch_sync (10)
      assert winner.representative.action == :call_api
    end

    test "batch_sync with empty actions list uses fallback priority" do
      # Edge case: empty actions list should not crash
      batch_cluster = %{
        representative: %{
          action: :batch_sync,
          params: %{actions: []},
          reasoning: ""
        },
        actions: [
          %{
            action: :batch_sync,
            params: %{actions: []},
            wait: false,
            auto_complete_todo: false
          }
        ],
        count: 2
      }

      orient_cluster = %{
        representative: %{action: :orient, params: %{}, reasoning: ""},
        actions: [%{action: :orient, wait: false, auto_complete_todo: false, params: %{}}],
        count: 2
      }

      # Empty batch should have some fallback priority (0 or 999)
      # orient (1) should win
      winner = Result.break_tie([batch_cluster, orient_cluster])
      assert winner.representative.action == :orient
    end
  end

  describe "merge_cluster_params/1 batch_sync handling" do
    # R38: batch_sync Merging Uses batch_sequence_merge
    test "batch_sync merge uses batch_sequence_merge rule" do
      # [UNIT] - WHEN merge_cluster_params called with batch_sync THEN delegates to ConsensusRules.apply_rule(:batch_sequence_merge, ...)
      #
      # Key insight: Without batch_sequence_merge, mode_selection picks the most common WHOLE LIST
      # With batch_sequence_merge, each POSITION is merged separately
      #
      # Design: 3 responses where:
      # - Position 0: paths [A, B, B] -> mode = B
      # - Position 1: paths [X, Y, X] -> mode = X
      # Mode of whole lists would pick list 1 or 3 (both appear once, tie)
      # but batch_sequence_merge gives [B, X] which is DIFFERENT from any input list
      cluster = %{
        actions: [
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/A.txt"}},
                %{action: :file_read, params: %{path: "/tmp/X.txt"}}
              ]
            },
            reasoning: "Read files",
            wait: false
          },
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/B.txt"}},
                %{action: :file_read, params: %{path: "/tmp/Y.txt"}}
              ]
            },
            reasoning: "Reading files",
            wait: false
          },
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/B.txt"}},
                %{action: :file_read, params: %{path: "/tmp/X.txt"}}
              ]
            },
            reasoning: "Read",
            wait: false
          }
        ],
        representative: %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :file_read, params: %{path: "/tmp/A.txt"}},
              %{action: :file_read, params: %{path: "/tmp/X.txt"}}
            ]
          },
          reasoning: "Read files"
        }
      }

      {result, _acc} = Result.merge_cluster_params(cluster)

      # Result should be a successful merge with batch_sync structure
      assert result.action == :batch_sync
      assert Map.has_key?(result.params, :actions)
      assert length(result.params.actions) == 2

      # With batch_sequence_merge:
      # - Position 0: [A, B, B] -> mode = B
      # - Position 1: [X, Y, X] -> mode = X
      # Result should be [{path: B}, {path: X}]
      #
      # Without batch_sequence_merge (mode on whole lists):
      # - Lists are all different, so mode picks first = [{A}, {X}]
      [first_action, second_action] = result.params.actions
      assert first_action.params.path == "/tmp/B.txt"
      assert second_action.params.path == "/tmp/X.txt"
    end

    # R39: batch_sync Merge Failure Returns Error
    test "batch_sync merge failure propagates error" do
      # [UNIT] - WHEN batch_sequence_merge fails THEN merge_cluster_params returns {:error, reason}
      # Two responses with different sequence lengths (should fail)
      cluster = %{
        actions: [
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/a.txt"}}
              ]
            },
            reasoning: "One file",
            wait: false
          },
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/a.txt"}},
                %{action: :file_read, params: %{path: "/tmp/b.txt"}}
              ]
            },
            reasoning: "Two files",
            wait: false
          }
        ],
        representative: %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :file_read, params: %{path: "/tmp/a.txt"}}
            ]
          },
          reasoning: "One file"
        }
      }

      result = Result.merge_cluster_params(cluster)

      # Should return error tuple when merge fails
      assert {:error, :sequence_length_mismatch} = result
    end

    # R40: batch_sync Merge Preserves Structure
    test "batch_sync merge preserves action structure" do
      # [UNIT] - WHEN batch_sync merged successfully THEN result has action: :batch_sync and params: %{actions: [...]}
      # TEST-FIXES: Changed from :orient (requires embeddings for semantic_similarity) to :file_read
      # Use DIFFERENT values to ensure actual merging, not just returning representative
      # Position 0: path [A, B, B] -> mode = B (triggers fallback since exact_match fails)
      # Position 1: items different across responses
      cluster = %{
        actions: [
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/file_A.txt"}},
                %{action: :todo, params: %{items: [%{content: "task1", state: "todo"}]}}
              ]
            },
            reasoning: "Read and track",
            wait: false
          },
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/file_B.txt"}},
                %{action: :todo, params: %{items: [%{content: "task2", state: "todo"}]}}
              ]
            },
            reasoning: "Track progress",
            wait: false
          },
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/file_B.txt"}},
                %{action: :todo, params: %{items: [%{content: "task1", state: "todo"}]}}
              ]
            },
            reasoning: "Document state",
            wait: false
          }
        ],
        representative: %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :file_read, params: %{path: "/tmp/file_A.txt"}},
              %{action: :todo, params: %{items: [%{content: "task1", state: "todo"}]}}
            ]
          },
          reasoning: "Read and track"
        }
      }

      {result, _acc} = Result.merge_cluster_params(cluster)

      # Verify structure preserved
      assert result.action == :batch_sync
      assert is_map(result.params)
      assert is_list(result.params.actions)
      assert length(result.params.actions) == 2

      # Each action should have :action and :params keys
      Enum.each(result.params.actions, fn action ->
        assert Map.has_key?(action, :action)
        assert Map.has_key?(action, :params)
      end)

      # Verify action types preserved
      action_types = Enum.map(result.params.actions, & &1.action)
      assert :file_read in action_types
      assert :todo in action_types

      # Verify actual merging happened (not just returning representative)
      # Position 0: [A, B, B] -> mode = B (different from representative's A)
      file_read_action = Enum.find(result.params.actions, &(&1.action == :file_read))
      assert file_read_action.params.path == "/tmp/file_B.txt"

      # Verify reasoning included
      assert is_binary(result.reasoning)
      assert result.reasoning != ""
    end

    test "batch_sync merge with mismatched action types fails" do
      # Two responses with different action types at same position
      cluster = %{
        actions: [
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/a.txt"}},
                %{action: :orient, params: %{current_situation: "test"}}
              ]
            },
            reasoning: "Read then orient",
            wait: false
          },
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/a.txt"}},
                %{action: :todo, params: %{items: []}}
              ]
            },
            reasoning: "Read then todo",
            wait: false
          }
        ],
        representative: %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :file_read, params: %{path: "/tmp/a.txt"}},
              %{action: :orient, params: %{current_situation: "test"}}
            ]
          },
          reasoning: "Read then orient"
        }
      }

      result = Result.merge_cluster_params(cluster)

      # Should fail with sequence_mismatch
      assert {:error, :sequence_mismatch} = result
    end

    test "batch_sync merge includes wait parameter" do
      # Verify wait parameter handling for batch_sync
      cluster = %{
        actions: [
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/a.txt"}}
              ]
            },
            reasoning: "Read file",
            wait: false
          },
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/a.txt"}}
              ]
            },
            reasoning: "Reading",
            wait: 5
          }
        ],
        representative: %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :file_read, params: %{path: "/tmp/a.txt"}}
            ]
          },
          reasoning: "Read file"
        }
      }

      {result, _acc} = Result.merge_cluster_params(cluster)

      # Should have wait field merged
      assert Map.has_key?(result, :wait)
    end
  end

  describe "format_result/3 batch_sync integration" do
    test "format_result handles batch_sync majority consensus with proper merging" do
      # Integration: full format_result with batch_sync cluster
      # Use same pattern as R38: results that differ from any single input
      # Position 0: [A, B, B] -> merged = B
      # Position 1: [X, Y, X] -> merged = X
      # Merged result [B, X] is different from any input list
      majority_cluster = %{
        count: 3,
        actions: [
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/A.txt"}},
                %{action: :file_read, params: %{path: "/tmp/X.txt"}}
              ]
            },
            reasoning: "Read files"
          },
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/B.txt"}},
                %{action: :file_read, params: %{path: "/tmp/Y.txt"}}
              ]
            },
            reasoning: "Reading"
          },
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :file_read, params: %{path: "/tmp/B.txt"}},
                %{action: :file_read, params: %{path: "/tmp/X.txt"}}
              ]
            },
            reasoning: "Read"
          }
        ],
        representative: %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :file_read, params: %{path: "/tmp/A.txt"}},
              %{action: :file_read, params: %{path: "/tmp/X.txt"}}
            ]
          },
          reasoning: "Read files"
        }
      }

      minority_cluster = %{
        count: 2,
        actions: [
          %{action: :wait, params: %{wait: 5000}, reasoning: "w1"},
          %{action: :wait, params: %{wait: 5000}, reasoning: "w2"}
        ],
        representative: %{action: :wait, params: %{wait: 5000}, reasoning: "w1"}
      }

      result = Result.format_result([majority_cluster, minority_cluster], 5, 1)

      assert {:consensus, action, confidence: conf} = result
      assert action.action == :batch_sync
      assert conf > 0.5
      assert Map.has_key?(action.params, :actions)

      # With batch_sequence_merge: [B, X] - different from any input
      # Without: mode picks first list [A, X]
      [first_action, second_action] = action.params.actions
      assert first_action.params.path == "/tmp/B.txt"
      assert second_action.params.path == "/tmp/X.txt"
    end

    test "format_result handles batch_sync forced decision with tie-breaking" do
      # No majority - batch_sync competes with other actions
      # batch_sync contains [spawn_child(10), file_read(4)] -> max = 10
      # Without max priority: batch_sync uses priority 3
      # With max priority: batch_sync uses priority 10
      batch_cluster = %{
        count: 2,
        actions: [
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :spawn_child, params: %{task_description: "test"}},
                %{action: :file_read, params: %{path: "/tmp/a.txt"}}
              ]
            },
            reasoning: "Batch spawn"
          },
          %{
            action: :batch_sync,
            params: %{
              actions: [
                %{action: :spawn_child, params: %{task_description: "test"}},
                %{action: :file_read, params: %{path: "/tmp/a.txt"}}
              ]
            },
            reasoning: "Batch"
          }
        ],
        representative: %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :spawn_child, params: %{task_description: "test"}},
              %{action: :file_read, params: %{path: "/tmp/a.txt"}}
            ]
          },
          reasoning: "Batch spawn"
        }
      }

      # execute_shell has priority 8
      # Without max priority: batch_sync (3) < execute_shell (8), batch wins
      # With max priority: batch_sync (10) > execute_shell (8), execute_shell wins
      shell_cluster = %{
        count: 2,
        actions: [
          %{action: :execute_shell, params: %{command: "ls"}, reasoning: "r1"},
          %{action: :execute_shell, params: %{command: "ls"}, reasoning: "r2"}
        ],
        representative: %{action: :execute_shell, params: %{command: "ls"}, reasoning: "r1"}
      }

      # 4 total, no majority (need >2)
      # Put batch_cluster first
      result = Result.format_result([batch_cluster, shell_cluster], 4, 1)

      assert {:forced_decision, action, confidence: _} = result
      # With max priority, execute_shell (8) should beat batch_sync (10)
      assert action.action == :execute_shell
    end
  end
end
