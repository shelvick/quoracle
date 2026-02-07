defmodule Quoracle.Actions.SchemaWebTest do
  @moduledoc """
  Tests for fetch_web action schema updates per ACTION_Web specification.

  Verifies:
  - Removal of method/headers/body parameters
  - Addition of security_check/timeout/user_agent parameters
  - Correct parameter types and consensus rules
  """

  use ExUnit.Case, async: true
  alias Quoracle.Actions.Schema

  describe "fetch_web action updated schema" do
    test "has url as only required param" do
      {:ok, schema} = Schema.get_schema(:fetch_web)
      assert schema.required_params == [:url]
    end

    test "does NOT have method param (GET-only now)" do
      {:ok, schema} = Schema.get_schema(:fetch_web)

      # Should NOT be in optional_params
      refute :method in schema.optional_params,
             "method param should be removed (GET-only action)"

      # Should NOT be in param_types
      refute Map.has_key?(schema.param_types, :method),
             "method param_type should be removed"

      # Should NOT be in consensus_rules
      refute Map.has_key?(schema.consensus_rules, :method),
             "method consensus_rule should be removed"
    end

    test "does NOT have headers param (not needed for simple fetch)" do
      {:ok, schema} = Schema.get_schema(:fetch_web)

      refute :headers in schema.optional_params,
             "headers param should be removed"

      refute Map.has_key?(schema.param_types, :headers),
             "headers param_type should be removed"

      refute Map.has_key?(schema.consensus_rules, :headers),
             "headers consensus_rule should be removed"
    end

    test "does NOT have body param (GET requests don't have bodies)" do
      {:ok, schema} = Schema.get_schema(:fetch_web)

      refute :body in schema.optional_params,
             "body param should be removed (GET-only)"

      refute Map.has_key?(schema.param_types, :body),
             "body param_type should be removed"

      refute Map.has_key?(schema.consensus_rules, :body),
             "body consensus_rule should be removed"
    end

    test "has security_check as optional param" do
      {:ok, schema} = Schema.get_schema(:fetch_web)

      assert :security_check in schema.optional_params,
             "security_check should be in optional_params"

      assert schema.param_types.security_check == :boolean,
             "security_check should be boolean type"

      assert schema.consensus_rules.security_check == :mode_selection,
             "security_check should use mode_selection consensus"
    end

    test "has timeout as optional param" do
      {:ok, schema} = Schema.get_schema(:fetch_web)

      assert :timeout in schema.optional_params,
             "timeout should be in optional_params"

      assert schema.param_types.timeout == :number,
             "timeout should be number type (milliseconds)"

      assert schema.consensus_rules.timeout == {:percentile, 50},
             "timeout should use 50th percentile consensus"
    end

    test "has user_agent as optional param" do
      {:ok, schema} = Schema.get_schema(:fetch_web)

      assert :user_agent in schema.optional_params,
             "user_agent should be in optional_params"

      assert schema.param_types.user_agent == :string,
             "user_agent should be string type"

      assert schema.consensus_rules.user_agent == :exact_match,
             "user_agent should use exact_match consensus"
    end

    test "still has follow_redirects param (kept from original)" do
      {:ok, schema} = Schema.get_schema(:fetch_web)

      assert :follow_redirects in schema.optional_params,
             "follow_redirects should remain in optional_params"

      assert schema.param_types.follow_redirects == :boolean,
             "follow_redirects should be boolean type"

      assert schema.consensus_rules.follow_redirects == :mode_selection,
             "follow_redirects should use mode_selection consensus"
    end

    test "has exactly the correct optional params" do
      {:ok, schema} = Schema.get_schema(:fetch_web)

      # Note: auto_complete_todo is injected by Validator, not in schema definitions
      expected_optional = [
        :security_check,
        :timeout,
        :user_agent,
        :follow_redirects
      ]

      assert Enum.sort(schema.optional_params) == Enum.sort(expected_optional),
             "Expected optional params #{inspect(expected_optional)}, got #{inspect(schema.optional_params)}"
    end

    test "has url with correct type and consensus" do
      {:ok, schema} = Schema.get_schema(:fetch_web)

      assert schema.param_types.url == :string,
             "url should be string type"

      assert schema.consensus_rules.url == :exact_match,
             "url should use exact_match consensus"
    end

    test "all params have types defined" do
      {:ok, schema} = Schema.get_schema(:fetch_web)

      all_params = schema.required_params ++ schema.optional_params

      for param <- all_params do
        assert Map.has_key?(schema.param_types, param),
               "Missing param_type for #{param}"
      end
    end

    test "all params have consensus rules defined" do
      {:ok, schema} = Schema.get_schema(:fetch_web)

      all_params = schema.required_params ++ schema.optional_params

      for param <- all_params do
        assert Map.has_key?(schema.consensus_rules, param),
               "Missing consensus_rule for #{param}"
      end
    end

    test "no extra param types beyond required+optional" do
      {:ok, schema} = Schema.get_schema(:fetch_web)

      all_params = schema.required_params ++ schema.optional_params
      param_type_keys = Map.keys(schema.param_types)

      extra_types = param_type_keys -- all_params

      assert extra_types == [],
             "Found extra param_types that aren't in required/optional: #{inspect(extra_types)}"
    end

    test "no extra consensus rules beyond required+optional" do
      {:ok, schema} = Schema.get_schema(:fetch_web)

      all_params = schema.required_params ++ schema.optional_params
      consensus_keys = Map.keys(schema.consensus_rules)

      extra_rules = consensus_keys -- all_params

      assert extra_rules == [],
             "Found extra consensus_rules that aren't in required/optional: #{inspect(extra_rules)}"
    end
  end

  describe "fetch_web priority" do
    test "maintains priority 6 (read-only external)" do
      assert Schema.get_action_priority(:fetch_web) == 6
    end

    test "is less risky than call_api" do
      fetch_priority = Schema.get_action_priority(:fetch_web)
      api_priority = Schema.get_action_priority(:call_api)

      assert fetch_priority < api_priority,
             "fetch_web should be less risky than call_api"
    end

    test "is more risky than send_message" do
      fetch_priority = Schema.get_action_priority(:fetch_web)
      message_priority = Schema.get_action_priority(:send_message)

      assert fetch_priority > message_priority,
             "fetch_web should be more risky than send_message"
    end
  end
end
