defmodule Quoracle.Security.OutputScrubberTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Quoracle.Security.OutputScrubber

  describe "scrub_result/2" do
    # R1: String Scrubbing
    test "scrubs secret from string output" do
      result = "The API key is: secret123abc and it works"
      secrets_used = %{"api_key" => "secret123abc"}

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      assert scrubbed == "The API key is: [REDACTED:api_key] and it works"
    end

    # R2: Multiple Secrets
    test "scrubs multiple different secrets" do
      result = "Connect with user:password456 to api.example.com with token789"

      secrets_used = %{
        "db_pass" => "password456",
        "api_token" => "token789"
      }

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)

      assert scrubbed ==
               "Connect with user:[REDACTED:db_pass] to api.example.com with [REDACTED:api_token]"
    end

    # R3: Nested Map Scrubbing
    test "scrubs secrets from nested maps" do
      result = %{
        "status" => "ok",
        "config" => %{
          "auth" => %{
            "token" => "secret_token_123",
            "user" => "admin"
          },
          "database" => %{
            "password" => "db_pass_456",
            "host" => "localhost"
          }
        }
      }

      secrets_used = %{
        "api_token" => "secret_token_123",
        "db_password" => "db_pass_456"
      }

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      assert scrubbed["status"] == "ok"
      assert scrubbed["config"]["auth"]["token"] == "[REDACTED:api_token]"
      assert scrubbed["config"]["auth"]["user"] == "admin"
      assert scrubbed["config"]["database"]["password"] == "[REDACTED:db_password]"
      assert scrubbed["config"]["database"]["host"] == "localhost"
    end

    # R4: List Scrubbing
    test "scrubs secrets from lists" do
      result = [
        "normal value",
        "contains secret123 here",
        %{"key" => "password456"},
        ["nested", "token789"]
      ]

      secrets_used = %{
        "api" => "secret123",
        "pass" => "password456",
        "tok" => "token789"
      }

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)

      assert scrubbed == [
               "normal value",
               "contains [REDACTED:api] here",
               %{"key" => "[REDACTED:pass]"},
               ["nested", "[REDACTED:tok]"]
             ]
    end

    # R5: Substring Scrubbing
    test "scrubs secret substring within larger string" do
      result = "Authorization: Bearer abc123xyz789 for endpoint"
      secrets_used = %{"token" => "abc123xyz789"}

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      assert scrubbed == "Authorization: Bearer [REDACTED:token] for endpoint"
    end

    # R6: Case Sensitivity
    test "scrubbing is case sensitive" do
      result = "Password: SECRET123 and secret123 and SeCrEt123"
      secrets_used = %{"pass" => "secret123"}

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      # Only exact case match should be scrubbed
      assert scrubbed == "Password: SECRET123 and [REDACTED:pass] and SeCrEt123"
    end

    # R7: Short Value Protection
    test "ignores short secret values" do
      result = "The key is abc and the password is short"

      secrets_used = %{
        # 3 chars - too short
        "key1" => "abc",
        # 5 chars - too short
        "key2" => "short"
      }

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      # Unchanged - values too short
      assert scrubbed == result
    end

    test "scrubs values longer than 8 characters" do
      result = "The key is abcdefghi"
      # 9 chars - should scrub
      secrets_used = %{"key" => "abcdefghi"}

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      assert scrubbed == "The key is [REDACTED:key]"
    end

    # R8: Order Independence
    test "processes longest secrets first" do
      result = "The value is secret123extended"

      secrets_used = %{
        "short" => "secret123",
        "long" => "secret123extended"
      }

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      # Should match the longer one, not create nested redaction
      assert scrubbed == "The value is [REDACTED:long]"
    end

    # R9: Structure Preservation
    test "preserves data structure after scrubbing" do
      result = %{
        "string" => "value",
        "number" => 42,
        "boolean" => true,
        "nil" => nil,
        "list" => [1, 2, 3],
        "map" => %{"nested" => "data"}
      }

      secrets_used = %{"secret" => "notpresent"}

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      # Structure unchanged when no secrets found
      assert scrubbed == result
      assert is_map(scrubbed)
      assert is_list(scrubbed["list"])
      assert is_map(scrubbed["map"])
    end

    # R10: Tuple Handling
    test "scrubs secrets from tuples" do
      result = {:ok, "The password is secret123", 42}
      secrets_used = %{"pass" => "secret123"}

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      assert scrubbed == {:ok, "The password is [REDACTED:pass]", 42}
      assert is_tuple(scrubbed)
    end

    # R11: Binary Data
    test "handles binary data" do
      result = <<"The secret is ", "mysecret456"::binary>>
      secrets_used = %{"sec" => "mysecret456"}

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      assert scrubbed == "The secret is [REDACTED:sec]"
    end

    # R12: Nil Handling
    test "handles nil values" do
      assert OutputScrubber.scrub_result(nil, %{}) == nil
      assert OutputScrubber.scrub_result(nil, %{"key" => "value"}) == nil

      result = %{"key" => nil, "other" => "secret123"}
      secrets_used = %{"sec" => "secret123"}

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      assert scrubbed == %{"key" => nil, "other" => "[REDACTED:sec]"}
    end

    # R13: Error Format Scrubbing
    test "scrubs secrets from error tuples" do
      result = {:error, "Authentication failed with password: supersecret123"}
      secrets_used = %{"password" => "supersecret123"}

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      assert scrubbed == {:error, "Authentication failed with password: [REDACTED:password]"}
    end

    test "handles complex error structures" do
      result =
        {:error,
         %{
           message: "Failed to connect",
           details: %{
             credentials: "user:password123",
             url: "https://api.example.com"
           }
         }}

      secrets_used = %{"db_pass" => "password123"}

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      assert elem(scrubbed, 0) == :error
      assert elem(scrubbed, 1).details.credentials == "user:[REDACTED:db_pass]"
    end

    # R14: JSON Response Scrubbing
    test "scrubs secrets from JSON responses" do
      # Simulated JSON response (as parsed map)
      result = %{
        "status" => 200,
        "body" => %{
          "message" => "API key apikey789xyz is invalid",
          "error_code" => "INVALID_KEY"
        },
        "headers" => %{
          "Authorization" => "Bearer token456abc"
        }
      }

      secrets_used = %{
        "api_key" => "apikey789xyz",
        "token" => "token456abc"
      }

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)
      assert scrubbed["body"]["message"] == "API key [REDACTED:api_key] is invalid"
      assert scrubbed["headers"]["Authorization"] == "Bearer [REDACTED:token]"
    end

    # R15: Shell Output Scrubbing
    test "scrubs secrets from shell command output" do
      result = %{
        stdout: "Successfully authenticated with token abc123def456\nConnected to database",
        stderr: "Warning: Using password pass789xyz in connection string",
        exit_code: 0
      }

      secrets_used = %{
        "auth_token" => "abc123def456",
        "db_password" => "pass789xyz"
      }

      scrubbed = OutputScrubber.scrub_result(result, secrets_used)

      assert scrubbed.stdout ==
               "Successfully authenticated with token [REDACTED:auth_token]\nConnected to database"

      assert scrubbed.stderr ==
               "Warning: Using password [REDACTED:db_password] in connection string"

      assert scrubbed.exit_code == 0
    end
  end

  describe "scrub_string/2" do
    test "scrubs single secret from string" do
      result = OutputScrubber.scrub_string("Password is secret123", %{"pass" => "secret123"})
      assert result == "Password is [REDACTED:pass]"
    end

    test "scrubs multiple occurrences of same secret" do
      result =
        OutputScrubber.scrub_string(
          "Key: secret123, repeated: secret123",
          %{"key" => "secret123"}
        )

      assert result == "Key: [REDACTED:key], repeated: [REDACTED:key]"
    end

    test "returns original string when no secrets present" do
      original = "No secrets here"
      result = OutputScrubber.scrub_string(original, %{"key" => "notfound"})
      assert result == original
    end
  end

  describe "scrub_deep/2" do
    test "recursively scrubs deeply nested structures" do
      result = %{
        level1: %{
          level2: %{
            level3: %{
              level4: "Contains secret999 here"
            }
          }
        }
      }

      secrets_used = %{"deep_secret" => "secret999"}

      scrubbed = OutputScrubber.scrub_deep(result, secrets_used)
      assert scrubbed.level1.level2.level3.level4 == "Contains [REDACTED:deep_secret] here"
    end

    test "handles mixed nested types" do
      result = %{
        list: [
          %{map: "secret111"},
          ["nested", "list", "with", "secret222"],
          {:tuple, "secret333"}
        ]
      }

      secrets_used = %{
        "s1" => "secret111",
        "s2" => "secret222",
        "s3" => "secret333"
      }

      scrubbed = OutputScrubber.scrub_deep(result, secrets_used)

      assert scrubbed.list == [
               %{map: "[REDACTED:s1]"},
               ["nested", "list", "with", "[REDACTED:s2]"],
               {:tuple, "[REDACTED:s3]"}
             ]
    end
  end

  describe "contains_secret?/2" do
    test "detects when string contains secret value" do
      assert OutputScrubber.contains_secret?("This contains mysecret here", "mysecret")
      refute OutputScrubber.contains_secret?("This does not contain it", "mysecret")
    end

    test "is case sensitive" do
      refute OutputScrubber.contains_secret?("This contains MYSECRET", "mysecret")
      assert OutputScrubber.contains_secret?("This contains mysecret", "mysecret")
    end
  end

  describe "redact_value/2" do
    test "replaces secret value with redacted format" do
      result = OutputScrubber.redact_value("my_secret_value", "api_key")
      assert result == "[REDACTED:api_key]"
    end

    test "uses provided name in redaction" do
      result = OutputScrubber.redact_value("value", "custom_name")
      assert result == "[REDACTED:custom_name]"
    end
  end

  # R16: Property-Based Testing
  describe "property-based tests" do
    property "scrubs secrets from any data structure" do
      check all(
              secret_value <- string(:alphanumeric, min_length: 9, max_length: 50),
              secret_name <- string(:alphanumeric, min_length: 1, max_length: 20),
              data <- random_data_with_secret(secret_value)
            ) do
        secrets_used = %{secret_name => secret_value}
        scrubbed = OutputScrubber.scrub_result(data, secrets_used)

        # Verify the secret value doesn't appear in scrubbed output
        refute contains_value?(scrubbed, secret_value)

        # If the secret was present, redacted version should appear
        if contains_value?(data, secret_value) do
          assert contains_value?(scrubbed, "[REDACTED:#{secret_name}]")
        end
      end
    end

    property "preserves structure of any data" do
      check all(data <- random_nested_data()) do
        # Scrub with non-existent secret
        scrubbed = OutputScrubber.scrub_result(data, %{"nonexistent" => "notfound123456"})

        # Structure should be identical
        assert same_structure?(data, scrubbed)
      end
    end

    property "handles empty secrets map safely" do
      check all(data <- random_nested_data()) do
        scrubbed = OutputScrubber.scrub_result(data, %{})
        assert scrubbed == data
      end
    end
  end

  # Helper functions for property tests
  defp random_data_with_secret(secret) do
    one_of([
      # String containing secret
      map(string(:alphanumeric, max_length: 10), fn s -> s <> secret <> s end),
      # Map with secret in value
      map(string(:alphanumeric, max_length: 10), fn key -> %{key => secret} end),
      # List with secret
      list_of(one_of([constant(secret), string(:alphanumeric, max_length: 10)]), max_length: 5),
      # Nested structure
      map(string(:alphanumeric, max_length: 10), fn k ->
        %{k => %{"nested" => secret, "other" => "value"}}
      end)
    ])
  end

  defp random_nested_data do
    sized(fn size ->
      # Limit recursion depth to prevent exponential growth
      random_nested_data(min(size, 2))
    end)
  end

  defp random_nested_data(0),
    do: one_of([string(:alphanumeric, max_length: 20), integer(), boolean(), constant(nil)])

  defp random_nested_data(size) do
    one_of([
      random_nested_data(0),
      list_of(random_nested_data(size - 1), max_length: 2),
      map_of(
        string(:alphanumeric, min_length: 1, max_length: 10),
        random_nested_data(size - 1),
        max_length: 2
      ),
      tuple({random_nested_data(size - 1), random_nested_data(size - 1)})
    ])
  end

  defp contains_value?(data, value) when is_binary(value) do
    case data do
      str when is_binary(str) ->
        String.contains?(str, value)

      map when is_map(map) ->
        Enum.any?(map, fn {_k, v} -> contains_value?(v, value) end)

      list when is_list(list) ->
        Enum.any?(list, &contains_value?(&1, value))

      tuple when is_tuple(tuple) ->
        tuple |> Tuple.to_list() |> Enum.any?(&contains_value?(&1, value))

      _ ->
        false
    end
  end

  defp same_structure?(data1, data2) do
    case {data1, data2} do
      {m1, m2} when is_map(m1) and is_map(m2) ->
        Map.keys(m1) == Map.keys(m2) and
          Enum.all?(m1, fn {k, v1} -> same_structure?(v1, Map.get(m2, k)) end)

      {l1, l2} when is_list(l1) and is_list(l2) ->
        length(l1) == length(l2) and
          Enum.zip(l1, l2) |> Enum.all?(fn {e1, e2} -> same_structure?(e1, e2) end)

      {t1, t2} when is_tuple(t1) and is_tuple(t2) ->
        tuple_size(t1) == tuple_size(t2)

      {v1, v2} ->
        # For primitives, just check type
        is_binary(v1) == is_binary(v2) and
          is_integer(v1) == is_integer(v2) and
          is_float(v1) == is_float(v2) and
          is_boolean(v1) == is_boolean(v2) and
          is_nil(v1) == is_nil(v2)
    end
  end
end
