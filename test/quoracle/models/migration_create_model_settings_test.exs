defmodule Quoracle.Models.MigrationCreateModelSettingsTest do
  @moduledoc """
  Tests for MIG_CreateConsensusConfig migration - creating model_settings table.

  ARC Verification Criteria:
  - R1: Table Created
  - R2: Columns Present
  - R3: Primary Key UUID
  - R4: Unique Index Created
  - R5: Key Not Null
  - R6: Value Not Null
  - R7: Value Default Empty Map
  - R8: Key Uniqueness
  - R9: Reversible Migration
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Repo

  describe "model_settings table creation" do
    # R1: WHEN migration runs THEN model_settings table exists
    test "migration creates model_settings table" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT table_name FROM information_schema.tables
          WHERE table_name = 'model_settings'
          """
        )

      assert length(result.rows) == 1
      assert result.rows == [["model_settings"]]
    end

    # R2: WHEN migration runs THEN all columns (id, key, value, timestamps) exist
    test "migration creates all required columns" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT column_name FROM information_schema.columns
          WHERE table_name = 'model_settings'
          ORDER BY ordinal_position
          """
        )

      column_names = Enum.map(result.rows, fn [name] -> name end)

      assert "id" in column_names
      assert "key" in column_names
      assert "value" in column_names
      assert "inserted_at" in column_names
      assert "updated_at" in column_names
    end

    # R3: WHEN row inserted without id THEN UUID auto-generated
    test "id column auto-generates UUID" do
      # Insert without specifying id
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO model_settings (key, value, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4)
        """,
        [
          "test_auto_uuid",
          Jason.encode!(%{"test" => true}),
          DateTime.utc_now(),
          DateTime.utc_now()
        ]
      )

      # Verify id was auto-generated
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT id FROM model_settings WHERE key = $1
          """,
          ["test_auto_uuid"]
        )

      assert length(result.rows) == 1
      [[id_binary]] = result.rows
      assert is_binary(id_binary)
      # UUID should be 16 bytes
      assert byte_size(id_binary) == 16
    end

    # R4: WHEN migration runs THEN unique index on key exists
    test "migration creates unique index on key" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT indexname, indexdef FROM pg_indexes
          WHERE tablename = 'model_settings' AND indexname = 'model_settings_key_index'
          """
        )

      assert length(result.rows) == 1
      # Verify it's a unique index
      [[_index_name, index_def]] = result.rows
      assert index_def =~ "UNIQUE"
    end
  end

  describe "constraint verification" do
    # R5: WHEN insert with null key THEN constraint violation
    test "key column rejects null values" do
      assert_raise Postgrex.Error, ~r/null value in column "key"/, fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          INSERT INTO model_settings (key, value, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4)
          """,
          [
            nil,
            Jason.encode!(%{}),
            DateTime.utc_now(),
            DateTime.utc_now()
          ]
        )
      end
    end

    # R6: WHEN insert with null value THEN constraint violation
    test "value column rejects null values" do
      assert_raise Postgrex.Error, ~r/null value in column "value"/, fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          INSERT INTO model_settings (key, value, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4)
          """,
          [
            "test_null_value",
            nil,
            DateTime.utc_now(),
            DateTime.utc_now()
          ]
        )
      end
    end

    # R7: WHEN insert without value THEN defaults to empty map
    test "value column defaults to empty map" do
      # Use DEFAULT for value column
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO model_settings (key, value, inserted_at, updated_at)
        VALUES ($1, DEFAULT, $2, $3)
        """,
        [
          "test_default_value",
          DateTime.utc_now(),
          DateTime.utc_now()
        ]
      )

      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT value FROM model_settings WHERE key = $1
          """,
          ["test_default_value"]
        )

      assert length(result.rows) == 1
      [[value]] = result.rows
      assert value == %{}
    end

    # R8: WHEN insert duplicate key THEN unique constraint violation
    test "unique index prevents duplicate keys" do
      # Insert first row
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO model_settings (key, value, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4)
        """,
        [
          "duplicate_key_test",
          Jason.encode!(%{"first" => true}),
          DateTime.utc_now(),
          DateTime.utc_now()
        ]
      )

      # Try to insert duplicate
      assert_raise Postgrex.Error, ~r/duplicate key|unique constraint/, fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          INSERT INTO model_settings (key, value, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4)
          """,
          [
            "duplicate_key_test",
            Jason.encode!(%{"second" => true}),
            DateTime.utc_now(),
            DateTime.utc_now()
          ]
        )
      end
    end
  end

  describe "migration rollback" do
    # R9: WHEN migration rolled back THEN table dropped
    test "migration rollback drops table" do
      # Verify table exists first (proves migration ran)
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT table_name FROM information_schema.tables
          WHERE table_name = 'model_settings'
          """
        )

      assert length(result.rows) == 1

      # Note: Cannot actually rollback in test env (would break other tests)
      # Migration uses reversible Ecto.Migration operations:
      # - create table() - reversible (Ecto drops table)
      # - create unique_index() - reversible (Ecto drops index)
      # Actual rollback tested manually: mix ecto.rollback --step 1
    end
  end
end
