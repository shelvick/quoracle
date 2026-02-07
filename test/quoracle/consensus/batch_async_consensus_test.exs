defmodule Quoracle.Consensus.BatchAsyncConsensusTest do
  @moduledoc """
  Tests for batch_async consensus handling - sorted fingerprinting and priority calculation.
  WorkGroupID: feat-20260126-batch-async
  Packet: 2 (Consensus Logic)

  Covers:
  - R48: batch_async fingerprint uses sorted action type sequence
  - R49: Same actions different order cluster together (order-independent)
  - R50: Different action sets separate
  - R51: Dual key support (string keys from LLM)
  - R52: format_action_summary for batch_async (sorted list)
  - R53: batch_sync and batch_async with same actions have different fingerprints
  - R42: batch_async cluster priority is max of sub-action priorities
  - R43: batch_async uses same priority calculation as batch_sync
  - R45: batch_async cluster competes with non-batch clusters
  - R46: Empty batch_async uses default priority
  """
  use Quoracle.DataCase, async: true
  use ExUnitProperties

  alias Quoracle.Consensus.Aggregator
  alias Quoracle.Consensus.Aggregator.ActionSummary
  alias Quoracle.Consensus.Result.Scoring

  @moduletag :batch_async_consensus

  # ===========================================================================
  # R48-R51: batch_async Sorted Fingerprinting
  # ===========================================================================
  describe "batch_async fingerprinting" do
    # R48: batch_async fingerprint uses sorted action type sequence
    test "batch_async fingerprint uses sorted action type sequence" do
      # [UNIT] - WHEN action_fingerprint called with batch_async THEN returns {:batch_async, sorted_action_types}
      response = %{
        action: :batch_async,
        params: %{
          actions: [
            %{action: :todo, params: %{operation: :list}},
            %{action: :file_read, params: %{path: "/tmp/a.txt"}}
          ]
        }
      }

      fingerprint = Aggregator.action_fingerprint(response)

      # Fingerprint should be sorted: [:file_read, :todo] (alphabetical)
      assert fingerprint == {:batch_async, [:file_read, :todo]}
    end

    # R49: Same actions different order cluster together (order-independent)
    test "batch_async responses with same actions different order cluster together" do
      # [UNIT] - WHEN two batch_async have same actions in different order THEN fingerprints match
      # Actions in order: todo, file_read
      response1 = %{
        action: :batch_async,
        params: %{
          actions: [
            %{action: :todo, params: %{operation: :list}},
            %{action: :file_read, params: %{path: "/tmp/a.txt"}}
          ]
        }
      }

      # Actions in order: file_read, todo (reversed)
      response2 = %{
        action: :batch_async,
        params: %{
          actions: [
            %{action: :file_read, params: %{path: "/tmp/b.txt"}},
            %{action: :todo, params: %{operation: :add, content: "task"}}
          ]
        }
      }

      fp1 = Aggregator.action_fingerprint(response1)
      fp2 = Aggregator.action_fingerprint(response2)

      # Both should have same fingerprint (sorted)
      assert fp1 == fp2
      assert fp1 == {:batch_async, [:file_read, :todo]}
    end

    # R50: Different action sets separate
    test "batch_async responses with different actions separate" do
      # [UNIT] - WHEN two batch_async have different action sets THEN fingerprints differ
      response1 = %{
        action: :batch_async,
        params: %{
          actions: [
            %{action: :todo, params: %{}},
            %{action: :file_read, params: %{path: "/tmp/a.txt"}}
          ]
        }
      }

      response2 = %{
        action: :batch_async,
        params: %{
          actions: [
            %{action: :orient, params: %{}},
            %{action: :file_read, params: %{path: "/tmp/a.txt"}}
          ]
        }
      }

      fp1 = Aggregator.action_fingerprint(response1)
      fp2 = Aggregator.action_fingerprint(response2)

      # Different action sets = different fingerprints
      refute fp1 == fp2
    end

    # R51: Dual key support (string keys from LLM)
    test "batch_async fingerprint handles string keys from LLM" do
      # [UNIT] - WHEN batch_async action uses string keys THEN fingerprint still works
      response = %{
        action: :batch_async,
        params: %{
          "actions" => [
            %{"action" => "todo", "params" => %{}},
            %{"action" => "file_read", "params" => %{"path" => "/tmp/a.txt"}}
          ]
        }
      }

      fingerprint = Aggregator.action_fingerprint(response)

      # Should still produce sorted fingerprint
      assert fingerprint == {:batch_async, [:file_read, :todo]}
    end

    test "batch_async fingerprint handles mixed keys" do
      # [UNIT] - WHEN batch_async has mix of atom and string keys THEN fingerprint works
      response = %{
        action: :batch_async,
        params: %{
          actions: [
            %{action: :todo, params: %{}},
            %{"action" => "file_read", "params" => %{"path" => "/tmp/a.txt"}}
          ]
        }
      }

      fingerprint = Aggregator.action_fingerprint(response)

      assert fingerprint == {:batch_async, [:file_read, :todo]}
    end

    test "batch_async fingerprint handles three or more actions" do
      # [UNIT] - WHEN batch_async has 3+ actions THEN fingerprint is fully sorted
      response = %{
        action: :batch_async,
        params: %{
          actions: [
            %{action: :todo, params: %{}},
            %{action: :orient, params: %{}},
            %{action: :file_read, params: %{path: "/tmp/a.txt"}}
          ]
        }
      }

      fingerprint = Aggregator.action_fingerprint(response)

      # Sorted: file_read < orient < todo
      assert fingerprint == {:batch_async, [:file_read, :orient, :todo]}
    end
  end

  # ===========================================================================
  # R53: batch_sync vs batch_async Fingerprint Comparison
  # ===========================================================================
  describe "fingerprint comparison" do
    # R53: batch_sync and batch_async with same actions have different fingerprints
    test "batch_sync and batch_async with same actions have different fingerprints" do
      # [UNIT] - WHEN same actions as batch_sync and batch_async THEN fingerprints differ
      actions = [
        %{action: :todo, params: %{}},
        %{action: :file_read, params: %{path: "/tmp/a.txt"}}
      ]

      batch_sync_response = %{
        action: :batch_sync,
        params: %{actions: actions}
      }

      batch_async_response = %{
        action: :batch_async,
        params: %{actions: actions}
      }

      fp_sync = Aggregator.action_fingerprint(batch_sync_response)
      fp_async = Aggregator.action_fingerprint(batch_async_response)

      # Different action types = different fingerprints
      refute fp_sync == fp_async

      # batch_sync: ordered sequence (preserves input order)
      assert {:batch_sync, [:todo, :file_read]} = fp_sync

      # batch_async: sorted sequence (alphabetical)
      assert {:batch_async, [:file_read, :todo]} = fp_async
    end

    test "batch_sync order-sensitive vs batch_async order-independent" do
      # [UNIT] - WHEN actions reversed THEN batch_sync fingerprints differ but batch_async match
      actions_order1 = [
        %{action: :todo, params: %{}},
        %{action: :file_read, params: %{path: "/a.txt"}}
      ]

      actions_order2 = [
        %{action: :file_read, params: %{path: "/b.txt"}},
        %{action: :todo, params: %{}}
      ]

      # batch_sync responses
      sync1 = %{action: :batch_sync, params: %{actions: actions_order1}}
      sync2 = %{action: :batch_sync, params: %{actions: actions_order2}}

      # batch_async responses
      async1 = %{action: :batch_async, params: %{actions: actions_order1}}
      async2 = %{action: :batch_async, params: %{actions: actions_order2}}

      # batch_sync: different order = different fingerprint
      refute Aggregator.action_fingerprint(sync1) == Aggregator.action_fingerprint(sync2)

      # batch_async: different order = same fingerprint (sorted)
      assert Aggregator.action_fingerprint(async1) == Aggregator.action_fingerprint(async2)
    end
  end

  # ===========================================================================
  # R52: format_action_summary for batch_async
  # ===========================================================================
  describe "format_action_summary for batch_async" do
    # R52: format_action_summary shows batch_async sorted action list
    test "format_action_summary shows batch_async sorted action list" do
      # [UNIT] - WHEN format_action_summary called with batch_async THEN shows sorted action list
      response = %{
        action: :batch_async,
        params: %{
          actions: [
            %{action: :todo, params: %{}},
            %{action: :file_read, params: %{path: "/tmp/a.txt"}},
            %{action: :orient, params: %{}}
          ]
        }
      }

      summary = ActionSummary.format_action_summary(response)

      # Should show sorted list
      assert summary =~ "batch_async"
      assert summary =~ "file_read"
      assert summary =~ "orient"
      assert summary =~ "todo"
      # Verify sorted order in the output
      assert summary == "[batch_async: [file_read, orient, todo]]"
    end

    test "format_action_summary handles string action keys" do
      # [UNIT] - WHEN batch_async actions use string keys THEN shows sorted list correctly
      response = %{
        action: :batch_async,
        params: %{
          actions: [
            %{"action" => "orient", "params" => %{}},
            %{"action" => "file_read", "params" => %{}}
          ]
        }
      }

      summary = ActionSummary.format_action_summary(response)

      assert summary == "[batch_async: [file_read, orient]]"
    end

    test "format_action_summary handles empty batch_async" do
      # [UNIT] - WHEN batch_async has empty actions THEN shows empty list
      response = %{
        action: :batch_async,
        params: %{actions: []}
      }

      summary = ActionSummary.format_action_summary(response)

      assert summary == "[batch_async: []]"
    end

    test "format_action_summary handles missing actions param" do
      # [UNIT] - WHEN batch_async has no actions param THEN shows generic format
      response = %{
        action: :batch_async,
        params: %{}
      }

      summary = ActionSummary.format_action_summary(response)

      assert summary == "[batch_async]"
    end
  end

  # ===========================================================================
  # R42-R46: Priority Calculation for batch_async
  # ===========================================================================
  describe "calculate_cluster_priority for batch_async" do
    # R42: batch_async cluster priority is max of sub-action priorities
    test "batch_async cluster priority is max of sub-action priorities" do
      # [UNIT] - WHEN cluster contains batch_async THEN priority is max of sub-actions
      cluster = %{
        representative: %{
          action: :batch_async,
          params: %{
            actions: [
              %{action: :todo, params: %{}},
              %{action: :spawn_child, params: %{task_description: "test"}}
            ]
          }
        }
      }

      priority = Scoring.calculate_cluster_priority(cluster)

      # spawn_child has higher priority than todo, so should be spawn_child's priority
      # (We don't hardcode the exact number - just verify it's the max)
      todo_priority = Quoracle.Actions.Schema.get_action_priority(:todo)
      spawn_priority = Quoracle.Actions.Schema.get_action_priority(:spawn_child)

      assert priority == max(todo_priority, spawn_priority)
    end

    # R43: batch_async uses same priority calculation as batch_sync
    test "batch_async uses same priority calculation as batch_sync" do
      # [UNIT] - WHEN same sub-actions in batch_sync and batch_async THEN same priority
      actions = [
        %{action: :todo, params: %{}},
        %{action: :file_read, params: %{path: "/tmp/a.txt"}}
      ]

      sync_cluster = %{
        representative: %{action: :batch_sync, params: %{actions: actions}}
      }

      async_cluster = %{
        representative: %{action: :batch_async, params: %{actions: actions}}
      }

      sync_priority = Scoring.calculate_cluster_priority(sync_cluster)
      async_priority = Scoring.calculate_cluster_priority(async_cluster)

      # Same sub-actions = same priority
      assert sync_priority == async_priority
    end

    # R45: batch_async cluster competes with non-batch clusters
    test "batch_async cluster competes with non-batch clusters" do
      # [INTEGRATION] - WHEN comparing batch_async cluster to single action cluster THEN priorities compare correctly
      batch_cluster = %{
        representative: %{
          action: :batch_async,
          params: %{
            actions: [
              %{action: :todo, params: %{}},
              %{action: :orient, params: %{}}
            ]
          }
        }
      }

      single_cluster = %{
        representative: %{action: :spawn_child, params: %{task_description: "test"}}
      }

      batch_priority = Scoring.calculate_cluster_priority(batch_cluster)
      single_priority = Scoring.calculate_cluster_priority(single_cluster)

      # Both should be valid priorities (not 999)
      assert is_integer(batch_priority)
      assert is_integer(single_priority)
      assert batch_priority < 999
      assert single_priority < 999
    end

    # R46: Empty batch_async uses default priority
    test "empty batch_async uses default priority" do
      # [UNIT] - WHEN batch_async has empty actions THEN uses high priority (loses to real actions)
      cluster = %{
        representative: %{
          action: :batch_async,
          params: %{actions: []}
        }
      }

      priority = Scoring.calculate_cluster_priority(cluster)

      # Empty batch should use high priority (999) so it loses to real actions
      assert priority == 999
    end

    test "batch_async with missing actions param uses default priority" do
      # [UNIT] - WHEN batch_async has no actions param THEN uses high priority
      cluster = %{
        representative: %{
          action: :batch_async,
          params: %{}
        }
      }

      priority = Scoring.calculate_cluster_priority(cluster)

      assert priority == 999
    end
  end

  # ===========================================================================
  # Clustering Integration
  # ===========================================================================
  describe "batch_async clustering" do
    test "batch_async responses cluster by sorted action sequence" do
      # [INTEGRATION] - WHEN clustering batch_async responses THEN groups by sorted action sequence
      responses = [
        # Order: todo, file_read
        %{
          action: :batch_async,
          params: %{
            actions: [
              %{action: :todo, params: %{}},
              %{action: :file_read, params: %{path: "/a.txt"}}
            ]
          }
        },
        # Order: file_read, todo (reversed - should cluster with first)
        %{
          action: :batch_async,
          params: %{
            actions: [
              %{action: :file_read, params: %{path: "/b.txt"}},
              %{action: :todo, params: %{}}
            ]
          }
        },
        # Different action set
        %{
          action: :batch_async,
          params: %{
            actions: [
              %{action: :orient, params: %{}},
              %{action: :todo, params: %{}}
            ]
          }
        }
      ]

      clusters = Aggregator.cluster_responses(responses)

      # Should have 2 clusters: [:file_read, :todo] (2 actions) and [:orient, :todo] (1 action)
      assert length(clusters) == 2

      # Find the larger cluster (2 actions with [:file_read, :todo])
      large_cluster = Enum.find(clusters, fn c -> c.count == 2 end)
      assert large_cluster.fingerprint == {:batch_async, [:file_read, :todo]}

      # Find the smaller cluster (1 action with [:orient, :todo])
      small_cluster = Enum.find(clusters, fn c -> c.count == 1 end)
      assert small_cluster.fingerprint == {:batch_async, [:orient, :todo]}
    end
  end

  # ===========================================================================
  # Property Tests
  # ===========================================================================
  describe "property tests" do
    property "batch_async fingerprint is order-independent" do
      check all(
              actions <-
                list_of(
                  member_of([:todo, :orient, :file_read, :spawn_child, :send_message]),
                  min_length: 2,
                  max_length: 5
                )
            ) do
        # Create action specs
        action_specs = Enum.map(actions, fn a -> %{action: a, params: %{}} end)

        # Original order
        response1 = %{action: :batch_async, params: %{actions: action_specs}}

        # Shuffled order
        shuffled = Enum.shuffle(action_specs)
        response2 = %{action: :batch_async, params: %{actions: shuffled}}

        fp1 = Aggregator.action_fingerprint(response1)
        fp2 = Aggregator.action_fingerprint(response2)

        # Same fingerprint regardless of order
        assert fp1 == fp2
      end
    end

    property "batch_async fingerprint is always sorted" do
      check all(
              actions <-
                list_of(
                  member_of([:todo, :orient, :file_read, :spawn_child, :send_message]),
                  min_length: 2,
                  max_length: 5
                )
            ) do
        action_specs = Enum.map(actions, fn a -> %{action: a, params: %{}} end)
        response = %{action: :batch_async, params: %{actions: action_specs}}

        {:batch_async, fingerprint_actions} = Aggregator.action_fingerprint(response)

        # Fingerprint should be sorted
        assert fingerprint_actions == Enum.sort(fingerprint_actions)
      end
    end

    property "batch_sync order-dependent vs batch_async order-independent" do
      check all(
              actions <-
                list_of(
                  member_of([:todo, :orient, :file_read, :spawn_child, :send_message]),
                  min_length: 2,
                  max_length: 5
                )
            ) do
        action_specs = Enum.map(actions, fn a -> %{action: a, params: %{}} end)
        shuffled = Enum.shuffle(action_specs)

        # Only test when shuffle actually changes the order
        if action_specs != shuffled do
          sync1 = %{action: :batch_sync, params: %{actions: action_specs}}
          sync2 = %{action: :batch_sync, params: %{actions: shuffled}}

          async1 = %{action: :batch_async, params: %{actions: action_specs}}
          async2 = %{action: :batch_async, params: %{actions: shuffled}}

          # batch_sync: order matters
          refute Aggregator.action_fingerprint(sync1) == Aggregator.action_fingerprint(sync2)

          # batch_async: order doesn't matter
          assert Aggregator.action_fingerprint(async1) == Aggregator.action_fingerprint(async2)
        end
      end
    end
  end
end
