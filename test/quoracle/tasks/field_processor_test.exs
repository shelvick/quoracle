defmodule Quoracle.Tasks.FieldProcessorTest do
  use ExUnit.Case, async: true

  alias Quoracle.Tasks.FieldProcessor

  describe "process_form_params/1" do
    # R1: Required Field Validation - Missing
    test "returns error when task_description is missing" do
      params = %{
        "profile" => "test-profile",
        "global_context" => "Some context",
        "success_criteria" => "Some criteria"
      }

      assert {:error, {:missing_required, [:task_description]}} =
               FieldProcessor.process_form_params(params)
    end

    test "returns error when task_description is empty string" do
      params = %{
        "task_description" => "",
        "profile" => "test-profile",
        "global_context" => "Some context"
      }

      assert {:error, {:missing_required, [:task_description]}} =
               FieldProcessor.process_form_params(params)
    end

    test "returns error when task_description is whitespace only" do
      params = %{
        "task_description" => "   ",
        "profile" => "test-profile",
        "global_context" => "Some context"
      }

      assert {:error, {:missing_required, [:task_description]}} =
               FieldProcessor.process_form_params(params)
    end

    # R2: Required Field Validation - Present
    test "includes task_description in agent_fields when present" do
      params = %{
        "task_description" => "Build a TODO app",
        "profile" => "test-profile"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{agent_fields: agent_fields} = result
      assert agent_fields.task_description == "Build a TODO app"
    end

    # R3: Optional Field Omission
    test "omits empty optional fields from output" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "success_criteria" => "",
        "immediate_context" => "",
        "approach_guidance" => "",
        "role" => "",
        "output_style" => "",
        "delegation_strategy" => ""
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{agent_fields: agent_fields} = result

      # Should only have task_description
      assert Map.keys(agent_fields) == [:task_description]
      refute Map.has_key?(agent_fields, :success_criteria)
      refute Map.has_key?(agent_fields, :immediate_context)
      refute Map.has_key?(agent_fields, :approach_guidance)
      refute Map.has_key?(agent_fields, :role)
      refute Map.has_key?(agent_fields, :output_style)
      refute Map.has_key?(agent_fields, :delegation_strategy)
    end

    test "includes non-empty optional fields in output" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "success_criteria" => "App works",
        "immediate_context" => "Starting fresh",
        "role" => "Developer"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{agent_fields: agent_fields} = result

      assert agent_fields.task_description == "Build app"
      assert agent_fields.success_criteria == "App works"
      assert agent_fields.immediate_context == "Starting fresh"
      assert agent_fields.role == "Developer"
    end

    # R4: Task Field Separation
    test "separates global_context into task_fields" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "global_context" => "This is a learning project"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields, agent_fields: agent_fields} = result

      # global_context should be in task_fields, not agent_fields
      assert task_fields.global_context == "This is a learning project"
      refute Map.has_key?(agent_fields, :global_context)
    end

    test "omits empty global_context from task_fields" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "global_context" => ""
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      refute Map.has_key?(task_fields, :global_context)
    end

    # R5: Constraint List Parsing
    test "parses comma-separated global_constraints into list" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "global_constraints" => "Use Elixir, Follow TDD, Keep it simple"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      assert task_fields.global_constraints == ["Use Elixir", "Follow TDD", "Keep it simple"]
    end

    test "handles global_constraints with extra spaces" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "global_constraints" => "  Use Elixir  ,  Follow TDD  ,  Keep it simple  "
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      assert task_fields.global_constraints == ["Use Elixir", "Follow TDD", "Keep it simple"]
    end

    test "handles single constraint without comma" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "global_constraints" => "Use Elixir only"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      assert task_fields.global_constraints == ["Use Elixir only"]
    end

    test "handles global_constraints as array (already parsed)" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "global_constraints" => ["Use Elixir", "Follow TDD"]
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      assert task_fields.global_constraints == ["Use Elixir", "Follow TDD"]
    end

    # R6: Enum Validation
    test "validates cognitive_style enum values" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "cognitive_style" => "invalid_style"
      }

      assert {:error, {:invalid_enum, :cognitive_style, "invalid_style", allowed}} =
               FieldProcessor.process_form_params(params)

      # Should return allowed values
      assert is_list(allowed)
      assert "efficient" in allowed
      assert "creative" in allowed
      assert "systematic" in allowed
    end

    test "validates output_style enum values" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "output_style" => "invalid_output"
      }

      assert {:error, {:invalid_enum, :output_style, "invalid_output", allowed}} =
               FieldProcessor.process_form_params(params)

      assert is_list(allowed)
      assert "detailed" in allowed
      assert "concise" in allowed
    end

    test "validates delegation_strategy enum values" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "delegation_strategy" => "invalid_strategy"
      }

      assert {:error, {:invalid_enum, :delegation_strategy, "invalid_strategy", allowed}} =
               FieldProcessor.process_form_params(params)

      assert is_list(allowed)
      assert "sequential" in allowed
      assert "parallel" in allowed
    end

    # R7: Whitespace Trimming
    test "trims whitespace from string fields" do
      params = %{
        "task_description" => "  Build app  ",
        "profile" => "  test-profile  ",
        "success_criteria" => "  App works  ",
        "immediate_context" => "  Starting now  ",
        "approach_guidance" => "  Be careful  ",
        "role" => "  Developer  ",
        "global_context" => "  Learning project  "
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields, agent_fields: agent_fields} = result

      assert agent_fields.task_description == "Build app"
      assert agent_fields.success_criteria == "App works"
      assert agent_fields.immediate_context == "Starting now"
      assert agent_fields.approach_guidance == "Be careful"
      assert agent_fields.role == "Developer"
      assert task_fields.global_context == "Learning project"
    end

    # R8: All Fields Passthrough
    test "handles all 11 fields correctly" do
      params = %{
        # Task fields (3)
        "profile" => "test-profile",
        "global_context" => "Project context",
        "global_constraints" => "Use Elixir, Follow TDD",
        # Agent fields (8)
        "task_description" => "Build TODO app",
        "success_criteria" => "All tests pass",
        "immediate_context" => "Starting from scratch",
        "approach_guidance" => "Use best practices",
        "role" => "Senior Developer",
        "cognitive_style" => "systematic",
        "output_style" => "detailed",
        "delegation_strategy" => "parallel"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields, agent_fields: agent_fields} = result

      # Check task_fields (3 fields)
      assert map_size(task_fields) == 3
      assert task_fields.profile == "test-profile"
      assert task_fields.global_context == "Project context"
      assert task_fields.global_constraints == ["Use Elixir", "Follow TDD"]

      # Check agent_fields (8 fields)
      assert map_size(agent_fields) == 8
      assert agent_fields.task_description == "Build TODO app"
      assert agent_fields.success_criteria == "All tests pass"
      assert agent_fields.immediate_context == "Starting from scratch"
      assert agent_fields.approach_guidance == "Use best practices"
      assert agent_fields.role == "Senior Developer"
      assert agent_fields.cognitive_style == :systematic
      assert agent_fields.output_style == :detailed
      assert agent_fields.delegation_strategy == :parallel
    end

    # R9: Enum Passthrough
    test "preserves valid enum values" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "cognitive_style" => "systematic",
        "output_style" => "concise",
        "delegation_strategy" => "parallel"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{agent_fields: agent_fields} = result

      # Enums should be converted to atoms
      assert agent_fields.cognitive_style == :systematic
      assert agent_fields.output_style == :concise
      assert agent_fields.delegation_strategy == :parallel
    end

    test "handles all cognitive_style enum values" do
      cognitive_styles = ["efficient", "exploratory", "problem_solving", "creative", "systematic"]

      for style <- cognitive_styles do
        params = %{
          "task_description" => "Build app",
          "profile" => "test-profile",
          "cognitive_style" => style
        }

        assert {:ok, result} = FieldProcessor.process_form_params(params)
        assert %{agent_fields: agent_fields} = result
        assert agent_fields.cognitive_style == String.to_existing_atom(style)
      end
    end

    test "handles all output_style enum values" do
      output_styles = ["detailed", "concise", "technical", "narrative"]

      for style <- output_styles do
        params = %{
          "task_description" => "Build app",
          "profile" => "test-profile",
          "output_style" => style
        }

        assert {:ok, result} = FieldProcessor.process_form_params(params)
        assert %{agent_fields: agent_fields} = result
        assert agent_fields.output_style == String.to_existing_atom(style)
      end
    end

    test "handles all delegation_strategy enum values" do
      strategies = ["sequential", "parallel", "none"]

      for strategy <- strategies do
        params = %{
          "task_description" => "Build app",
          "profile" => "test-profile",
          "delegation_strategy" => strategy
        }

        assert {:ok, result} = FieldProcessor.process_form_params(params)
        assert %{agent_fields: agent_fields} = result
        assert agent_fields.delegation_strategy == String.to_existing_atom(strategy)
      end
    end

    # R10: Empty Constraint List
    test "omits empty global_constraints list" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "global_constraints" => ""
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      refute Map.has_key?(task_fields, :global_constraints)
    end

    test "omits whitespace-only global_constraints" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "global_constraints" => "   "
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      refute Map.has_key?(task_fields, :global_constraints)
    end

    test "handles empty array for global_constraints" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "global_constraints" => []
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      refute Map.has_key?(task_fields, :global_constraints)
    end

    # Additional edge cases
    test "handles minimal valid params" do
      params = %{
        "task_description" => "Do something",
        "profile" => "test-profile"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields, agent_fields: agent_fields} = result

      # task_fields should only have profile
      assert task_fields == %{profile: "test-profile"}

      # agent_fields should only have task_description
      assert agent_fields == %{task_description: "Do something"}
    end

    test "handles nil values as empty" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "success_criteria" => nil,
        "global_context" => nil,
        "global_constraints" => nil
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields, agent_fields: agent_fields} = result

      # Nil values should be omitted (except profile)
      assert task_fields == %{profile: "test-profile"}
      assert agent_fields == %{task_description: "Build app"}
    end

    test "ignores unexpected fields" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "unexpected_field" => "some value",
        "another_unexpected" => "another value"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{agent_fields: agent_fields, task_fields: task_fields} = result

      # Should only include known fields
      assert agent_fields == %{task_description: "Build app"}
      assert task_fields == %{profile: "test-profile"}
      refute Map.has_key?(agent_fields, :unexpected_field)
      refute Map.has_key?(agent_fields, :another_unexpected)
    end
  end

  # ===========================================================================
  # Skills Field Parsing (v3.0 - feat-20260205-root-skills)
  # ===========================================================================

  describe "skills field parsing (v3.0)" do
    # R15: Skills Extracted to task_fields
    test "extracts skills to task_fields as list" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "skills" => "deployment, code-review"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      # Skills should be in task_fields as a list
      assert task_fields.skills == ["deployment", "code-review"]
    end

    # R16: Skills Comma Parsing
    test "parses comma-separated skills into list" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "skills" => "skill-a, skill-b"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      assert task_fields.skills == ["skill-a", "skill-b"]
    end

    # R17: Skills Empty Omission
    test "omits empty skills from task_fields" do
      # First verify skills ARE extracted when provided (fails before implementation)
      params_with_skills = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "skills" => "skill-a"
      }

      assert {:ok, result_with} = FieldProcessor.process_form_params(params_with_skills)

      assert Map.has_key?(result_with.task_fields, :skills),
             "skills should be in task_fields when provided"

      # Then verify empty skills are omitted
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "skills" => ""
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      # Empty skills should be omitted
      refute Map.has_key?(task_fields, :skills)
    end

    # R18: Skills Whitespace Trimming
    test "trims whitespace from skill names" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "skills" => " skill-a , skill-b "
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      # Whitespace should be trimmed from each skill name
      assert task_fields.skills == ["skill-a", "skill-b"]
    end

    # R19: Skills Single Value
    test "single skill becomes single-element list" do
      params = %{
        "task_description" => "Build app",
        "profile" => "test-profile",
        "skills" => "single-skill"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      # Single skill without comma should become a single-element list
      assert task_fields.skills == ["single-skill"]
    end
  end
end
