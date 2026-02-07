defmodule Quoracle.Actions.ValidatorApiCallTest do
  use ExUnit.Case, async: true
  alias Quoracle.Actions.Validator

  describe "call_api validation" do
    test "REST requires method parameter" do
      # R1: WHEN validate called IF api_type=:rest and method missing THEN returns error
      action_json = %{
        "action" => "call_api",
        "params" => %{
          "api_type" => "rest",
          "url" => "https://api.example.com/data"
          # method is missing
        }
      }

      assert {:error, :missing_required_param} = Validator.validate_action(action_json)
    end

    test "GraphQL requires query parameter" do
      # R2: WHEN validate called IF api_type=:graphql and query missing THEN returns error
      action_json = %{
        "action" => "call_api",
        "params" => %{
          "api_type" => "graphql",
          "url" => "https://api.example.com/graphql"
          # query is missing
        }
      }

      assert {:error, :missing_required_param} = Validator.validate_action(action_json)
    end

    test "JSON-RPC requires rpc_method parameter" do
      # R3: WHEN validate called IF api_type=:jsonrpc and rpc_method missing THEN returns error
      action_json = %{
        "action" => "call_api",
        "params" => %{
          "api_type" => "jsonrpc",
          "url" => "https://api.example.com/rpc"
          # rpc_method is missing
        }
      }

      assert {:error, :missing_required_param} = Validator.validate_action(action_json)
    end

    test "validates URL format and scheme" do
      # R4: WHEN validate called IF url missing or invalid scheme THEN returns error

      # Missing URL
      action_json = %{
        "action" => "call_api",
        "params" => %{
          "api_type" => "rest",
          "method" => "GET"
          # url is missing
        }
      }

      assert {:error, :missing_required_param} = Validator.validate_action(action_json)

      # Invalid URL scheme
      action_json_invalid = %{
        "action" => "call_api",
        "params" => %{
          "api_type" => "rest",
          # Invalid scheme
          "url" => "ftp://files.example.com/data",
          "method" => "GET"
        }
      }

      assert {:error, :invalid_url_scheme} = Validator.validate_action(action_json_invalid)
    end

    test "validates HTTP method enum" do
      # R5: WHEN validate called IF method not in valid methods THEN returns error
      action_json = %{
        "action" => "call_api",
        "params" => %{
          "api_type" => "rest",
          "url" => "https://api.example.com/data",
          # Invalid HTTP method
          "method" => "INVALID"
        }
      }

      assert {:error, :invalid_http_method} = Validator.validate_action(action_json)
    end

    test "validates api_type enum" do
      # R6: WHEN validate called IF api_type not in [:rest, :graphql, :jsonrpc] THEN returns error
      action_json = %{
        "action" => "call_api",
        "params" => %{
          # Invalid api_type
          "api_type" => "soap",
          "url" => "https://api.example.com/service"
        }
      }

      assert {:error, :invalid_enum_value} = Validator.validate_action(action_json)
    end

    test "validates complete REST API call" do
      # Additional test for valid REST call
      action_json = %{
        "action" => "call_api",
        "params" => %{
          "api_type" => "rest",
          "url" => "https://api.example.com/users/123",
          "method" => "GET",
          "headers" => %{"Accept" => "application/json"},
          "timeout" => 30
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :call_api
      assert validated.params.api_type == :rest
      assert validated.params.method == "GET"
      assert validated.params.url == "https://api.example.com/users/123"
    end

    test "validates complete GraphQL API call" do
      # Additional test for valid GraphQL call
      action_json = %{
        "action" => "call_api",
        "params" => %{
          "api_type" => "graphql",
          "url" => "https://api.example.com/graphql",
          "query" => "query { user(id: \"123\") { name email } }",
          "variables" => %{"id" => "123"}
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :call_api
      assert validated.params.api_type == :graphql
      assert validated.params.query == "query { user(id: \"123\") { name email } }"
    end

    test "validates complete JSON-RPC API call" do
      # Additional test for valid JSON-RPC call
      action_json = %{
        "action" => "call_api",
        "params" => %{
          "api_type" => "jsonrpc",
          "url" => "https://api.example.com/rpc",
          "rpc_method" => "getUser",
          "rpc_params" => %{"id" => 123},
          "rpc_id" => "abc123"
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :call_api
      assert validated.params.api_type == :jsonrpc
      assert validated.params.rpc_method == "getUser"
    end

    test "validates API call with authentication" do
      # Additional test for auth configuration
      action_json = %{
        "action" => "call_api",
        "params" => %{
          "api_type" => "rest",
          "url" => "https://api.example.com/protected",
          "method" => "POST",
          "body" => %{"data" => "test"},
          "auth" => %{
            "auth_type" => "bearer",
            "token" => "{{SECRET:api_token}}"
          }
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.params.auth["auth_type"] == "bearer"
      assert validated.params.auth["token"] == "{{SECRET:api_token}}"
    end

    test "normalizes HTTP method to uppercase" do
      # Additional test for method normalization
      action_json = %{
        "action" => "call_api",
        "params" => %{
          "api_type" => "rest",
          "url" => "https://api.example.com/data",
          # lowercase
          "method" => "get"
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      # Should be uppercase
      assert validated.params.method == "GET"
    end

    test "validates max_body_size is integer" do
      # Additional test for integer validation
      action_json = %{
        "action" => "call_api",
        "params" => %{
          "api_type" => "rest",
          "url" => "https://api.example.com/data",
          "method" => "POST",
          # String instead of integer
          "max_body_size" => "5000"
        }
      }

      assert {:error, :invalid_param_type} = Validator.validate_action(action_json)
    end
  end
end
