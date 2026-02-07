defmodule Quoracle.Actions.GenerateSecretTest do
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.GenerateSecret
  alias Quoracle.Models.TableSecrets

  describe "execute/3" do
    # R1: Basic Generation
    test "generates basic alphanumeric secret", %{sandbox_owner: owner} do
      params = %{
        "name" => "test_secret",
        "description" => "Test secret for unit test"
      }

      result = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      assert {:ok, response} = result
      assert response.action == "generate_secret"
      assert response.secret_name == "test_secret"

      # Verify secret was stored
      assert {:ok, secret} = TableSecrets.get_by_name("test_secret")
      assert secret.description == "Test secret for unit test"
    end

    # R2: Name Validation
    test "rejects invalid secret name", %{sandbox_owner: owner} do
      params = %{
        # Contains invalid characters
        "name" => "invalid-name!",
        "description" => "Should fail"
      }

      result = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      assert {:error, reason} = result
      assert reason =~ "alphanumeric"
    end

    # R3: Length Validation
    test "validates length range", %{sandbox_owner: owner} do
      # Too short
      params = %{
        "name" => "short_secret",
        "length" => 7
      }

      result = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)
      assert {:error, reason} = result
      assert reason =~ ~r/8|length/

      # Too long
      params = %{
        "name" => "long_secret",
        "length" => 129
      }

      result = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)
      assert {:error, reason} = result
      assert reason =~ ~r/128|length/
    end

    # R4: Default Parameters
    test "uses default parameters when not specified", %{sandbox_owner: owner} do
      params = %{"name" => "default_test"}

      result = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      assert {:ok, response} = result
      assert response.action == "generate_secret"

      # Verify default length (32)
      assert {:ok, secret} = TableSecrets.get_by_name("default_test")
      assert String.length(secret.value) == 32
    end

    # R5: Include Numbers
    test "includes numbers when requested", %{sandbox_owner: owner} do
      # Use length=100 to make probabilistic failure negligible
      # Probability of no numbers: (52/62)^100 ≈ 1.6×10⁻⁸ (effectively deterministic)
      params = %{
        "name" => "with_numbers",
        "include_numbers" => true,
        "include_symbols" => false,
        "length" => 100
      }

      result = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      assert {:ok, _response} = result

      assert {:ok, secret} = TableSecrets.get_by_name("with_numbers")
      assert String.length(secret.value) == 100

      assert String.match?(secret.value, ~r/[0-9]/),
             "Generated secret should contain at least one number"

      assert String.match?(secret.value, ~r/^[a-zA-Z0-9]+$/),
             "Secret should only contain letters and numbers"
    end

    # R6: Include Symbols
    test "includes symbols when requested", %{sandbox_owner: owner} do
      # Use length=100 to make probabilistic failure negligible
      # Probability of no symbols: (62/74)^100 ≈ 2.1×10⁻⁸ (effectively deterministic)
      params = %{
        "name" => "with_symbols",
        "include_symbols" => true,
        "length" => 100
      }

      result = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      assert {:ok, _response} = result

      assert {:ok, secret} = TableSecrets.get_by_name("with_symbols")
      assert String.length(secret.value) == 100

      assert String.match?(secret.value, ~r/[!@#$%^&*\-_=+]/),
             "Generated secret should contain at least one symbol"

      assert String.match?(secret.value, ~r/^[a-zA-Z0-9!@#$%^&*\-_=+]+$/),
             "Secret should only contain letters, numbers, and symbols"
    end

    # R7: Storage Integration
    test "stores generated secret in database", %{sandbox_owner: owner} do
      params = %{
        "name" => "db_test",
        "description" => "Database storage test"
      }

      result = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      assert {:ok, _response} = result

      # Verify retrieval
      assert {:ok, secret} = TableSecrets.get_by_name("db_test")
      assert secret.name == "db_test"
      assert secret.description == "Database storage test"
      assert is_binary(secret.encrypted_value)
    end

    # R8: No Value Leakage
    test "result does not contain generated value", %{sandbox_owner: owner} do
      params = %{"name" => "no_leak_test"}

      result = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      assert {:ok, response} = result

      # Get the actual generated value
      assert {:ok, secret} = TableSecrets.get_by_name("no_leak_test")

      # Ensure it's not in the response
      response_string = inspect(response)
      refute String.contains?(response_string, secret.value)
    end

    # R9: Duplicate Name Handling
    test "fails if secret name already exists", %{sandbox_owner: owner} do
      # Create first secret
      params = %{"name" => "duplicate_test"}
      assert {:ok, _} = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      # Try to create duplicate
      result = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      assert {:error, reason} = result
      assert reason =~ ~r/already exists|taken/
    end

    # R10: Description Storage
    test "stores description with secret", %{sandbox_owner: owner} do
      params = %{
        "name" => "desc_test",
        "description" => "This is a detailed description"
      }

      result = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      assert {:ok, _response} = result

      assert {:ok, secret} = TableSecrets.get_by_name("desc_test")
      assert secret.description == "This is a detailed description"
    end

    # R11: Cryptographic Strength (indirect test)
    test "uses cryptographically secure random", %{sandbox_owner: owner} do
      # Generate multiple secrets with same params
      secrets =
        for i <- 1..5 do
          params = %{
            "name" => "crypto_test_#{i}",
            "length" => 16
          }

          assert {:ok, _} = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

          assert {:ok, secret} = TableSecrets.get_by_name("crypto_test_#{i}")
          secret.value
        end

      # All should be unique (cryptographically random)
      assert length(Enum.uniq(secrets)) == 5
    end

    # R12: Standard Action Format
    test "returns standard action result format", %{sandbox_owner: owner} do
      params = %{"name" => "format_test"}

      result = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      assert {:ok, response} = result
      assert Map.has_key?(response, :action)
      assert response.action == "generate_secret"
    end

    # R13: Length Accuracy
    test "generates exact length requested", %{sandbox_owner: owner} do
      for length <- [8, 16, 32, 64, 128] do
        params = %{
          "name" => "length_test_#{length}",
          "length" => length
        }

        assert {:ok, _} = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

        assert {:ok, secret} = TableSecrets.get_by_name("length_test_#{length}")
        assert String.length(secret.value) == length
      end
    end

    # R14: Character Set Compliance
    test "uses only specified character sets", %{sandbox_owner: owner} do
      # Only letters
      params = %{
        "name" => "letters_only",
        "include_numbers" => false,
        "include_symbols" => false,
        "length" => 20
      }

      assert {:ok, _} = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      assert {:ok, secret} = TableSecrets.get_by_name("letters_only")
      assert String.match?(secret.value, ~r/^[a-zA-Z]+$/)

      # Letters and numbers
      params = %{
        "name" => "letters_numbers",
        "include_numbers" => true,
        "include_symbols" => false,
        "length" => 20
      }

      assert {:ok, _} = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      assert {:ok, secret} = TableSecrets.get_by_name("letters_numbers")
      assert String.match?(secret.value, ~r/^[a-zA-Z0-9]+$/)

      # All character sets
      params = %{
        "name" => "all_chars",
        "include_numbers" => true,
        "include_symbols" => true,
        "length" => 20
      }

      assert {:ok, _} = GenerateSecret.execute(params, "agent_123", sandbox_owner: owner)

      assert {:ok, secret} = TableSecrets.get_by_name("all_chars")
      assert String.match?(secret.value, ~r/^[a-zA-Z0-9!@#$%^&*\-_=+]+$/)
    end
  end
end
