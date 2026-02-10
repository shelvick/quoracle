defmodule Quoracle.Fields.SchemasTest do
  use ExUnit.Case, async: true

  alias Quoracle.Fields.Schemas

  describe "get_schema/1" do
    test "retrieves schema for known field" do
      assert {:ok, schema} = Schemas.get_schema(:task_description)
      assert schema.type == :string
      assert schema.required == true
      assert schema.category == :provided
    end

    test "retrieves schema for global_context field" do
      assert {:ok, schema} = Schemas.get_schema(:global_context)
      assert schema.type == :string
      assert schema.required == false
      assert schema.category == :injected
    end

    test "retrieves schema for cognitive_style enum field" do
      assert {:ok, schema} = Schemas.get_schema(:cognitive_style)
      assert {:enum, allowed_values} = schema.type
      assert :efficient in allowed_values
      assert :exploratory in allowed_values
      assert :problem_solving in allowed_values
      assert :creative in allowed_values
      assert :systematic in allowed_values
    end

    test "returns error for unknown field" do
      assert {:error, :unknown_field} = Schemas.get_schema(:nonexistent_field)
    end
  end

  describe "validate_field/2" do
    test "validates conforming field values" do
      assert {:ok, "valid task"} = Schemas.validate_field(:task_description, "valid task")
      assert {:ok, "context"} = Schemas.validate_field(:global_context, "context")
    end

    test "rejects type mismatches" do
      assert {:error, "Expected string, got integer"} =
               Schemas.validate_field(:task_description, 123)

      assert {:error, "Expected list of strings, got string"} =
               Schemas.validate_field(:constraints, "not a list")
    end

    test "accepts strings of any length" do
      # No max_length limits on string fields
      long_string = String.duplicate("a", 5000)
      assert {:ok, ^long_string} = Schemas.validate_field(:task_description, long_string)

      very_long_string = String.duplicate("x", 10000)
      assert {:ok, ^very_long_string} = Schemas.validate_field(:global_context, very_long_string)
    end

    test "validates enum fields against allowed values" do
      assert {:ok, :efficient} = Schemas.validate_field(:cognitive_style, :efficient)
      assert {:ok, :creative} = Schemas.validate_field(:cognitive_style, :creative)

      assert {:error,
              "Invalid enum value: :invalid_style. Allowed values: [:efficient, :exploratory, :problem_solving, :creative, :systematic]"} =
               Schemas.validate_field(:cognitive_style, :invalid_style)
    end

    test "validates list element types" do
      assert {:ok, ["constraint1", "constraint2"]} =
               Schemas.validate_field(:constraints, ["constraint1", "constraint2"])

      assert {:error, "List element at index 1 is not a string"} =
               Schemas.validate_field(:constraints, ["valid", 123, "also valid"])
    end

    test "validates sibling_context as list of maps" do
      valid_context = [
        %{agent_id: "agent-1", task: "Do something"},
        %{agent_id: "agent-2", task: "Do something else"}
      ]

      assert {:ok, ^valid_context} = Schemas.validate_field(:sibling_context, valid_context)

      invalid_context = ["not", "maps"]

      assert {:error, "List element at index 0 is not a map"} =
               Schemas.validate_field(:sibling_context, invalid_context)
    end

    test "validates delegation_strategy enum" do
      assert {:ok, :sequential} = Schemas.validate_field(:delegation_strategy, :sequential)
      assert {:ok, :parallel} = Schemas.validate_field(:delegation_strategy, :parallel)
      assert {:ok, :none} = Schemas.validate_field(:delegation_strategy, :none)

      assert {:error,
              "Invalid enum value: :random. Allowed values: [:sequential, :parallel, :none]"} =
               Schemas.validate_field(:delegation_strategy, :random)
    end

    test "validates output_style enum" do
      assert {:ok, :detailed} = Schemas.validate_field(:output_style, :detailed)
      assert {:ok, :concise} = Schemas.validate_field(:output_style, :concise)
      assert {:ok, :technical} = Schemas.validate_field(:output_style, :technical)
      assert {:ok, :narrative} = Schemas.validate_field(:output_style, :narrative)

      assert {:error,
              "Invalid enum value: :poetic. Allowed values: [:detailed, :concise, :technical, :narrative]"} =
               Schemas.validate_field(:output_style, :poetic)
    end

    test "validates accumulated_narrative accepts any length" do
      # No max_length limit on accumulated_narrative
      short_narrative = String.duplicate("x", 500)

      assert {:ok, ^short_narrative} =
               Schemas.validate_field(:accumulated_narrative, short_narrative)

      long_narrative = String.duplicate("x", 5000)

      assert {:ok, ^long_narrative} =
               Schemas.validate_field(:accumulated_narrative, long_narrative)
    end

    test "validates constraints as list of strings" do
      constraints = ["constraint1", "constraint2", "constraint3"]
      assert {:ok, ^constraints} = Schemas.validate_field(:constraints, constraints)

      invalid_constraints = ["valid", %{not: "string"}]

      assert {:error, "List element at index 1 is not a string"} =
               Schemas.validate_field(:constraints, invalid_constraints)
    end
  end

  describe "list_fields/0" do
    test "returns all field names" do
      fields = Schemas.list_fields()

      # All 13 fields from spec
      assert :global_context in fields
      assert :task_description in fields
      assert :success_criteria in fields
      assert :immediate_context in fields
      assert :approach_guidance in fields
      assert :role in fields
      assert :delegation_strategy in fields
      assert :sibling_context in fields
      assert :output_style in fields
      assert :cognitive_style in fields
      assert :downstream_constraints in fields
      assert :accumulated_narrative in fields
      assert :constraints in fields

      assert length(fields) == 13
    end
  end

  describe "get_fields_by_category/1" do
    test "returns injected fields" do
      fields = Schemas.get_fields_by_category(:injected)
      assert Enum.sort(fields) == [:global_context]
    end

    test "returns provided fields" do
      fields = Schemas.get_fields_by_category(:provided)
      assert :task_description in fields
      assert :success_criteria in fields
      assert :immediate_context in fields
      assert :approach_guidance in fields
      assert :role in fields
      assert :delegation_strategy in fields
      assert :sibling_context in fields
      assert :output_style in fields
      assert :cognitive_style in fields
      assert :downstream_constraints in fields
      assert length(fields) == 10
    end

    test "returns transformed fields" do
      fields = Schemas.get_fields_by_category(:transformed)
      assert Enum.sort(fields) == [:accumulated_narrative, :constraints]
    end
  end

  describe "required_fields/0" do
    test "returns only required provided fields" do
      fields = Schemas.required_fields()

      # Sorted alphabetically for deterministic comparison
      assert Enum.sort(fields) == [
               :approach_guidance,
               :immediate_context,
               :success_criteria,
               :task_description
             ]
    end
  end
end
