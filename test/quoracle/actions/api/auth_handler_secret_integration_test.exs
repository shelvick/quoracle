defmodule Quoracle.Actions.API.AuthHandlerSecretIntegrationTest do
  @moduledoc """
  Integration tests for AuthHandler with SecretResolver.
  Tests secret template resolution in authentication parameters.
  """

  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Actions.API.AuthHandler
  alias Quoracle.Models.TableSecrets

  describe "Bearer token with secret templates [INTEGRATION]" do
    setup do
      # Create test secrets
      {:ok, _} = TableSecrets.create(%{name: "bearer_token", value: "actual-bearer-123"})
      {:ok, _} = TableSecrets.create(%{name: "api_key", value: "actual-key-456"})
      :ok
    end

    test "resolves {{SECRET:name}} in Bearer token before applying auth" do
      request = %{headers: %{}}

      params = %{
        auth_type: "bearer",
        auth_token: "{{SECRET:bearer_token}}"
      }

      # Should resolve template before applying auth
      {:ok, enhanced} = AuthHandler.apply_auth_with_secrets(request, params)

      # Should have resolved token
      assert enhanced.headers["authorization"] == "Bearer actual-bearer-123"
    end

    test "resolves multiple secrets in Bearer with custom header" do
      request = %{headers: %{}}

      params = %{
        auth_type: "bearer",
        auth_token: "{{SECRET:bearer_token}}",
        auth_header_name: "x-custom-{{SECRET:api_key}}"
      }

      {:ok, enhanced} = AuthHandler.apply_auth_with_secrets(request, params)

      # Should resolve both the token and header name
      assert enhanced.headers["x-custom-actual-key-456"] == "Bearer actual-bearer-123"
    end

    test "keeps literal template when secret not found" do
      request = %{headers: %{}}

      params = %{
        auth_type: "bearer",
        auth_token: "{{SECRET:nonexistent}}"
      }

      # Missing secrets pass-through as literals (capture expected warning)
      capture_log(fn ->
        {:ok, enhanced} = AuthHandler.apply_auth_with_secrets(request, params)
        # Template kept as literal in the Authorization header
        assert enhanced.headers["authorization"] == "Bearer {{SECRET:nonexistent}}"
      end)
    end
  end

  describe "Basic auth with secret templates [INTEGRATION]" do
    setup do
      {:ok, _} = TableSecrets.create(%{name: "basic_user", value: "actual-user"})
      {:ok, _} = TableSecrets.create(%{name: "basic_pass", value: "actual-pass"})
      :ok
    end

    test "resolves templates in Basic auth credentials" do
      request = %{headers: %{}}

      params = %{
        auth_type: "basic",
        auth_username: "{{SECRET:basic_user}}",
        auth_password: "{{SECRET:basic_pass}}"
      }

      {:ok, enhanced} = AuthHandler.apply_auth_with_secrets(request, params)

      # Should have resolved and encoded
      expected = Base.encode64("actual-user:actual-pass")
      assert enhanced.headers["authorization"] == "Basic #{expected}"
    end

    test "resolves partial template in Basic auth" do
      request = %{headers: %{}}

      params = %{
        auth_type: "basic",
        auth_username: "user-{{SECRET:basic_user}}",
        auth_password: "{{SECRET:basic_pass}}-suffix"
      }

      {:ok, enhanced} = AuthHandler.apply_auth_with_secrets(request, params)

      expected = Base.encode64("user-actual-user:actual-pass-suffix")
      assert enhanced.headers["authorization"] == "Basic #{expected}"
    end
  end

  describe "API key auth with secret templates [INTEGRATION]" do
    setup do
      {:ok, _} = TableSecrets.create(%{name: "api_key", value: "actual-key-789"})
      {:ok, _} = TableSecrets.create(%{name: "key_name", value: "X-Real-Key"})
      :ok
    end

    test "resolves template in API key header" do
      request = %{headers: %{}}

      params = %{
        auth_type: "api_key",
        auth_key_name: "X-API-Key",
        auth_key_value: "{{SECRET:api_key}}",
        auth_key_location: "header"
      }

      {:ok, enhanced} = AuthHandler.apply_auth_with_secrets(request, params)

      assert enhanced.headers["X-API-Key"] == "actual-key-789"
    end

    test "resolves template in API key query param" do
      request = %{headers: %{}, query: %{}}

      params = %{
        auth_type: "api_key",
        auth_key_name: "api_key",
        auth_key_value: "{{SECRET:api_key}}",
        auth_key_location: "query"
      }

      {:ok, enhanced} = AuthHandler.apply_auth_with_secrets(request, params)

      assert enhanced.query["api_key"] == "actual-key-789"
    end

    test "resolves template in both key name and value" do
      request = %{headers: %{}}

      params = %{
        auth_type: "api_key",
        auth_key_name: "{{SECRET:key_name}}",
        auth_key_value: "{{SECRET:api_key}}",
        auth_key_location: "header"
      }

      {:ok, enhanced} = AuthHandler.apply_auth_with_secrets(request, params)

      assert enhanced.headers["X-Real-Key"] == "actual-key-789"
    end
  end

  describe "OAuth2 with secret templates [INTEGRATION]" do
    setup do
      {:ok, _} = TableSecrets.create(%{name: "oauth_client", value: "actual-client-id"})
      {:ok, _} = TableSecrets.create(%{name: "oauth_secret", value: "actual-client-secret"})
      :ok
    end

    test "resolves templates in OAuth2 credentials" do
      request = %{headers: %{}}

      params = %{
        auth_type: "oauth2_client_credentials",
        auth_client_id: "{{SECRET:oauth_client}}",
        auth_client_secret: "{{SECRET:oauth_secret}}",
        auth_token_url: "https://oauth.example.com/token"
      }

      {:ok, enhanced} = AuthHandler.apply_auth_with_secrets(request, params)

      # Should have exchanged with resolved credentials
      # The stub will use the resolved values to determine token
      assert {"authorization", _} =
               Enum.find(enhanced.headers, fn {key, _} -> key == "authorization" end)
    end
  end

  describe "No auth with templates [INTEGRATION]" do
    test "returns unchanged when auth_type is none even with templates" do
      request = %{headers: %{}}

      params = %{
        auth_type: "none",
        some_field: "{{SECRET:anything}}"
      }

      {:ok, enhanced} = AuthHandler.apply_auth_with_secrets(request, params)

      assert enhanced == request
    end
  end

  describe "Integration with SecretResolver [INTEGRATION]" do
    test "delegates template resolution to SecretResolver with pass-through for missing" do
      params = %{
        auth_type: "bearer",
        auth_token: "{{SECRET:test_token}}"
      }

      # Should use SecretResolver internally, missing secrets kept as literals (capture warning)
      capture_log(fn ->
        {:ok, resolved, used} = AuthHandler.resolve_auth_secrets(params)
        assert resolved.auth_token == "{{SECRET:test_token}}"
        assert used == %{}
      end)
    end

    test "tracks which secrets were used" do
      {:ok, _} = TableSecrets.create(%{name: "tracked", value: "value"})

      params = %{
        auth_type: "bearer",
        auth_token: "{{SECRET:tracked}}"
      }

      {:ok, resolved, used_secrets} = AuthHandler.resolve_auth_secrets(params)

      assert resolved.auth_token == "value"
      assert used_secrets == %{"tracked" => "value"}
    end

    test "preserves non-auth fields during resolution" do
      {:ok, _} = TableSecrets.create(%{name: "token", value: "resolved"})

      params = %{
        auth_type: "bearer",
        auth_token: "{{SECRET:token}}",
        other_field: "untouched",
        nested: %{data: "preserved"}
      }

      {:ok, resolved, _} = AuthHandler.resolve_auth_secrets(params)

      assert resolved.auth_token == "resolved"
      assert resolved.other_field == "untouched"
      assert resolved.nested == %{data: "preserved"}
    end
  end

  describe "Error handling [INTEGRATION]" do
    test "missing secrets kept as literals" do
      params = %{
        auth_type: "bearer",
        auth_token: "{{SECRET:missing}}"
      }

      # Missing secrets pass-through as literals (capture expected warning)
      capture_log(fn ->
        {:ok, enhanced} =
          AuthHandler.apply_auth_with_secrets(%{headers: %{}}, params)

        # Literal template ends up in auth header
        assert enhanced.headers["authorization"] == "Bearer {{SECRET:missing}}"
      end)
    end

    test "validates templates before attempting resolution" do
      params = %{
        auth_type: "api_key",
        auth_key_name: "{{INVALID:syntax}}",
        auth_key_value: "value"
      }

      # Should not resolve invalid syntax
      {:ok, enhanced} = AuthHandler.apply_auth_with_secrets(%{headers: %{}}, params)

      # Invalid template treated as literal
      assert enhanced.headers["{{INVALID:syntax}}"] == "value"
    end
  end
end
