defmodule Quoracle.Models.TableSecretsTest do
  use Quoracle.DataCase, async: true

  alias Quoracle.Models.TableSecrets
  alias Quoracle.Repo

  describe "create/1" do
    # R1: Secret Creation
    test "creates secret with valid name" do
      attrs = %{
        name: "github_token",
        value: "ghp_abc123xyz789",
        description: "GitHub personal access token"
      }

      assert {:ok, secret} = TableSecrets.create(attrs)
      assert secret.name == "github_token"
      assert secret.description == "GitHub personal access token"
      # Value should be encrypted, not plaintext
      refute secret.encrypted_value == "ghp_abc123xyz789"
    end

    # R2: Name Validation
    test "rejects secret with invalid characters in name" do
      attrs = %{
        # Invalid: contains dash and exclamation
        name: "github-token!",
        value: "secret_value"
      }

      assert {:error, changeset} = TableSecrets.create(attrs)
      errors = errors_on(changeset)

      assert "must be alphanumeric with underscores only" in (errors[:name] || [])
    end

    test "validates name length" do
      # Too long (>64 chars)
      long_name = String.duplicate("a", 65)
      attrs = %{name: long_name, value: "secret"}
      assert {:error, changeset} = TableSecrets.create(attrs)
      errors = errors_on(changeset)

      assert "should be at most 64 character(s)" in (errors[:name] || [])

      # Empty name
      attrs = %{name: "", value: "secret"}
      assert {:error, changeset} = TableSecrets.create(attrs)
      errors = errors_on(changeset)
      assert "can't be blank" in (errors[:name] || [])
    end

    test "requires non-empty value" do
      attrs = %{name: "test_secret", value: ""}
      assert {:error, changeset} = TableSecrets.create(attrs)
      errors = errors_on(changeset)
      assert "can't be blank" in (errors[:value] || [])
    end

    test "validates description length" do
      long_desc = String.duplicate("a", 501)

      attrs = %{
        name: "test_secret",
        value: "secret",
        description: long_desc
      }

      assert {:error, changeset} = TableSecrets.create(attrs)
      errors = errors_on(changeset)

      assert "should be at most 500 character(s)" in (errors[:description] || [])
    end

    # R11: Duplicate Name Prevention
    test "prevents duplicate secret names" do
      attrs = %{name: "unique_secret", value: "value1"}
      assert {:ok, _} = TableSecrets.create(attrs)

      # Try to create another with same name
      attrs2 = %{name: "unique_secret", value: "value2"}
      assert {:error, changeset} = TableSecrets.create(attrs2)
      errors = errors_on(changeset)
      assert "has already been taken" in (errors[:name] || [])
    end
  end

  describe "get_by_name/1" do
    setup do
      {:ok, secret} =
        TableSecrets.create(%{
          name: "test_secret",
          value: "super_secret_value"
        })

      %{secret: secret}
    end

    # R4: Decryption Success
    test "retrieves and decrypts secret by name", %{secret: _secret} do
      assert {:ok, retrieved} = TableSecrets.get_by_name("test_secret")
      assert retrieved.name == "test_secret"
      # Should decrypt the value
      assert retrieved.value == "super_secret_value"
    end

    # R5: Missing Secret
    test "returns not_found for missing secret" do
      assert {:error, :not_found} = TableSecrets.get_by_name("nonexistent")
    end

    # R12: Decryption Error Handling
    test "handles decryption failures gracefully" do
      # Simulate corrupted encrypted data
      {:ok, secret} =
        TableSecrets.create(%{
          name: "corrupted_secret",
          value: "test"
        })

      # Manually corrupt the encrypted value in DB
      Repo.update_all(
        from(s in TableSecrets, where: s.id == ^secret.id),
        set: [encrypted_value: <<0, 0, 0, 0>>]
      )

      assert {:error, :decryption_failed} = TableSecrets.get_by_name("corrupted_secret")
    end
  end

  describe "list_names/0" do
    setup do
      {:ok, _} = TableSecrets.create(%{name: "secret1", value: "val1"})
      {:ok, _} = TableSecrets.create(%{name: "secret2", value: "val2"})
      {:ok, _} = TableSecrets.create(%{name: "secret3", value: "val3"})
      :ok
    end

    # R6: List Names Only
    test "lists all secret names without values" do
      assert {:ok, names} = TableSecrets.list_names()
      assert length(names) == 3
      assert "secret1" in names
      assert "secret2" in names
      assert "secret3" in names
      # Should be just names (strings), not full structs
      Enum.each(names, fn name -> assert is_binary(name) end)
    end

    test "returns empty list when no secrets" do
      Repo.delete_all(TableSecrets)
      assert {:ok, []} = TableSecrets.list_names()
    end
  end

  describe "update/2" do
    setup do
      {:ok, secret} =
        TableSecrets.create(%{
          name: "updatable_secret",
          value: "original_value",
          description: "Original description"
        })

      %{secret: secret}
    end

    # R7: Update Secret Value
    test "updates existing secret value", %{secret: _secret} do
      assert {:ok, updated} =
               TableSecrets.update("updatable_secret", %{
                 value: "new_value",
                 description: "Updated description"
               })

      assert updated.value == "new_value"
      assert updated.description == "Updated description"
      # Name unchanged
      assert updated.name == "updatable_secret"

      # Verify encryption changed
      {:ok, retrieved} = TableSecrets.get_by_name("updatable_secret")
      assert retrieved.value == "new_value"
    end

    test "returns error when updating non-existent secret" do
      assert {:error, :not_found} = TableSecrets.update("nonexistent", %{value: "new"})
    end

    test "validates updated value" do
      assert {:error, changeset} = TableSecrets.update("updatable_secret", %{value: ""})
      errors = errors_on(changeset)
      assert "can't be blank" in (errors[:value] || [])
    end
  end

  describe "delete/1" do
    setup do
      {:ok, secret} =
        TableSecrets.create(%{
          name: "deletable_secret",
          value: "to_be_deleted"
        })

      %{secret: secret}
    end

    # R8: Delete Secret
    test "deletes secret by name", %{secret: secret} do
      assert {:ok, deleted} = TableSecrets.delete("deletable_secret")
      assert deleted.id == secret.id
      assert {:error, :not_found} = TableSecrets.get_by_name("deletable_secret")
    end

    test "returns error when deleting non-existent secret" do
      assert {:error, :not_found} = TableSecrets.delete("nonexistent")
    end
  end

  describe "resolve_secrets/1" do
    setup do
      {:ok, _} = TableSecrets.create(%{name: "api_key", value: "key123"})
      {:ok, _} = TableSecrets.create(%{name: "db_password", value: "pass456"})
      {:ok, _} = TableSecrets.create(%{name: "token", value: "tok789"})
      :ok
    end

    # R9: Batch Resolution
    test "resolves multiple secrets in batch" do
      names = ["api_key", "db_password", "token"]
      assert {:ok, resolved} = TableSecrets.resolve_secrets(names)

      assert resolved == %{
               "api_key" => "key123",
               "db_password" => "pass456",
               "token" => "tok789"
             }
    end

    # R10: Batch Resolution Failure
    test "batch resolution fails fast on missing secret" do
      names = ["api_key", "missing_secret", "token"]
      assert {:error, :secret_not_found, "missing_secret"} = TableSecrets.resolve_secrets(names)
    end

    test "resolves empty list successfully" do
      assert {:ok, %{}} = TableSecrets.resolve_secrets([])
    end

    test "handles duplicates in request" do
      names = ["api_key", "api_key", "token"]
      assert {:ok, resolved} = TableSecrets.resolve_secrets(names)
      assert map_size(resolved) == 2
      assert resolved["api_key"] == "key123"
      assert resolved["token"] == "tok789"
    end
  end

  describe "encryption verification" do
    # R3: Encryption Verification
    test "stores encrypted value in database" do
      {:ok, secret} =
        TableSecrets.create(%{
          name: "encryption_test",
          value: "plaintext_password"
        })

      # Query database directly
      raw_record = Repo.get!(TableSecrets, secret.id)

      # encrypted_value should exist and not be plaintext
      assert raw_record.encrypted_value != nil
      refute raw_record.encrypted_value == "plaintext_password"
      # Should be binary encrypted data
      assert is_binary(raw_record.encrypted_value)
    end
  end

  # v2.0: search_by_terms/1 tests (R13-R20)
  describe "search_by_terms/1" do
    setup do
      # Create test secrets with varied names for search testing
      {:ok, _} = TableSecrets.create(%{name: "aws_api_key", value: "secret1"})
      {:ok, _} = TableSecrets.create(%{name: "azure_token", value: "secret2"})
      {:ok, _} = TableSecrets.create(%{name: "github_api_key", value: "secret3"})
      {:ok, _} = TableSecrets.create(%{name: "database_password", value: "secret4"})
      {:ok, _} = TableSecrets.create(%{name: "stripe_secret", value: "secret5"})
      :ok
    end

    # R13: Basic Search Matching
    test "finds secrets by substring match" do
      assert {:ok, names} = TableSecrets.search_by_terms(["api"])
      assert length(names) == 2
      assert "aws_api_key" in names
      assert "github_api_key" in names
    end

    # R14: Case Insensitive Search
    test "search is case insensitive" do
      # Search with uppercase should match lowercase names
      assert {:ok, names} = TableSecrets.search_by_terms(["API"])
      assert length(names) == 2
      assert "aws_api_key" in names
      assert "github_api_key" in names

      # Mixed case
      assert {:ok, names2} = TableSecrets.search_by_terms(["AwS"])
      assert "aws_api_key" in names2
    end

    # R15: Multiple Terms OR Logic
    test "multiple terms use OR logic" do
      assert {:ok, names} = TableSecrets.search_by_terms(["aws", "azure"])
      assert length(names) == 2
      assert "aws_api_key" in names
      assert "azure_token" in names
    end

    # R16: Empty Terms List
    test "empty terms list returns empty results" do
      assert {:ok, []} = TableSecrets.search_by_terms([])
    end

    # R17: Empty String Filtering
    test "filters out empty string terms" do
      # Empty strings should be filtered, only "api" should match
      assert {:ok, names} = TableSecrets.search_by_terms(["", "api", ""])
      assert length(names) == 2
      assert "aws_api_key" in names
      assert "github_api_key" in names

      # Only empty strings should return empty results
      assert {:ok, []} = TableSecrets.search_by_terms(["", "", ""])
    end

    # R18: No Matches
    test "returns empty list when no matches found" do
      assert {:ok, []} = TableSecrets.search_by_terms(["nonexistent"])
      assert {:ok, []} = TableSecrets.search_by_terms(["xyz123"])
    end

    # R19: Wildcard Escaping
    test "escapes SQL wildcards for literal matching" do
      # Create secrets - note: names can only be alphanumeric + underscore
      {:ok, _} = TableSecrets.create(%{name: "test_50_percent", value: "val1"})
      {:ok, _} = TableSecrets.create(%{name: "user_name_field", value: "val2"})

      # Search for "50%" should NOT match "test_50_percent" because:
      # - "%" is escaped and treated literally
      # - "test_50_percent" contains "50_p", not "50%"
      # - If unescaped, "%" would act as wildcard matching anything after "50"
      assert {:ok, names} = TableSecrets.search_by_terms(["50%"])
      assert names == []

      # Search for "_" in "user_name" is escaped and treated literally
      # "user_name_field" contains "user_name" so it matches
      assert {:ok, names2} = TableSecrets.search_by_terms(["user_name"])
      assert "user_name_field" in names2
    end

    # R20: Names Only Returned
    test "search returns names only, never values" do
      assert {:ok, names} = TableSecrets.search_by_terms(["stripe"])
      assert length(names) == 1
      assert "stripe_secret" in names
      # Should be strings (names), not structs
      Enum.each(names, fn name ->
        assert is_binary(name)
        refute is_struct(name)
      end)
    end
  end
end
