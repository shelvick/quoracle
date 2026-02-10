defmodule Quoracle.Actions.SchemaApiCallTest do
  use ExUnit.Case, async: true
  alias Quoracle.Actions.Schema

  describe "call_api schema" do
    test "lists call_api in available actions" do
      # R1: WHEN list_actions called THEN includes :call_api in action list
      actions = Schema.list_actions()
      assert :call_api in actions
      assert length(actions) == 22
    end

    test "retrieves call_api schema" do
      # R2: WHEN get_schema(:call_api) called THEN returns call_api schema
      assert {:ok, schema} = Schema.get_schema(:call_api)
      assert Map.has_key?(schema, :required_params)
      assert Map.has_key?(schema, :optional_params)
      assert Map.has_key?(schema, :param_types)
      assert Map.has_key?(schema, :consensus_rules)
      assert Map.has_key?(schema, :param_descriptions)
    end

    test "call_api has correct required parameters" do
      # R3: WHEN schema accessed THEN api_type and url are required
      assert {:ok, schema} = Schema.get_schema(:call_api)
      assert :api_type in schema.required_params
      assert :url in schema.required_params
      assert length(schema.required_params) == 2
    end

    test "call_api api_type is enum" do
      # R4: WHEN schema accessed THEN api_type is enum type
      assert {:ok, schema} = Schema.get_schema(:call_api)
      assert schema.param_types[:api_type] == {:enum, [:rest, :graphql, :jsonrpc]}
    end

    test "provides call_api action description" do
      # R5: WHEN get_action_description(:call_api) called THEN returns WHEN/HOW guidance
      description = Schema.get_action_description(:call_api)
      assert description =~ "WHEN:"
      assert description =~ "HOW:"
      assert description =~ "REST"
      assert description =~ "GraphQL"
      assert description =~ "JSON-RPC"
    end

    test "call_api has priority 17" do
      # R6: WHEN get_action_priority(:call_api) called THEN returns 17
      priority = Schema.get_action_priority(:call_api)
      assert priority == 17
    end

    test "call_api has correct optional parameters" do
      # Additional coverage for optional params
      assert {:ok, schema} = Schema.get_schema(:call_api)

      # REST-specific
      assert :method in schema.optional_params
      assert :query_params in schema.optional_params
      assert :body in schema.optional_params

      # GraphQL-specific
      assert :query in schema.optional_params
      assert :variables in schema.optional_params

      # JSON-RPC-specific
      assert :rpc_method in schema.optional_params
      assert :rpc_params in schema.optional_params
      assert :rpc_id in schema.optional_params

      # Common
      assert :timeout in schema.optional_params
      assert :headers in schema.optional_params
      assert :auth in schema.optional_params
      assert :max_body_size in schema.optional_params
    end

    test "call_api has correct parameter types" do
      # Additional coverage for parameter types
      assert {:ok, schema} = Schema.get_schema(:call_api)

      assert schema.param_types[:url] == :string
      assert schema.param_types[:method] == :string
      assert schema.param_types[:timeout] == :integer
      assert schema.param_types[:headers] == :map
      assert schema.param_types[:auth] == :map
      assert schema.param_types[:max_body_size] == :integer
      assert schema.param_types[:query_params] == :map
      assert schema.param_types[:body] == :any
      assert schema.param_types[:query] == :string
      assert schema.param_types[:variables] == :map
      assert schema.param_types[:rpc_method] == :string
      assert schema.param_types[:rpc_params] == :any
      assert schema.param_types[:rpc_id] == :string
    end

    test "call_api has correct consensus rules" do
      # Additional coverage for consensus rules
      assert {:ok, schema} = Schema.get_schema(:call_api)

      assert schema.consensus_rules[:api_type] == :exact_match
      assert schema.consensus_rules[:url] == :exact_match
      assert schema.consensus_rules[:method] == :exact_match
      assert schema.consensus_rules[:timeout] == {:percentile, 100}
      assert schema.consensus_rules[:auth] == :exact_match
    end

    test "call_api has parameter descriptions" do
      # Additional coverage for param descriptions
      assert {:ok, schema} = Schema.get_schema(:call_api)

      assert schema.param_descriptions[:api_type] =~ "Protocol type"
      assert schema.param_descriptions[:url] =~ "Target API endpoint"
      assert schema.param_descriptions[:timeout] =~ "Request timeout"
      assert schema.param_descriptions[:method] =~ "HTTP method"
      assert schema.param_descriptions[:query] =~ "GraphQL"
      assert schema.param_descriptions[:rpc_method] =~ "JSON-RPC"
    end
  end
end
