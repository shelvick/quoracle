defmodule Quoracle.Actions.API.GraphQLAdapterTest do
  @moduledoc """
  Tests for GraphQL protocol adapter module.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Actions.API.GraphQLAdapter

  describe "format_request/2 - Query formatting" do
    test "formats simple GraphQL query" do
      params = %{
        query: "query { user(id: 1) { name email } }"
      }

      {:ok, request} = GraphQLAdapter.format_request("https://api.example.com/graphql", params)

      assert request.method == :post
      assert request.url == "https://api.example.com/graphql"
      assert request.headers == [{"content-type", "application/json"}]

      assert request.body == %{
               "query" => "query { user(id: 1) { name email } }"
             }
    end

    test "formats GraphQL mutation" do
      params = %{
        query: "mutation CreateUser($name: String!) { createUser(name: $name) { id } }",
        variables: %{"name" => "Alice"}
      }

      {:ok, request} = GraphQLAdapter.format_request("https://api.example.com/graphql", params)

      assert request.body == %{
               "query" =>
                 "mutation CreateUser($name: String!) { createUser(name: $name) { id } }",
               "variables" => %{"name" => "Alice"}
             }
    end

    test "includes operation name when provided" do
      params = %{
        query: "query GetUser { user(id: 1) { name } }",
        operation_name: "GetUser"
      }

      {:ok, request} = GraphQLAdapter.format_request("https://api.example.com/graphql", params)

      assert request.body == %{
               "query" => "query GetUser { user(id: 1) { name } }",
               "operationName" => "GetUser"
             }
    end

    test "handles variables injection" do
      params = %{
        query: "query GetUser($id: ID!) { user(id: $id) { name email } }",
        variables: %{
          "id" => "123",
          "includeDetails" => true
        }
      }

      {:ok, request} = GraphQLAdapter.format_request("https://api.example.com/graphql", params)

      assert request.body["variables"] == %{
               "id" => "123",
               "includeDetails" => true
             }
    end

    test "handles empty/nil variables" do
      params = %{
        query: "query { users { name } }",
        variables: nil
      }

      {:ok, request} = GraphQLAdapter.format_request("https://api.example.com/graphql", params)

      refute Map.has_key?(request.body, "variables")
    end

    test "validates basic query structure" do
      # Missing braces before field name
      params = %{query: "query user name }"}

      assert {:error, :invalid_graphql_syntax} =
               GraphQLAdapter.format_request("https://api.example.com/graphql", params)

      # Empty query
      params = %{query: ""}

      assert {:error, :empty_query} =
               GraphQLAdapter.format_request("https://api.example.com/graphql", params)

      # Nil query
      params = %{}

      assert {:error, :missing_query} =
               GraphQLAdapter.format_request("https://api.example.com/graphql", params)
    end
  end

  describe "parse_response/1 - Response parsing" do
    test "extracts data from successful response" do
      response = %{
        status: 200,
        body: %{
          "data" => %{
            "user" => %{
              "id" => "123",
              "name" => "Alice",
              "email" => "alice@example.com"
            }
          }
        }
      }

      {:ok, parsed} = GraphQLAdapter.parse_response(response)

      assert parsed == %{
               status: :success,
               data: %{
                 "user" => %{
                   "id" => "123",
                   "name" => "Alice",
                   "email" => "alice@example.com"
                 }
               }
             }
    end

    test "extracts errors from error response" do
      response = %{
        status: 200,
        body: %{
          "errors" => [
            %{
              "message" => "Field 'invalidField' doesn't exist on type 'User'",
              "extensions" => %{
                "code" => "GRAPHQL_VALIDATION_FAILED"
              }
            }
          ]
        }
      }

      {:ok, parsed} = GraphQLAdapter.parse_response(response)

      assert parsed == %{
               status: :error,
               errors: [
                 %{
                   "message" => "Field 'invalidField' doesn't exist on type 'User'",
                   "extensions" => %{
                     "code" => "GRAPHQL_VALIDATION_FAILED"
                   }
                 }
               ]
             }
    end

    test "handles partial success (data + errors)" do
      response = %{
        status: 200,
        body: %{
          "data" => %{
            "user" => %{
              "id" => "123",
              "name" => "Alice"
            }
          },
          "errors" => [
            %{
              "message" => "Field 'restricted' requires authentication",
              "path" => ["user", "restricted"]
            }
          ]
        }
      }

      {:ok, parsed} = GraphQLAdapter.parse_response(response)

      assert parsed == %{
               status: :partial_success,
               data: %{
                 "user" => %{
                   "id" => "123",
                   "name" => "Alice"
                 }
               },
               errors: [
                 %{
                   "message" => "Field 'restricted' requires authentication",
                   "path" => ["user", "restricted"]
                 }
               ]
             }
    end

    test "handles HTTP error status codes" do
      response = %{
        status: 401,
        body: %{
          "message" => "Unauthorized"
        }
      }

      {:ok, parsed} = GraphQLAdapter.parse_response(response)

      assert parsed == %{
               status: :http_error,
               http_status: 401,
               error: %{"message" => "Unauthorized"}
             }
    end

    test "handles malformed response body" do
      response = %{
        status: 200,
        body: "not json"
      }

      {:error, :invalid_response_format} = GraphQLAdapter.parse_response(response)
    end

    test "handles missing data and errors fields" do
      response = %{
        status: 200,
        body: %{}
      }

      {:error, :invalid_graphql_response} = GraphQLAdapter.parse_response(response)
    end
  end

  describe "format_error/1 - Error formatting" do
    test "formats single GraphQL error" do
      errors = [
        %{
          "message" => "Cannot query field 'invalid' on type 'User'",
          "extensions" => %{"code" => "GRAPHQL_VALIDATION_FAILED"}
        }
      ]

      formatted = GraphQLAdapter.format_error(errors)

      assert formatted ==
               "GraphQL error: Cannot query field 'invalid' on type 'User' (GRAPHQL_VALIDATION_FAILED)"
    end

    test "formats multiple GraphQL errors" do
      errors = [
        %{"message" => "Field error 1"},
        %{"message" => "Field error 2"}
      ]

      formatted = GraphQLAdapter.format_error(errors)

      assert formatted == "GraphQL errors:\n- Field error 1\n- Field error 2"
    end

    test "includes error path when available" do
      errors = [
        %{
          "message" => "Field error",
          "path" => ["user", "posts", 0, "title"]
        }
      ]

      formatted = GraphQLAdapter.format_error(errors)

      assert formatted == "GraphQL error: Field error (at user.posts.0.title)"
    end

    test "includes error locations when available" do
      errors = [
        %{
          "message" => "Syntax error",
          "locations" => [%{"line" => 2, "column" => 5}]
        }
      ]

      formatted = GraphQLAdapter.format_error(errors)

      assert formatted == "GraphQL error: Syntax error (line 2, column 5)"
    end
  end

  describe "validate_query/1 - Query validation" do
    test "validates valid query syntax" do
      assert :ok = GraphQLAdapter.validate_query("query { user { name } }")
      assert :ok = GraphQLAdapter.validate_query("mutation { createUser(name: \"Bob\") { id } }")
      # shorthand
      assert :ok = GraphQLAdapter.validate_query("{ user { name } }")
    end

    test "detects missing braces" do
      assert {:error, :invalid_graphql_syntax} =
               GraphQLAdapter.validate_query("query user name }")

      assert {:error, :invalid_graphql_syntax} =
               GraphQLAdapter.validate_query("query { user name ")
    end

    test "detects unbalanced braces" do
      assert {:error, :unbalanced_braces} = GraphQLAdapter.validate_query("query { user { name }")

      assert {:error, :unbalanced_braces} =
               GraphQLAdapter.validate_query("query { user { name } } }")
    end

    test "detects empty query" do
      assert {:error, :empty_query} = GraphQLAdapter.validate_query("")
      assert {:error, :empty_query} = GraphQLAdapter.validate_query("   ")
    end
  end

  describe "extract_operation_type/1" do
    test "identifies query operations" do
      assert GraphQLAdapter.extract_operation_type("query GetUser { user { name } }") == :query
      assert GraphQLAdapter.extract_operation_type("query { user { name } }") == :query
      # default
      assert GraphQLAdapter.extract_operation_type("{ user { name } }") == :query
    end

    test "identifies mutation operations" do
      assert GraphQLAdapter.extract_operation_type("mutation CreateUser { createUser { id } }") ==
               :mutation

      assert GraphQLAdapter.extract_operation_type("mutation { createUser { id } }") == :mutation
    end

    test "identifies subscription operations" do
      assert GraphQLAdapter.extract_operation_type(
               "subscription OnUserUpdate { userUpdated { id } }"
             ) == :subscription

      assert GraphQLAdapter.extract_operation_type("subscription { userUpdated { id } }") ==
               :subscription
    end
  end

  describe "Integration with RequestBuilder and ResponseParser" do
    test "delegates HTTP request construction to RequestBuilder" do
      params = %{
        query: "query { users { name } }",
        auth_type: "bearer",
        auth_token: "secret123"
      }

      {:ok, request} = GraphQLAdapter.format_request("https://api.example.com/graphql", params)

      # Should pass auth params through for RequestBuilder to handle
      assert request.auth_params == %{
               auth_type: "bearer",
               auth_token: "secret123"
             }
    end

    test "delegates HTTP response parsing to ResponseParser" do
      # ResponseParser should handle HTTP-level concerns
      # GraphQLAdapter focuses on GraphQL-specific structure
      response = %{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: %{
          "data" => %{"users" => [%{"name" => "Alice"}]}
        }
      }

      {:ok, parsed} = GraphQLAdapter.parse_response(response)

      # GraphQLAdapter extracts GraphQL structure
      assert parsed.data["users"] == [%{"name" => "Alice"}]
    end
  end
end
