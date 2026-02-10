defmodule Quoracle.Security.SecretResolverTest do
  use Quoracle.DataCase, async: true
  use ExUnitProperties

  alias Quoracle.Security.SecretResolver
  alias Quoracle.Models.TableSecrets

  describe "resolve_params/1" do
    setup do
      # Create test secrets
      {:ok, _} = TableSecrets.create(%{name: "api_key", value: "secret123"})
      {:ok, _} = TableSecrets.create(%{name: "db_pass", value: "password456"})
      {:ok, _} = TableSecrets.create(%{name: "token", value: "tok789xyz"})
      :ok
    end

    # R1: Simple Template Resolution
    test "resolves simple {{SECRET:name}} template" do
      params = %{
        "api_key" => "{{SECRET:api_key}}"
      }

      assert {:ok, resolved, used} = SecretResolver.resolve_params(params)
      assert resolved["api_key"] == "secret123"
      assert used == %{"api_key" => "secret123"}
    end

    # R2: Multiple Template Resolution
    test "resolves multiple templates in same string" do
      params = %{
        "connection" => "user:{{SECRET:db_pass}}@host:{{SECRET:token}}"
      }

      assert {:ok, resolved, used} = SecretResolver.resolve_params(params)
      assert resolved["connection"] == "user:password456@host:tok789xyz"
      assert Map.keys(used) |> Enum.sort() == ["db_pass", "token"]
    end

    # R3: Nested Structure Resolution
    test "resolves templates in nested data structures" do
      params = %{
        "config" => %{
          "auth" => %{
            "bearer" => "{{SECRET:api_key}}",
            "basic" => ["user", "{{SECRET:db_pass}}"]
          },
          "tokens" => ["{{SECRET:token}}", "static_value"]
        }
      }

      assert {:ok, resolved, used} = SecretResolver.resolve_params(params)
      assert resolved["config"]["auth"]["bearer"] == "secret123"
      assert resolved["config"]["auth"]["basic"] == ["user", "password456"]
      assert resolved["config"]["tokens"] == ["tok789xyz", "static_value"]
      assert map_size(used) == 3
    end

    # R4: Missing Secret - Pass-Through as Literal
    test "keeps literal template when secret not found" do
      params = %{
        "key" => "{{SECRET:nonexistent}}"
      }

      # Missing secrets now pass-through as literals instead of erroring
      assert {:ok, resolved, used} = SecretResolver.resolve_params(params)
      # Template kept as literal
      assert resolved["key"] == "{{SECRET:nonexistent}}"
      # No secrets resolved
      assert used == %{}
    end

    # R5: Invalid Template Syntax
    test "ignores malformed templates" do
      params = %{
        # Missing name
        "a" => "{{SECRET}}",
        # Empty name
        "b" => "{{SECRET:}}",
        # Missing colon
        "c" => "{{SECRET name}}",
        # Single brace
        "d" => "{SECRET:api_key}",
        # Wrong case
        "e" => "{{secret:api_key}}"
      }

      assert {:ok, resolved, used} = SecretResolver.resolve_params(params)
      # All unchanged
      assert resolved == params
      assert used == %{}
    end

    # R6: Template Name Validation
    test "rejects templates with invalid characters" do
      params = %{
        # Dash
        "a" => "{{SECRET:api-key}}",
        # Dot
        "b" => "{{SECRET:api.key}}",
        # Space
        "c" => "{{SECRET:api key}}",
        # Slash
        "d" => "{{SECRET:api/key}}",
        # Special char
        "e" => "{{SECRET:api@key}}"
      }

      assert {:ok, resolved, used} = SecretResolver.resolve_params(params)
      # All unchanged (treated as literal)
      assert resolved == params
      assert used == %{}
    end

    # R7: Partial String Replacement
    test "replaces template within larger string" do
      params = %{
        "auth" => "Bearer {{SECRET:api_key}}",
        "url" => "https://user:{{SECRET:db_pass}}@example.com/path"
      }

      assert {:ok, resolved, used} = SecretResolver.resolve_params(params)
      assert resolved["auth"] == "Bearer secret123"
      assert resolved["url"] == "https://user:password456@example.com/path"
      assert Map.keys(used) |> Enum.sort() == ["api_key", "db_pass"]
    end

    # R9: Empty Params Handling
    test "handles empty params map" do
      assert {:ok, %{}, %{}} = SecretResolver.resolve_params(%{})
    end

    # R10: Non-String Values
    test "preserves non-string values" do
      params = %{
        "string" => "{{SECRET:api_key}}",
        "number" => 42,
        "boolean" => true,
        "atom" => :some_atom,
        "nil" => nil,
        "list" => [1, 2, 3],
        "nested" => %{"key" => 123}
      }

      assert {:ok, resolved, used} = SecretResolver.resolve_params(params)
      assert resolved["string"] == "secret123"
      assert resolved["number"] == 42
      assert resolved["boolean"] == true
      assert resolved["atom"] == :some_atom
      assert resolved["nil"] == nil
      assert resolved["list"] == [1, 2, 3]
      assert resolved["nested"] == %{"key" => 123}
      assert used == %{"api_key" => "secret123"}
    end

    # R11: Batch Resolution Efficiency
    test "resolves multiple secrets in single batch" do
      params = %{
        "a" => "{{SECRET:api_key}}",
        "b" => "{{SECRET:db_pass}}",
        "c" => "{{SECRET:token}}",
        # Duplicate
        "d" => "{{SECRET:api_key}}"
      }

      # Should make only one batch query to resolve all
      assert {:ok, resolved, used} = SecretResolver.resolve_params(params)
      assert resolved["a"] == "secret123"
      assert resolved["b"] == "password456"
      assert resolved["c"] == "tok789xyz"
      assert resolved["d"] == "secret123"
      # Should deduplicate in used list
      assert Map.keys(used) |> Enum.sort() == ["api_key", "db_pass", "token"]
    end

    # R12: Case Sensitivity
    test "secret names are case sensitive" do
      {:ok, _} = TableSecrets.create(%{name: "CaseSensitive", value: "value1"})

      params = %{
        # Correct case
        "a" => "{{SECRET:CaseSensitive}}",
        # Wrong case
        "b" => "{{SECRET:casesensitive}}",
        # Wrong case
        "c" => "{{SECRET:CASESENSITIVE}}"
      }

      # Correct case should resolve
      assert {:ok, resolved, _} = SecretResolver.resolve_params(%{"a" => params["a"]})
      assert resolved["a"] == "value1"

      # Wrong case should pass-through as literal
      assert {:ok, resolved_b, used_b} =
               SecretResolver.resolve_params(%{"b" => params["b"]})

      assert resolved_b["b"] == "{{SECRET:casesensitive}}"
      assert used_b == %{}

      assert {:ok, resolved_c, used_c} =
               SecretResolver.resolve_params(%{"c" => params["c"]})

      assert resolved_c["c"] == "{{SECRET:CASESENSITIVE}}"
      assert used_c == %{}
    end

    # R13: Template Edge Cases
    test "handles edge case template patterns" do
      params = %{
        # Empty name
        "a" => "{{SECRET:}}",
        # No colon
        "b" => "{{SECRET}}",
        # Unclosed
        "c" => "{{SECRET:",
        # No opening
        "d" => "SECRET:api_key}}",
        # Empty template
        "e" => "{{}}",
        # Spaces
        "f" => "{{ SECRET:api_key }}",
        # Unclosed
        "g" => "{{SECRET:api_key",
        # No braces
        "h" => "SECRET:api_key"
      }

      assert {:ok, resolved, used} = SecretResolver.resolve_params(params)
      # All unchanged
      assert resolved == params
      assert used == %{}
    end
  end

  describe "find_templates/1" do
    test "finds templates in strings" do
      data = "Bearer {{SECRET:token}} and {{SECRET:api_key}}"
      assert SecretResolver.find_templates(data) == ["token", "api_key"]
    end

    test "finds templates in nested structures" do
      data = %{
        "auth" => "{{SECRET:auth_token}}",
        "config" => %{
          "db" => ["host", "{{SECRET:db_pass}}"],
          "api" => %{"key" => "{{SECRET:api_key}}"}
        }
      }

      templates = SecretResolver.find_templates(data)
      assert Enum.sort(templates) == ["api_key", "auth_token", "db_pass"]
    end

    test "returns empty list when no templates" do
      assert SecretResolver.find_templates("no templates here") == []
      assert SecretResolver.find_templates(%{key: "value"}) == []
      assert SecretResolver.find_templates([1, 2, 3]) == []
    end

    test "deduplicates template names" do
      data = %{
        "a" => "{{SECRET:token}}",
        "b" => "{{SECRET:token}}",
        "c" => "{{SECRET:token}}"
      }

      assert SecretResolver.find_templates(data) == ["token"]
    end
  end

  describe "list_available_secrets/0" do
    # R8: List Available Secrets
    test "lists all available secret names" do
      {:ok, _} = TableSecrets.create(%{name: "secret1", value: "val1"})
      {:ok, _} = TableSecrets.create(%{name: "secret2", value: "val2"})

      assert {:ok, names} = SecretResolver.list_available_secrets()
      assert "secret1" in names
      assert "secret2" in names
      assert is_list(names)
      Enum.each(names, &assert(is_binary(&1)))
    end

    test "returns empty list when no secrets" do
      assert {:ok, []} = SecretResolver.list_available_secrets()
    end
  end

  describe "validate_template/1" do
    test "validates correct template syntax" do
      assert {:ok, "api_key"} = SecretResolver.validate_template("{{SECRET:api_key}}")
      assert {:ok, "API_KEY_123"} = SecretResolver.validate_template("{{SECRET:API_KEY_123}}")
      assert {:ok, "under_score"} = SecretResolver.validate_template("{{SECRET:under_score}}")
    end

    test "rejects invalid template syntax" do
      assert {:error, :invalid_template} = SecretResolver.validate_template("{{SECRET:api-key}}")
      assert {:error, :invalid_template} = SecretResolver.validate_template("{{SECRET:}}")
      assert {:error, :invalid_template} = SecretResolver.validate_template("{{SECRET}}")
      assert {:error, :invalid_template} = SecretResolver.validate_template("{SECRET:api_key}")
      assert {:error, :invalid_template} = SecretResolver.validate_template("SECRET:api_key")
    end
  end

  describe "resolve_template/1" do
    setup do
      {:ok, _} = TableSecrets.create(%{name: "existing_secret", value: "secret_value"})
      :ok
    end

    test "resolves single template to actual value" do
      assert {:ok, "secret_value"} = SecretResolver.resolve_template("existing_secret")
    end

    test "returns error for non-existent secret" do
      assert {:error, :secret_not_found} = SecretResolver.resolve_template("nonexistent")
    end
  end

  # R14: Property-Based Testing
  describe "property-based tests" do
    property "resolves any valid template pattern" do
      check all(
              name <- valid_secret_name(),
              value <- string(:alphanumeric, min_length: 1)
            ) do
        # Setup: Create the secret
        {:ok, _} = TableSecrets.create(%{name: name, value: value})

        # Create params with the template
        template = "{{SECRET:#{name}}}"
        params = %{"key" => template}

        # Should resolve correctly
        assert {:ok, resolved, used} = SecretResolver.resolve_params(params)
        assert resolved["key"] == value
        assert Map.has_key?(used, name)

        # Cleanup
        TableSecrets.delete(name)
      end
    end

    property "handles any invalid template pattern safely" do
      check all(invalid_pattern <- invalid_template_pattern()) do
        params = %{"key" => invalid_pattern}

        # Should always return ok with unchanged params (invalid patterns ignored,
        # valid patterns with missing secrets kept as literals)
        assert {:ok, resolved, used} = SecretResolver.resolve_params(params)
        # Should be unchanged (no secrets resolved)
        assert resolved == params
        assert used == %{}
      end
    end
  end

  # Generators for property tests
  defp valid_secret_name do
    gen all(
          base <- string(:alphanumeric, min_length: 2, max_length: 20),
          suffix <- string([?_, ?0..?9, ?a..?z, ?A..?Z], max_length: 20)
        ) do
      base <> suffix
    end
  end

  defp invalid_template_pattern do
    gen all(
          pattern <-
            one_of([
              # Missing parts
              constant("{{SECRET}}"),
              constant("{{SECRET:}}"),
              constant("{{}}"),
              # Wrong delimiters
              constant("{SECRET:name}"),
              constant("{{SECRET:name}"),
              constant("{SECRET:name}}"),
              # Invalid characters in name
              string_with_template(["api-key", "api.key", "api key", "api/key", "api@key"]),
              # Malformed
              constant("SECRET:name"),
              constant("{{ SECRET:name }}"),
              # Random string that might look like template
              string(:ascii, min_length: 5, max_length: 50)
            ])
        ) do
      pattern
    end
  end

  defp string_with_template(names) do
    gen all(name <- member_of(names)) do
      "{{SECRET:#{name}}}"
    end
  end
end
