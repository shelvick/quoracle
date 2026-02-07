defmodule Quoracle.Actions.SchemaTodoEnhancementTest do
  @moduledoc """
  Tests for the enhanced TODO action schema with explicit nested structure.
  This ensures LLMs receive proper field definitions for TODO items.

  Tests verify the TODO schema includes:
  - Nested map structure with explicit properties
  - Enum type for state field
  - Proper consensus rules
  """
  use ExUnit.Case, async: true
  alias Quoracle.Actions.Schema

  describe "todo action enhanced schema" do
    test "returns enhanced nested structure for todo action" do
      assert {:ok, schema} = Schema.get_schema(:todo)

      # Verify basic structure
      assert schema.required_params == [:items]
      assert schema.optional_params == []

      # CRITICAL: Verify the enhanced nested type structure
      assert schema.param_types.items ==
               {:list,
                {:map,
                 %{
                   content: :string,
                   state: {:enum, [:todo, :pending, :done]}
                 }}}
    end

    test "todo items param_type has nested map with content and state fields" do
      {:ok, schema} = Schema.get_schema(:todo)

      # Extract the nested type structure
      assert {:list, inner_type} = schema.param_types.items
      assert {:map, properties} = inner_type

      # Verify the exact property definitions
      assert properties.content == :string
      assert properties.state == {:enum, [:todo, :pending, :done]}
    end

    test "todo state field uses enum type with specific values" do
      {:ok, schema} = Schema.get_schema(:todo)

      # Navigate to the state enum definition
      {:list, {:map, properties}} = schema.param_types.items
      {:enum, allowed_values} = properties.state

      # Verify exact enum values
      assert allowed_values == [:todo, :pending, :done]
      assert length(allowed_values) == 3
    end

    test "todo schema defines exactly two properties: content and state" do
      {:ok, schema} = Schema.get_schema(:todo)

      # Extract property map
      {:list, {:map, properties}} = schema.param_types.items

      # Verify only content and state exist
      assert Map.keys(properties) |> Enum.sort() == [:content, :state]
      assert map_size(properties) == 2
    end

    test "todo consensus rule uses semantic_similarity with 0.85 threshold" do
      {:ok, schema} = Schema.get_schema(:todo)

      # Verify consensus rule remains unchanged
      assert schema.consensus_rules.items == {:semantic_similarity, threshold: 0.85}
    end

    test "todo action has priority 11 in action priorities" do
      # This ensures TODO action is properly integrated
      assert Schema.get_action_priority(:todo) == 11
    end

    test "todo is included in list_actions" do
      actions = Schema.list_actions()
      assert :todo in actions
    end

    test "validate_action_type accepts todo" do
      assert {:ok, :todo} = Schema.validate_action_type(:todo)
    end

    test "wait_required? returns true for todo action" do
      assert Schema.wait_required?(:todo) == true
    end
  end

  describe "nested type structure validation" do
    test "nested map type is not the same as generic map" do
      {:ok, todo_schema} = Schema.get_schema(:todo)
      {:ok, api_schema} = Schema.get_schema(:call_api)

      # TODO uses nested map with properties
      assert {:list, {:map, %{}}} = todo_schema.param_types.items

      # call_api.headers uses generic map (no nested structure)
      assert api_schema.param_types.headers == :map

      # They should be different
      refute todo_schema.param_types.items == {:list, :map}
    end

    test "enum type provides constrained values" do
      {:ok, schema} = Schema.get_schema(:todo)
      {:list, {:map, properties}} = schema.param_types.items

      # State uses enum type, not plain atom
      assert {:enum, _values} = properties.state
      refute properties.state == :atom
      refute properties.state == :string
    end
  end

  describe "backward compatibility" do
    test "other actions still return their original schemas" do
      # Verify wait action has new union type (breaking change)
      # Note: auto_complete_todo is injected by Validator, not in schema definitions
      {:ok, wait_schema} = Schema.get_schema(:wait)
      assert wait_schema.optional_params == [:wait]
      assert wait_schema.param_types.wait == {:union, [:boolean, :number]}

      # Verify orient action unchanged
      {:ok, orient_schema} = Schema.get_schema(:orient)
      assert :current_situation in orient_schema.required_params
      assert orient_schema.param_types.current_situation == :string

      # Verify spawn_child has profile as required (v24.0)
      {:ok, spawn_schema} = Schema.get_schema(:spawn_child)

      assert spawn_schema.required_params == [
               :task_description,
               :success_criteria,
               :immediate_context,
               :approach_guidance,
               :profile
             ]

      assert spawn_schema.param_types.task_description == :string
    end

    test "all 21 actions remain accessible" do
      actions = Schema.list_actions()
      assert length(actions) == 22
      assert :record_cost in actions
    end
  end

  describe "type system completeness" do
    test "schema supports all required type representations" do
      {:ok, todo_schema} = Schema.get_schema(:todo)

      # Verify the type system can represent:
      # 1. Lists
      assert {:list, _} = todo_schema.param_types.items

      # 2. Nested maps with properties
      {:list, nested} = todo_schema.param_types.items
      assert {:map, %{}} = nested

      # 3. Enums
      {:list, {:map, props}} = todo_schema.param_types.items
      assert {:enum, _} = props.state

      # 4. Basic types
      assert props.content == :string
    end

    test "nested structure is properly recursive" do
      {:ok, schema} = Schema.get_schema(:todo)

      # Unpack the nested structure step by step
      items_type = schema.param_types.items
      assert {:list, inner} = items_type

      assert {:map, properties} = inner
      assert is_map(properties)

      assert Map.has_key?(properties, :content)
      assert Map.has_key?(properties, :state)

      # Each property has its own type
      assert properties.content == :string
      assert {:enum, values} = properties.state
      assert is_list(values)
    end
  end

  describe "error handling for enhanced types" do
    test "get_schema still returns error for invalid actions" do
      assert {:error, :unknown_action} = Schema.get_schema(:not_todo)
      assert {:error, :unknown_action} = Schema.get_schema(:invalid)
      assert {:error, :unknown_action} = Schema.get_schema(nil)
    end

    test "get_schema handles todo action without errors" do
      assert {:ok, schema} = Schema.get_schema(:todo)
      assert is_map(schema)
      assert Map.has_key?(schema, :param_types)
    end
  end

  describe "integration with consensus rules" do
    test "todo items consensus rule works with nested structure" do
      {:ok, schema} = Schema.get_schema(:todo)

      # Consensus rule should apply to the entire items list
      assert Map.has_key?(schema.consensus_rules, :items)
      assert {:semantic_similarity, opts} = schema.consensus_rules.items
      assert opts[:threshold] == 0.85
    end

    test "all todo params have consensus rules defined" do
      {:ok, schema} = Schema.get_schema(:todo)

      # Every required param must have a consensus rule
      for param <- schema.required_params do
        assert Map.has_key?(schema.consensus_rules, param),
               "Missing consensus rule for #{param}"
      end

      # Every optional param must have a consensus rule (none for TODO)
      for param <- schema.optional_params do
        assert Map.has_key?(schema.consensus_rules, param),
               "Missing consensus rule for #{param}"
      end
    end
  end

  describe "property-based testing for type consistency" do
    test "all enum values are atoms" do
      {:ok, schema} = Schema.get_schema(:todo)
      {:list, {:map, props}} = schema.param_types.items
      {:enum, values} = props.state

      assert Enum.all?(values, &is_atom/1),
             "All enum values should be atoms"
    end

    test "nested map properties are all atoms" do
      {:ok, schema} = Schema.get_schema(:todo)
      {:list, {:map, props}} = schema.param_types.items

      assert Enum.all?(Map.keys(props), &is_atom/1),
             "All property keys should be atoms"
    end

    test "type definitions are properly nested without cycles" do
      {:ok, schema} = Schema.get_schema(:todo)

      # Traverse the type tree to ensure no circular references
      assert {:list, inner} = schema.param_types.items
      assert {:map, props} = inner
      # Terminal type
      assert props.content == :string
      assert {:enum, values} = props.state
      # Terminal values
      assert Enum.all?(values, &is_atom/1)
    end
  end
end
