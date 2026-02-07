defmodule Quoracle.Actions.SchemaApiIntegrationTest do
  @moduledoc """
  Integration tests for Schema system support of call_api action.
  Tests schema retrieval, validation, and parameter checking.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Actions.Schema
  alias Quoracle.Actions.Validator

  describe "Schema.get_schema for call_api [UNIT]" do
    test "returns schema for call_api action" do
      assert {:ok, schema} = Schema.get_schema(:call_api)

      # Check required params
      assert :api_type in schema.required_params
      assert :url in schema.required_params

      # Check optional params
      assert :method in schema.optional_params
      assert :query_params in schema.optional_params
      assert :body in schema.optional_params
      assert :headers in schema.optional_params
      assert :auth in schema.optional_params

      # GraphQL-specific
      assert :query in schema.optional_params
      assert :variables in schema.optional_params

      # JSON-RPC-specific
      assert :rpc_method in schema.optional_params
      assert :rpc_params in schema.optional_params

      # Check param types
      assert schema.param_types.api_type == {:enum, [:rest, :graphql, :jsonrpc]}
      assert schema.param_types.url == :string
      assert schema.param_types.method == :string
      assert schema.param_types.headers == :map
      assert schema.param_types.body == :any
      assert schema.param_types.auth == :map
    end

    test "includes param descriptions for call_api" do
      {:ok, schema} = Schema.get_schema(:call_api)

      assert is_binary(schema.param_descriptions.api_type)
      assert String.contains?(schema.param_descriptions.api_type, "rest")
      assert String.contains?(schema.param_descriptions.api_type, "graphql")
      assert String.contains?(schema.param_descriptions.api_type, "jsonrpc")

      assert is_binary(schema.param_descriptions.url)
      assert is_binary(schema.param_descriptions.method)
      assert is_binary(schema.param_descriptions.query)
      assert is_binary(schema.param_descriptions.rpc_method)
    end

    test "includes consensus rules for call_api" do
      {:ok, schema} = Schema.get_schema(:call_api)

      assert schema.consensus_rules.api_type == :exact_match
      assert schema.consensus_rules.url == :exact_match
      assert schema.consensus_rules.method == :exact_match
      assert schema.consensus_rules.timeout == {:percentile, 100}
      assert schema.consensus_rules.auth == :exact_match
    end
  end

  describe "Schema.list_actions includes call_api [UNIT]" do
    test "call_api is in the list of available actions" do
      actions = Schema.list_actions()
      assert :call_api in actions
    end
  end

  describe "Schema.validate_action_type for call_api [UNIT]" do
    test "validates call_api as a valid action type" do
      assert {:ok, :call_api} = Schema.validate_action_type(:call_api)
    end

    test "accepts call_api as atom" do
      assert {:ok, :call_api} = Schema.validate_action_type(:call_api)
    end
  end

  describe "Schema.get_action_description for call_api [UNIT]" do
    test "returns description for call_api" do
      description = Schema.get_action_description(:call_api)
      assert is_binary(description)
      assert description =~ ~r/api/i
    end
  end

  describe "Schema.get_action_priority for call_api [UNIT]" do
    test "returns priority for call_api" do
      priority = Schema.get_action_priority(:call_api)
      assert is_integer(priority)
      assert priority >= 1
      assert priority <= 22
    end
  end

  describe "Validator validates call_api parameters [INTEGRATION]" do
    test "validates REST call_api with all required params" do
      params = %{
        api_type: "rest",
        url: "https://api.example.com/data",
        method: "GET"
      }

      assert {:ok, validated} = Validator.validate_params(:call_api, params)
      assert validated.api_type == :rest
      assert validated.url == "https://api.example.com/data"
      assert validated.method == "GET"
    end

    test "validates GraphQL call_api with query" do
      params = %{
        api_type: "graphql",
        url: "https://api.github.com/graphql",
        query: "{ viewer { login } }",
        variables: %{first: 10}
      }

      assert {:ok, validated} = Validator.validate_params(:call_api, params)
      assert validated.api_type == :graphql
      assert validated.query == "{ viewer { login } }"
      assert validated.variables == %{first: 10}
    end

    test "validates JSON-RPC call_api with method and params" do
      params = %{
        api_type: "jsonrpc",
        url: "https://mainnet.infura.io/v3/key",
        rpc_method: "eth_getBalance",
        rpc_params: ["0x0000000000000000000000000000000000000000", "latest"]
      }

      assert {:ok, validated} = Validator.validate_params(:call_api, params)
      assert validated.api_type == :jsonrpc
      assert validated.rpc_method == "eth_getBalance"
      assert validated.rpc_params == ["0x0000000000000000000000000000000000000000", "latest"]
    end

    test "rejects call_api with missing required params" do
      # Missing url
      params = %{
        api_type: "rest",
        method: "GET"
      }

      assert {:error, errors} = Validator.validate_params(:call_api, params)
      assert errors == :missing_required_param
    end

    test "rejects call_api with invalid api_type" do
      params = %{
        api_type: "invalid",
        url: "https://api.example.com"
      }

      assert {:error, errors} = Validator.validate_params(:call_api, params)
      assert errors == :invalid_enum_value
    end

    test "rejects call_api with invalid method for REST" do
      params = %{
        api_type: "rest",
        url: "https://api.example.com",
        method: "INVALID"
      }

      assert {:error, errors} = Validator.validate_params(:call_api, params)

      assert errors == :invalid_http_method
    end

    test "validates authentication parameters" do
      # Bearer auth
      bearer_params = %{
        api_type: "rest",
        url: "https://api.example.com",
        method: "GET",
        auth: %{
          type: "bearer",
          token: "test-token"
        }
      }

      assert {:ok, validated} = Validator.validate_params(:call_api, bearer_params)
      assert validated.auth.type == "bearer"
      assert validated.auth.token == "test-token"

      # Basic auth
      basic_params = %{
        api_type: "rest",
        url: "https://api.example.com",
        method: "GET",
        auth: %{
          type: "basic",
          username: "user",
          password: "pass"
        }
      }

      assert {:ok, validated} = Validator.validate_params(:call_api, basic_params)
      assert validated.auth.type == "basic"
      assert validated.auth.username == "user"
    end

    test "validates headers as map" do
      params = %{
        api_type: "rest",
        url: "https://api.example.com",
        method: "POST",
        headers: %{
          "Content-Type" => "application/json",
          "X-API-Key" => "key123"
        }
      }

      assert {:ok, validated} = Validator.validate_params(:call_api, params)
      assert validated.headers["Content-Type"] == "application/json"
      assert validated.headers["X-API-Key"] == "key123"
    end

    test "rejects headers that are not a map" do
      params = %{
        api_type: "rest",
        url: "https://api.example.com",
        method: "GET",
        headers: "invalid"
      }

      assert {:error, errors} = Validator.validate_params(:call_api, params)
      assert errors == :invalid_param_type
    end

    test "validates timeout as number" do
      params = %{
        api_type: "rest",
        url: "https://api.example.com",
        method: "GET",
        timeout: 30
      }

      assert {:ok, validated} = Validator.validate_params(:call_api, params)
      assert validated.timeout == 30
    end
  end

  describe "Protocol-specific validation [INTEGRATION]" do
    test "REST requires method parameter" do
      params = %{
        api_type: "rest",
        url: "https://api.example.com",
        body: %{"data" => "test"}
      }

      # Method is required for REST
      assert {:error, :missing_required_param} = Validator.validate_params(:call_api, params)
    end

    test "GraphQL requires query parameter" do
      params = %{
        api_type: "graphql",
        url: "https://api.github.com/graphql"
        # Missing query
      }

      assert {:error, :missing_required_param} = Validator.validate_params(:call_api, params)
    end

    test "JSON-RPC requires rpc_method" do
      params = %{
        api_type: "jsonrpc",
        url: "https://mainnet.infura.io/v3/key"
        # Missing rpc_method
      }

      assert {:error, :missing_required_param} = Validator.validate_params(:call_api, params)
    end

    test "validates complex nested auth structures" do
      params = %{
        api_type: "rest",
        url: "https://api.example.com",
        method: "GET",
        auth: %{
          type: "oauth2",
          client_id: "client123",
          client_secret: "secret456",
          token_url: "https://oauth.example.com/token",
          scope: "read write"
        }
      }

      assert {:ok, validated} = Validator.validate_params(:call_api, params)
      assert validated.auth.type == "oauth2"
      assert validated.auth.client_id == "client123"
      assert validated.auth.token_url == "https://oauth.example.com/token"
    end
  end
end
