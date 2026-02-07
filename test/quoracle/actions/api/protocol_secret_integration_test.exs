defmodule Quoracle.Actions.API.ProtocolSecretIntegrationTest do
  @moduledoc """
  Integration tests for GraphQL and JSON-RPC protocol adapters with secret resolution.
  Tests that secret templates in GraphQL/JSON-RPC requests are properly resolved.
  """

  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Actions.API.GraphQLAdapter
  alias Quoracle.Actions.API.JSONRPCAdapter
  alias Quoracle.Models.TableSecrets
  alias Quoracle.Security.SecretResolver

  describe "GraphQL with secret templates [INTEGRATION]" do
    setup do
      # Create test secrets
      {:ok, _} = TableSecrets.create(%{name: "graphql_token", value: "actual-gql-token"})
      {:ok, _} = TableSecrets.create(%{name: "user_id", value: "user-12345"})
      :ok
    end

    test "resolves templates in GraphQL query variables" do
      params = %{
        query: "query GetUser($id: ID!, $token: String!) {
          user(id: $id, token: $token) {
            name
            email
          }
        }",
        variables: %{
          "id" => "{{SECRET:user_id}}",
          "token" => "{{SECRET:graphql_token}}"
        }
      }

      # Resolve secrets first
      {:ok, resolved, used} = SecretResolver.resolve_params(params)

      # Then format for GraphQL
      {:ok, request} = GraphQLAdapter.format_request("https://api.example.com/graphql", resolved)

      assert request.body["variables"]["id"] == "user-12345"
      assert request.body["variables"]["token"] == "actual-gql-token"

      assert used == %{
               "user_id" => "user-12345",
               "graphql_token" => "actual-gql-token"
             }
    end

    test "resolves templates in GraphQL with auth" do
      params = %{
        query: "mutation CreatePost($title: String!) { createPost(title: $title) { id } }",
        variables: %{"title" => "My Post"},
        auth_type: "bearer",
        auth_token: "{{SECRET:graphql_token}}"
      }

      # Should resolve auth token template
      {:ok, resolved, _} = SecretResolver.resolve_params(params)

      assert resolved[:auth_token] == "actual-gql-token"

      # Format request with resolved auth
      {:ok, request} =
        GraphQLAdapter.format_request_with_auth("https://api.example.com/graphql", resolved)

      # Should have auth applied
      assert request.auth_params[:auth_token] == "actual-gql-token"
    end

    test "handles missing secrets in GraphQL variables with pass-through" do
      params = %{
        query: "query { user(id: $id) { name } }",
        variables: %{
          "id" => "{{SECRET:nonexistent}}"
        }
      }

      # Missing secrets kept as literals (capture expected warning)
      capture_log(fn ->
        {:ok, resolved, used} = SecretResolver.resolve_params(params)
        assert resolved.variables["id"] == "{{SECRET:nonexistent}}"
        assert used == %{}
      end)
    end

    test "resolves nested templates in GraphQL complex variables" do
      {:ok, _} = TableSecrets.create(%{name: "api_key", value: "key-789"})

      params = %{
        query:
          "mutation UpdateConfig($config: ConfigInput!) { updateConfig(config: $config) { success } }",
        variables: %{
          "config" => %{
            "apiKey" => "{{SECRET:api_key}}",
            "nested" => %{
              "token" => "{{SECRET:graphql_token}}"
            },
            "list" => ["item1", "{{SECRET:user_id}}", "item3"]
          }
        }
      }

      {:ok, resolved, _} = SecretResolver.resolve_params(params)

      assert resolved.variables["config"]["apiKey"] == "key-789"
      assert resolved.variables["config"]["nested"]["token"] == "actual-gql-token"
      assert resolved.variables["config"]["list"] == ["item1", "user-12345", "item3"]
    end

    test "preserves non-template values in GraphQL" do
      params = %{
        query: "query { users { id name } }",
        variables: %{
          "normal" => "value",
          "secret" => "{{SECRET:graphql_token}}",
          "number" => 42
        },
        operation_name: "GetUsers"
      }

      {:ok, resolved, _} = SecretResolver.resolve_params(params)

      assert resolved.variables["normal"] == "value"
      assert resolved.variables["secret"] == "actual-gql-token"
      assert resolved.variables["number"] == 42
      assert resolved.operation_name == "GetUsers"
    end
  end

  describe "JSON-RPC with secret templates [INTEGRATION]" do
    setup do
      {:ok, _} = TableSecrets.create(%{name: "rpc_token", value: "actual-rpc-token"})
      {:ok, _} = TableSecrets.create(%{name: "api_key", value: "actual-api-key"})
      :ok
    end

    test "resolves templates in JSON-RPC params" do
      params = %{
        method: "eth_sendTransaction",
        params: %{
          "from" => "0x123",
          "to" => "0x456",
          "apiKey" => "{{SECRET:api_key}}"
        }
      }

      {:ok, resolved, used} = SecretResolver.resolve_params(params)

      {:ok, request} = JSONRPCAdapter.format_request("https://rpc.example.com", resolved)

      assert request.body["params"]["apiKey"] == "actual-api-key"
      assert request.body["method"] == "eth_sendTransaction"
      assert used == %{"api_key" => "actual-api-key"}
    end

    test "resolves templates in JSON-RPC array params" do
      params = %{
        method: "eth_call",
        params: [
          "{{SECRET:api_key}}",
          %{"data" => "0xabcd", "token" => "{{SECRET:rpc_token}}"},
          "latest"
        ]
      }

      {:ok, resolved, _} = SecretResolver.resolve_params(params)

      {:ok, request} = JSONRPCAdapter.format_request("https://rpc.example.com", resolved)

      assert request.body["params"] == [
               "actual-api-key",
               %{"data" => "0xabcd", "token" => "actual-rpc-token"},
               "latest"
             ]
    end

    test "resolves templates in JSON-RPC with auth" do
      params = %{
        method: "getBalance",
        params: ["0xabc"],
        auth_type: "bearer",
        auth_token: "{{SECRET:rpc_token}}"
      }

      {:ok, resolved, _} = SecretResolver.resolve_params(params)

      assert resolved[:auth_token] == "actual-rpc-token"

      {:ok, request} =
        JSONRPCAdapter.format_request_with_auth("https://rpc.example.com", resolved)

      # Should pass auth through
      assert request.auth_params[:auth_token] == "actual-rpc-token"
    end

    test "handles missing secrets in JSON-RPC params with pass-through" do
      params = %{
        method: "sendData",
        params: %{
          "key" => "{{SECRET:missing_key}}"
        }
      }

      # Missing secrets kept as literals (capture expected warning)
      capture_log(fn ->
        {:ok, resolved, used} = SecretResolver.resolve_params(params)
        assert resolved.params["key"] == "{{SECRET:missing_key}}"
        assert used == %{}
      end)
    end

    test "preserves JSON-RPC protocol fields while resolving secrets" do
      params = %{
        method: "processData",
        params: %{"token" => "{{SECRET:api_key}}"},
        id: "custom-id-123"
      }

      {:ok, resolved, _} = SecretResolver.resolve_params(params)

      {:ok, request} = JSONRPCAdapter.format_request("https://rpc.example.com", resolved)

      # Protocol fields preserved
      assert request.body["jsonrpc"] == "2.0"
      assert request.body["method"] == "processData"
      assert request.body["id"] == "custom-id-123"

      # Secret resolved
      assert request.body["params"]["token"] == "actual-api-key"
    end

    test "resolves deeply nested templates in JSON-RPC" do
      params = %{
        method: "complexCall",
        params: %{
          "level1" => %{
            "level2" => %{
              "level3" => %{
                "secret" => "{{SECRET:rpc_token}}"
              },
              "list" => [
                %{"key" => "{{SECRET:api_key}}"},
                "static",
                "{{SECRET:rpc_token}}"
              ]
            }
          }
        }
      }

      {:ok, resolved, used} = SecretResolver.resolve_params(params)

      assert get_in(resolved.params, ["level1", "level2", "level3", "secret"]) ==
               "actual-rpc-token"

      assert get_in(resolved.params, ["level1", "level2", "list", Access.at(0), "key"]) ==
               "actual-api-key"

      assert get_in(resolved.params, ["level1", "level2", "list", Access.at(2)]) ==
               "actual-rpc-token"

      # Should track both secrets as used
      assert Map.keys(used) |> Enum.sort() == ["api_key", "rpc_token"]
    end
  end

  describe "Protocol adapter integration patterns [INTEGRATION]" do
    setup do
      {:ok, _} = TableSecrets.create(%{name: "shared_token", value: "shared-secret-xyz"})
      :ok
    end

    test "GraphQL adapter preserves structure after secret resolution" do
      original = %{
        query: "mutation { update(token: $token) { success } }",
        variables: %{
          "token" => "{{SECRET:shared_token}}",
          "untouched" => %{"nested" => "data"}
        },
        operation_name: "UpdateOp"
      }

      {:ok, resolved, _} = SecretResolver.resolve_params(original)

      # Structure preserved
      assert resolved.query == original.query
      assert resolved.operation_name == original.operation_name
      assert resolved.variables["untouched"] == %{"nested" => "data"}

      # Only secret resolved
      assert resolved.variables["token"] == "shared-secret-xyz"
    end

    test "JSON-RPC adapter handles batch requests with secrets" do
      batch = [
        %{
          method: "call1",
          params: %{"token" => "{{SECRET:shared_token}}"},
          id: 1
        },
        %{
          method: "call2",
          params: ["{{SECRET:shared_token}}", "data"],
          id: 2
        }
      ]

      # Resolve each request
      resolved_batch =
        Enum.map(batch, fn req ->
          {:ok, resolved, _} = SecretResolver.resolve_params(req)
          resolved
        end)

      assert Enum.at(resolved_batch, 0).params["token"] == "shared-secret-xyz"
      assert Enum.at(resolved_batch, 1).params |> Enum.at(0) == "shared-secret-xyz"
    end

    test "tracks all used secrets across protocol requests" do
      {:ok, _} = TableSecrets.create(%{name: "extra_key", value: "extra-val"})

      # GraphQL request using multiple secrets
      graphql_params = %{
        query: "query",
        variables: %{
          "key1" => "{{SECRET:shared_token}}",
          "key2" => "{{SECRET:extra_key}}"
        }
      }

      # JSON-RPC request using same secrets
      jsonrpc_params = %{
        method: "test",
        params: %{
          "auth" => "{{SECRET:shared_token}}",
          "api" => "{{SECRET:extra_key}}"
        }
      }

      {:ok, _, graphql_used} = SecretResolver.resolve_params(graphql_params)
      {:ok, _, jsonrpc_used} = SecretResolver.resolve_params(jsonrpc_params)

      # Both should track the same secrets
      assert graphql_used == jsonrpc_used
      assert Map.keys(graphql_used) |> Enum.sort() == ["extra_key", "shared_token"]
    end
  end
end
