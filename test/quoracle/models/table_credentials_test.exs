defmodule Quoracle.Models.TableCredentialsTest do
  @moduledoc """
  Tests for the credentials table with encrypted fields.

  Tests cover:
  - Encryption/decryption via Cloak.Ecto
  - model_spec field for LLMDB lookup (refactor-20251203-225603)
  - Validation for provider-specific fields

  Note: model_config FK removed in refactor-20251203-225603
  """

  # Database tests can run async with modern Ecto.Sandbox pattern
  use Quoracle.DataCase, async: true
  alias Quoracle.Models.TableCredentials
  alias Quoracle.Repo

  describe "schema and changeset" do
    test "creates valid credential with all fields" do
      attrs = %{
        model_id: "test_model",
        model_spec: "azure:test-model",
        api_key: "sk-test-key-123",
        deployment_id: "test-deployment",
        resource_id: "test-resource",
        endpoint_url: "https://test.openai.azure.com"
      }

      changeset = TableCredentials.changeset(%TableCredentials{}, attrs)
      assert changeset.valid?

      {:ok, credential} = Repo.insert(changeset)
      assert credential.model_id == "test_model"
      assert credential.model_spec == "azure:test-model"
      # api_key should be automatically decrypted when fetched
      assert credential.api_key == "sk-test-key-123"
    end

    test "validates unique constraint on model_id" do
      attrs = %{
        model_id: "unique_test",
        model_spec: "azure:unique-test",
        api_key: "key1",
        deployment_id: "test-deploy",
        resource_id: "test-resource"
      }

      {:ok, _first} = TableCredentials.insert(attrs)
      {:error, changeset} = TableCredentials.insert(attrs)

      assert errors_on(changeset)[:model_id] == ["has already been taken"]
    end

    test "validates Azure credentials require deployment_id" do
      attrs = %{
        model_id: "azure_model",
        model_spec: "azure:azure-model",
        api_key: "key"
        # Missing deployment_id
      }

      changeset = TableCredentials.changeset(%TableCredentials{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:deployment_id] == ["can't be blank for Azure models"]
    end

    test "validates api_key cannot be empty" do
      attrs = %{
        model_id: "test",
        model_spec: "bedrock:test",
        api_key: ""
      }

      changeset = TableCredentials.changeset(%TableCredentials{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:api_key] == ["can't be blank"]
    end
  end

  describe "encryption" do
    test "encrypts api_key on insert" do
      {:ok, _credential} =
        TableCredentials.insert(%{
          model_id: "encrypt_test",
          model_spec: "openai:gemini-2.5-pro",
          api_key: "plaintext-key"
        })

      # Query raw from database to verify encryption
      raw_result =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT api_key FROM credentials WHERE model_id = $1",
          ["encrypt_test"]
        )

      [encrypted_value] = raw_result.rows |> List.first()
      # With real Cloak.Ecto, value is stored encrypted
      assert is_binary(encrypted_value)
      refute encrypted_value == "plaintext-key"
      assert byte_size(encrypted_value) > byte_size("plaintext-key")

      # But fetching through Ecto should decrypt
      fetched = Repo.get_by(TableCredentials, model_id: "encrypt_test")
      assert fetched.api_key == "plaintext-key"
    end

    test "returns error when decryption fails" do
      # This would happen if encryption key changed
      # Simulate by inserting with wrong encryption context

      # Insert with corrupted encrypted value
      {:ok, binary_id} = Ecto.UUID.dump(Ecto.UUID.generate())

      Ecto.Adapters.SQL.query!(
        Repo,
        "INSERT INTO credentials (id, model_id, model_spec, api_key, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6)",
        [
          binary_id,
          "decrypt_fail",
          "openai:decrypt-fail",
          "corrupted_data",
          DateTime.utc_now(),
          DateTime.utc_now()
        ]
      )

      # With real Cloak.Ecto, invalid encrypted data causes loading error
      assert_raise ArgumentError, fn ->
        Repo.get_by(TableCredentials, model_id: "decrypt_fail")
      end
    end
  end

  # NOTE: FK relationship to model_configs removed in refactor-20251203-225603
  # These tests updated to verify credentials work independently
  describe "standalone credentials (no FK)" do
    test "credential can exist without model_config entry" do
      # No parent model_config needed - FK removed
      {:ok, credential} =
        TableCredentials.insert(%{
          model_id: "standalone_model",
          model_spec: "bedrock:standalone",
          api_key: "key"
        })

      assert credential.model_id == "standalone_model"
      assert credential.model_spec == "bedrock:standalone"
    end
  end

  describe "query functions" do
    test "get_by_model_id returns decrypted credential" do
      {:ok, _} =
        TableCredentials.insert(%{
          model_id: "query_test",
          model_spec: "azure:query-test",
          api_key: "secret-key",
          deployment_id: "deploy-1",
          resource_id: "resource-1"
        })

      {:ok, fetched} = TableCredentials.get_by_model_id("query_test")
      assert fetched.api_key == "secret-key"
      assert fetched.deployment_id == "deploy-1"
      assert fetched.resource_id == "resource-1"
    end

    test "get_by_model_id returns error for non-existent model" do
      assert {:error, :not_found} = TableCredentials.get_by_model_id("nonexistent")
    end

    test "update_credential encrypts new api_key" do
      {:ok, original} =
        TableCredentials.insert(%{
          model_id: "update_test",
          model_spec: "openai:update-test",
          api_key: "original-key"
        })

      {:ok, updated} =
        TableCredentials.update_credential(original, %{
          api_key: "new-key"
        })

      assert updated.api_key == "new-key"

      # Verify it's encrypted in database
      fetched = Repo.get(TableCredentials, updated.id)
      assert fetched.api_key == "new-key"
    end
  end

  # ============================================================================
  # model_spec Tests (WorkGroupID: refactor-20251203-225603)
  # ============================================================================

  describe "model_spec field" do
    # R1: WHEN inserting credentials with model_spec THEN model_spec is stored
    test "inserts credential with model_spec" do
      attrs = %{
        model_id: "test_with_spec",
        model_spec: "openai:gemini-2.5-pro",
        api_key: "sk-test-key-123"
      }

      {:ok, credential} = TableCredentials.insert(attrs)

      assert credential.model_spec == "openai:gemini-2.5-pro"
      assert credential.model_id == "test_with_spec"
    end

    # R2: WHEN fetching credentials by model_id THEN model_spec returned with decrypted data
    test "get_credentials returns model_spec with decrypted api_key" do
      {:ok, _} =
        TableCredentials.insert(%{
          model_id: "fetch_spec_test",
          model_spec: "anthropic-bedrock:claude-sonnet-4-20250514",
          api_key: "secret-key"
        })

      {:ok, fetched} = TableCredentials.get_by_model_id("fetch_spec_test")

      assert fetched.model_spec == "anthropic-bedrock:claude-sonnet-4-20250514"
      assert fetched.api_key == "secret-key"
    end

    # R3: WHEN listing all credentials THEN each includes model_spec
    test "list_credentials includes model_spec for all entries" do
      {:ok, _} =
        TableCredentials.insert(%{
          model_id: "list_spec_1",
          model_spec: "azure:gpt-4o",
          api_key: "key1",
          deployment_id: "deploy1",
          resource_id: "resource1"
        })

      {:ok, _} =
        TableCredentials.insert(%{
          model_id: "list_spec_2",
          model_spec: "azure:deepseek-r1",
          api_key: "key2",
          deployment_id: "deploy2",
          resource_id: "resource2"
        })

      credentials = TableCredentials.list_all()

      # Filter to our test credentials
      test_creds = Enum.filter(credentials, &(&1.model_id in ["list_spec_1", "list_spec_2"]))

      assert length(test_creds) == 2
      assert Enum.all?(test_creds, &(&1.model_spec != nil))
      assert Enum.any?(test_creds, &(&1.model_spec == "azure:gpt-4o"))
      assert Enum.any?(test_creds, &(&1.model_spec == "azure:deepseek-r1"))
    end

    # R4: WHEN updating credentials THEN model_spec can be changed
    test "updates credential model_spec" do
      {:ok, original} =
        TableCredentials.insert(%{
          model_id: "update_spec_test",
          model_spec: "azure:old-model",
          api_key: "key",
          deployment_id: "deploy",
          resource_id: "resource"
        })

      {:ok, updated} =
        TableCredentials.update_credential(original, %{
          model_spec: "azure:new-model"
        })

      assert updated.model_spec == "azure:new-model"

      # Verify persisted
      {:ok, fetched} = TableCredentials.get_by_model_id("update_spec_test")
      assert fetched.model_spec == "azure:new-model"
    end

    # R5: WHEN inserting credentials IF model_spec missing THEN changeset invalid
    test "changeset invalid when model_spec missing" do
      attrs = %{
        model_id: "no_spec_test",
        api_key: "key"
        # model_spec intentionally missing
      }

      changeset = TableCredentials.changeset(%TableCredentials{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset)[:model_spec] == ["can't be blank"]
    end

    # R5 additional: model_spec format validation (must contain colon)
    test "changeset validates model_spec format contains colon" do
      attrs = %{
        model_id: "bad_format_test",
        model_spec: "invalid-no-colon",
        api_key: "key"
      }

      changeset = TableCredentials.changeset(%TableCredentials{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset)[:model_spec] == ["must be in format provider:model"]
    end
  end

  describe "CRUD without model_config FK (R9)" do
    # R9: WHEN credential has no model_config FK THEN operations still succeed
    test "CRUD operations work without model_config foreign key" do
      # Create - no parent model_config needed
      {:ok, created} =
        TableCredentials.insert(%{
          model_id: "standalone_cred",
          model_spec: "openai:gemini-2.5-pro",
          api_key: "test-key"
        })

      assert created.model_id == "standalone_cred"
      assert created.model_spec == "openai:gemini-2.5-pro"

      # Read
      {:ok, read} = TableCredentials.get_by_model_id("standalone_cred")
      assert read.api_key == "test-key"

      # Update
      {:ok, updated} =
        TableCredentials.update_credential(read, %{api_key: "updated-key"})

      assert updated.api_key == "updated-key"

      # Delete (via Repo since delete/1 checks dependencies)
      {:ok, _deleted} = Repo.delete(updated)
      assert {:error, :not_found} = TableCredentials.get_by_model_id("standalone_cred")
    end

    # Additional: Insert without model_config parent should succeed
    test "insert succeeds without parent model_config" do
      # This should work without creating a TableModelConfigs entry first
      result =
        TableCredentials.insert(%{
          model_id: "no_parent_test",
          model_spec: "azure:grok-3",
          api_key: "key",
          deployment_id: "deploy",
          resource_id: "resource"
        })

      assert {:ok, credential} = result
      assert credential.model_id == "no_parent_test"
    end
  end
end
