defmodule Quoracle.Models.TableConsensusConfigTest do
  @moduledoc """
  Tests for TABLE_ConsensusConfig - Ecto schema for model_settings table.

  ARC Verification Criteria:
  - R1-R7: CRUD Operations
  - R8-R11: Validation
  - R12-R14: JSONB Storage
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Models.TableConsensusConfig

  describe "get/1" do
    setup do
      # Insert a test config entry directly
      {:ok, config} =
        TableConsensusConfig.upsert("test_config", %{"setting" => "value"})

      %{config: config}
    end

    # R1: WHEN get called with existing key THEN returns {:ok, config}
    test "get returns config for existing key", %{config: config} do
      assert {:ok, retrieved} = TableConsensusConfig.get("test_config")
      assert retrieved.id == config.id
      assert retrieved.key == "test_config"
      assert retrieved.value == %{"setting" => "value"}
    end

    # R2: WHEN get called with missing key THEN returns {:error, :not_found}
    test "get returns error for missing key" do
      assert {:error, :not_found} = TableConsensusConfig.get("nonexistent_key")
    end
  end

  describe "upsert/2" do
    # R3: WHEN upsert called with new key THEN inserts and returns {:ok, config}
    test "upsert inserts new config entry" do
      assert {:ok, config} =
               TableConsensusConfig.upsert("new_key", %{"models" => ["model1", "model2"]})

      assert config.key == "new_key"
      assert config.value == %{"models" => ["model1", "model2"]}
      assert config.id != nil

      # Verify it's in the database
      assert {:ok, _} = TableConsensusConfig.get("new_key")
    end

    # R4: WHEN upsert called with existing key THEN updates value and returns {:ok, config}
    test "upsert updates existing config entry" do
      # Insert first
      {:ok, original} =
        TableConsensusConfig.upsert("update_test", %{"version" => 1})

      # Update
      {:ok, updated} =
        TableConsensusConfig.upsert("update_test", %{"version" => 2})

      # Same record (same id)
      assert updated.id == original.id
      # Updated value
      assert updated.value == %{"version" => 2}
      # Key unchanged
      assert updated.key == "update_test"
    end
  end

  describe "delete/1" do
    setup do
      {:ok, config} =
        TableConsensusConfig.upsert("deletable_key", %{"temp" => true})

      %{config: config}
    end

    # R5: WHEN delete called with existing key THEN removes and returns {:ok, config}
    test "delete removes existing config entry", %{config: config} do
      assert {:ok, deleted} = TableConsensusConfig.delete("deletable_key")
      assert deleted.id == config.id

      # Verify it's gone
      assert {:error, :not_found} = TableConsensusConfig.get("deletable_key")
    end

    # R6: WHEN delete called with missing key THEN returns {:error, :not_found}
    test "delete returns error for missing key" do
      assert {:error, :not_found} = TableConsensusConfig.delete("nonexistent_key")
    end
  end

  describe "list_all/0" do
    setup do
      {:ok, c1} = TableConsensusConfig.upsert("config_1", %{"a" => 1})
      {:ok, c2} = TableConsensusConfig.upsert("config_2", %{"b" => 2})
      {:ok, c3} = TableConsensusConfig.upsert("config_3", %{"c" => 3})
      %{configs: [c1, c2, c3]}
    end

    # R7: WHEN list_all called THEN returns all config entries
    test "list_all returns all config entries", %{configs: configs} do
      all = TableConsensusConfig.list_all()
      assert length(all) >= 3

      config_ids = Enum.map(configs, & &1.id)
      retrieved_ids = Enum.map(all, & &1.id)

      Enum.each(config_ids, fn id ->
        assert id in retrieved_ids
      end)
    end
  end

  describe "changeset validation" do
    # R8: WHEN changeset created without key THEN changeset invalid
    test "changeset requires key" do
      changeset = TableConsensusConfig.changeset(%{value: %{"test" => true}})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in (errors[:key] || [])
    end

    # R9: WHEN changeset created without value THEN changeset invalid
    test "changeset requires value" do
      changeset = TableConsensusConfig.changeset(%{key: "test_key"})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in (errors[:value] || [])
    end

    # R10: WHEN insert with duplicate key THEN unique constraint error
    test "insert fails on duplicate key" do
      {:ok, _} = TableConsensusConfig.upsert("unique_key", %{"first" => true})

      # Try direct insert with same key (bypassing upsert logic)
      changeset =
        TableConsensusConfig.changeset(%{
          key: "unique_key",
          value: %{"second" => true}
        })

      assert {:error, failed_changeset} = Quoracle.Repo.insert(changeset)
      errors = errors_on(failed_changeset)
      assert "has already been taken" in (errors[:key] || [])
    end

    # R11: WHEN key exceeds 255 chars THEN changeset invalid
    test "changeset rejects keys over 255 characters" do
      long_key = String.duplicate("a", 256)

      changeset =
        TableConsensusConfig.changeset(%{
          key: long_key,
          value: %{"test" => true}
        })

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "should be at most 255 character(s)" in (errors[:key] || [])
    end
  end

  describe "JSONB storage" do
    # R12: WHEN map value stored THEN retrieved as map with same structure
    test "stores and retrieves map values correctly" do
      original_value = %{
        "string" => "hello",
        "number" => 42,
        "boolean" => true,
        "null_value" => nil
      }

      {:ok, _} = TableConsensusConfig.upsert("map_test", original_value)
      {:ok, retrieved} = TableConsensusConfig.get("map_test")

      assert retrieved.value == original_value
    end

    # R13: WHEN nested map stored THEN all nesting preserved on retrieval
    test "preserves nested map structure" do
      nested_value = %{
        "level1" => %{
          "level2" => %{
            "level3" => %{
              "deep" => "value"
            }
          }
        }
      }

      {:ok, _} = TableConsensusConfig.upsert("nested_test", nested_value)
      {:ok, retrieved} = TableConsensusConfig.get("nested_test")

      assert retrieved.value == nested_value
      assert get_in(retrieved.value, ["level1", "level2", "level3", "deep"]) == "value"
    end

    # R14: WHEN map with list values stored THEN lists preserved on retrieval
    test "preserves list values in maps" do
      value_with_lists = %{
        "models" => ["model_a", "model_b", "model_c"],
        "numbers" => [1, 2, 3, 4, 5],
        "mixed" => ["string", 123, true, nil]
      }

      {:ok, _} = TableConsensusConfig.upsert("list_test", value_with_lists)
      {:ok, retrieved} = TableConsensusConfig.get("list_test")

      assert retrieved.value == value_with_lists
      assert retrieved.value["models"] == ["model_a", "model_b", "model_c"]
      assert retrieved.value["numbers"] == [1, 2, 3, 4, 5]
    end
  end
end
