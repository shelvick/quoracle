defmodule Quoracle.Actions.SchemaTodoTest do
  use ExUnit.Case, async: true

  alias Quoracle.Actions.Schema

  describe "TODO action schema" do
    test "todo action is included in @actions list" do
      actions = Schema.list_actions()
      assert :todo in actions
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

    test "wait_required?/1 returns true for todo action" do
      # Only :wait action returns false, all others including :todo return true
      assert Schema.wait_required?(:todo)
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
  end
end
