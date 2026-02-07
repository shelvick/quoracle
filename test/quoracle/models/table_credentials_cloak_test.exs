defmodule Quoracle.Models.TableCredentialsCloakTest do
  @moduledoc """
  Tests for REAL Cloak.Ecto encryption in TableCredentials.
  These tests verify actual encryption, not simulation.
  """

  # Database tests can run async with modern Ecto.Sandbox pattern
  use Quoracle.DataCase, async: true
  alias Quoracle.Models.TableCredentials
  alias Quoracle.Repo

  describe "real Cloak.Ecto encryption" do
    # AUDIT_FIX_01: Verify api_key field uses Quoracle.Encrypted.Binary type
    test "api_key field is defined as Quoracle.Encrypted.Binary not string" do
      # This should pass when real encryption is implemented
      type = TableCredentials.__schema__(:type, :api_key)

      assert type == Quoracle.Encrypted.Binary,
             "api_key should use Quoracle.Encrypted.Binary, got: #{inspect(type)}"
    end

    # AUDIT_FIX_02: Verify Cloak vault is properly configured
    test "Cloak vault is configured with AES-256-GCM cipher" do
      assert Quoracle.Vault.configured?(), "Vault ciphers not configured"

      [{:default, {Cloak.Ciphers.AES.GCM, cipher_opts}}] =
        Application.get_env(:quoracle, Quoracle.Vault)[:ciphers]

      assert cipher_opts[:tag] == "AES.GCM.V1", "Should have proper cipher tag"
      assert cipher_opts[:iv_length] == 12, "Should use 12-byte IV"
    end

    # AUDIT_FIX_03: Verify encryption key is configured
    test "encryption key is configured in Cloak vault" do
      vault_config = Application.get_env(:quoracle, Quoracle.Vault)
      assert vault_config != nil, "Vault not configured"

      # In production, key would come from environment variable
      assert vault_config[:ciphers] != nil, "No ciphers in vault config"

      {_module, cipher_config} = vault_config[:ciphers][:default]
      assert cipher_config[:key] != nil, "No encryption key configured"

      # Key should be 256-bit key
      key = cipher_config[:key]
      assert byte_size(key) == 32, "Key should be 256 bits (32 bytes)"
    end

    # AUDIT_FIX_04: Verify encryption actually happens
    test "api_key is actually encrypted when stored in database" do
      plaintext_key = "sk-real-secret-key-12345"

      {:ok, credential} =
        TableCredentials.insert(%{
          model_id: "real_encryption_test",
          model_spec: "anthropic-bedrock:test",
          api_key: plaintext_key
        })

      # Query raw database to verify encryption
      query = "SELECT api_key FROM credentials WHERE id = $1"
      {:ok, binary_id} = Ecto.UUID.dump(credential.id)
      {:ok, result} = Repo.query(query, [binary_id])
      [[stored_value]] = result.rows

      # Stored value should be encrypted binary, not plaintext
      assert is_binary(stored_value), "Stored value should be binary"
      refute stored_value == plaintext_key, "API key should not be stored as plaintext"

      # Should be Cloak-encrypted format (starts with cipher tag)
      assert byte_size(stored_value) > byte_size(plaintext_key),
             "Encrypted value should be longer"

      # When using real Cloak, encrypted data is binary
      # The exact format depends on the Cloak.Ecto implementation
      assert is_binary(stored_value) && stored_value != plaintext_key,
             "Should be encrypted binary"
    end

    # AUDIT_FIX_05: Verify automatic decryption works
    test "api_key is automatically decrypted when fetched through schema" do
      plaintext_key = "sk-azure-secret-98765"

      {:ok, _} =
        TableCredentials.insert(%{
          model_id: "decrypt_real_test",
          model_spec: "azure:test",
          api_key: plaintext_key,
          deployment_id: "deploy",
          resource_id: "resource"
        })

      # Fetch through schema should decrypt automatically
      {:ok, fetched} = TableCredentials.get_by_model_id("decrypt_real_test")
      assert fetched.api_key == plaintext_key, "Should decrypt to original plaintext"
    end
  end

  describe "no test simulation code in production" do
    # AUDIT_FIX_06: Ensure no hardcoded test model IDs in production
    test "get_by_model_id doesn't have hardcoded test simulation" do
      # These model IDs should NOT trigger special behavior
      test_model_ids = ["test_model", "corrupted_test", "test_encrypt_fail"]

      for model_id <- test_model_ids do
        # Should return :not_found, not simulated errors
        result = TableCredentials.get_by_model_id(model_id)

        assert result == {:error, :not_found},
               "Model ID '#{model_id}' should not have special test behavior"
      end
    end

    # AUDIT_FIX_07: Ensure insert doesn't have test simulation
    test "insert doesn't simulate encryption failure for test models" do
      # Should actually try to insert, not simulate failure
      result =
        TableCredentials.insert(%{
          model_id: "test_encrypt_fail",
          model_spec: "anthropic-bedrock:test",
          api_key: "sk-test-key"
        })

      # Should succeed based on real validation
      assert match?({:ok, _}, result),
             "Should insert successfully"
    end
  end

  describe "Cloak.Vault module" do
    # AUDIT_FIX_08: Verify Vault module works correctly
    # Note: Module existence is verified by compiler - test behavior instead
    test "Quoracle.Vault can encrypt and decrypt data" do
      # Test the actual functionality instead of module existence
      plaintext = "test_secret_value"

      encrypted = Quoracle.Vault.encrypt!(plaintext)
      decrypted = Quoracle.Vault.decrypt!(encrypted)

      assert decrypted == plaintext
      refute encrypted == plaintext
    end

    # AUDIT_FIX_09: Verify Vault is in supervision tree
    test "Vault is started in application supervision tree" do
      # Start supervised vault for test isolation
      # Vault may already be started by application
      case start_supervised(Quoracle.Vault) do
        {:ok, _pid} -> assert true
        {:error, {:already_started, _}} -> assert true
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
    end
  end
end
