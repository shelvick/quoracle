defmodule Quoracle.Tasks.FieldProcessorProfileTest do
  @moduledoc """
  Tests for TASK_FieldProcessor v2.0 - Profile field extraction.

  ARC Requirements (feat-20260105-profiles):
  - R11: Profile extracted to task_fields [UNIT]
  - R12: Profile required validation [UNIT]
  - R13: Profile preserved exactly [UNIT]
  - R14: Validates task_description before profile [UNIT]
  """

  use ExUnit.Case, async: true

  alias Quoracle.Tasks.FieldProcessor

  describe "profile field extraction (R11-R14)" do
    # R11: Profile Extracted to task_fields
    test "R11: profile extracted to task_fields" do
      params = %{
        "task_description" => "Build app",
        "profile" => "my-research-profile"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      # Profile should be in task_fields, not agent_fields
      assert task_fields.profile == "my-research-profile"
      refute Map.has_key?(result.agent_fields, :profile)
    end

    # R12: Profile Required Validation
    test "R12: returns error when profile is missing" do
      params = %{
        "task_description" => "Build app"
        # No profile
      }

      assert {:error, {:missing_required, fields}} =
               FieldProcessor.process_form_params(params)

      assert :profile in fields
    end

    test "R12: returns error when profile is empty string" do
      params = %{
        "task_description" => "Build app",
        "profile" => ""
      }

      assert {:error, {:missing_required, fields}} =
               FieldProcessor.process_form_params(params)

      assert :profile in fields
    end

    test "R12: returns error when profile is whitespace only" do
      params = %{
        "task_description" => "Build app",
        "profile" => "   "
      }

      assert {:error, {:missing_required, fields}} =
               FieldProcessor.process_form_params(params)

      assert :profile in fields
    end

    # R13: Profile Preserved Exactly
    test "R13: profile name preserved exactly (no transformation)" do
      params = %{
        "task_description" => "Build app",
        "profile" => "My-Custom_Profile123"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert result.task_fields.profile == "My-Custom_Profile123"
    end

    test "R13: profile whitespace trimmed but value preserved" do
      params = %{
        "task_description" => "Build app",
        "profile" => "  my-profile  "
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert result.task_fields.profile == "my-profile"
    end

    # R14: Validates task_description Before Profile
    test "R14: task_description missing reported before profile" do
      params = %{
        # Missing task_description
        "profile" => "my-profile"
      }

      assert {:error, {:missing_required, fields}} =
               FieldProcessor.process_form_params(params)

      # task_description should be in the error, not profile
      assert :task_description in fields
    end

    test "R14: both missing reports task_description first" do
      params = %{}

      assert {:error, {:missing_required, fields}} =
               FieldProcessor.process_form_params(params)

      # task_description validation happens before profile
      assert :task_description in fields
    end
  end

  describe "profile with other fields" do
    test "profile works with all other task fields" do
      params = %{
        "task_description" => "Build app",
        "profile" => "my-profile",
        "global_context" => "Project context",
        "global_constraints" => "Use Elixir, Follow TDD"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert %{task_fields: task_fields} = result

      assert task_fields.profile == "my-profile"
      assert task_fields.global_context == "Project context"
      assert task_fields.global_constraints == ["Use Elixir", "Follow TDD"]
    end

    test "profile works with budget_limit" do
      params = %{
        "task_description" => "Build app",
        "profile" => "my-profile",
        "budget_limit" => "10.50"
      }

      assert {:ok, result} = FieldProcessor.process_form_params(params)
      assert result.task_fields.profile == "my-profile"
      assert result.task_fields.budget_limit == Decimal.new("10.50")
    end
  end
end
