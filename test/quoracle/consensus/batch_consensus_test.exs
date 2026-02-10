defmodule Quoracle.Consensus.BatchConsensusTest do
  @moduledoc """
  Tests for batch_sync consensus handling - fingerprinting and action summary.
  WorkGroupID: feat-20260123-batch-sync
  Packet: 2 (Consensus Logic)

  Covers:
  - R43: batch_sync fingerprint uses action type sequence
  - R44: Same sequence same fingerprint (different params)
  - R45: Different sequence different fingerprint
  - R46: Dual key support (string keys from LLM)
  - R47: format_action_summary for batch_sync
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Consensus.Aggregator
  alias Quoracle.Consensus.Aggregator.ActionSummary

  @moduletag :batch_consensus

  # ===========================================================================
  # R43-R46: batch_sync Fingerprinting
  # ===========================================================================
  describe "batch_sync fingerprinting" do
    # R43: batch_sync Fingerprint Uses Sequence
    test "batch_sync fingerprint uses action type sequence" do
      # [UNIT] - WHEN action_fingerprint called with batch_sync THEN returns {:batch_sync, [action_types]}
      response = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :file_read, params: %{path: "/a.txt"}},
            %{action: :todo, params: %{items: []}}
          ]
        }
      }

      fingerprint = Aggregator.action_fingerprint(response)

      assert fingerprint == {:batch_sync, [:file_read, :todo]}
    end

    # R44: Same Sequence Same Fingerprint
    test "batch_sync responses with same sequence cluster together" do
      # [UNIT] - WHEN two batch_sync have same action sequence different params THEN fingerprints match
      response1 = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :file_read, params: %{path: "/a.txt", limit: 100}},
            %{action: :todo, params: %{items: ["item1"]}}
          ]
        }
      }

      response2 = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :file_read, params: %{path: "/b.txt", limit: 200}},
            %{action: :todo, params: %{items: ["item2", "item3"]}}
          ]
        }
      }

      fp1 = Aggregator.action_fingerprint(response1)
      fp2 = Aggregator.action_fingerprint(response2)

      # Same action sequence, different params = same fingerprint
      assert fp1 == fp2
      assert fp1 == {:batch_sync, [:file_read, :todo]}
    end

    # R45: Different Sequence Different Fingerprint
    test "batch_sync responses with different sequences separate" do
      # [UNIT] - WHEN two batch_sync have different action sequences THEN fingerprints differ
      response1 = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :file_read, params: %{path: "/a.txt"}},
            %{action: :todo, params: %{items: []}}
          ]
        }
      }

      response2 = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :todo, params: %{items: []}},
            %{action: :file_read, params: %{path: "/a.txt"}}
          ]
        }
      }

      fp1 = Aggregator.action_fingerprint(response1)
      fp2 = Aggregator.action_fingerprint(response2)

      assert fp1 != fp2
      assert fp1 == {:batch_sync, [:file_read, :todo]}
      assert fp2 == {:batch_sync, [:todo, :file_read]}
    end

    # R46: Dual Key Support
    test "batch_sync fingerprint handles string keys from LLM" do
      # [UNIT] - WHEN batch_sync action uses string keys THEN fingerprint still works
      response = %{
        action: :batch_sync,
        params: %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "todo", "params" => %{"items" => []}}
          ]
        }
      }

      fingerprint = Aggregator.action_fingerprint(response)

      assert fingerprint == {:batch_sync, [:file_read, :todo]}
    end

    test "batch_sync fingerprint handles mixed keys" do
      # [UNIT] - WHEN batch_sync has mix of atom and string keys THEN fingerprint works
      response = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :file_read, params: %{path: "/a.txt"}},
            %{"action" => "todo", "params" => %{"items" => []}}
          ]
        }
      }

      fingerprint = Aggregator.action_fingerprint(response)

      assert fingerprint == {:batch_sync, [:file_read, :todo]}
    end
  end

  # ===========================================================================
  # R47: format_action_summary for batch_sync
  # ===========================================================================
  describe "format_action_summary for batch_sync" do
    # R47: format_action_summary for batch_sync
    test "format_action_summary shows batch_sync action list" do
      # [UNIT] - WHEN format_action_summary called with batch_sync THEN shows action list
      response = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :file_read, params: %{path: "/a.txt"}},
            %{action: :todo, params: %{items: []}}
          ]
        }
      }

      summary = ActionSummary.format_action_summary(response)

      assert summary == "[batch_sync: [file_read, todo]]"
    end

    test "format_action_summary handles string action keys" do
      # [UNIT] - WHEN batch_sync actions use string keys THEN shows action list correctly
      response = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{"action" => "orient", "params" => %{}},
            %{"action" => "send_message", "params" => %{}}
          ]
        }
      }

      summary = ActionSummary.format_action_summary(response)

      assert summary == "[batch_sync: [orient, send_message]]"
    end

    test "format_action_summary handles empty batch_sync" do
      # [UNIT] - WHEN batch_sync has empty actions THEN shows empty list
      response = %{
        action: :batch_sync,
        params: %{actions: []}
      }

      summary = ActionSummary.format_action_summary(response)

      assert summary == "[batch_sync: []]"
    end

    test "format_action_summary handles missing actions param" do
      # [UNIT] - WHEN batch_sync has no actions param THEN shows generic format
      response = %{
        action: :batch_sync,
        params: %{}
      }

      summary = ActionSummary.format_action_summary(response)

      assert summary == "[batch_sync]"
    end
  end

  # ===========================================================================
  # Clustering Integration
  # ===========================================================================
  describe "batch_sync clustering" do
    test "batch_sync responses cluster by action sequence" do
      # [INTEGRATION] - WHEN clustering batch_sync responses THEN groups by action sequence
      responses = [
        %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :file_read, params: %{path: "/a.txt"}},
              %{action: :todo, params: %{items: []}}
            ]
          }
        },
        %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :file_read, params: %{path: "/b.txt"}},
              %{action: :todo, params: %{items: ["x"]}}
            ]
          }
        },
        %{
          action: :batch_sync,
          params: %{
            actions: [
              %{action: :orient, params: %{current_situation: "test"}},
              %{action: :todo, params: %{items: []}}
            ]
          }
        }
      ]

      clusters = Aggregator.cluster_responses(responses)

      # Should have 2 clusters: [:file_read, :todo] and [:orient, :todo]
      assert length(clusters) == 2

      # Find the larger cluster (2 actions with [:file_read, :todo])
      large_cluster = Enum.find(clusters, fn c -> length(c.actions) == 2 end)
      assert large_cluster.fingerprint == {:batch_sync, [:file_read, :todo]}

      # Find the smaller cluster (1 action with [:orient, :todo])
      small_cluster = Enum.find(clusters, fn c -> length(c.actions) == 1 end)
      assert small_cluster.fingerprint == {:batch_sync, [:orient, :todo]}
    end
  end
end
