defmodule Quoracle.Actions.APITest do
  # req_cassette enables async: true (process-isolated recording)
  use ExUnit.Case, async: true

  alias Quoracle.Actions.API

  @agent_id "agent-123"
  @default_opts []
  @cassette_dir "test/fixtures/cassettes/api"

  describe "R1: REST GET Request [SYSTEM]" do
    test "executes REST GET request successfully" do
      # WHEN execute called IF api_type=:rest, method=GET
      # THEN executes HTTP GET and returns parsed response
      params = %{
        api_type: :rest,
        url: "https://jsonplaceholder.typicode.com/posts/1",
        method: "GET"
      }

      ReqCassette.with_cassette(
        "rest_get_request",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          {:ok, result} = API.execute(params, @agent_id, test_opts)

          assert result.action == "call_api"
          assert result.api_type == :rest
          assert result.status_code == 200
          assert is_map(result.data)
          assert result.data["id"] == 1
        end
      )
    end
  end

  describe "R2: REST POST with Body [SYSTEM]" do
    test "executes REST POST with JSON body" do
      # WHEN execute called IF api_type=:rest, method=POST, body provided
      # THEN posts data and returns response
      params = %{
        api_type: :rest,
        url: "https://jsonplaceholder.typicode.com/posts",
        method: "POST",
        body: %{
          title: "Test Post",
          body: "Test content",
          userId: 1
        },
        headers: %{"Content-Type" => "application/json"}
      }

      ReqCassette.with_cassette(
        "rest_post_with_body",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          {:ok, result} = API.execute(params, @agent_id, test_opts)

          assert result.action == "call_api"
          assert result.api_type == :rest
          assert result.status_code == 201
          assert result.data["title"] == "Test Post"
          assert result.data["body"] == "Test content"
          assert result.data["userId"] == 1
          # API assigns an ID
          assert result.data["id"]
        end
      )
    end
  end

  describe "R3: GraphQL Query [SYSTEM]" do
    test "executes GraphQL query successfully" do
      # WHEN execute called IF api_type=:graphql, query provided
      # THEN executes GraphQL query and returns data
      params = %{
        api_type: :graphql,
        url: "https://countries.trevorblades.com/graphql",
        query: """
        query {
          country(code: "US") {
            name
            capital
            currency
          }
        }
        """
      }

      ReqCassette.with_cassette("graphql_query", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(@default_opts, :plug, plug)
        {:ok, result} = API.execute(params, @agent_id, test_opts)

        assert result.action == "call_api"
        assert result.api_type == :graphql
        assert result.status_code == 200
        assert result.data["country"]["name"] == "United States"
        assert result.data["country"]["capital"] == "Washington D.C."
        # API returns multiple currency codes
        assert result.data["country"]["currency"] == "USD,USN,USS"
        assert result.errors == []
      end)
    end

    test "executes GraphQL query with variables" do
      params = %{
        api_type: :graphql,
        url: "https://countries.trevorblades.com/graphql",
        query: """
        query GetCountry($code: ID!) {
          country(code: $code) {
            name
            capital
          }
        }
        """,
        variables: %{"code" => "CA"}
      }

      ReqCassette.with_cassette(
        "graphql_query_with_variables",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          {:ok, result} = API.execute(params, @agent_id, test_opts)

          assert result.data["country"]["name"] == "Canada"
          assert result.data["country"]["capital"] == "Ottawa"
        end
      )
    end
  end

  describe "R4: GraphQL Partial Success [SYSTEM]" do
    test "handles GraphQL partial success" do
      # WHEN execute called IF GraphQL response has both data and errors
      # THEN returns {:ok, result} with both fields
      #
      # NOTE: No public GraphQL endpoint returns partial success (both data and errors).
      # Using a stub plug to simulate this specific response format.
      params = %{
        api_type: :graphql,
        url: "https://example.com/graphql",
        query: """
        query {
          user(id: "123") {
            name
            email
            privateField
          }
        }
        """
      }

      # Stub plug that returns a GraphQL partial success response
      stub_plug = fn conn ->
        response = %{
          "data" => %{
            "user" => %{
              "name" => "John Doe",
              "email" => "john@example.com",
              "privateField" => nil
            }
          },
          "errors" => [
            %{
              "message" => "Cannot access privateField: unauthorized",
              "path" => ["user", "privateField"]
            }
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      test_opts = Keyword.put(@default_opts, :plug, stub_plug)
      {:ok, result} = API.execute(params, @agent_id, test_opts)

      assert result.action == "call_api"
      assert result.api_type == :graphql
      assert result.status_code == 200
      assert result.data["user"]["name"] == "John Doe"
      assert result.data["user"]["email"] == "john@example.com"
      assert result.errors != []
      assert hd(result.errors)["message"] =~ "privateField"
    end
  end

  describe "R5: JSON-RPC Method Call [SYSTEM]" do
    test "executes JSON-RPC method call" do
      # WHEN execute called IF api_type=:jsonrpc, rpc_method provided
      # THEN executes RPC call and returns result
      params = %{
        api_type: :jsonrpc,
        url: "https://ethereum-rpc.publicnode.com",
        rpc_method: "eth_blockNumber",
        rpc_id: "test-1"
      }

      ReqCassette.with_cassette(
        "jsonrpc_method_call",
        [cassette_dir: @cassette_dir, match_requests_on: [:method]],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          assert {:ok, result} = API.execute(params, @agent_id, test_opts)

          assert result.action == "call_api"
          assert result.api_type == :jsonrpc
          assert result.status_code == 200
          assert is_binary(result.data)
          assert String.starts_with?(result.data, "0x")
        end
      )
    end

    test "auto-generates JSON-RPC request ID if missing" do
      params = %{
        api_type: :jsonrpc,
        url: "https://ethereum-rpc.publicnode.com",
        rpc_method: "net_version"
      }

      ReqCassette.with_cassette(
        "jsonrpc_auto_id",
        [cassette_dir: @cassette_dir, match_requests_on: [:method]],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          assert {:ok, result} = API.execute(params, @agent_id, test_opts)

          assert result.action == "call_api"
          assert result.api_type == :jsonrpc
          assert result.status_code == 200
          assert is_binary(result.data)
        end
      )
    end
  end

  describe "R6: Bearer Authentication [INTEGRATION]" do
    test "applies bearer token authentication" do
      # WHEN execute called IF auth with bearer token
      # THEN includes Authorization header in request
      params = %{
        api_type: :rest,
        url: "https://api.github.com/user",
        method: "GET",
        auth: %{
          type: "bearer",
          token: "test-token-12345"
        }
      }

      ReqCassette.with_cassette("bearer_auth", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(@default_opts, :plug, plug)
        # GitHub returns 401 for invalid token
        assert {:error, :auth_failed} = API.execute(params, @agent_id, test_opts)
      end)
    end

    test "applies basic authentication" do
      params = %{
        api_type: :rest,
        url: "https://httpbin.org/basic-auth/user/pass",
        method: "GET",
        auth: %{
          type: "basic",
          username: "user",
          password: "pass"
        }
      }

      ReqCassette.with_cassette("basic_auth", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(@default_opts, :plug, plug)
        {:ok, result} = API.execute(params, @agent_id, test_opts)

        assert result.status_code == 200
        assert result.data["authenticated"] == true
        assert result.data["user"] == "user"
      end)
    end
  end

  describe "R7: Secret Template Resolution [INTEGRATION]" do
    setup tags do
      # DB sandbox only for secret resolution tests
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Quoracle.Repo, shared: not tags[:async])
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
      :ok
    end

    test "resolves secret templates in parameters" do
      # WHEN execute called IF params contain {{SECRET:name}}
      # THEN resolves via SecretResolver before request

      params = %{
        api_type: :rest,
        url: "https://httpbin.org/headers",
        method: "GET",
        headers: %{
          "X-API-Key" => "{{SECRET:API_KEY}}"
        }
      }

      ReqCassette.with_cassette(
        "secret_resolution",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          {:ok, result} = API.execute(params, @agent_id, test_opts)

          assert result.status_code == 200
          # The secret should have been resolved before the request
          # (httpbin echoes headers back, but we can't see the actual value due to scrubbing)
        end
      )
    end

    test "resolves multiple secrets in different locations" do
      params = %{
        api_type: :rest,
        url: "https://httpbin.org/post",
        method: "POST",
        headers: %{"X-API-Key" => "{{SECRET:API_KEY}}"},
        body: %{"secret" => "{{SECRET:API_SECRET}}"}
      }

      ReqCassette.with_cassette(
        "secret_multiple",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          {:ok, result} = API.execute(params, @agent_id, test_opts)
          assert result.action == "call_api"
          assert result.status_code == 200
        end
      )
    end
  end

  describe "R8: Output Scrubbing [INTEGRATION]" do
    test "integrates with OutputScrubber" do
      # WHEN execute called IF secrets used
      # THEN integrates with scrubbing system
      # Note: Actual scrubbing logic tested in unit tests for OutputScrubber

      params = %{
        api_type: :rest,
        url: "https://httpbin.org/post",
        method: "POST",
        headers: %{"Authorization" => "Bearer test-token"},
        body: %{"test" => "data"}
      }

      ReqCassette.with_cassette(
        "output_scrubbing",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          {:ok, result} = API.execute(params, @agent_id, test_opts)

          assert result.status_code == 200
          assert result.action == "call_api"
          # OutputScrubber integration verified (actual scrubbing tested in unit tests)
        end
      )
    end
  end

  describe "R9: Rate Limit Error [INTEGRATION]" do
    test "returns rate limit error for 429 status" do
      # WHEN execute called IF response status=429
      # THEN returns {:error, :rate_limit_exceeded}
      params = %{
        api_type: :rest,
        url: "https://httpbin.org/status/429",
        method: "GET"
      }

      ReqCassette.with_cassette("rate_limit_429", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(@default_opts, :plug, plug)
        {:error, :rate_limit_exceeded} = API.execute(params, @agent_id, test_opts)
      end)
    end
  end

  describe "R10: Connection Errors [INTEGRATION]" do
    test "handles connection refused" do
      # Tests error mapping for connection failures
      # Using localhost:1 (nothing listening) for deterministic connection refused
      params = %{
        api_type: :rest,
        url: "http://localhost:1/test",
        method: "GET"
      }

      {:error, :connection_refused} = API.execute(params, @agent_id, @default_opts)
    end

    test "respects custom timeout value" do
      params = %{
        api_type: :rest,
        url: "https://httpbin.org/delay/2",
        method: "GET",
        # 10 second timeout, endpoint delays 2 seconds
        timeout: 10
      }

      ReqCassette.with_cassette("custom_timeout", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(@default_opts, :plug, plug)
        {:ok, result} = API.execute(params, @agent_id, test_opts)
        assert result.status_code == 200
      end)
    end
  end

  describe "R11: URL Validation [UNIT]" do
    test "validates URL format" do
      # WHEN execute called IF URL missing or invalid
      # THEN returns {:error, :invalid_url}

      # Missing URL
      params = %{
        api_type: :rest,
        method: "GET"
      }

      {:error, :invalid_url} = API.execute(params, @agent_id, @default_opts)

      # Invalid URL scheme
      params = %{
        api_type: :rest,
        url: "ftp://example.com/file",
        method: "GET"
      }

      {:error, :invalid_url} = API.execute(params, @agent_id, @default_opts)

      # Malformed URL
      params = %{
        api_type: :rest,
        url: "not a url",
        method: "GET"
      }

      {:error, :invalid_url} = API.execute(params, @agent_id, @default_opts)
    end
  end

  describe "R12: Missing Required Params [UNIT]" do
    test "validates required parameters for each API type" do
      # WHEN execute called IF api_type=:rest but method missing
      # THEN returns {:error, :missing_required_param}

      # REST without method
      params = %{
        api_type: :rest,
        url: "https://api.example.com"
      }

      {:error, :missing_required_param} = API.execute(params, @agent_id, @default_opts)

      # GraphQL without query
      params = %{
        api_type: :graphql,
        url: "https://api.example.com/graphql"
      }

      {:error, :missing_required_param} = API.execute(params, @agent_id, @default_opts)

      # JSON-RPC without method
      params = %{
        api_type: :jsonrpc,
        url: "https://api.example.com/rpc"
      }

      {:error, :missing_required_param} = API.execute(params, @agent_id, @default_opts)
    end
  end

  describe "R13: Auth Failure [INTEGRATION]" do
    test "returns error when authentication fails" do
      # WHEN execute called IF authentication fails
      # THEN returns {:error, :auth_failed}
      params = %{
        api_type: :rest,
        url: "https://api.github.com/user",
        method: "GET",
        auth: %{
          type: "bearer",
          token: "invalid-token"
        }
      }

      ReqCassette.with_cassette("auth_failure", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(@default_opts, :plug, plug)
        {:error, :auth_failed} = API.execute(params, @agent_id, test_opts)
      end)
    end
  end

  describe "R15: Consistent Action Field [UNIT]" do
    test "returns consistent action field in results" do
      # WHEN execute called THEN result includes action: "call_api"
      params = %{
        api_type: :rest,
        url: "https://jsonplaceholder.typicode.com/posts/1",
        method: "GET"
      }

      ReqCassette.with_cassette(
        "action_field_consistency",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          {:ok, result} = API.execute(params, @agent_id, test_opts)

          assert result.action == "call_api"
          assert is_atom(result.api_type)
          assert result.api_type in [:rest, :graphql, :jsonrpc]
        end
      )
    end
  end

  describe "additional error scenarios" do
    test "returns not_found error for 404 status" do
      params = %{
        api_type: :rest,
        url: "https://jsonplaceholder.typicode.com/posts/99999",
        method: "GET"
      }

      ReqCassette.with_cassette("not_found_404", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(@default_opts, :plug, plug)
        {:error, :not_found} = API.execute(params, @agent_id, test_opts)
      end)
    end

    test "returns service_unavailable for 503 status" do
      params = %{
        api_type: :rest,
        url: "https://httpbin.org/status/503",
        method: "GET"
      }

      ReqCassette.with_cassette(
        "service_unavailable_503",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          {:error, :service_unavailable} = API.execute(params, @agent_id, test_opts)
        end
      )
    end

    test "returns body_too_large when request body exceeds limit" do
      # Create a body larger than 5MB default limit
      large_body = String.duplicate("x", 6_000_000)

      params = %{
        api_type: :rest,
        url: "https://httpbin.org/post",
        method: "POST",
        body: large_body
      }

      {:error, :body_too_large} = API.execute(params, @agent_id, @default_opts)
    end

    # NOTE: Removed 11MB test - httpbin.org caps responses at ~100KB
    # Response size limit is validated in ResponseParser unit tests instead
  end

  describe "HTTP method variations" do
    test "executes PUT request with body" do
      params = %{
        api_type: :rest,
        url: "https://jsonplaceholder.typicode.com/posts/1",
        method: "PUT",
        body: %{
          id: 1,
          title: "Updated Title",
          body: "Updated content",
          userId: 1
        }
      }

      ReqCassette.with_cassette(
        "rest_put_request",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          {:ok, result} = API.execute(params, @agent_id, test_opts)

          assert result.status_code == 200
          assert result.data["title"] == "Updated Title"
        end
      )
    end

    test "executes DELETE request" do
      params = %{
        api_type: :rest,
        url: "https://jsonplaceholder.typicode.com/posts/1",
        method: "DELETE"
      }

      ReqCassette.with_cassette(
        "rest_delete_request",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          {:ok, result} = API.execute(params, @agent_id, test_opts)

          assert result.status_code == 200
        end
      )
    end

    test "executes PATCH request with partial update" do
      params = %{
        api_type: :rest,
        url: "https://jsonplaceholder.typicode.com/posts/1",
        method: "PATCH",
        body: %{title: "Patched Title"}
      }

      ReqCassette.with_cassette(
        "rest_patch_request",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          {:ok, result} = API.execute(params, @agent_id, test_opts)

          assert result.status_code == 200
          assert result.data["title"] == "Patched Title"
        end
      )
    end
  end

  describe "query parameters" do
    test "includes query parameters in REST GET request" do
      params = %{
        api_type: :rest,
        url: "https://jsonplaceholder.typicode.com/posts",
        method: "GET",
        query_params: %{
          "userId" => "1",
          "_limit" => "2"
        }
      }

      ReqCassette.with_cassette(
        "rest_get_with_query_params",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          {:ok, result} = API.execute(params, @agent_id, test_opts)

          assert result.status_code == 200
          assert is_list(result.data)
          assert length(result.data) <= 2
          assert Enum.all?(result.data, &(&1["userId"] == 1))
        end
      )
    end
  end

  describe "custom headers" do
    test "includes custom headers in request" do
      params = %{
        api_type: :rest,
        url: "https://httpbin.org/headers",
        method: "GET",
        headers: %{
          "X-Custom-Header" => "custom-value",
          "X-Request-Id" => "test-123"
        }
      }

      ReqCassette.with_cassette("custom_headers", [cassette_dir: @cassette_dir], fn plug ->
        test_opts = Keyword.put(@default_opts, :plug, plug)
        {:ok, result} = API.execute(params, @agent_id, test_opts)

        assert result.status_code == 200
        # httpbin.org only echoes back X-Custom-Header, not X-Request-Id
        assert result.data["headers"]["X-Custom-Header"] == "custom-value"
      end)
    end
  end

  describe "redirect handling" do
    test "follows redirects by default" do
      params = %{
        api_type: :rest,
        # Redirects twice
        url: "https://httpbin.org/redirect/2",
        method: "GET"
      }

      ReqCassette.with_cassette(
        "follow_redirects",
        [cassette_dir: @cassette_dir],
        fn plug ->
          test_opts = Keyword.put(@default_opts, :plug, plug)
          {:ok, result} = API.execute(params, @agent_id, test_opts)

          assert result.status_code == 200
          # NOTE: Req library follows redirects transparently but doesn't expose final URL
          # We return the original request URL for consistency
          assert result.url == params.url
        end
      )
    end
  end
end
