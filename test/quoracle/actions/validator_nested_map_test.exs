defmodule Quoracle.Actions.ValidatorNestedMapTest do
  @moduledoc """
  Tests for nested map type validation in Validator.
  Verifies that Validator can handle {:map, %{field: type}} specifications.
  """
  use ExUnit.Case, async: true

  alias Quoracle.Actions.Validator

  describe "validate_params with nested map structure" do
    test "validates params with correct nested structure" do
      params = %{
        items: [
          %{content: "First item", state: :todo},
          %{content: "Second item", state: :pending}
        ]
      }

      # This will fail until Validator supports {:map, %{field: type}}
      assert {:ok, validated} = Validator.validate_params(:todo, params)
      assert validated.items == params.items
    end

    test "rejects params with invalid item fields" do
      params = %{
        items: [
          # Wrong field names
          %{task: "Wrong field", status: :todo}
        ]
      }

      # Should reject due to missing required fields
      assert {:error, :missing_required_field} = Validator.validate_params(:todo, params)
    end

    test "rejects params with extra item fields" do
      params = %{
        items: [
          %{
            content: "Has extra fields",
            state: :todo,
            # Extra field
            description: "Not allowed",
            # Extra field
            priority: "high"
          }
        ]
      }

      # Should reject due to unknown fields
      assert {:error, :unknown_field} = Validator.validate_params(:todo, params)
    end

    test "validates params with string keys and values" do
      params = %{
        "items" => [
          %{"content" => "String keys test", "state" => "todo"}
        ]
      }

      assert {:ok, validated} = Validator.validate_params(:todo, params)
      assert [%{content: "String keys test", state: :todo}] = validated.items
    end

    test "enforces exact field names to prevent field invention" do
      # These are field names that should be rejected
      wrong_field_variations = [
        # Wrong content field names
        %{task: "Wrong", state: :todo},
        %{description: "Wrong", state: :todo},
        %{title: "Wrong", state: :todo},
        %{text: "Wrong", state: :todo},
        %{details: "Wrong", state: :todo},
        %{item: "Wrong", state: :todo},
        # Wrong state field names
        %{content: "Test", status: :todo},
        %{content: "Test", progress: :todo},
        %{content: "Test", phase: :todo},
        %{content: "Test", stage: :todo}
      ]

      for wrong_item <- wrong_field_variations do
        params = %{items: [wrong_item]}

        assert {:error, :missing_required_field} = Validator.validate_params(:todo, params),
               "Should reject item with fields: #{inspect(Map.keys(wrong_item))}"
      end
    end

    test "validates multiple items with different states" do
      params = %{
        items: [
          %{content: "Completed task", state: :done},
          %{content: "In progress task", state: :pending},
          %{content: "New task", state: :todo}
        ]
      }

      assert {:ok, validated} = Validator.validate_params(:todo, params)
      assert length(validated.items) == 3
    end

    test "rejects invalid state values" do
      params = %{
        items: [
          # Not a valid state
          %{content: "Invalid state", state: :cancelled}
        ]
      }

      assert {:error, :invalid_enum_value} = Validator.validate_params(:todo, params)
    end
  end

  describe "validate_action with nested structure" do
    test "validates complete action JSON" do
      action_json = %{
        "action" => "todo",
        "params" => %{
          "items" => [
            %{"content" => "Test task", "state" => "todo"}
          ]
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :todo
      assert [%{content: "Test task", state: :todo}] = validated.params.items
    end

    test "rejects action with wrong item structure" do
      action_json = %{
        "action" => "todo",
        "params" => %{
          "items" => [
            %{"task" => "Wrong field", "status" => "todo"}
          ]
        }
      }

      assert {:error, :missing_required_field} = Validator.validate_action(action_json)
    end

    test "rejects action with extra fields in items" do
      action_json = %{
        "action" => "todo",
        "params" => %{
          "items" => [
            %{
              "content" => "Test",
              "state" => "todo",
              # Extra field
              "priority" => "high"
            }
          ]
        }
      }

      assert {:error, :unknown_field} = Validator.validate_action(action_json)
    end
  end

  describe "field name enforcement" do
    test "prevents alternative content field names" do
      alternative_names = ["task", "description", "title", "text", "details", "item"]

      for field_name <- alternative_names do
        action_json = %{
          "action" => "todo",
          "params" => %{
            "items" => [
              %{field_name => "Test content", "state" => "todo"}
            ]
          }
        }

        assert {:error, :missing_required_field} = Validator.validate_action(action_json),
               "Should reject field name: #{field_name}"
      end
    end

    test "prevents alternative state field names" do
      alternative_names = ["status", "progress", "phase", "stage", "step"]

      for field_name <- alternative_names do
        action_json = %{
          "action" => "todo",
          "params" => %{
            "items" => [
              %{"content" => "Test", field_name => "todo"}
            ]
          }
        }

        assert {:error, :missing_required_field} = Validator.validate_action(action_json),
               "Should reject field name: #{field_name}"
      end
    end

    test "only accepts exact schema structure" do
      # Only this exact structure should pass
      valid_action = %{
        "action" => "todo",
        "params" => %{
          "items" => [
            %{"content" => "First task", "state" => "todo"},
            %{"content" => "Second task", "state" => "pending"}
          ]
        }
      }

      assert {:ok, validated} = Validator.validate_action(valid_action)
      assert length(validated.params.items) == 2

      # Verify no extra fields allowed
      for item <- validated.params.items do
        assert Map.keys(item) -- [:content, :state] == []
      end
    end
  end
end
