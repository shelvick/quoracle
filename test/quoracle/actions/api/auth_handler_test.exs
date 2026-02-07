defmodule Quoracle.Actions.API.AuthHandlerTest do
  @moduledoc """
  Tests for API authentication handler module.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Actions.API.AuthHandler

  describe "apply_auth/2 - Bearer token authentication" do
    test "adds Bearer token to Authorization header" do
      request = %{headers: %{}}
      params = %{auth_type: "bearer", auth_token: "secret123"}

      {:ok, enhanced} = AuthHandler.apply_auth(request, params)

      assert enhanced.headers["authorization"] == "Bearer secret123"
    end

    test "resolves Bearer token template from secrets" do
      request = %{headers: %{}}
      params = %{auth_type: "bearer", auth_token: "{{my_token}}"}

      # Should resolve template using SecretResolver
      {:ok, enhanced} = AuthHandler.apply_auth(request, params)
      assert enhanced.headers["authorization"] == "Bearer resolved_token"
    end

    test "returns error when Bearer token is missing" do
      request = %{headers: %{}}
      params = %{auth_type: "bearer"}

      assert {:error, :missing_auth_token} = AuthHandler.apply_auth(request, params)
    end
  end

  describe "apply_auth/2 - Basic authentication" do
    test "adds Basic auth to Authorization header" do
      request = %{headers: %{}}

      params = %{
        auth_type: "basic",
        auth_username: "user",
        auth_password: "pass"
      }

      {:ok, enhanced} = AuthHandler.apply_auth(request, params)

      # user:pass base64 encoded = dXNlcjpwYXNz
      assert enhanced.headers["authorization"] == "Basic dXNlcjpwYXNz"
    end

    test "resolves Basic auth credentials from secrets" do
      request = %{headers: %{}}

      params = %{
        auth_type: "basic",
        auth_username: "{{username}}",
        auth_password: "{{password}}"
      }

      {:ok, enhanced} = AuthHandler.apply_auth(request, params)

      # Should have resolved credentials and base64 encoded them
      expected_encoded = Base.encode64("resolved_user:resolved_pass")
      assert enhanced.headers["authorization"] == "Basic #{expected_encoded}"
    end

    test "returns error when Basic auth credentials are missing" do
      request = %{headers: %{}}

      assert {:error, :missing_auth_username} =
               AuthHandler.apply_auth(request, %{auth_type: "basic", auth_password: "pass"})

      assert {:error, :missing_auth_password} =
               AuthHandler.apply_auth(request, %{auth_type: "basic", auth_username: "user"})
    end
  end

  describe "apply_auth/2 - API key authentication" do
    test "adds API key to custom header" do
      request = %{headers: %{}}

      params = %{
        auth_type: "api_key",
        auth_key_name: "x-api-key",
        auth_key_value: "secret123",
        auth_key_location: "header"
      }

      {:ok, enhanced} = AuthHandler.apply_auth(request, params)

      assert enhanced.headers["x-api-key"] == "secret123"
    end

    test "adds API key to query parameters" do
      request = %{headers: [], query: %{}}

      params = %{
        auth_type: "api_key",
        auth_key_name: "api_key",
        auth_key_value: "secret123",
        auth_key_location: "query"
      }

      {:ok, enhanced} = AuthHandler.apply_auth(request, params)

      assert enhanced.query["api_key"] == "secret123"
    end

    test "resolves API key from secrets" do
      request = %{headers: %{}}

      params = %{
        auth_type: "api_key",
        auth_key_name: "x-api-key",
        auth_key_value: "{{api_key}}",
        auth_key_location: "header"
      }

      {:ok, enhanced} = AuthHandler.apply_auth(request, params)
      assert enhanced.headers["x-api-key"] == "resolved_key"
    end

    test "defaults to header location when not specified" do
      request = %{headers: %{}}

      params = %{
        auth_type: "api_key",
        auth_key_name: "x-api-key",
        auth_key_value: "secret123"
      }

      {:ok, enhanced} = AuthHandler.apply_auth(request, params)

      assert enhanced.headers["x-api-key"] == "secret123"
    end

    test "returns error when API key details are missing" do
      request = %{headers: %{}}

      assert {:error, :missing_auth_key_name} =
               AuthHandler.apply_auth(request, %{auth_type: "api_key", auth_key_value: "val"})

      assert {:error, :missing_auth_key_value} =
               AuthHandler.apply_auth(request, %{auth_type: "api_key", auth_key_name: "name"})
    end

    test "returns error for invalid API key location" do
      request = %{headers: %{}}

      params = %{
        auth_type: "api_key",
        auth_key_name: "x-api-key",
        auth_key_value: "secret123",
        auth_key_location: "invalid"
      }

      assert {:error, :invalid_auth_key_location} = AuthHandler.apply_auth(request, params)
    end
  end

  describe "apply_auth/2 - OAuth2 Client Credentials flow" do
    test "exchanges client credentials for access token" do
      request = %{headers: %{}}

      params = %{
        auth_type: "oauth2_client_credentials",
        auth_client_id: "client123",
        auth_client_secret: "secret456",
        auth_token_url: "https://oauth.example.com/token"
      }

      # Should exchange credentials for token and add to headers
      {:ok, enhanced} = AuthHandler.apply_auth(request, params)
      assert enhanced.headers["authorization"] == "Bearer cached_token"
    end

    test "resolves OAuth2 credentials from secrets" do
      request = %{headers: %{}}

      params = %{
        auth_type: "oauth2_client_credentials",
        auth_client_id: "{{client_id}}",
        auth_client_secret: "{{client_secret}}",
        auth_token_url: "https://oauth.example.com/token"
      }

      # Should resolve templates and exchange for token
      {:ok, enhanced} = AuthHandler.apply_auth(request, params)
      assert enhanced.headers["authorization"] == "Bearer token123"
    end

    test "returns error when OAuth2 token exchange fails" do
      request = %{headers: %{}}

      params = %{
        auth_type: "oauth2_client_credentials",
        auth_client_id: "invalid",
        auth_client_secret: "invalid",
        auth_token_url: "https://oauth.example.com/token"
      }

      # Should return error for invalid credentials
      assert {:error, :auth_failed} = AuthHandler.apply_auth(request, params)
    end

    test "returns error when OAuth2 credentials are missing" do
      request = %{headers: %{}}

      base_params = %{
        auth_type: "oauth2_client_credentials",
        auth_token_url: "https://oauth.example.com/token"
      }

      assert {:error, :missing_auth_client_id} =
               AuthHandler.apply_auth(
                 request,
                 Map.merge(base_params, %{auth_client_secret: "secret"})
               )

      assert {:error, :missing_auth_client_secret} =
               AuthHandler.apply_auth(
                 request,
                 Map.merge(base_params, %{auth_client_id: "client"})
               )

      assert {:error, :missing_auth_token_url} =
               AuthHandler.apply_auth(request, %{
                 auth_type: "oauth2_client_credentials",
                 auth_client_id: "client",
                 auth_client_secret: "secret"
               })
    end

    test "caches access token for subsequent requests" do
      request = %{headers: %{}}

      params = %{
        auth_type: "oauth2_client_credentials",
        auth_client_id: "client123",
        auth_client_secret: "secret456",
        auth_token_url: "https://oauth.example.com/token"
      }

      # First call should exchange credentials
      {:ok, enhanced1} = AuthHandler.apply_auth(request, params)
      assert {"authorization", "Bearer cached_token"} in enhanced1.headers

      # Second call should use cached token (no HTTP call)
      {:ok, enhanced2} = AuthHandler.apply_auth(request, params)
      assert {"authorization", "Bearer cached_token"} in enhanced2.headers
    end
  end

  describe "apply_auth/2 - No authentication" do
    test "returns request unchanged when auth_type is none" do
      request = %{headers: [{"existing", "header"}]}
      params = %{auth_type: "none"}

      {:ok, enhanced} = AuthHandler.apply_auth(request, params)

      assert enhanced == request
    end

    test "returns request unchanged when auth_type is not specified" do
      request = %{headers: [{"existing", "header"}]}
      params = %{}

      {:ok, enhanced} = AuthHandler.apply_auth(request, params)

      assert enhanced == request
    end
  end

  describe "apply_auth/2 - Custom authentication header" do
    test "supports custom authentication header name" do
      request = %{headers: %{}}

      params = %{
        auth_type: "bearer",
        auth_token: "secret123",
        auth_header_name: "x-custom-auth"
      }

      {:ok, enhanced} = AuthHandler.apply_auth(request, params)

      assert enhanced.headers["x-custom-auth"] == "Bearer secret123"
      refute Enum.any?(enhanced.headers, fn {key, _val} -> key == "authorization" end)
    end
  end

  describe "apply_auth/2 - Validation" do
    test "returns error for unsupported auth_type" do
      request = %{headers: %{}}
      params = %{auth_type: "unsupported"}

      assert {:error, :unsupported_auth_type} = AuthHandler.apply_auth(request, params)
    end

    test "validates auth_type parameter against supported types" do
      supported_types = ["none", "bearer", "basic", "api_key", "oauth2_client_credentials"]

      for auth_type <- supported_types do
        assert AuthHandler.supported_auth_type?(auth_type) == true
      end

      assert AuthHandler.supported_auth_type?("invalid") == false
    end
  end

  describe "format_auth_error/1" do
    test "formats authentication errors for user display" do
      assert AuthHandler.format_auth_error(:missing_auth_token) ==
               "Missing auth_token parameter for Bearer authentication"

      assert AuthHandler.format_auth_error(:auth_failed) ==
               "Authentication failed: Invalid credentials or unauthorized"

      assert AuthHandler.format_auth_error(:unsupported_auth_type) ==
               "Unsupported authentication type. Supported: none, bearer, basic, api_key, oauth2_client_credentials"
    end
  end
end
