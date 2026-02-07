defmodule Quoracle.Actions.SchemaAutoCompleteTodoTest do
  @moduledoc """
  Tests for auto_complete_todo parameter in ACTION_Schema (v19.0)
  WorkGroupID: autocomplete-20251116-001905

  Note: auto_complete_todo is INJECTED by SchemaFormatter (like wait parameter),
  not defined in Definitions.ex schemas.
  """
  use ExUnit.Case, async: true
  alias Quoracle.Actions.Schema

  describe "auto_complete_todo_available?/1" do
    # R1/R2: Returns true for :spawn_child (tests function exists by calling it)
    test "returns true for :spawn_child action" do
      assert Schema.auto_complete_todo_available?(:spawn_child) == true
    end

    # R3: Returns true for :wait
    test "returns true for :wait action" do
      assert Schema.auto_complete_todo_available?(:wait) == true
    end

    # R4: Returns false for :todo
    test "returns false for :todo action" do
      assert Schema.auto_complete_todo_available?(:todo) == false
    end

    # R5: Returns false for invalid actions
    test "returns false for :invalid_action" do
      assert Schema.auto_complete_todo_available?(:invalid_action) == false
    end

    # R6: Returns true for all valid actions except :todo
    test "returns true for all valid actions except :todo" do
      valid_actions = Schema.list_actions()

      for action <- valid_actions do
        result = Schema.auto_complete_todo_available?(action)

        if action == :todo do
          assert result == false, "Expected false for :todo, got #{result}"
        else
          assert result == true, "Expected true for #{action}, got #{result}"
        end
      end
    end

    # R7: Guards against non-atom input
    test "raises FunctionClauseError for non-atom input" do
      assert_raise FunctionClauseError, fn ->
        Schema.auto_complete_todo_available?("spawn_child")
      end
    end
  end

  describe "backward compatibility" do
    # R8: Action List Unchanged (updated for record_cost)
    test "action list has 21 actions" do
      actions = Schema.list_actions()
      assert length(actions) == 22

      # Verify record_cost is included
      assert :record_cost in actions
    end

    # R9: Backward Compatibility - existing parameters unchanged
    test "existing parameters unchanged for all actions" do
      # Verify critical existing params still present
      {:ok, spawn_schema} = Schema.get_schema(:spawn_child)
      assert :task_description in spawn_schema.required_params
      assert :role in spawn_schema.optional_params

      {:ok, wait_schema} = Schema.get_schema(:wait)
      assert :wait in wait_schema.optional_params

      {:ok, send_message_schema} = Schema.get_schema(:send_message)
      assert :to in send_message_schema.required_params
      assert :content in send_message_schema.required_params

      {:ok, todo_schema} = Schema.get_schema(:todo)
      assert :items in todo_schema.required_params
    end
  end
end
