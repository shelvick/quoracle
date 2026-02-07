defmodule Quoracle.Actions.API.JSONRPCAdapterTest do
  @moduledoc """
  Tests for the JSON-RPC 2.0 protocol adapter module.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Actions.API.JSONRPCAdapter

  describe "format_request/2 - Request formatting" do
    test "formats JSON-RPC request with method and params" do
      params = %{
        method: "eth_getBalance",
        params: ["0x123", "latest"]
      }

      {:ok, request} = JSONRPCAdapter.format_request("https://rpc.example.com", params)

      assert request.method == :post
      assert request.url == "https://rpc.example.com"
      assert request.headers == [{"content-type", "application/json"}]
      assert request.body["jsonrpc"] == "2.0"
      assert request.body["method"] == "eth_getBalance"
      assert request.body["params"] == ["0x123", "latest"]
      # Auto-generated UUID
      assert is_binary(request.body["id"])
    end

    test "auto-generates request ID when not provided" do
      params = %{method: "eth_blockNumber"}

      {:ok, request} = JSONRPCAdapter.format_request("https://rpc.example.com", params)

      # Should be a UUID format
      assert is_binary(request.body["id"])

      assert String.match?(
               request.body["id"],
               ~r/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/
             )
    end

    test "uses provided request ID" do
      params = %{
        method: "eth_getBalance",
        params: ["0x123", "latest"],
        id: "custom-id-123"
      }

      {:ok, request} = JSONRPCAdapter.format_request("https://rpc.example.com", params)

      assert request.body["id"] == "custom-id-123"
    end

    test "supports positional parameters (array)" do
      params = %{
        method: "eth_call",
        params: [%{"to" => "0x123", "data" => "0x456"}, "latest"]
      }

      {:ok, request} = JSONRPCAdapter.format_request("https://rpc.example.com", params)

      assert request.body["params"] == [%{"to" => "0x123", "data" => "0x456"}, "latest"]
    end

    test "supports named parameters (map)" do
      params = %{
        method: "eth_getLogs",
        params: %{
          "fromBlock" => "0x1",
          "toBlock" => "latest",
          "address" => "0x123"
        }
      }

      {:ok, request} = JSONRPCAdapter.format_request("https://rpc.example.com", params)

      assert request.body["params"] == %{
               "fromBlock" => "0x1",
               "toBlock" => "latest",
               "address" => "0x123"
             }
    end

    test "handles nil/empty params" do
      params = %{
        method: "net_version",
        params: nil
      }

      {:ok, request} = JSONRPCAdapter.format_request("https://rpc.example.com", params)

      refute Map.has_key?(request.body, "params")
    end

    test "validates required method parameter" do
      params = %{}

      assert {:error, :missing_method} =
               JSONRPCAdapter.format_request("https://rpc.example.com", params)
    end

    test "validates method is a string" do
      params = %{method: 123}

      assert {:error, :invalid_method_type} =
               JSONRPCAdapter.format_request("https://rpc.example.com", params)
    end
  end

  describe "parse_response/1 - Response parsing" do
    test "parses successful result response" do
      response = %{
        status: 200,
        body: %{
          "jsonrpc" => "2.0",
          "id" => "test-123",
          "result" => "0x1234"
        }
      }

      {:ok, parsed} = JSONRPCAdapter.parse_response(response, "test-123")

      assert parsed == %{
               status: :success,
               result: "0x1234",
               id: "test-123"
             }
    end

    test "parses error response" do
      response = %{
        status: 200,
        body: %{
          "jsonrpc" => "2.0",
          "id" => "test-123",
          "error" => %{
            "code" => -32601,
            "message" => "Method not found"
          }
        }
      }

      {:ok, parsed} = JSONRPCAdapter.parse_response(response, "test-123")

      assert parsed == %{
               status: :error,
               error: %{
                 "code" => -32601,
                 "message" => "Method not found"
               },
               id: "test-123"
             }
    end

    test "validates JSON-RPC version" do
      response = %{
        status: 200,
        body: %{
          # Wrong version
          "jsonrpc" => "1.0",
          "id" => "test-123",
          "result" => "0x1234"
        }
      }

      assert {:error, :invalid_jsonrpc_version} =
               JSONRPCAdapter.parse_response(response, "test-123")
    end

    test "validates response ID matches request ID" do
      response = %{
        status: 200,
        body: %{
          "jsonrpc" => "2.0",
          # Doesn't match
          "id" => "wrong-id",
          "result" => "0x1234"
        }
      }

      assert {:error, :id_mismatch} = JSONRPCAdapter.parse_response(response, "test-123")
    end

    test "handles missing result and error fields" do
      response = %{
        status: 200,
        body: %{
          "jsonrpc" => "2.0",
          "id" => "test-123"
        }
      }

      assert {:error, :invalid_jsonrpc_response} =
               JSONRPCAdapter.parse_response(response, "test-123")
    end

    test "handles HTTP error status codes" do
      response = %{
        status: 500,
        body: "Internal Server Error"
      }

      {:ok, parsed} = JSONRPCAdapter.parse_response(response, "test-123")

      assert parsed == %{
               status: :http_error,
               http_status: 500,
               error: "Internal Server Error"
             }
    end

    test "handles malformed JSON response" do
      response = %{
        status: 200,
        body: "not json"
      }

      assert {:error, :invalid_response_format} =
               JSONRPCAdapter.parse_response(response, "test-123")
    end
  end

  describe "format_error/1 - Error formatting" do
    test "formats standard JSON-RPC errors" do
      error = %{
        "code" => -32700,
        "message" => "Parse error"
      }

      formatted = JSONRPCAdapter.format_error(error)

      assert formatted == "JSON-RPC error -32700: Parse error"
    end

    test "includes error data when available" do
      error = %{
        "code" => -32602,
        "message" => "Invalid params",
        "data" => "Parameter 'address' is required"
      }

      formatted = JSONRPCAdapter.format_error(error)

      assert formatted ==
               "JSON-RPC error -32602: Invalid params (Parameter 'address' is required)"
    end

    test "recognizes standard error codes" do
      standard_errors = [
        {-32700, "Parse error"},
        {-32600, "Invalid request"},
        {-32601, "Method not found"},
        {-32602, "Invalid params"},
        {-32603, "Internal error"}
      ]

      for {code, expected_msg} <- standard_errors do
        error = %{"code" => code, "message" => expected_msg}
        formatted = JSONRPCAdapter.format_error(error)
        assert String.contains?(formatted, "#{code}")
        assert String.contains?(formatted, expected_msg)
      end
    end
  end

  describe "validate_request/1 - Request validation" do
    test "validates valid request structure" do
      params = %{
        method: "eth_getBalance",
        params: ["0x123", "latest"]
      }

      assert :ok = JSONRPCAdapter.validate_request(params)
    end

    test "validates method is required" do
      params = %{params: []}

      assert {:error, :missing_method} = JSONRPCAdapter.validate_request(params)
    end

    test "validates method is a string" do
      params = %{method: 123}

      assert {:error, :invalid_method_type} = JSONRPCAdapter.validate_request(params)

      params = %{method: :atom}

      assert {:error, :invalid_method_type} = JSONRPCAdapter.validate_request(params)
    end

    test "validates params is array or map" do
      # Valid
      assert :ok = JSONRPCAdapter.validate_request(%{method: "test", params: []})
      assert :ok = JSONRPCAdapter.validate_request(%{method: "test", params: %{}})
      assert :ok = JSONRPCAdapter.validate_request(%{method: "test", params: nil})

      # Invalid
      assert {:error, :invalid_params_type} =
               JSONRPCAdapter.validate_request(%{method: "test", params: "string"})

      assert {:error, :invalid_params_type} =
               JSONRPCAdapter.validate_request(%{method: "test", params: 123})
    end
  end

  describe "generate_id/0" do
    test "generates unique UUIDs" do
      id1 = JSONRPCAdapter.generate_id()
      id2 = JSONRPCAdapter.generate_id()
      id3 = JSONRPCAdapter.generate_id()

      assert id1 != id2
      assert id2 != id3
      assert id1 != id3

      # All should be valid UUID format
      for id <- [id1, id2, id3] do
        assert String.match?(
                 id,
                 ~r/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/
               )
      end
    end
  end

  describe "extract_error_message/1" do
    test "extracts message from error map" do
      error = %{"code" => -32601, "message" => "Method not found"}
      assert JSONRPCAdapter.extract_error_message(error) == "Method not found"
    end

    test "includes data field if present" do
      error = %{
        "code" => -32602,
        "message" => "Invalid params",
        "data" => %{"missing" => ["address"]}
      }

      message = JSONRPCAdapter.extract_error_message(error)
      assert String.contains?(message, "Invalid params")
      assert String.contains?(message, "missing")
    end

    test "handles missing message field" do
      error = %{"code" => -32603}
      assert JSONRPCAdapter.extract_error_message(error) == "Unknown error (code: -32603)"
    end
  end

  describe "Integration" do
    test "delegates auth to RequestBuilder" do
      params = %{
        method: "eth_getBalance",
        params: ["0x123"],
        auth_type: "bearer",
        auth_token: "secret123"
      }

      {:ok, request} = JSONRPCAdapter.format_request("https://rpc.example.com", params)

      # Should pass auth params through
      assert request.auth_params == %{
               auth_type: "bearer",
               auth_token: "secret123"
             }
    end

    test "works with ResponseParser for HTTP concerns" do
      # ResponseParser handles HTTP-level parsing
      # JSONRPCAdapter handles JSON-RPC protocol
      response = %{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: %{
          "jsonrpc" => "2.0",
          "id" => "test-123",
          "result" => %{"balance" => "0x1234"}
        }
      }

      {:ok, parsed} = JSONRPCAdapter.parse_response(response, "test-123")

      assert parsed.result == %{"balance" => "0x1234"}
    end
  end
end
