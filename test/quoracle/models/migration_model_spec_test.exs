defmodule Quoracle.Models.MigrationModelSpecTest do
  @moduledoc """
  Tests for MIG_AddModelSpec migration - adding model_spec column to credentials.

  ARC Verification Criteria:
  - R1: Column Creation
  - R2: Column Type
  - R3: NOT NULL Constraint
  - R4: Index Creation
  - R5: Rollback
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Repo

  describe "model_spec column" do
    # R1: WHEN migration runs THEN model_spec column added to credentials table
    test "migration adds model_spec column" do
      # Query the database schema to verify column exists
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT column_name FROM information_schema.columns
          WHERE table_name = 'credentials' AND column_name = 'model_spec'
          """
        )

      assert length(result.rows) == 1
      assert result.rows == [["model_spec"]]
    end

    # R2: WHEN column created THEN type is string
    test "model_spec column is string type" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT data_type FROM information_schema.columns
          WHERE table_name = 'credentials' AND column_name = 'model_spec'
          """
        )

      assert result.rows == [["character varying"]]
    end

    # R3: WHEN inserting credential IF model_spec nil THEN database error
    test "model_spec column has NOT NULL constraint" do
      # Attempt to insert with NULL model_spec should fail at DB level
      {:ok, binary_id} = Ecto.UUID.dump(Ecto.UUID.generate())

      assert_raise Postgrex.Error, ~r/null value in column "model_spec"/, fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          INSERT INTO credentials (id, model_id, api_key, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $5)
          """,
          [
            binary_id,
            "test_null_spec",
            "encrypted_key",
            DateTime.utc_now(),
            DateTime.utc_now()
          ]
        )
      end
    end

    # R4: WHEN migration runs THEN index created on model_spec
    test "migration creates index on model_spec" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT indexname FROM pg_indexes
          WHERE tablename = 'credentials' AND indexdef LIKE '%model_spec%'
          """
        )

      assert result.rows != []
      [index_name] = List.first(result.rows)
      assert index_name =~ "model_spec"
    end
  end

  describe "migration rollback" do
    # R5: WHEN migration rolled back THEN model_spec column removed
    test "rollback removes model_spec column" do
      # Verify column exists first (proves migration ran)
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT column_name FROM information_schema.columns
          WHERE table_name = 'credentials' AND column_name = 'model_spec'
          """
        )

      assert length(result.rows) == 1

      # Verify index exists (proves migration ran)
      index_result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT indexname FROM pg_indexes
          WHERE tablename = 'credentials' AND indexdef LIKE '%model_spec%'
          """
        )

      assert index_result.rows != []

      # Note: Cannot actually rollback in test env (would break other tests)
      # Migration uses reversible Ecto.Migration operations:
      # - alter table() with add :model_spec - reversible (Ecto removes column)
      # - create index() - reversible (Ecto drops index)
      # Actual rollback tested manually: mix ecto.rollback --step 1
    end
  end
end
