defmodule Quoracle.Actions.SchemaTodoTest do
  use ExUnit.Case, async: true

  alias Quoracle.Actions.Schema

  describe "TODO action schema" do
    test "todo action is included in @actions list" do
      actions = Schema.list_actions()
      assert :todo in actions
      # Should have 21 actions now (including record_cost)
      assert length(actions) == 22
    end

    test "get_schema/1 returns todo schema" do
      assert {:ok, schema} = Schema.get_schema(:todo)

      assert schema == %{
               required_params: [:items],
               optional_params: [],
               param_types: %{
                 items:
                   {:list,
                    {:map,
                     %{
                       content: :string,
                       state: {:enum, [:todo, :pending, :done]}
                     }}}
               },
               param_descriptions: %{
                 items:
                   "Full replacement TODO list - array of {content, state} objects where state is 'todo' (not started), 'pending' (in progress), or 'done' (completed)"
               },
               consensus_rules: %{
                 items: {:semantic_similarity, threshold: 0.85}
               }
             }
    end

    test "todo schema has correct required params" do
      assert {:ok, schema} = Schema.get_schema(:todo)
      assert schema.required_params == [:items]
    end

    test "todo schema has no optional params" do
      assert {:ok, schema} = Schema.get_schema(:todo)
      assert schema.optional_params == []
    end

    test "todo schema defines items as list of maps with nested structure" do
      assert {:ok, schema} = Schema.get_schema(:todo)

      assert schema.param_types.items ==
               {:list,
                {:map,
                 %{
                   content: :string,
                   state: {:enum, [:todo, :pending, :done]}
                 }}}
    end

    test "todo schema uses semantic similarity for consensus" do
      assert {:ok, schema} = Schema.get_schema(:todo)
      assert schema.consensus_rules.items == {:semantic_similarity, threshold: 0.85}
    end

    test "todo schema has high similarity threshold" do
      assert {:ok, schema} = Schema.get_schema(:todo)
      {:semantic_similarity, threshold: threshold} = schema.consensus_rules.items
      assert threshold == 0.85
    end

    test "wait_required?/1 returns true for todo action" do
      # Only :wait action returns false, all others including :todo return true
      assert Schema.wait_required?(:todo)
    end

    test "get_action_priority/1 returns priority for todo" do
      # Todo should have a defined priority for consensus tiebreaking
      priority = Schema.get_action_priority(:todo)
      assert is_integer(priority)
      assert priority >= 0
    end

    test "todo action priority is between safer and riskier actions" do
      # Todo (6) should be between orient (1) and spawn_child (11)
      todo_priority = Schema.get_action_priority(:todo)
      orient_priority = Schema.get_action_priority(:orient)
      spawn_priority = Schema.get_action_priority(:spawn_child)

      # Higher number = more consequential, lower = more conservative
      # todo (6) > orient (1) - todo is more consequential than orient
      assert todo_priority > orient_priority
      # todo (6) < spawn_child (11) - todo is less consequential than spawn_child
      assert todo_priority < spawn_priority
    end

    test "todo schema is compatible with validator" do
      # The schema should be structured correctly for ACTION_Validator
      assert {:ok, schema} = Schema.get_schema(:todo)

      assert Map.has_key?(schema, :required_params)
      assert Map.has_key?(schema, :optional_params)
      assert Map.has_key?(schema, :param_types)
      assert Map.has_key?(schema, :consensus_rules)

      assert is_list(schema.required_params)
      assert is_list(schema.optional_params)
      assert is_map(schema.param_types)
      assert is_map(schema.consensus_rules)
    end
  end

  describe "integration with other actions" do
    test "todo schema structure matches other action schemas" do
      assert {:ok, todo_schema} = Schema.get_schema(:todo)
      assert {:ok, wait_schema} = Schema.get_schema(:wait)

      # Should have same top-level keys (all schemas now have param_descriptions)
      assert MapSet.new(Map.keys(todo_schema)) == MapSet.new(Map.keys(wait_schema))
    end

    test "todo doesn't interfere with existing actions" do
      # Existing actions should still work (using correct action names)
      assert {:ok, _} = Schema.get_schema(:wait)
      assert {:ok, _} = Schema.get_schema(:spawn_child)
      assert {:ok, _} = Schema.get_schema(:send_message)
      assert {:ok, _} = Schema.get_schema(:orient)
      assert {:ok, _} = Schema.get_schema(:answer_engine)
      assert {:ok, _} = Schema.get_schema(:fetch_web)
      assert {:ok, _} = Schema.get_schema(:execute_shell)
      assert {:ok, _} = Schema.get_schema(:call_api)
      assert {:ok, _} = Schema.get_schema(:call_mcp)
    end

    test "all 21 actions have schemas defined" do
      actions = Schema.list_actions()
      assert length(actions) == 22

      for action <- actions do
        assert {:ok, schema} = Schema.get_schema(action)
        assert is_map(schema), "Missing schema for action: #{action}"
        assert Map.has_key?(schema, :required_params)
      end
    end
  end
end
