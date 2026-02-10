defmodule Quoracle.Agent.StateUtilsPerModelTest do
  @moduledoc """
  Tests for AGENT_StateUtils per-model histories (Packet 1).
  WorkGroupID: feat-20251207-022443

  Tests R1-R8 from AGENT_StateUtils_PerModelHistories.md spec.

  v2.0 Addition (wip-20251230-075616):
  - R9-R12: rekey_model_histories/2 for model pool switching
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.StateUtils

  describe "add_history_entry/3 with model_histories (R1-R4, R8)" do
    # R1: Append to All Histories
    test "add_history_entry appends to all model histories" do
      state = %{
        model_histories: %{
          "model-a" => [],
          "model-b" => [],
          "model-c" => []
        }
      }

      updated_state = StateUtils.add_history_entry(state, :user, "test message")

      # All three models should have the new entry
      assert length(updated_state.model_histories["model-a"]) == 1
      assert length(updated_state.model_histories["model-b"]) == 1
      assert length(updated_state.model_histories["model-c"]) == 1
    end

    # R2: Same Entry Reference
    test "same entry added to all model histories" do
      state = %{
        model_histories: %{
          "model-a" => [],
          "model-b" => []
        }
      }

      updated_state = StateUtils.add_history_entry(state, :user, "shared message")

      [entry_a] = updated_state.model_histories["model-a"]
      [entry_b] = updated_state.model_histories["model-b"]

      # Same entry struct (content, type match)
      assert entry_a.type == entry_b.type
      assert entry_a.content == entry_b.content
      assert entry_a.timestamp == entry_b.timestamp
    end

    # R3: Preserves Existing Entries
    test "preserves existing entries when adding new entry" do
      existing_entry = %{
        type: :decision,
        content: %{action: :send_message},
        timestamp: ~U[2025-01-01 00:00:00Z]
      }

      state = %{
        model_histories: %{
          "model-a" => [existing_entry],
          "model-b" => [existing_entry]
        }
      }

      updated_state = StateUtils.add_history_entry(state, :user, "new message")

      # Each history should have 2 entries (new + existing)
      assert length(updated_state.model_histories["model-a"]) == 2
      assert length(updated_state.model_histories["model-b"]) == 2

      # Existing entry should still be present
      [_new_entry, old_entry] = updated_state.model_histories["model-a"]
      assert old_entry.content == %{action: :send_message}
    end

    # R4: Empty Histories Handling
    # SPEC CLARIFICATION: Creates default model to prevent silent message loss
    test "handles empty model_histories gracefully" do
      state = %{model_histories: %{}}

      updated_state = StateUtils.add_history_entry(state, :user, "message")

      # Creates default model to avoid losing messages (backward compatibility)
      assert Map.has_key?(updated_state.model_histories, "default")
      [entry] = updated_state.model_histories["default"]
      assert entry.type == :user
      assert entry.content == "message"
    end

    # R8: Timestamp Consistency
    test "entry has identical timestamp across all model histories" do
      state = %{
        model_histories: %{
          "model-a" => [],
          "model-b" => [],
          "model-c" => []
        }
      }

      updated_state = StateUtils.add_history_entry(state, :user, "test")

      [entry_a] = updated_state.model_histories["model-a"]
      [entry_b] = updated_state.model_histories["model-b"]
      [entry_c] = updated_state.model_histories["model-c"]

      # All timestamps should be identical (same entry)
      assert entry_a.timestamp == entry_b.timestamp
      assert entry_b.timestamp == entry_c.timestamp
    end
  end

  describe "add_history_entry_with_action/4 with model_histories (R5)" do
    # R5: Add Entry With Action Type
    test "add_history_entry_with_action includes action_type in all histories" do
      state = %{
        model_histories: %{
          "model-a" => [],
          "model-b" => []
        }
      }

      updated_state =
        StateUtils.add_history_entry_with_action(
          state,
          :result,
          {"action_123", {:ok, "output"}},
          :execute_shell
        )

      [entry_a] = updated_state.model_histories["model-a"]
      [entry_b] = updated_state.model_histories["model-b"]

      # Both should have action_type
      assert entry_a.action_type == :execute_shell
      assert entry_b.action_type == :execute_shell
    end

    test "add_history_entry_with_action appends to all histories" do
      state = %{
        model_histories: %{
          "model-a" => [],
          "model-b" => [],
          "model-c" => []
        }
      }

      updated_state =
        StateUtils.add_history_entry_with_action(
          state,
          :result,
          {"action_456", {:ok, "data"}},
          :fetch_web
        )

      # All three should have the entry
      assert length(updated_state.model_histories["model-a"]) == 1
      assert length(updated_state.model_histories["model-b"]) == 1
      assert length(updated_state.model_histories["model-c"]) == 1
    end
  end

  describe "find_last_decision/2 with model_id (R6)" do
    # R6: Find Last Decision With Model ID
    test "find_last_decision searches specific model history" do
      decision_entry = %{
        type: :decision,
        content: %{action: :send_message, params: %{message: "hello"}},
        timestamp: ~U[2025-01-01 12:00:00Z]
      }

      state = %{
        model_histories: %{
          "model-a" => [decision_entry],
          "model-b" => []
        }
      }

      # Should find decision in model-a
      result_a = StateUtils.find_last_decision(state, "model-a")
      assert result_a.content.action == :send_message

      # Should NOT find decision in model-b (empty)
      result_b = StateUtils.find_last_decision(state, "model-b")
      assert result_b == nil
    end

    test "find_last_decision returns nil for unknown model" do
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :decision, content: %{action: :wait}, timestamp: DateTime.utc_now()}
          ]
        }
      }

      result = StateUtils.find_last_decision(state, "unknown-model")
      assert result == nil
    end

    test "find_last_decision finds most recent decision in model history" do
      older_decision = %{
        type: :decision,
        content: %{action: :send_message},
        timestamp: ~U[2025-01-01 10:00:00Z]
      }

      newer_decision = %{
        type: :decision,
        content: %{action: :spawn_child},
        timestamp: ~U[2025-01-01 12:00:00Z]
      }

      # Newer first (prepended)
      state = %{
        model_histories: %{
          "model-a" => [newer_decision, older_decision]
        }
      }

      result = StateUtils.find_last_decision(state, "model-a")
      assert result.content.action == :spawn_child
    end
  end

  describe "find_result_for_action/3 with model_id (R7)" do
    # R7: Find Result With Model ID
    test "find_result_for_action searches specific model history" do
      # New format: entry has action_id field for lookup
      result_entry = %{
        type: :result,
        content: "pre-wrapped JSON content",
        action_id: "action_123",
        result: {:ok, "success"},
        timestamp: DateTime.utc_now()
      }

      state = %{
        model_histories: %{
          "model-a" => [result_entry],
          "model-b" => []
        }
      }

      # Should find in model-a
      result_a = StateUtils.find_result_for_action(state, "model-a", "action_123")
      assert result_a.action_id == "action_123"
      assert result_a.result == {:ok, "success"}

      # Should NOT find in model-b
      result_b = StateUtils.find_result_for_action(state, "model-b", "action_123")
      assert result_b == nil
    end

    test "find_result_for_action returns nil for unknown action_id" do
      # New format: entry has action_id field for lookup
      result_entry = %{
        type: :result,
        content: "pre-wrapped JSON content",
        action_id: "action_123",
        result: {:ok, "data"},
        timestamp: DateTime.utc_now()
      }

      state = %{
        model_histories: %{
          "model-a" => [result_entry]
        }
      }

      result = StateUtils.find_result_for_action(state, "model-a", "unknown_action")
      assert result == nil
    end

    test "find_result_for_action returns nil for unknown model" do
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :result, content: {"action_1", {:ok, :done}}, timestamp: DateTime.utc_now()}
          ]
        }
      }

      result = StateUtils.find_result_for_action(state, "unknown-model", "action_1")
      assert result == nil
    end
  end

  # =============================================================
  # rekey_model_histories/2 (R9-R12) - NEW v2.0
  # WorkGroupID: wip-20251230-075616
  # =============================================================

  describe "rekey_model_histories/2" do
    # R9: WHEN rekey_model_histories called THEN returns new map with new model IDs as keys
    test "creates map with new model IDs" do
      history = [
        %{type: :user, content: "hello", timestamp: ~U[2025-01-01 12:00:00Z]},
        %{type: :assistant, content: "hi", timestamp: ~U[2025-01-01 12:00:01Z]}
      ]

      new_pool = ["new-model-x", "new-model-y", "new-model-z"]

      result = StateUtils.rekey_model_histories(new_pool, history)

      assert Map.keys(result) |> Enum.sort() == Enum.sort(new_pool)
      assert Map.has_key?(result, "new-model-x")
      assert Map.has_key?(result, "new-model-y")
      assert Map.has_key?(result, "new-model-z")
    end

    # R10: WHEN rekey_model_histories called THEN all new models have same history reference
    test "all new models share same history reference after rekey" do
      history = [
        %{type: :user, content: "shared message", timestamp: ~U[2025-01-01 12:00:00Z]}
      ]

      new_pool = ["model-a", "model-b", "model-c"]

      result = StateUtils.rekey_model_histories(new_pool, history)

      # All histories should be identical (same reference)
      history_a = result["model-a"]
      history_b = result["model-b"]
      history_c = result["model-c"]

      assert history_a == history_b
      assert history_b == history_c
      assert history_a == history
    end

    # R11: WHEN new_model_pool is empty THEN returns empty map
    test "returns empty map for empty pool" do
      history = [%{type: :user, content: "test", timestamp: DateTime.utc_now()}]

      result = StateUtils.rekey_model_histories([], history)

      assert result == %{}
    end

    # R12: WHEN history is empty list THEN all new models have empty history
    test "preserves empty history" do
      new_pool = ["model-x", "model-y"]

      result = StateUtils.rekey_model_histories(new_pool, [])

      assert result["model-x"] == []
      assert result["model-y"] == []
    end
  end
end
