defmodule Quoracle.Fields.FieldValidatorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Quoracle.Fields.FieldValidator

  describe "validate_fields/1" do
    # R1: Required Field Validation
    test "validates presence of required fields" do
      # Missing required field: task_description
      fields = %{
        success_criteria: "Complete the task",
        immediate_context: "User request",
        approach_guidance: "Use best practices"
      }

      assert {:error, {:missing_required_fields, missing}} =
               FieldValidator.validate_fields(fields)

      assert :task_description in missing
    end

    test "returns error listing all missing required fields" do
      # Missing multiple required fields
      fields = %{
        immediate_context: "Some context"
      }

      assert {:error, {:missing_required_fields, missing}} =
               FieldValidator.validate_fields(fields)

      assert :task_description in missing
      assert :success_criteria in missing
      assert :approach_guidance in missing
      assert length(missing) == 3
    end

    # R7: Valid Field Acceptance
    test "accepts all valid field combinations" do
      fields = %{
        # Required provided fields
        task_description: "Implement feature X",
        success_criteria: "Feature works correctly",
        immediate_context: "Current codebase state",
        approach_guidance: "Use TDD methodology",
        # Optional provided fields
        role: "Senior Developer",
        cognitive_style: "systematic",
        delegation_strategy: "parallel",
        output_style: "technical",
        # Injected fields
        global_context: "System configuration",
        # Transformed fields
        accumulated_narrative: "Previous agent findings",
        constraints: ["Focus on performance"]
      }

      assert {:ok, validated} = FieldValidator.validate_fields(fields)
      assert validated == fields
    end

    test "accepts fields with only required provided fields" do
      fields = %{
        task_description: "Build API endpoint",
        success_criteria: "Returns JSON responses",
        immediate_context: "REST API context",
        approach_guidance: "Follow REST patterns"
      }

      assert {:ok, validated} = FieldValidator.validate_fields(fields)
      assert validated == fields
    end
  end

  describe "validate_field/2" do
    # R2: String Validation (no length limits)
    test "accepts long strings without length limit" do
      # No max_length enforcement - strings can be any length
      long_string = String.duplicate("a", 5000)
      assert {:ok, ^long_string} = FieldValidator.validate_field(:task_description, long_string)
    end

    test "accepts very long global_context" do
      long_context = String.duplicate("x", 10000)
      assert {:ok, ^long_context} = FieldValidator.validate_field(:global_context, long_context)
    end

    # R3: Enum Value Validation
    test "validates enum values against allowed list" do
      # cognitive_style must be one of: efficient, creative, systematic, exploratory, problem_solving
      assert {:error, msg} = FieldValidator.validate_field(:cognitive_style, "random")
      assert msg =~ "must be one of"
      assert msg =~ "efficient"
      assert msg =~ "creative"
    end

    test "accepts valid enum value for delegation_strategy" do
      # delegation_strategy: sequential, parallel, none
      assert {:ok, "parallel"} = FieldValidator.validate_field(:delegation_strategy, "parallel")

      assert {:ok, "sequential"} =
               FieldValidator.validate_field(:delegation_strategy, "sequential")

      assert {:ok, "none"} = FieldValidator.validate_field(:delegation_strategy, "none")
    end

    test "rejects invalid enum value for output_style" do
      # output_style: detailed, concise, technical, narrative
      assert {:error, msg} = FieldValidator.validate_field(:output_style, "verbose")
      assert msg =~ "must be one of"
      assert msg =~ "concise"
      assert msg =~ "detailed"
      assert msg =~ "technical"
      assert msg =~ "narrative"
    end

    # R4: List Type Validation
    test "validates list element types" do
      # global_constraints should be a list of strings
      assert {:error, msg} = FieldValidator.validate_field(:constraints, [123, 456])
      assert msg =~ "must be strings"
    end

    test "accepts valid list of strings for constraints" do
      constraints = ["Constraint 1", "Constraint 2", "Constraint 3"]

      assert {:ok, ^constraints} =
               FieldValidator.validate_field(:constraints, constraints)
    end

    test "rejects non-list value for list fields" do
      assert {:error, msg} = FieldValidator.validate_field(:constraints, "not a list")
      assert msg =~ "must be a list"
    end

    test "accepts empty list for constraint fields" do
      assert {:ok, []} = FieldValidator.validate_field(:constraints, [])
      assert {:ok, []} = FieldValidator.validate_field(:constraints, [])
    end

    # R5: Nested Map Validation
    test "validates sibling_context map structure" do
      # Each sibling must have agent_id and task keys
      invalid_siblings = [
        # Missing task
        %{agent_id: "agent-1"},
        # Missing agent_id
        %{task: "Do something"}
      ]

      assert {:error, msg} = FieldValidator.validate_field(:sibling_context, invalid_siblings)
      assert msg =~ "must have agent_id and task"
    end

    test "accepts valid sibling_context structure" do
      valid_siblings = [
        %{agent_id: "agent-1", task: "Process data"},
        %{agent_id: "agent-2", task: "Generate report"}
      ]

      assert {:ok, ^valid_siblings} =
               FieldValidator.validate_field(:sibling_context, valid_siblings)
    end

    test "rejects sibling_context with wrong types" do
      invalid_siblings = [
        # agent_id should be string
        %{agent_id: 123, task: "Task 1"},
        # task should be string
        %{agent_id: "agent-2", task: nil}
      ]

      assert {:error, msg} = FieldValidator.validate_field(:sibling_context, invalid_siblings)
      assert msg =~ "must be strings"
    end

    test "accepts empty sibling_context" do
      assert {:ok, []} = FieldValidator.validate_field(:sibling_context, [])
    end

    # Unknown field handling
    test "returns error for unknown field" do
      assert {:error, msg} = FieldValidator.validate_field(:unknown_field, "value")
      assert msg == "Unknown field: unknown_field"
    end

    # Type mismatches
    test "rejects wrong type for string fields" do
      assert {:error, msg} = FieldValidator.validate_field(:task_description, 123)
      assert msg =~ "must be a string"
    end

    test "rejects wrong type for list fields" do
      assert {:error, msg} = FieldValidator.validate_field(:constraints, %{not: "a list"})
      assert msg =~ "must be a list"
    end
  end

  describe "error handling" do
    # R6: Error Message Format
    test "returns errors in consistent format" do
      # Test various error conditions to ensure consistent format

      # Missing field error
      fields = %{task_description: "Test"}
      {:error, {:missing_required_fields, _}} = FieldValidator.validate_fields(fields)

      # Enum error
      {:error, enum_msg} = FieldValidator.validate_field(:cognitive_style, "invalid")
      assert is_binary(enum_msg)
      assert enum_msg =~ "must be one of"

      # Type error
      {:error, type_msg} = FieldValidator.validate_field(:task_description, [:not, :a, :string])
      assert is_binary(type_msg)
      assert type_msg =~ "must be a string"
    end

    test "includes field name in error messages" do
      {:error, msg} = FieldValidator.validate_field(:cognitive_style, "bad")
      assert msg =~ "cognitive_style"

      {:error, msg} = FieldValidator.validate_field(:task_description, 123)
      assert msg =~ "task_description"
    end
  end

  # R8: Property Testing
  describe "property-based tests" do
    property "validates any conforming field set" do
      check all(fields <- valid_field_generator()) do
        assert {:ok, validated} = FieldValidator.validate_fields(fields)

        # Ensure all required fields are present
        required = [:task_description, :success_criteria, :immediate_context, :approach_guidance]

        for field <- required do
          assert Map.has_key?(validated, field)
        end
      end
    end

    property "rejects any non-conforming field set" do
      check all(fields <- invalid_field_generator()) do
        assert {:error, _} = FieldValidator.validate_fields(fields)
      end
    end

    property "string fields accept values of any length" do
      # No max_length limits on string fields
      string_fields = [
        :task_description,
        :success_criteria,
        :immediate_context,
        :approach_guidance,
        :role,
        :accumulated_narrative
      ]

      check all(
              field <- member_of(string_fields),
              length <- integer(1000..5000)
            ) do
        long_string = String.duplicate("a", length)
        assert {:ok, ^long_string} = FieldValidator.validate_field(field, long_string)
      end
    end

    property "enum fields accept only valid values" do
      check all(
              style <-
                member_of([
                  "efficient",
                  "creative",
                  "systematic",
                  "exploratory",
                  "problem_solving"
                ])
            ) do
        assert {:ok, ^style} = FieldValidator.validate_field(:cognitive_style, style)
      end

      check all(
              invalid <-
                string(:alphanumeric, min_length: 1)
                |> filter(
                  &(&1 not in [
                      "efficient",
                      "creative",
                      "systematic",
                      "exploratory",
                      "problem_solving"
                    ])
                )
            ) do
        assert {:error, _} = FieldValidator.validate_field(:cognitive_style, invalid)
      end
    end

    property "list fields accept lists of strings" do
      check all(strings <- list_of(string(:alphanumeric, min_length: 1))) do
        assert {:ok, ^strings} = FieldValidator.validate_field(:constraints, strings)
        assert {:ok, ^strings} = FieldValidator.validate_field(:constraints, strings)
      end
    end
  end

  # Generators for property tests
  defp valid_field_generator do
    gen all(
          task_desc <- string(:alphanumeric, min_length: 1, max_length: 500),
          success <- string(:alphanumeric, min_length: 1, max_length: 500),
          context <- string(:alphanumeric, min_length: 1, max_length: 500),
          guidance <- string(:alphanumeric, min_length: 1, max_length: 500),
          cognitive <-
            member_of(["efficient", "creative", "systematic", "exploratory", "problem_solving"]),
          delegation <- member_of(["sequential", "parallel", "none"]),
          output <- member_of(["detailed", "concise", "technical", "narrative"])
        ) do
      %{
        task_description: task_desc,
        success_criteria: success,
        immediate_context: context,
        approach_guidance: guidance,
        cognitive_style: cognitive,
        delegation_strategy: delegation,
        output_style: output
      }
    end
  end

  # Generate maps missing exactly one required field (deterministic, no duplicates)
  defp invalid_field_generator do
    gen all(
          # Pick which required field to exclude
          field_to_exclude <-
            member_of([
              :task_description,
              :success_criteria,
              :immediate_context,
              :approach_guidance
            ]),
          # Generate values for all 4 required fields
          task_desc <- string(:alphanumeric, min_length: 1, max_length: 100),
          success <- string(:alphanumeric, min_length: 1, max_length: 100),
          context <- string(:alphanumeric, min_length: 1, max_length: 100),
          guidance <- string(:alphanumeric, min_length: 1, max_length: 100)
        ) do
      # Build complete map then remove the excluded field
      %{
        task_description: task_desc,
        success_criteria: success,
        immediate_context: context,
        approach_guidance: guidance
      }
      |> Map.delete(field_to_exclude)
    end
  end
end
