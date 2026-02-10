defmodule Quoracle.Fields.PromptFieldManagerTest do
  @moduledoc """
  Tests for PromptFieldManager - the central field orchestrator.
  Tests all ARC verification criteria from the specification.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Fields.PromptFieldManager

  describe "extract_fields_from_params/1" do
    # R1: Field Extraction - Valid Params
    test "extracts and categorizes valid fields" do
      params = %{
        task_description: "Analyze the codebase",
        success_criteria: "Complete analysis with recommendations",
        immediate_context: "Working on refactoring project",
        approach_guidance: "Focus on performance bottlenecks",
        role: "Code Analyzer",
        delegation_strategy: :parallel
      }

      assert {:ok, fields} = PromptFieldManager.extract_fields_from_params(params)
      assert is_map(fields[:provided])
      assert fields[:provided][:task_description] == "Analyze the codebase"
      assert fields[:provided][:success_criteria] == "Complete analysis with recommendations"
      assert fields[:provided][:immediate_context] == "Working on refactoring project"
      assert fields[:provided][:approach_guidance] == "Focus on performance bottlenecks"
      assert fields[:provided][:role] == "Code Analyzer"
      assert fields[:provided][:delegation_strategy] == :parallel
    end

    # R2: Field Extraction - Missing Required
    test "returns error for missing required fields" do
      params = %{
        # Missing task_description and success_criteria
        immediate_context: "Some context",
        approach_guidance: "Some guidance"
      }

      assert {:error, {:missing_required_fields, missing}} =
               PromptFieldManager.extract_fields_from_params(params)

      assert :task_description in missing
      assert :success_criteria in missing
    end

    test "handles optional fields correctly" do
      params = %{
        task_description: "Task",
        success_criteria: "Success",
        immediate_context: "Context",
        approach_guidance: "Guidance"
        # No optional fields
      }

      assert {:ok, fields} = PromptFieldManager.extract_fields_from_params(params)
      assert is_map(fields[:provided])
      refute Map.has_key?(fields[:provided], :role)
      refute Map.has_key?(fields[:provided], :delegation_strategy)
    end

    test "validates field types during extraction" do
      params = %{
        task_description: "Valid task",
        success_criteria: "Valid criteria",
        immediate_context: "Valid context",
        approach_guidance: "Valid guidance",
        # Invalid enum value
        delegation_strategy: :invalid_strategy
      }

      assert {:error, _} = PromptFieldManager.extract_fields_from_params(params)
    end

    test "handles sibling_context list validation" do
      params = %{
        task_description: "Task",
        success_criteria: "Success",
        immediate_context: "Context",
        approach_guidance: "Guidance",
        sibling_context: [
          %{agent_id: "agent-123", task: "Sibling task 1"},
          %{agent_id: "agent-456", task: "Sibling task 2"}
        ]
      }

      assert {:ok, fields} = PromptFieldManager.extract_fields_from_params(params)
      assert length(fields[:provided][:sibling_context]) == 2
    end
  end

  describe "transform_for_child/3" do
    alias Quoracle.Models.TableConsensusConfig

    setup do
      # Setup database sandbox and configure summarization model
      # (needed when narrative exceeds 500 chars and triggers LLM)
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Quoracle.Repo, shared: false)

      {:ok, _} =
        TableConsensusConfig.upsert("summarization_model", %{
          "model_id" => "google-vertex:gemini-2.0-flash"
        })

      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
      :ok
    end

    # R3: Field Transformation
    test "transforms fields for child propagation" do
      parent_fields = %{
        transformed: %{
          accumulated_narrative: "Parent has been working on analysis",
          constraints: ["Be thorough", "Document findings"]
        }
      }

      provided_fields = %{
        task_description: "Analyze subsystem",
        success_criteria: "Find all issues",
        immediate_context: "Focusing on database layer",
        approach_guidance: "Check for N+1 queries",
        constraints: ["Focus on performance"]
      }

      task_id = "task-123"

      result = PromptFieldManager.transform_for_child(parent_fields, provided_fields, task_id)

      assert is_map(result[:injected])
      assert is_map(result[:provided])
      assert is_map(result[:transformed])
      assert Map.has_key?(result[:injected], :global_context)
      assert Map.has_key?(result[:injected], :constraints)
      assert is_binary(result[:transformed][:accumulated_narrative])
      assert is_list(result[:transformed][:constraints])
    end

    test "merges constraints from parent and child" do
      parent_fields = %{
        transformed: %{
          constraints: ["Parent constraint 1", "Parent constraint 2"]
        }
      }

      provided_fields = %{
        task_description: "Task",
        success_criteria: "Success",
        immediate_context: "Context",
        approach_guidance: "Guidance",
        downstream_constraints: "Child constraint 1"
      }

      task_id = "task-456"

      result = PromptFieldManager.transform_for_child(parent_fields, provided_fields, task_id)

      constraints = result[:transformed][:constraints]
      assert "Parent constraint 1" in constraints
      assert "Parent constraint 2" in constraints
      assert "Child constraint 1" in constraints
    end

    test "handles narrative summarization when exceeding limits" do
      # Create a long parent narrative
      long_narrative = String.duplicate("Previous work history. ", 30)

      parent_fields = %{
        transformed: %{
          accumulated_narrative: long_narrative
        }
      }

      provided_fields = %{
        task_description: "Task",
        success_criteria: "Success",
        immediate_context: String.duplicate("New context. ", 20),
        approach_guidance: "Guidance"
      }

      task_id = "task-789"

      # with_log suppresses expected "LLM summarization failed" warning
      # On LLM failure, original text is preserved (no truncation to avoid data loss)
      {result, _log} =
        with_log(fn ->
          PromptFieldManager.transform_for_child(parent_fields, provided_fields, task_id)
        end)

      # LLM summarization attempted; on failure, original text preserved untruncated
      assert is_binary(result[:transformed][:accumulated_narrative])
      assert String.length(result[:transformed][:accumulated_narrative]) > 0
    end

    test "handles missing parent fields gracefully" do
      # No transformed fields
      parent_fields = %{}

      provided_fields = %{
        task_description: "Task",
        success_criteria: "Success",
        immediate_context: "Context",
        approach_guidance: "Guidance"
      }

      task_id = "task-000"

      result = PromptFieldManager.transform_for_child(parent_fields, provided_fields, task_id)

      assert is_map(result)
      assert is_list(result[:transformed][:constraints])
      assert is_binary(result[:transformed][:accumulated_narrative])
    end
  end

  describe "build_prompts_from_fields/1" do
    # R4: Prompt Building - System Prompt
    test "builds system prompt with role and constraints" do
      fields = %{
        injected: %{
          global_context: "System-wide context"
        },
        provided: %{
          role: "Data Analyst",
          cognitive_style: :exploratory
        },
        transformed: %{
          constraints: ["Constraint 1", "Constraint 2", "Local constraint"]
        }
      }

      {system_prompt, _user_prompt} = PromptFieldManager.build_prompts_from_fields(fields)

      assert is_binary(system_prompt)
      assert system_prompt =~ "Data Analyst"
      assert system_prompt =~ "Constraint 1"
      assert system_prompt =~ "Constraint 2"
      assert system_prompt =~ "Local constraint"
      # Cognitive style should be included
      assert system_prompt =~ "EXPLORATORY"
    end

    # R5: Prompt Building - User Prompt
    test "builds user prompt with task and context" do
      fields = %{
        provided: %{
          task_description: "Analyze the database schema",
          success_criteria: "Document all tables and relationships",
          immediate_context: "Working on database migration",
          approach_guidance: "Focus on foreign key constraints"
        }
      }

      {_system_prompt, user_prompt} = PromptFieldManager.build_prompts_from_fields(fields)

      assert is_binary(user_prompt)
      assert user_prompt =~ "Analyze the database schema"
      assert user_prompt =~ "Document all tables and relationships"
      assert user_prompt =~ "Working on database migration"
      assert user_prompt =~ "Focus on foreign key constraints"
    end

    # R6: Constraint Rendering
    test "renders constraints from transformed field only" do
      fields = %{
        injected: %{
          global_context: "Context"
        },
        provided: %{
          role: "Primary Role"
        },
        transformed: %{
          constraints: ["First constraint", "Second constraint"]
        }
      }

      {system_prompt, _} = PromptFieldManager.build_prompts_from_fields(fields)

      # Only transformed.constraints appear in prompt
      assert system_prompt =~ "First constraint"
      assert system_prompt =~ "Second constraint"
      assert system_prompt =~ "<constraints>"
    end

    # R7: XML Tag Formatting
    test "formats prompts with XML tags" do
      fields = %{
        provided: %{
          task_description: "Task",
          success_criteria: "Success",
          immediate_context: "Context",
          approach_guidance: "Guidance",
          role: "Analyst"
        }
      }

      {system_prompt, user_prompt} = PromptFieldManager.build_prompts_from_fields(fields)

      # Check for XML tag structure
      assert system_prompt =~ ~r/<\w+>/
      assert system_prompt =~ ~r/<\/\w+>/
      assert user_prompt =~ ~r/<task>/
      assert user_prompt =~ ~r/<\/task>/
      assert user_prompt =~ ~r/<success_criteria>/
      assert user_prompt =~ ~r/<\/success_criteria>/
    end

    # R8: Empty Field Handling
    test "omits empty optional fields from prompts" do
      fields = %{
        provided: %{
          task_description: "Task",
          success_criteria: "Success",
          immediate_context: "Context",
          approach_guidance: "Guidance",
          # Empty optional field
          role: ""
        }
      }

      {system_prompt, _} = PromptFieldManager.build_prompts_from_fields(fields)

      # Empty role should not appear in prompt
      refute system_prompt =~ "<role>"
      refute system_prompt =~ "</role>"
    end

    test "includes output style when specified" do
      fields = %{
        provided: %{
          task_description: "Task",
          success_criteria: "Success",
          immediate_context: "Context",
          approach_guidance: "Guidance",
          output_style: :technical
        }
      }

      {system_prompt, _} = PromptFieldManager.build_prompts_from_fields(fields)

      assert system_prompt =~ "technical"
    end

    test "handles sibling context in prompts" do
      fields = %{
        provided: %{
          task_description: "Task",
          success_criteria: "Success",
          immediate_context: "Context",
          approach_guidance: "Guidance",
          sibling_context: [
            %{agent_id: "agent-1", task: "Parallel task 1"},
            %{agent_id: "agent-2", task: "Parallel task 2"}
          ]
        }
      }

      {_, user_prompt} = PromptFieldManager.build_prompts_from_fields(fields)

      assert user_prompt =~ "Parallel task 1"
      assert user_prompt =~ "Parallel task 2"
    end

    test "handles delegation strategy formatting" do
      fields = %{
        provided: %{
          task_description: "Task",
          success_criteria: "Success",
          immediate_context: "Context",
          approach_guidance: "Guidance",
          delegation_strategy: :sequential
        }
      }

      {system_prompt, _} = PromptFieldManager.build_prompts_from_fields(fields)

      assert system_prompt =~ "sequential"
    end
  end

  describe "integration scenarios" do
    test "complete field processing pipeline" do
      # Step 1: Extract from params
      params = %{
        task_description: "Main task",
        success_criteria: "Complete successfully",
        immediate_context: "Starting fresh",
        approach_guidance: "Be methodical",
        role: "Coordinator",
        cognitive_style: :systematic
      }

      assert {:ok, extracted} = PromptFieldManager.extract_fields_from_params(params)

      # Step 2: Transform for child
      parent_fields = %{
        transformed: %{
          accumulated_narrative: "Parent has been coordinating",
          constraints: ["Follow standards"]
        }
      }

      task_id = "task-integration"

      transformed =
        PromptFieldManager.transform_for_child(
          parent_fields,
          extracted[:provided],
          task_id
        )

      # Step 3: Build prompts
      {system_prompt, user_prompt} = PromptFieldManager.build_prompts_from_fields(transformed)

      # Verify complete pipeline
      assert is_binary(system_prompt)
      assert is_binary(user_prompt)
      assert system_prompt =~ "Coordinator"
      assert system_prompt =~ "SYSTEMATIC"
      assert user_prompt =~ "Main task"
    end

    test "handles complex nested field structures" do
      params = %{
        task_description: "Complex task",
        success_criteria: "Handle all cases",
        immediate_context: "Nested scenario",
        approach_guidance: "Consider edge cases",
        sibling_context: [
          %{agent_id: "a1", task: "Task 1"},
          %{agent_id: "a2", task: "Task 2"},
          %{agent_id: "a3", task: "Task 3"}
        ],
        constraints: ["C1", "C2", "C3"]
      }

      assert {:ok, fields} = PromptFieldManager.extract_fields_from_params(params)
      assert length(fields[:provided][:sibling_context]) == 3
      assert length(fields[:provided][:constraints]) == 3
    end
  end
end
