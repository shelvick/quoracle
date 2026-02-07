defmodule Quoracle.Actions.API.ResponseScrubbingIntegrationTest do
  @moduledoc """
  Integration tests for API response scrubbing with OutputScrubber.
  Tests that secret values are removed from API responses before returning to agents.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.API
  alias Quoracle.Models.TableSecrets

  describe "REST API response scrubbing [INTEGRATION]" do
    setup do
      # Create test secrets that might appear in responses
      {:ok, _} = TableSecrets.create(%{name: "api_key", value: "secret-key-123456789"})
      {:ok, _} = TableSecrets.create(%{name: "password", value: "secret-pass-abcdefgh"})
      :ok
    end

    test "scrubs secret values from REST response body" do
      # Simulate API response containing secret value
      response = %{
        status_code: 200,
        body: %{
          "data" => "The API key is secret-key-123456789",
          "config" => %{
            "auth" => "Bearer secret-key-123456789",
            "password" => "secret-pass-abcdefgh"
          }
        }
      }

      # Get secrets that were used (would come from request resolution)
      used_secrets = %{
        "api_key" => "secret-key-123456789",
        "password" => "secret-pass-abcdefgh"
      }

      # Should scrub before returning
      scrubbed = API.scrub_response(response, used_secrets)

      assert scrubbed.body["data"] == "The API key is [REDACTED:api_key]"
      assert scrubbed.body["config"]["auth"] == "Bearer [REDACTED:api_key]"
      assert scrubbed.body["config"]["password"] == "[REDACTED:password]"
    end

    test "scrubs secrets from error messages" do
      response = %{
        status_code: 401,
        body: %{
          "error" => "Invalid API key: secret-key-123456789",
          "details" => "Authentication failed for key secret-key-123456789"
        }
      }

      used_secrets = %{"api_key" => "secret-key-123456789"}

      scrubbed = API.scrub_response(response, used_secrets)

      assert scrubbed.body["error"] == "Invalid API key: [REDACTED:api_key]"
      assert scrubbed.body["details"] == "Authentication failed for key [REDACTED:api_key]"
    end

    test "scrubs headers containing secrets" do
      response = %{
        status_code: 200,
        headers: [
          {"content-type", "application/json"},
          {"x-api-key", "secret-key-123456789"},
          {"authorization", "Bearer secret-key-123456789"}
        ],
        body: %{"status" => "ok"}
      }

      used_secrets = %{"api_key" => "secret-key-123456789"}

      scrubbed = API.scrub_response(response, used_secrets)

      # Headers should be scrubbed
      assert {"x-api-key", "[REDACTED:api_key]"} in scrubbed.headers
      assert {"authorization", "Bearer [REDACTED:api_key]"} in scrubbed.headers
      assert {"content-type", "application/json"} in scrubbed.headers
    end

    test "preserves response structure while scrubbing" do
      response = %{
        status_code: 200,
        body: %{
          "users" => [
            %{"id" => 1, "token" => "secret-key-123456789"},
            %{"id" => 2, "token" => "different-token"}
          ],
          "meta" => %{"total" => 2}
        }
      }

      used_secrets = %{"api_key" => "secret-key-123456789"}

      scrubbed = API.scrub_response(response, used_secrets)

      # Structure preserved, only secret value scrubbed
      assert length(scrubbed.body["users"]) == 2
      assert scrubbed.body["users"] |> Enum.at(0) |> Map.get("token") == "[REDACTED:api_key]"
      assert scrubbed.body["users"] |> Enum.at(1) |> Map.get("token") == "different-token"
      assert scrubbed.body["meta"]["total"] == 2
    end
  end

  describe "GraphQL response scrubbing [INTEGRATION]" do
    setup do
      {:ok, _} = TableSecrets.create(%{name: "graphql_token", value: "gql-secret-xyz"})
      :ok
    end

    test "scrubs GraphQL data response" do
      response = %{
        status_code: 200,
        body: %{
          "data" => %{
            "user" => %{
              "id" => "123",
              "apiKey" => "gql-secret-xyz",
              "profile" => %{
                "token" => "gql-secret-xyz"
              }
            }
          }
        }
      }

      used_secrets = %{"graphql_token" => "gql-secret-xyz"}

      scrubbed = API.scrub_response(response, used_secrets)

      assert scrubbed.body["data"]["user"]["apiKey"] == "[REDACTED:graphql_token]"
      assert scrubbed.body["data"]["user"]["profile"]["token"] == "[REDACTED:graphql_token]"
    end

    test "scrubs GraphQL error messages" do
      response = %{
        status_code: 200,
        body: %{
          "errors" => [
            %{
              "message" => "Invalid token: gql-secret-xyz",
              "extensions" => %{
                "code" => "UNAUTHENTICATED",
                "token" => "gql-secret-xyz"
              }
            }
          ]
        }
      }

      used_secrets = %{"graphql_token" => "gql-secret-xyz"}

      scrubbed = API.scrub_response(response, used_secrets)

      assert scrubbed.body["errors"] |> Enum.at(0) |> Map.get("message") ==
               "Invalid token: [REDACTED:graphql_token]"

      assert scrubbed.body["errors"] |> Enum.at(0) |> get_in(["extensions", "token"]) ==
               "[REDACTED:graphql_token]"
    end

    test "scrubs GraphQL partial success (data + errors)" do
      response = %{
        status_code: 200,
        body: %{
          "data" => %{
            "user" => %{"id" => "123", "name" => "Alice"}
          },
          "errors" => [
            %{
              "message" => "Field 'secret' requires token gql-secret-xyz",
              "path" => ["user", "secret"]
            }
          ]
        }
      }

      used_secrets = %{"graphql_token" => "gql-secret-xyz"}

      scrubbed = API.scrub_response(response, used_secrets)

      # Data unchanged
      assert scrubbed.body["data"]["user"]["name"] == "Alice"

      # Error message scrubbed
      assert scrubbed.body["errors"] |> Enum.at(0) |> Map.get("message") ==
               "Field 'secret' requires token [REDACTED:graphql_token]"
    end
  end

  describe "JSON-RPC response scrubbing [INTEGRATION]" do
    setup do
      {:ok, _} = TableSecrets.create(%{name: "rpc_key", value: "rpc-secret-12345"})
      :ok
    end

    test "scrubs JSON-RPC result response" do
      response = %{
        status_code: 200,
        body: %{
          "jsonrpc" => "2.0",
          "id" => "uuid-123",
          "result" => %{
            "apiKey" => "rpc-secret-12345",
            "data" => "Token is rpc-secret-12345"
          }
        }
      }

      used_secrets = %{"rpc_key" => "rpc-secret-12345"}

      scrubbed = API.scrub_response(response, used_secrets)

      assert scrubbed.body["result"]["apiKey"] == "[REDACTED:rpc_key]"
      assert scrubbed.body["result"]["data"] == "Token is [REDACTED:rpc_key]"

      # Protocol fields unchanged
      assert scrubbed.body["jsonrpc"] == "2.0"
      assert scrubbed.body["id"] == "uuid-123"
    end

    test "scrubs JSON-RPC error response" do
      response = %{
        status_code: 200,
        body: %{
          "jsonrpc" => "2.0",
          "id" => "uuid-456",
          "error" => %{
            "code" => -32602,
            "message" => "Invalid params",
            "data" => "API key rpc-secret-12345 is invalid"
          }
        }
      }

      used_secrets = %{"rpc_key" => "rpc-secret-12345"}

      scrubbed = API.scrub_response(response, used_secrets)

      assert scrubbed.body["error"]["data"] == "API key [REDACTED:rpc_key] is invalid"
      assert scrubbed.body["error"]["code"] == -32602
      assert scrubbed.body["error"]["message"] == "Invalid params"
    end
  end

  describe "Integration with OutputScrubber [INTEGRATION]" do
    test "delegates scrubbing to OutputScrubber module" do
      response = %{
        status_code: 200,
        body: %{"key" => "secret-value-xyz"}
      }

      used_secrets = %{"my_secret" => "secret-value-xyz"}

      # Should use OutputScrubber internally
      scrubbed = API.scrub_response(response, used_secrets)

      assert scrubbed.body["key"] == "[REDACTED:my_secret]"
    end

    test "handles complex nested structures" do
      response = %{
        status_code: 200,
        body: %{
          "level1" => %{
            "level2" => %{
              "level3" => ["item1", "complex-secret-999", "item3"],
              "data" => %{"secret" => "complex-secret-999"}
            }
          }
        }
      }

      used_secrets = %{"nested" => "complex-secret-999"}

      scrubbed = API.scrub_response(response, used_secrets)

      assert scrubbed.body["level1"]["level2"]["level3"] ==
               ["item1", "[REDACTED:nested]", "item3"]

      assert scrubbed.body["level1"]["level2"]["data"]["secret"] == "[REDACTED:nested]"
    end

    test "only scrubs secrets that were actually used" do
      {:ok, _} = TableSecrets.create(%{name: "unused", value: "unused-secret"})

      response = %{
        status_code: 200,
        body: %{
          "data" => "Contains unused-secret and used-secret",
          "key" => "used-secret"
        }
      }

      # Only secrets that were used in the request
      used_secrets = %{"used" => "used-secret"}

      scrubbed = API.scrub_response(response, used_secrets)

      # Only used secret is scrubbed (but it will also replace partial matches)
      assert scrubbed.body["data"] == "Contains un[REDACTED:used] and [REDACTED:used]"
      assert scrubbed.body["key"] == "[REDACTED:used]"
    end

    test "preserves nil and non-string values" do
      response = %{
        status_code: 200,
        body: %{
          "string" => "has-secret-123",
          "number" => 42,
          "boolean" => true,
          "null" => nil,
          "list" => [1, 2, "has-secret-123", 4],
          "atom" => :some_atom
        }
      }

      used_secrets = %{"key" => "has-secret-123"}

      scrubbed = API.scrub_response(response, used_secrets)

      assert scrubbed.body["string"] == "[REDACTED:key]"
      assert scrubbed.body["number"] == 42
      assert scrubbed.body["boolean"] == true
      assert scrubbed.body["null"] == nil
      assert scrubbed.body["list"] == [1, 2, "[REDACTED:key]", 4]
      assert scrubbed.body["atom"] == :some_atom
    end
  end

  describe "Error tuple scrubbing [INTEGRATION]" do
    test "scrubs error tuples from failed API calls" do
      error = {:error, :api_error, "Failed with key: sensitive-key-999"}
      used_secrets = %{"api_key" => "sensitive-key-999"}

      scrubbed = API.scrub_error(error, used_secrets)

      assert scrubbed == {:error, :api_error, "Failed with key: [REDACTED:api_key]"}
    end

    test "scrubs complex error structures" do
      error =
        {:error,
         %{
           message: "Authentication failed",
           details: %{
             provided_key: "sensitive-key-999",
             endpoint: "/api/v1/auth"
           }
         }}

      used_secrets = %{"api_key" => "sensitive-key-999"}

      scrubbed = API.scrub_error(error, used_secrets)

      assert {:error, %{details: details}} = scrubbed
      assert details.provided_key == "[REDACTED:api_key]"
      assert details.endpoint == "/api/v1/auth"
    end
  end
end
