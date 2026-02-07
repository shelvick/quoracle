defmodule Quoracle.Actions.API.ResponseParserTest do
  use ExUnit.Case, async: true

  alias Quoracle.Actions.API.ResponseParser

  describe "REST response parsing" do
    test "parses successful JSON response" do
      response = %{
        status: 200,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!(%{
            "id" => 1,
            "name" => "John Doe",
            "email" => "john@example.com"
          })
      }

      {:ok, result} = ResponseParser.parse(response, :rest)

      assert result.status_code == 200
      assert result.data["id"] == 1
      assert result.data["name"] == "John Doe"
      assert result.data["email"] == "john@example.com"
      assert result.errors == []
    end

    test "parses successful plain text response" do
      response = %{
        status: 200,
        headers: %{"content-type" => "text/plain"},
        body: "Hello, World!"
      }

      {:ok, result} = ResponseParser.parse(response, :rest)

      assert result.status_code == 200
      assert result.data == "Hello, World!"
    end

    test "parses HTML response" do
      response = %{
        status: 200,
        headers: %{"content-type" => "text/html"},
        body: "<html><body><h1>Title</h1></body></html>"
      }

      {:ok, result} = ResponseParser.parse(response, :rest)

      assert result.status_code == 200
      assert result.data =~ "<h1>Title</h1>"
    end

    test "parses XML response" do
      response = %{
        status: 200,
        headers: %{"content-type" => "application/xml"},
        body: """
        <?xml version="1.0"?>
        <user>
          <id>1</id>
          <name>Jane</name>
        </user>
        """
      }

      {:ok, result} = ResponseParser.parse(response, :rest)

      assert result.status_code == 200
      # XML should be returned as-is or parsed if XML parser available
      assert result.data =~ "<user>"
    end

    test "handles empty response body" do
      response = %{
        # No Content
        status: 204,
        headers: %{},
        body: ""
      }

      {:ok, result} = ResponseParser.parse(response, :rest)

      assert result.status_code == 204
      assert result.data in [nil, ""]
    end

    test "maps 404 to not_found error" do
      response = %{
        status: 404,
        headers: %{"content-type" => "application/json"},
        body: Jason.encode!(%{"error" => "Not found"})
      }

      {:error, :not_found} = ResponseParser.parse(response, :rest)
    end

    test "maps 401 to auth_failed error" do
      response = %{
        status: 401,
        headers: %{},
        body: "Unauthorized"
      }

      {:error, :auth_failed} = ResponseParser.parse(response, :rest)
    end

    test "maps 429 to rate_limit_exceeded error" do
      response = %{
        status: 429,
        headers: %{"retry-after" => "60"},
        body: "Rate limit exceeded"
      }

      {:error, :rate_limit_exceeded} = ResponseParser.parse(response, :rest)
    end

    test "maps 500 to internal_server_error" do
      response = %{
        status: 500,
        headers: %{},
        body: "Internal Server Error"
      }

      {:error, :internal_server_error} = ResponseParser.parse(response, :rest)
    end

    test "maps 503 to service_unavailable" do
      response = %{
        status: 503,
        headers: %{},
        body: "Service Unavailable"
      }

      {:error, :service_unavailable} = ResponseParser.parse(response, :rest)
    end

    test "handles malformed JSON in response" do
      response = %{
        status: 200,
        headers: %{"content-type" => "application/json"},
        body: "{invalid json"
      }

      {:ok, result} = ResponseParser.parse(response, :rest)

      # Should fallback to returning raw body when JSON parsing fails
      assert result.data == "{invalid json"
    end
  end

  describe "GraphQL response parsing" do
    test "parses successful GraphQL response with data only" do
      response = %{
        status: 200,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!(%{
            "data" => %{
              "user" => %{
                "id" => "123",
                "name" => "Alice",
                "email" => "alice@example.com"
              }
            }
          })
      }

      {:ok, result} = ResponseParser.parse(response, :graphql)

      assert result.status_code == 200
      assert result.data["user"]["id"] == "123"
      assert result.data["user"]["name"] == "Alice"
      assert result.errors == []
    end

    test "parses GraphQL response with errors only" do
      response = %{
        status: 200,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!(%{
            "errors" => [
              %{
                "message" => "User not found",
                "path" => ["user"],
                "extensions" => %{"code" => "NOT_FOUND"}
              }
            ]
          })
      }

      {:ok, result} = ResponseParser.parse(response, :graphql)

      assert result.status_code == 200
      assert result.data in [nil, %{}]
      assert length(result.errors) == 1
      assert hd(result.errors)["message"] == "User not found"
    end

    test "parses GraphQL response with both data and errors (partial success)" do
      response = %{
        status: 200,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!(%{
            "data" => %{
              "user" => %{
                "id" => "123",
                "name" => "Bob",
                # Error fetching email
                "email" => nil
              }
            },
            "errors" => [
              %{
                "message" => "Not authorized to view email",
                "path" => ["user", "email"],
                "extensions" => %{"code" => "UNAUTHORIZED"}
              }
            ]
          })
      }

      {:ok, result} = ResponseParser.parse(response, :graphql)

      assert result.status_code == 200
      assert result.data["user"]["id"] == "123"
      assert result.data["user"]["name"] == "Bob"
      assert result.data["user"]["email"] == nil
      assert length(result.errors) == 1
      assert hd(result.errors)["message"] =~ "Not authorized"
    end

    test "handles GraphQL response with extensions" do
      response = %{
        status: 200,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!(%{
            "data" => %{"test" => "value"},
            "extensions" => %{
              "tracing" => %{"version" => 1},
              "metrics" => %{"duration" => 123}
            }
          })
      }

      {:ok, result} = ResponseParser.parse(response, :graphql)

      assert result.data["test"] == "value"
      # Extensions might be included in the result or ignored
    end

    test "handles malformed GraphQL response" do
      response = %{
        status: 200,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!(%{
            "unexpected" => "structure"
          })
      }

      {:ok, result} = ResponseParser.parse(response, :graphql)

      # Should handle gracefully even without standard data/errors fields
      assert result.status_code == 200
    end

    test "handles GraphQL response with nested errors" do
      response = %{
        status: 200,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!(%{
            "data" => %{
              "users" => [
                %{"id" => "1", "name" => "User 1"},
                # Error loading this user
                nil,
                %{"id" => "3", "name" => "User 3"}
              ]
            },
            "errors" => [
              %{
                "message" => "User 2 not found",
                "path" => ["users", 1]
              }
            ]
          })
      }

      {:ok, result} = ResponseParser.parse(response, :graphql)

      assert length(result.data["users"]) == 3
      assert Enum.at(result.data["users"], 0)["name"] == "User 1"
      assert Enum.at(result.data["users"], 1) == nil
      assert Enum.at(result.data["users"], 2)["name"] == "User 3"
      assert length(result.errors) == 1
    end
  end

  describe "JSON-RPC response parsing" do
    test "parses successful JSON-RPC response" do
      response = %{
        status: 200,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "result" => %{
              "userId" => 42,
              "userName" => "john_doe",
              "balance" => 1000
            },
            "id" => "req-123"
          })
      }

      {:ok, result} = ResponseParser.parse(response, :jsonrpc)

      assert result.status_code == 200
      assert result.data["userId"] == 42
      assert result.data["userName"] == "john_doe"
      assert result.data["balance"] == 1000
    end

    test "parses JSON-RPC error response" do
      response = %{
        # JSON-RPC errors still return 200 HTTP
        status: 200,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "error" => %{
              "code" => -32601,
              "message" => "Method not found",
              "data" => %{"method" => "unknownMethod"}
            },
            "id" => "req-456"
          })
      }

      {:error, :rpc_error} = ResponseParser.parse(response, :jsonrpc)
    end

    test "handles JSON-RPC response with null result" do
      response = %{
        status: 200,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "result" => nil,
            "id" => "req-789"
          })
      }

      {:ok, result} = ResponseParser.parse(response, :jsonrpc)

      assert result.status_code == 200
      assert result.data == nil
    end

    test "handles JSON-RPC notification response (no id)" do
      response = %{
        status: 200,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "result" => "notification received"
            # No id field for notifications
          })
      }

      {:ok, result} = ResponseParser.parse(response, :jsonrpc)

      assert result.data == "notification received"
    end

    test "validates JSON-RPC version" do
      response = %{
        status: 200,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!(%{
            # Wrong version
            "jsonrpc" => "1.0",
            "result" => "test"
          })
      }

      # Should still parse but might note version mismatch
      {:ok, result} = ResponseParser.parse(response, :jsonrpc)

      assert result.data == "test"
    end

    test "handles batch response (single item)" do
      # Even though we don't support batch requests, we might receive
      # a single-item batch response from some APIs
      response = %{
        status: 200,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!([
            %{
              "jsonrpc" => "2.0",
              "result" => %{"status" => "ok"},
              "id" => "req-1"
            }
          ])
      }

      {:ok, result} = ResponseParser.parse(response, :jsonrpc)

      # Should handle single-item array response
      assert result.data["status"] == "ok"
    end

    test "maps JSON-RPC standard error codes" do
      test_cases = [
        {-32700, "Parse error", :parse_error},
        {-32600, "Invalid Request", :invalid_request},
        {-32601, "Method not found", :method_not_found},
        {-32602, "Invalid params", :invalid_params},
        {-32603, "Internal error", :internal_error}
      ]

      for {code, message, expected_error} <- test_cases do
        response = %{
          status: 200,
          headers: %{"content-type" => "application/json"},
          body:
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "error" => %{
                "code" => code,
                "message" => message
              },
              "id" => "test"
            })
        }

        {:error, error} = ResponseParser.parse(response, :jsonrpc)

        # Might map to specific error or generic rpc_error
        assert error in [expected_error, :rpc_error]
      end
    end
  end

  describe "content type detection" do
    test "detects JSON content type variations" do
      json_types = [
        "application/json",
        "application/json; charset=utf-8",
        "application/vnd.api+json",
        "text/json"
      ]

      for content_type <- json_types do
        response = %{
          status: 200,
          headers: %{"content-type" => content_type},
          body: Jason.encode!(%{"test" => "data"})
        }

        {:ok, result} = ResponseParser.parse(response, :rest)

        assert result.data["test"] == "data"
      end
    end

    test "handles missing content-type header" do
      response = %{
        status: 200,
        headers: %{},
        body: Jason.encode!(%{"test" => "data"})
      }

      {:ok, result} = ResponseParser.parse(response, :rest)

      # Should attempt to parse as JSON if it looks like JSON
      assert is_map(result.data) and result.data["test"] == "data"
    end
  end

  describe "error mapping" do
    test "maps HTTP status codes to semantic errors" do
      test_cases = [
        {400, :bad_request},
        {401, :auth_failed},
        {403, :forbidden},
        {404, :not_found},
        {408, :request_timeout},
        {429, :rate_limit_exceeded},
        {500, :internal_server_error},
        {502, :bad_gateway},
        {503, :service_unavailable},
        {504, :gateway_timeout}
      ]

      for {status, expected_error} <- test_cases do
        response = %{
          status: status,
          headers: %{},
          body: "Error"
        }

        {:error, error} = ResponseParser.parse(response, :rest)

        assert error == expected_error
      end
    end

    test "handles unknown error status codes" do
      response = %{
        # I'm a teapot
        status: 418,
        headers: %{},
        body: "I'm a teapot"
      }

      {:error, error} = ResponseParser.parse(response, :rest)

      # Should map to generic error for unknown status codes
      assert error in [:unknown_error, :server_error]
    end
  end

  describe "response size limits" do
    test "enforces response size limit" do
      # Create response larger than 10MB limit
      large_body = String.duplicate("x", 11_000_000)

      response = %{
        status: 200,
        headers: %{"content-type" => "text/plain"},
        body: large_body
      }

      {:error, :response_too_large} = ResponseParser.parse(response, :rest)
    end
  end

  describe "partial success handling" do
    test "returns partial data with errors for REST API" do
      # Some REST APIs return 207 Multi-Status with partial success
      response = %{
        status: 207,
        headers: %{"content-type" => "application/json"},
        body:
          Jason.encode!(%{
            "success" => [
              %{"id" => 1, "status" => "created"},
              %{"id" => 2, "status" => "created"}
            ],
            "errors" => [
              %{"id" => 3, "error" => "validation failed"}
            ]
          })
      }

      {:ok, result} = ResponseParser.parse(response, :rest)

      assert result.status_code == 207
      assert result.data["success"]
      assert result.data["errors"]
    end
  end
end
