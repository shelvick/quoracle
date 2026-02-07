defmodule Quoracle.Actions.OrientValidationTest do
  use ExUnit.Case, async: true
  alias Quoracle.Actions.Validator

  describe "orient action validation with all optional params" do
    test "validates orient action with all required and optional parameters" do
      # This is the exact scenario reported by the user
      action_json = %{
        "action" => "orient",
        "params" => %{
          # Required params
          "current_situation" =>
            "I have been given a high-level indication that I will be working on a significant task",
          "goal_clarity" =>
            "Very low - I know the task will involve an AI-run business but have no specifics",
          "available_resources" =>
            "I have access to various actions including web fetching, shell execution",
          "key_challenges" => "Complete lack of specificity about the task requirements",
          "delegation_consideration" =>
            "Cannot assess delegation needs without knowing task specifics",
          # Optional params - these were causing the validation failure
          "approach_options" =>
            "Wait for detailed instructions, then assess whether the task requires research",
          "assumptions" =>
            "The task will be substantial and complex given the 'significant' qualifier",
          "constraints_impact" =>
            "Cannot proceed with any meaningful work until more information is provided",
          "next_steps" => "Wait for detailed task instructions and requirements from the user",
          "parallelization_opportunities" => "Cannot determine without knowing task specifics",
          "risk_factors" =>
            "Acting without sufficient information, misunderstanding requirements",
          "success_criteria" =>
            "Unknown - will need to be defined once task details are provided",
          "unknowns" => "Task scope, timeline, specific objectives, business domain"
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :orient

      # Verify all params were converted to atoms
      assert is_atom(Map.keys(validated.params) |> List.first())

      # Check specific optional params that were previously failing
      assert validated.params.approach_options ==
               "Wait for detailed instructions, then assess whether the task requires research"

      assert validated.params.assumptions ==
               "The task will be substantial and complex given the 'significant' qualifier"

      assert validated.params.constraints_impact ==
               "Cannot proceed with any meaningful work until more information is provided"

      assert validated.params.unknowns ==
               "Task scope, timeline, specific objectives, business domain"
    end

    test "validates orient with only required params" do
      action_json = %{
        "action" => "orient",
        "params" => %{
          "current_situation" => "Starting a new task",
          "goal_clarity" => "High - objectives are clear",
          "available_resources" => "Full action suite available",
          "key_challenges" => "None identified",
          "delegation_consideration" => "No delegation needed for this straightforward task"
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :orient
      assert Map.keys(validated.params) |> length() == 5
    end

    test "validates orient with mix of required and some optional params" do
      action_json = %{
        "action" => "orient",
        "params" => %{
          "current_situation" => "Mid-task assessment",
          "goal_clarity" => "Medium",
          "available_resources" => "Limited to web actions",
          "key_challenges" => "API rate limits",
          "delegation_consideration" => "May need to delegate API work if rate limits persist",
          "next_steps" => "Implement caching strategy",
          "risk_factors" => "Potential for rate limit errors"
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :orient
      assert validated.params.next_steps == "Implement caching strategy"
      assert validated.params.risk_factors == "Potential for rate limit errors"
    end

    test "fails validation when required orient param is missing" do
      action_json = %{
        "action" => "orient",
        "params" => %{
          "current_situation" => "Starting",
          "goal_clarity" => "High"
          # Missing: available_resources, key_challenges
        }
      }

      assert {:error, :missing_required_param} = Validator.validate_action(action_json)
    end

    test "fails validation with truly unknown parameter" do
      action_json = %{
        "action" => "orient",
        "params" => %{
          "current_situation" => "Starting",
          "goal_clarity" => "High",
          "available_resources" => "All",
          "key_challenges" => "None",
          "delegation_consideration" => "None needed",
          "completely_unknown_param" => "This should fail"
        }
      }

      assert {:error, :unknown_parameter} = Validator.validate_action(action_json)
    end
  end
end
