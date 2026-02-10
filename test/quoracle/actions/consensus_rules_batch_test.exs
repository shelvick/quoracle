defmodule Quoracle.Actions.ConsensusRulesBatchTest do
  @moduledoc """
  Tests for ACTION_ConsensusRules v8.0 - :batch_sequence_merge rule.
  WorkGroupID: feat-20260123-batch-sync
  Packet: 1 (Schema Foundation)
  """

  use Quoracle.DataCase, async: true
  alias Quoracle.Actions.ConsensusRules

  # ARC Verification Criteria from ACTION_ConsensusRules v8.0

  describe ":batch_sequence_merge rule" do
    # R1: Merge Same-Length Sequences
    test "batch_sequence_merge accepts same-length sequences" do
      # [UNIT] - WHEN apply_rule(:batch_sequence_merge, sequences) called IF all sequences same length THEN proceeds to merge
      sequences = [
        [
          %{action: :file_read, params: %{path: "/a.txt"}},
          %{action: :todo, params: %{operation: :list}}
        ],
        [
          %{action: :file_read, params: %{path: "/a.txt"}},
          %{action: :todo, params: %{operation: :list}}
        ]
      ]

      assert {:ok, merged} = ConsensusRules.apply_rule(:batch_sequence_merge, sequences)
      assert length(merged) == 2
    end

    # R2: Reject Different-Length Sequences
    test "batch_sequence_merge rejects different-length sequences" do
      # [UNIT] - WHEN apply_rule(:batch_sequence_merge, sequences) called IF sequences have different lengths THEN returns {:error, :sequence_length_mismatch}
      sequences = [
        [
          %{action: :file_read, params: %{path: "/a.txt"}},
          %{action: :todo, params: %{operation: :list}}
        ],
        [
          %{action: :file_read, params: %{path: "/b.txt"}}
        ]
      ]

      assert {:error, :sequence_length_mismatch} =
               ConsensusRules.apply_rule(:batch_sequence_merge, sequences)
    end

    # R3: Reject Mismatched Action Types
    test "batch_sequence_merge rejects mismatched action types" do
      # [UNIT] - WHEN apply_rule(:batch_sequence_merge, sequences) called IF action types differ at any position THEN returns {:error, :sequence_mismatch}
      sequences = [
        [
          %{action: :file_read, params: %{path: "/a.txt"}},
          %{action: :todo, params: %{operation: :list}}
        ],
        [
          %{action: :todo, params: %{operation: :add}},
          %{action: :file_read, params: %{path: "/b.txt"}}
        ]
      ]

      assert {:error, :sequence_mismatch} =
               ConsensusRules.apply_rule(:batch_sequence_merge, sequences)
    end

    # R4: Per-Position Merging
    test "batch_sequence_merge applies action-specific rules per position" do
      # [UNIT] - WHEN apply_rule(:batch_sequence_merge, sequences) called THEN merges params at each position using that action's consensus rules
      sequences = [
        [
          %{action: :file_read, params: %{path: "/a.txt", limit: 100}},
          %{action: :orient, params: %{current_situation: "Testing"}}
        ],
        [
          %{action: :file_read, params: %{path: "/a.txt", limit: 200}},
          %{action: :orient, params: %{current_situation: "Testing"}}
        ]
      ]

      assert {:ok, merged} = ConsensusRules.apply_rule(:batch_sequence_merge, sequences)
      assert length(merged) == 2

      # First position: file_read - path uses exact_match, limit uses percentile
      [first_action, second_action] = merged
      assert first_action.action == :file_read
      assert first_action.params.path == "/a.txt"
      # Median of 100, 200 = 150
      assert first_action.params.limit == 150

      # Second position: orient - current_situation uses semantic_similarity
      assert second_action.action == :orient
      assert second_action.params.current_situation == "Testing"
    end

    # R5: Merge Failure Propagation
    test "batch_sequence_merge fails if any position fails" do
      # [UNIT] - WHEN apply_rule(:batch_sequence_merge, sequences) called IF any position fails to merge THEN returns {:error, :no_consensus}
      sequences = [
        [
          %{action: :file_read, params: %{path: "/a.txt"}}
        ],
        [
          %{action: :file_read, params: %{path: "/b.txt"}}
        ]
      ]

      # file_read path uses :exact_match, different paths = no consensus
      assert {:error, :no_consensus} =
               ConsensusRules.apply_rule(:batch_sequence_merge, sequences)
    end

    # R6: Successful Merge Result
    test "batch_sequence_merge returns merged sequence on success" do
      # [UNIT] - WHEN apply_rule(:batch_sequence_merge, sequences) succeeds THEN returns {:ok, merged_sequence} with same structure
      sequences = [
        [
          %{action: :todo, params: %{operation: :list}},
          %{action: :orient, params: %{current_situation: "Same"}}
        ],
        [
          %{action: :todo, params: %{operation: :list}},
          %{action: :orient, params: %{current_situation: "Same"}}
        ]
      ]

      assert {:ok, merged} = ConsensusRules.apply_rule(:batch_sequence_merge, sequences)
      assert is_list(merged)
      assert length(merged) == 2

      # Each element should have action and params
      Enum.each(merged, fn action_spec ->
        assert Map.has_key?(action_spec, :action)
        assert Map.has_key?(action_spec, :params)
      end)
    end

    # R7: Empty Sequences
    test "batch_sequence_merge handles empty input" do
      # [UNIT] - WHEN apply_rule(:batch_sequence_merge, []) called THEN returns {:ok, []}
      assert {:ok, []} = ConsensusRules.apply_rule(:batch_sequence_merge, [])
    end

    # R8: Single Sequence
    test "batch_sequence_merge handles single sequence" do
      # [UNIT] - WHEN apply_rule(:batch_sequence_merge, [seq]) called THEN returns {:ok, seq}
      sequence = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :todo, params: %{operation: :list}}
      ]

      assert {:ok, merged} = ConsensusRules.apply_rule(:batch_sequence_merge, [sequence])
      assert length(merged) == 2
      assert Enum.at(merged, 0).action == :file_read
      assert Enum.at(merged, 1).action == :todo
    end
  end

  describe ":batch_sequence_merge edge cases" do
    test "handles three sequences" do
      sequences = [
        [%{action: :todo, params: %{operation: :list}}],
        [%{action: :todo, params: %{operation: :list}}],
        [%{action: :todo, params: %{operation: :list}}]
      ]

      assert {:ok, merged} = ConsensusRules.apply_rule(:batch_sequence_merge, sequences)
      assert length(merged) == 1
      assert Enum.at(merged, 0).action == :todo
    end

    test "handles string keys from LLM responses" do
      # LLMs may return string keys instead of atom keys
      sequences = [
        [
          %{"action" => :file_read, "params" => %{path: "/a.txt"}}
        ],
        [
          %{"action" => :file_read, "params" => %{path: "/a.txt"}}
        ]
      ]

      # Should handle both atom and string keys
      result = ConsensusRules.apply_rule(:batch_sequence_merge, sequences)
      # May need normalization - verify it doesn't crash
      assert is_tuple(result)
    end

    test "merges with multiple param keys per action" do
      sequences = [
        [
          %{
            action: :spawn_child,
            params: %{
              task_description: "Process data",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: "test"
            }
          }
        ],
        [
          %{
            action: :spawn_child,
            params: %{
              task_description: "Process data",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: "test"
            }
          }
        ]
      ]

      assert {:ok, merged} = ConsensusRules.apply_rule(:batch_sequence_merge, sequences)
      assert length(merged) == 1
      assert Enum.at(merged, 0).action == :spawn_child
    end
  end
end
