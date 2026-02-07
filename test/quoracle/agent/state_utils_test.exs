defmodule Quoracle.Agent.StateUtilsTest do
  use ExUnit.Case, async: true

  alias Quoracle.Agent.StateUtils

  # Helper to get first model's history from model_histories
  defp first_history(state) do
    state.model_histories |> Map.values() |> List.first([])
  end

  describe "add_history_entry_with_action/4" do
    # R5: Add Entry with Action Type
    test "adds history entry with action_type for NO_EXECUTE tracking" do
      state = %{model_histories: %{"test-model" => []}}
      action_id = "action_123"
      result = {:ok, %{stdout: "command output"}}
      action_type = :execute_shell

      updated_state =
        StateUtils.add_history_entry_with_action(
          state,
          :result,
          {action_id, result},
          action_type
        )

      assert [entry] = first_history(updated_state)
      assert entry.type == :result
      # Content is now wrapped JSON string
      assert is_binary(entry.content)
      assert entry.content =~ "<NO_EXECUTE_"
      assert entry.content =~ "command output"
      # action_id and result stored separately
      assert entry.action_id == action_id
      assert entry.result == result
      assert entry.action_type == :execute_shell
      assert %DateTime{} = entry.timestamp
    end

    # R6: Action Type Preserved
    test "preserves action_type field through history operations" do
      state = %{model_histories: %{"test-model" => []}}

      # Add multiple entries with different action types
      state =
        StateUtils.add_history_entry_with_action(
          state,
          :result,
          {"action_1", {:ok, "data"}},
          :fetch_web
        )

      state =
        StateUtils.add_history_entry_with_action(
          state,
          :result,
          {"action_2", {:ok, "output"}},
          :call_api
        )

      # Verify both entries preserve their action_type fields
      assert [second_entry, first_entry] = first_history(state)
      assert first_entry.action_type == :fetch_web
      assert second_entry.action_type == :call_api
    end

    test "creates timestamped entry with all required fields" do
      state = %{model_histories: %{"test-model" => []}}

      updated_state =
        StateUtils.add_history_entry_with_action(
          state,
          :result,
          {"action_999", {:error, :timeout}},
          :call_api
        )

      [entry] = first_history(updated_state)

      # Verify all fields present
      assert Map.has_key?(entry, :type)
      assert Map.has_key?(entry, :content)
      assert Map.has_key?(entry, :action_type)
      assert Map.has_key?(entry, :timestamp)

      # Verify values
      assert entry.type == :result
      assert entry.action_type == :call_api
    end

    test "prepends to history (newest first)" do
      state = %{
        model_histories: %{
          "test-model" => [
            %{type: :event, content: "old entry", timestamp: DateTime.utc_now()}
          ]
        }
      }

      updated_state =
        StateUtils.add_history_entry_with_action(
          state,
          :result,
          {"new_action", {:ok, :done}},
          :call_mcp
        )

      assert [new_entry, old_entry] = first_history(updated_state)
      assert new_entry.action_type == :call_mcp
      assert old_entry.type == :event
    end
  end

  describe "backwards compatibility" do
    # R7: Backwards Compatibility
    test "maintains backwards compatibility for entries without action_type" do
      state = %{model_histories: %{"test-model" => []}}

      # Use old add_history_entry/3 (without action_type)
      state_with_old =
        StateUtils.add_history_entry(
          state,
          :result,
          {"action_old", {:ok, :result}}
        )

      # Use new add_history_entry_with_action/4
      state_with_new =
        StateUtils.add_history_entry_with_action(
          state_with_old,
          :result,
          {"action_new", {:ok, :result}},
          :execute_shell
        )

      [new_entry, old_entry] = first_history(state_with_new)

      # Old entry should NOT have action_type field
      refute Map.has_key?(old_entry, :action_type)

      # New entry SHOULD have action_type field
      assert Map.has_key?(new_entry, :action_type)
      assert new_entry.action_type == :execute_shell

      # Both should have standard fields
      assert old_entry.type == :result
      assert new_entry.type == :result
    end

    test "find_result_for_action uses action_id field for lookup" do
      state = %{model_histories: %{"test-model" => []}}

      # Add new-style entry (with action_type and action_id field)
      state =
        StateUtils.add_history_entry_with_action(
          state,
          :result,
          {"action_2", {:ok, :new_result}},
          :fetch_web
        )

      # New entries are findable via action_id field
      model_id = "test-model"
      new_result = StateUtils.find_result_for_action(state, model_id, "action_2")

      assert new_result != nil
      assert new_result.action_id == "action_2"
      assert new_result.result == {:ok, :new_result}
    end
  end

  describe "integration with existing functions" do
    test "works with find_last_decision" do
      state = %{model_histories: %{"test-model" => []}}

      state =
        StateUtils.add_history_entry(
          state,
          :decision,
          %{action: :execute_shell, params: %{command: "ls"}}
        )

      state =
        StateUtils.add_history_entry_with_action(
          state,
          :result,
          {"action_123", {:ok, "output"}},
          :execute_shell
        )

      decision = StateUtils.find_last_decision(state, "test-model")
      assert decision.content.action == :execute_shell
    end

    test "action_type field does not interfere with timestamp ordering" do
      state = %{model_histories: %{"test-model" => []}}

      # Add entries in sequence
      state =
        StateUtils.add_history_entry_with_action(
          state,
          :result,
          {"first", {:ok, 1}},
          :call_api
        )

      state =
        StateUtils.add_history_entry_with_action(
          state,
          :result,
          {"second", {:ok, 2}},
          :fetch_web
        )

      # Most recent should be first (newest-first ordering)
      [newest, oldest] = first_history(state)
      # action_id and result stored separately
      assert newest.action_id == "second"
      assert newest.result == {:ok, 2}
      assert oldest.action_id == "first"
      assert oldest.result == {:ok, 1}
    end
  end
end
