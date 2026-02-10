defmodule Quoracle.Actions.API.RequestBuilderTest do
  use ExUnit.Case, async: true

  alias Quoracle.Actions.API.RequestBuilder

  describe "REST request building" do
    test "builds GET request with URL and headers" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com/users",
        method: "GET",
        headers: %{"Accept" => "application/json"}
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.method == :get
      assert request.url == "https://api.example.com/users"
      assert request.headers["Accept"] == "application/json"
    end

    test "builds POST request with body" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com/users",
        method: "POST",
        body: %{name: "John", email: "john@example.com"},
        headers: %{"Content-Type" => "application/json"}
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.method == :post
      assert request.body == Jason.encode!(%{name: "John", email: "john@example.com"})
      assert request.headers["Content-Type"] == "application/json"
    end

    test "builds PUT request" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com/users/1",
        method: "PUT",
        body: %{name: "Jane"}
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.method == :put
      assert request.url == "https://api.example.com/users/1"
    end

    test "builds DELETE request" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com/users/1",
        method: "DELETE"
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.method == :delete
    end

    test "builds PATCH request with partial data" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com/users/1",
        method: "PATCH",
        body: %{email: "new@example.com"}
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.method == :patch
      assert request.body == Jason.encode!(%{email: "new@example.com"})
    end

    test "includes query parameters in URL" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com/users",
        method: "GET",
        query_params: %{
          "page" => "2",
          "limit" => "10",
          "sort" => "name"
        }
      }

      {:ok, request} = RequestBuilder.build(params)

      # Query params should be encoded in the URL
      assert request.url =~ "page=2"
      assert request.url =~ "limit=10"
      assert request.url =~ "sort=name"
    end

    test "normalizes HTTP method to atom" do
      # Test various case formats
      test_cases = [
        {"GET", :get},
        {"get", :get},
        {"Post", :post},
        {"DELETE", :delete}
      ]

      for {input, expected} <- test_cases do
        params = %{
          api_type: :rest,
          url: "https://api.example.com",
          method: input
        }

        {:ok, request} = RequestBuilder.build(params)
        assert request.method == expected
      end
    end
  end

  describe "GraphQL request building" do
    test "builds GraphQL query request" do
      params = %{
        api_type: :graphql,
        url: "https://api.example.com/graphql",
        query: """
        query GetUser($id: ID!) {
          user(id: $id) {
            name
            email
          }
        }
        """,
        variables: %{"id" => "123"}
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.method == :post
      assert request.url == "https://api.example.com/graphql"
      assert request.headers["Content-Type"] == "application/json"

      body = Jason.decode!(request.body)
      assert body["query"] =~ "GetUser"
      assert body["variables"] == %{"id" => "123"}
    end

    test "builds GraphQL mutation request" do
      params = %{
        api_type: :graphql,
        url: "https://api.example.com/graphql",
        query: """
        mutation CreateUser($input: UserInput!) {
          createUser(input: $input) {
            id
            name
          }
        }
        """,
        variables: %{"input" => %{"name" => "Alice", "email" => "alice@example.com"}}
      }

      {:ok, request} = RequestBuilder.build(params)

      body = Jason.decode!(request.body)
      assert body["query"] =~ "mutation CreateUser"
      assert body["variables"]["input"]["name"] == "Alice"
    end

    test "builds GraphQL request without variables" do
      params = %{
        api_type: :graphql,
        url: "https://api.example.com/graphql",
        query: """
        query {
          users {
            id
            name
          }
        }
        """
      }

      {:ok, request} = RequestBuilder.build(params)

      body = Jason.decode!(request.body)
      assert body["query"] =~ "users"
      assert body["variables"] in [nil, %{}]
    end

    test "includes custom headers in GraphQL request" do
      params = %{
        api_type: :graphql,
        url: "https://api.example.com/graphql",
        query: "{ users { id } }",
        headers: %{"X-API-Key" => "secret123"}
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.headers["X-API-Key"] == "secret123"
      assert request.headers["Content-Type"] == "application/json"
    end
  end

  describe "JSON-RPC request building" do
    test "builds JSON-RPC request with method and params" do
      params = %{
        api_type: :jsonrpc,
        url: "https://api.example.com/rpc",
        rpc_method: "getUser",
        rpc_params: %{"id" => 42},
        rpc_id: "req-1"
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.method == :post
      assert request.url == "https://api.example.com/rpc"
      assert request.headers["Content-Type"] == "application/json"

      body = Jason.decode!(request.body)
      assert body["jsonrpc"] == "2.0"
      assert body["method"] == "getUser"
      assert body["params"] == %{"id" => 42}
      assert body["id"] == "req-1"
    end

    test "builds JSON-RPC request with array params" do
      params = %{
        api_type: :jsonrpc,
        url: "https://api.example.com/rpc",
        rpc_method: "sum",
        rpc_params: [1, 2, 3, 4],
        rpc_id: "sum-request"
      }

      {:ok, request} = RequestBuilder.build(params)

      body = Jason.decode!(request.body)
      assert body["params"] == [1, 2, 3, 4]
    end

    test "auto-generates request ID if not provided" do
      params = %{
        api_type: :jsonrpc,
        url: "https://api.example.com/rpc",
        rpc_method: "ping"
      }

      {:ok, request} = RequestBuilder.build(params)

      body = Jason.decode!(request.body)
      assert body["jsonrpc"] == "2.0"
      assert body["method"] == "ping"
      assert is_binary(body["id"])
      assert String.length(body["id"]) > 0
    end

    test "builds JSON-RPC request without params" do
      params = %{
        api_type: :jsonrpc,
        url: "https://api.example.com/rpc",
        rpc_method: "getCurrentTime",
        rpc_id: "time-1"
      }

      {:ok, request} = RequestBuilder.build(params)

      body = Jason.decode!(request.body)
      assert body["method"] == "getCurrentTime"
      # params field is omitted for methods without parameters
      refute Map.has_key?(body, "params")
    end
  end

  describe "timeout configuration" do
    test "applies default timeout of 30 seconds" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com",
        method: "GET"
      }

      {:ok, request} = RequestBuilder.build(params)

      # 30 seconds in milliseconds
      assert request.timeout == 30_000
    end

    test "converts custom timeout from seconds to milliseconds" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com",
        method: "GET",
        # 5 seconds
        timeout: 5
      }

      {:ok, request} = RequestBuilder.build(params)

      # Converted to milliseconds
      assert request.timeout == 5_000
    end

    test "applies timeout to all API types" do
      for api_type <- [:rest, :graphql, :jsonrpc] do
        params = build_params_for_type(api_type, %{timeout: 10})

        {:ok, request} = RequestBuilder.build(params)

        assert request.timeout == 10_000
      end
    end
  end

  describe "URL validation" do
    test "accepts valid HTTP URLs" do
      params = %{
        api_type: :rest,
        url: "http://api.example.com",
        method: "GET"
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.url == "http://api.example.com"
    end

    test "accepts valid HTTPS URLs" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com",
        method: "GET"
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.url == "https://api.example.com"
    end

    test "rejects non-HTTP schemes" do
      params = %{
        api_type: :rest,
        url: "ftp://files.example.com",
        method: "GET"
      }

      {:error, :invalid_url} = RequestBuilder.build(params)
    end

    test "rejects malformed URLs" do
      params = %{
        api_type: :rest,
        url: "not a url",
        method: "GET"
      }

      {:error, :invalid_url} = RequestBuilder.build(params)
    end

    test "handles missing URL" do
      params = %{
        api_type: :rest,
        method: "GET"
      }

      {:error, :invalid_url} = RequestBuilder.build(params)
    end
  end

  describe "request body size validation" do
    test "accepts body within size limit" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com",
        method: "POST",
        # 1KB, well under 5MB limit
        body: %{data: String.duplicate("x", 1000)}
      }

      {:ok, request} = RequestBuilder.build(params)

      assert is_binary(request.body)
    end

    test "rejects body exceeding 5MB limit" do
      # 6MB
      large_data = String.duplicate("x", 6_000_000)

      params = %{
        api_type: :rest,
        url: "https://api.example.com",
        method: "POST",
        body: large_data
      }

      {:error, :body_too_large} = RequestBuilder.build(params)
    end

    test "allows configurable body size limit" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com",
        method: "POST",
        # 2MB
        body: String.duplicate("x", 2_000_000),
        # 1MB limit
        max_body_size: 1_000_000
      }

      {:error, :body_too_large} = RequestBuilder.build(params)
    end
  end

  describe "redirect configuration" do
    test "enables redirect following by default" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com",
        method: "GET"
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.follow_redirects == true
    end

    test "allows disabling redirect following" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com",
        method: "GET",
        follow_redirects: false
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.follow_redirects == false
    end
  end

  describe "header merging" do
    test "preserves user headers while adding required ones" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com",
        method: "POST",
        body: %{test: "data"},
        headers: %{
          "X-Custom" => "value",
          # Override default
          "Accept" => "application/xml"
        }
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.headers["X-Custom"] == "value"
      assert request.headers["Accept"] == "application/xml"
      # Added for JSON body
      assert request.headers["Content-Type"] == "application/json"
    end

    test "sets appropriate Content-Type for JSON body" do
      params = %{
        api_type: :rest,
        url: "https://api.example.com",
        method: "POST",
        body: %{json: "data"}
      }

      {:ok, request} = RequestBuilder.build(params)

      assert request.headers["Content-Type"] == "application/json"
    end
  end

  # Helper function to build params for different API types
  defp build_params_for_type(:rest, overrides) do
    Map.merge(
      %{
        api_type: :rest,
        url: "https://api.example.com",
        method: "GET"
      },
      overrides
    )
  end

  defp build_params_for_type(:graphql, overrides) do
    Map.merge(
      %{
        api_type: :graphql,
        url: "https://api.example.com/graphql",
        query: "{ test }"
      },
      overrides
    )
  end

  defp build_params_for_type(:jsonrpc, overrides) do
    Map.merge(
      %{
        api_type: :jsonrpc,
        url: "https://api.example.com/rpc",
        rpc_method: "test"
      },
      overrides
    )
  end
end
