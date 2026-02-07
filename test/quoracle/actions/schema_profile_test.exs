defmodule Quoracle.Actions.SchemaProfileTest do
  @moduledoc """
  Tests for ACTION_Schema v26.0 - Profile parameter for spawn_child.

  ARC Requirements (v26.0):
  - R7: spawn_child schema includes profile parameter
  - R8: profile parameter is required
  - R9: profile has string type
  - R10: profile has description
  - R11: Validator rejects spawn_child without profile
  """

  use ExUnit.Case, async: true

  alias Quoracle.Actions.Schema
  alias Quoracle.Actions.Validator

  describe "spawn_child profile parameter" do
    # R7: Profile in spawn_child Schema
    test "spawn_child schema includes profile parameter" do
      {:ok, schema} = Schema.get_schema(:spawn_child)

      # Profile must be in required_params (per R8: profile is required)
      assert :profile in schema.required_params
    end

    # R8: Profile Required
    test "spawn_child profile parameter is required" do
      {:ok, schema} = Schema.get_schema(:spawn_child)

      # Check various ways it might be marked required
      required =
        cond do
          Map.has_key?(schema, :required_params) ->
            :profile in schema.required_params

          Map.has_key?(schema, :parameters) ->
            param = Map.get(schema.parameters, :profile, %{})
            Map.get(param, :required, false)

          true ->
            false
        end

      assert required, "profile parameter should be required"
    end

    # R9: Profile Type String
    test "spawn_child profile has string type" do
      {:ok, schema} = Schema.get_schema(:spawn_child)

      param_type =
        cond do
          Map.has_key?(schema, :param_types) ->
            Map.get(schema.param_types, :profile)

          Map.has_key?(schema, :parameters) ->
            param = Map.get(schema.parameters, :profile, %{})
            Map.get(param, :type)

          true ->
            nil
        end

      assert param_type == :string, "profile type should be :string, got: #{inspect(param_type)}"
    end

    # R10: Profile Description
    test "spawn_child profile has description" do
      {:ok, schema} = Schema.get_schema(:spawn_child)

      has_description =
        cond do
          Map.has_key?(schema, :param_descriptions) ->
            desc = Map.get(schema.param_descriptions, :profile)
            is_binary(desc) and byte_size(desc) > 0

          Map.has_key?(schema, :parameters) ->
            param = Map.get(schema.parameters, :profile, %{})
            desc = Map.get(param, :description)
            is_binary(desc) and byte_size(desc) > 0

          true ->
            false
        end

      assert has_description, "profile parameter should have a description"
    end
  end

  describe "validator profile enforcement" do
    # R11: Validator Rejects Missing Profile
    test "validator rejects spawn_child without profile" do
      # spawn_child with all required params except profile
      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test context",
        "approach_guidance" => "Standard approach"
        # No profile param
      }

      result = Validator.validate_params(:spawn_child, params)

      # Must return error tuple for missing required param
      assert {:error, :missing_required_param} = result
    end

    test "validator accepts spawn_child with profile" do
      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test context",
        "approach_guidance" => "Standard approach",
        "profile" => "some-profile"
      }

      result = Validator.validate_params(:spawn_child, params)

      # Should pass validation (profile existence is checked at execution time)
      assert {:ok, _validated} = result
    end

    test "validator validates profile is string" do
      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test context",
        "approach_guidance" => "Standard approach",
        "profile" => 123
      }

      result = Validator.validate_params(:spawn_child, params)

      # Should fail - profile must be string
      assert {:error, _reason} = result
    end
  end
end
