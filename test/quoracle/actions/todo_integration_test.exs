defmodule Quoracle.Actions.TodoIntegrationTest do
  @moduledoc """
  Integration tests for TODO action validation and execution.
  Verifies data flow through ActionParser, Validator, and Router.
  """
  use ExUnit.Case, async: true

  alias Quoracle.Actions.Validator
  alias Quoracle.Consensus.ActionParser

  describe "ActionParser to Validator integration" do
    test "parses and validates correct TODO action from LLM" do
      # Simulate LLM response with TODO action
      # Note: wait is at response level, NOT in params
      llm_response = """
      {
        "action": "todo",
        "params": {
          "items": [
            {"content": "Analyze user requirements", "state": "done"},
            {"content": "Design system architecture", "state": "pending"},
            {"content": "Implement core features", "state": "todo"}
          ]
        },
        "wait": false,
        "reasoning": "Updating task list with current progress"
      }
      """

      # Parse the LLM response
      assert {:ok, action_response} = ActionParser.parse_json_response(llm_response)
      assert action_response.action == :todo
      assert action_response.wait == false

      # Validate the action (this should work with nested map validation)
      assert {:ok, validated} =
               Validator.validate_action(%{
                 "action" => "todo",
                 "params" => action_response.params
               })

      assert validated.action == :todo
      assert length(validated.params.items) == 3
    end

    test "rejects TODO action with invalid field names" do
      # LLM tries to use "task" instead of "content"
      llm_response = """
      {
        "action": "todo",
        "params": {
          "items": [
            {"task": "Wrong field name", "state": "todo"}
          ]
        },
        "wait": false,
        "reasoning": "This should fail validation"
      }
      """

      assert {:ok, action_response} = ActionParser.parse_json_response(llm_response)

      # Validation should fail due to wrong field name
      assert {:error, :missing_required_field} =
               Validator.validate_action(%{
                 "action" => "todo",
                 "params" => action_response.params
               })
    end

    test "rejects todo action with extra fields" do
      # LLM adds extra fields not in schema
      llm_response = """
      {
        "action": "todo",
        "params": {
          "items": [
            {
              "content": "Valid content",
              "state": "todo",
              "priority": "high",
              "description": "Extra details that shouldn't be here"
            }
          ]
        },
        "wait": false,
        "reasoning": "Added extra fields"
      }
      """

      assert {:ok, action_response} = ActionParser.parse_json_response(llm_response)

      # Validation should fail due to extra fields
      assert {:error, :unknown_field} =
               Validator.validate_action(%{
                 "action" => "todo",
                 "params" => action_response.params
               })
    end
  end

  describe "field name enforcement" do
    test "prevents LLM from using alternative field names" do
      # All these variations should be rejected
      invalid_variations = [
        # Wrong content field names
        %{"items" => [%{"task" => "Test", "state" => "todo"}]},
        %{"items" => [%{"description" => "Test", "state" => "todo"}]},
        %{"items" => [%{"title" => "Test", "state" => "todo"}]},
        %{"items" => [%{"text" => "Test", "state" => "todo"}]},
        %{"items" => [%{"item" => "Test", "state" => "todo"}]},
        %{"items" => [%{"details" => "Test", "state" => "todo"}]},
        # Wrong state field names
        %{"items" => [%{"content" => "Test", "status" => "todo"}]},
        %{"items" => [%{"content" => "Test", "progress" => "todo"}]},
        %{"items" => [%{"content" => "Test", "phase" => "todo"}]},
        %{"items" => [%{"content" => "Test", "stage" => "todo"}]}
      ]

      for invalid_params <- invalid_variations do
        action_json = %{
          "action" => "todo",
          "params" => invalid_params
        }

        assert {:error, :missing_required_field} = Validator.validate_action(action_json),
               "Should reject params: #{inspect(invalid_params)}"
      end
    end

    test "accepts only the exact schema structure" do
      # Only this exact structure should pass
      valid_params = %{
        "items" => [
          %{"content" => "First task", "state" => "todo"},
          %{"content" => "Second task", "state" => "pending"},
          %{"content" => "Third task", "state" => "done"}
        ]
      }

      action_json = %{
        "action" => "todo",
        "params" => valid_params
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert length(validated.params.items) == 3

      assert Enum.all?(validated.params.items, fn item ->
               Map.keys(item) -- [:content, :state] == []
             end)
    end
  end

  describe "LLM response validation" do
    test "validates realistic LLM response format" do
      # Actual format an LLM would generate
      # Note: wait is at response level, NOT in params
      llm_json = """
      {
        "action": "todo",
        "params": {
          "items": [
            {
              "content": "Research competitive landscape",
              "state": "done"
            },
            {
              "content": "Create project roadmap",
              "state": "pending"
            },
            {
              "content": "Build MVP features",
              "state": "todo"
            }
          ]
        },
        "wait": false,
        "reasoning": "Breaking down project into manageable tasks"
      }
      """

      # Should parse successfully
      assert {:ok, parsed} = ActionParser.parse_json_response(llm_json)
      assert parsed.action == :todo
      assert parsed.wait == false
      assert length(parsed.params["items"]) == 3

      # Should validate successfully with nested map support
      action_json = %{
        "action" => Atom.to_string(parsed.action),
        "params" => parsed.params
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :todo
      assert length(validated.params.items) == 3
    end

    test "rejects malformed LLM responses" do
      # Missing required fields
      bad_response = """
      {
        "action": "todo",
        "params": {
          "items": [
            {"something": "wrong"}
          ]
        },
        "wait": false,
        "reasoning": "Test malformed response"
      }
      """

      # Should parse successfully
      assert {:ok, parsed} = ActionParser.parse_json_response(bad_response)

      # Validation should fail due to missing required fields in items
      action_json = %{
        "action" => Atom.to_string(parsed.action),
        "params" => parsed.params
      }

      assert {:error, :missing_required_field} = Validator.validate_action(action_json)
    end
  end

  describe "state value validation" do
    test "accepts valid state values" do
      valid_states = ["todo", "pending", "done"]

      for state <- valid_states do
        action_json = %{
          "action" => "todo",
          "params" => %{
            "items" => [
              %{"content" => "Test", "state" => state}
            ]
          }
        }

        assert {:ok, validated} = Validator.validate_action(action_json)
        assert [item] = validated.params.items
        assert item.state == String.to_existing_atom(state)
      end
    end

    test "rejects invalid state values" do
      invalid_states = ["complete", "in_progress", "cancelled", "blocked", "ready"]

      for state <- invalid_states do
        action_json = %{
          "action" => "todo",
          "params" => %{
            "items" => [
              %{"content" => "Test", "state" => state}
            ]
          }
        }

        assert {:error, :invalid_enum_value} = Validator.validate_action(action_json),
               "Should reject state: #{state}"
      end
    end
  end
end
