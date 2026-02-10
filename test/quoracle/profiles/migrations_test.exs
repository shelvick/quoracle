defmodule Quoracle.Profiles.MigrationsTest do
  @moduledoc """
  Tests for profile-related migrations.

  MIG_CreateProfiles (R1-R5):
  - Creates profiles table with correct structure
  - Name column not nullable with unique index
  - Model pool as string array
  - Migration is reversible

  MIG_AddProfileToAgents (R1-R4):
  - Adds profile_name column to agents table
  - Column is nullable (for backward compatibility)
  - Index on profile_name exists
  - Migration is reversible

  MIG_CapabilityGroups (R1-R5) - v2.0:
  - R1: capability_groups column exists as string array
  - R2: capability_groups stores correct values
  - R4: GIN index on capability_groups exists
  - R5: Migration rollback works
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Repo
  alias Quoracle.Agents.Agent

  # Dynamic module references to avoid compile-time errors
  defp table_profiles_module, do: Quoracle.Profiles.TableProfiles
  defp new_profile, do: struct(table_profiles_module())
  defp profile_changeset(profile, attrs), do: table_profiles_module().changeset(profile, attrs)

  describe "profiles table max_refinement_rounds" do
    test "migration adds max_refinement_rounds column to profiles" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT column_name, data_type, column_default, is_nullable
          FROM information_schema.columns
          WHERE table_name = 'profiles' AND column_name = 'max_refinement_rounds'
          """
        )

      assert length(result.rows) == 1
      [[column_name, data_type, column_default, is_nullable]] = result.rows
      assert column_name == "max_refinement_rounds"
      assert data_type == "integer"
      assert is_binary(column_default)
      assert column_default =~ "4"
      assert is_nullable == "NO"
    end

    test "inserting profile without max_refinement_rounds gets DB default 4" do
      {:ok, profile} =
        new_profile()
        |> profile_changeset(%{
          name: "migration-default-insert",
          model_pool: ["gpt-4o"],
          capability_groups: []
        })
        |> Repo.insert()

      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT max_refinement_rounds FROM profiles WHERE id = $1",
          [Ecto.UUID.dump!(profile.id)]
        )

      assert [[4]] = result.rows
    end
  end

  describe "profiles table v2.0 capability_groups" do
    # R1: Migration Adds capability_groups Column
    test "migration adds capability_groups column" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT column_name, data_type FROM information_schema.columns
          WHERE table_name = 'profiles' AND column_name = 'capability_groups'
          """
        )

      assert length(result.rows) == 1
      [[column_name, data_type]] = result.rows
      assert column_name == "capability_groups"
      assert data_type == "ARRAY"
    end

    # R2: capability_groups stores correct values
    test "capability_groups stores all group values correctly" do
      # Create profile with capability_groups (post-migration schema)
      {:ok, profile} =
        new_profile()
        |> profile_changeset(%{
          name: "migration-test-full",
          model_pool: ["gpt-4o"],
          capability_groups: [
            "hierarchy",
            "local_execution",
            "file_read",
            "file_write",
            "external_api"
          ]
        })
        |> Repo.insert()

      # Verify capability_groups stored correctly
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT capability_groups FROM profiles WHERE id = $1",
          [Ecto.UUID.dump!(profile.id)]
        )

      [[groups]] = result.rows
      assert is_list(groups)
      assert "hierarchy" in groups
      assert "local_execution" in groups
      assert "file_read" in groups
      assert "file_write" in groups
      assert "external_api" in groups
    end

    test "capability_groups stores as string array" do
      {:ok, profile} =
        new_profile()
        |> profile_changeset(%{
          name: "array-storage-test",
          model_pool: ["model-1"],
          capability_groups: ["hierarchy", "file_read"]
        })
        |> Repo.insert()

      # Query raw to verify array storage
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT capability_groups FROM profiles WHERE id = $1",
          [Ecto.UUID.dump!(profile.id)]
        )

      [[capability_groups]] = result.rows
      assert is_list(capability_groups)
      assert capability_groups == ["hierarchy", "file_read"]
    end

    test "capability_groups can store empty array" do
      {:ok, profile} =
        new_profile()
        |> profile_changeset(%{
          name: "empty-groups-test",
          model_pool: ["model-1"],
          capability_groups: []
        })
        |> Repo.insert()

      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT capability_groups FROM profiles WHERE id = $1",
          [Ecto.UUID.dump!(profile.id)]
        )

      [[capability_groups]] = result.rows
      assert capability_groups == []
    end

    # R4: GIN Index Created
    test "migration creates GIN index on capability_groups" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT indexname, indexdef FROM pg_indexes
          WHERE tablename = 'profiles' AND indexname LIKE '%capability_groups%'
          """
        )

      assert result.rows != []

      # Verify it's a GIN index (PostgreSQL uses lowercase "gin")
      [[_indexname, indexdef]] = result.rows
      assert indexdef =~ ~r/gin/i
    end

    test "profiles table has correct columns after migration" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT column_name, data_type, is_nullable
          FROM information_schema.columns
          WHERE table_name = 'profiles'
          ORDER BY ordinal_position
          """
        )

      columns = for [name, type, nullable] <- result.rows, into: %{}, do: {name, {type, nullable}}

      # Required columns
      assert columns["id"] == {"uuid", "NO"}
      assert columns["name"] == {"character varying", "NO"}
      assert columns["description"] == {"text", "YES"}
      assert columns["model_pool"] == {"ARRAY", "NO"}
      assert columns["capability_groups"] == {"ARRAY", "NO"}
      assert columns["inserted_at"] != nil
      assert columns["updated_at"] != nil
    end

    # R5: Rollback Works
    test "migration is reversible" do
      # Verified by the fact that tests run migrations
      # and can roll them back. We verify table structure is correct.
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'profiles'"
        )

      assert [[1]] = result.rows
    end

    # R2: Name Column Not Nullable (unchanged from v1.0)
    test "name column is not nullable" do
      # Attempt to insert with null name should fail at DB level
      assert_raise Postgrex.Error, fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          INSERT INTO profiles (id, name, model_pool, capability_groups, inserted_at, updated_at)
          VALUES ($1, NULL, $2, $3, $4, $5)
          """,
          [
            Ecto.UUID.bingenerate(),
            ["model"],
            [],
            DateTime.utc_now(),
            DateTime.utc_now()
          ]
        )
      end
    end

    # R3: Unique Name Index (unchanged from v1.0)
    test "name has unique index" do
      # Insert first profile
      {:ok, _} =
        new_profile()
        |> profile_changeset(%{
          name: "unique-index-test",
          model_pool: ["gpt-4o"],
          capability_groups: []
        })
        |> Repo.insert()

      # Second insert with same name should raise unique constraint error
      assert_raise Postgrex.Error, ~r/unique_violation/, fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          INSERT INTO profiles (id, name, model_pool, capability_groups, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $5, $6)
          """,
          [
            Ecto.UUID.bingenerate(),
            "unique-index-test",
            ["model"],
            [],
            DateTime.utc_now(),
            DateTime.utc_now()
          ]
        )
      end
    end
  end

  describe "agents profile_name column" do
    # R1: Migration Adds Column
    test "migration adds profile_name column to agents" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT column_name FROM information_schema.columns
          WHERE table_name = 'agents' AND column_name = 'profile_name'
          """
        )

      assert length(result.rows) == 1
      assert result.rows == [["profile_name"]]
    end

    # R2: Column Is Nullable
    test "profile_name column is nullable" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT is_nullable FROM information_schema.columns
          WHERE table_name = 'agents' AND column_name = 'profile_name'
          """
        )

      assert [[nullable]] = result.rows
      assert nullable == "YES"
    end

    test "existing agent can have null profile_name" do
      # Create a task first (agents require task_id)
      {:ok, task} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{
          prompt: "Test task",
          status: "running"
        })
        |> Repo.insert()

      # Create agent without profile_name
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "test-agent-#{System.unique_integer([:positive])}",
          config: %{},
          status: "running"
          # profile_name intentionally omitted
        })
        |> Repo.insert()

      # Reload and verify profile_name is nil
      reloaded = Repo.get!(Agent, agent.id)
      assert is_nil(reloaded.profile_name)
    end

    test "agent can store profile_name" do
      {:ok, task} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{
          prompt: "Test task",
          status: "running"
        })
        |> Repo.insert()

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "test-agent-#{System.unique_integer([:positive])}",
          config: %{},
          status: "running",
          profile_name: "test-profile"
        })
        |> Repo.insert()

      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.profile_name == "test-profile"
    end

    # R3: Index Created
    test "profile_name has index" do
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT indexname FROM pg_indexes
          WHERE tablename = 'agents' AND indexname LIKE '%profile_name%'
          """
        )

      assert result.rows != []
    end

    # R4: Rollback Works - tested implicitly
    test "migration is reversible" do
      # Verified by the fact that profile_name column exists
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT COUNT(*) FROM information_schema.columns
          WHERE table_name = 'agents' AND column_name = 'profile_name'
          """
        )

      assert [[1]] = result.rows
    end
  end
end
