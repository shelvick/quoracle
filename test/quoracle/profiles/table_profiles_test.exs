defmodule Quoracle.Profiles.TableProfilesTest do
  @moduledoc """
  Tests for TABLE_Profiles - Ecto schema for profiles table.

  Tests cover all ARC requirements R1-R11 (v2.0 Capability Groups):
  - R1: Schema field definitions (including capability_groups)
  - R2: Name required validation
  - R3: Name format validation
  - R4: Name uniqueness (integration)
  - R5: Model_pool required
  - R6: Model_pool minimum length
  - R7: Capability_groups optional (defaults to [])
  - R8: Capability_groups validation
  - R9: Valid capability_groups produce valid changeset
  - R10: Description optional
  - R11: capability_groups_as_atoms/1 converts strings to atoms
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Repo

  # Dynamic module reference to avoid compile-time errors
  defp table_profiles_module, do: Quoracle.Profiles.TableProfiles

  defp new_profile, do: struct(table_profiles_module())

  defp changeset(profile, attrs), do: table_profiles_module().changeset(profile, attrs)

  describe "schema" do
    # R1: Schema Has Required Fields
    test "schema defines all required fields including capability_groups" do
      profile = new_profile()

      # Check all expected fields exist
      assert Map.has_key?(profile, :id)
      assert Map.has_key?(profile, :name)
      assert Map.has_key?(profile, :description)
      assert Map.has_key?(profile, :model_pool)
      assert Map.has_key?(profile, :capability_groups)
      assert Map.has_key?(profile, :inserted_at)
      assert Map.has_key?(profile, :updated_at)
    end
  end

  describe "changeset validations" do
    # R2: Name Required Validation
    test "changeset requires name" do
      attrs = %{
        model_pool: ["gpt-4o"],
        capability_groups: ["hierarchy"]
      }

      cs = changeset(new_profile(), attrs)

      refute cs.valid?
      assert errors_on(cs)[:name] == ["can't be blank"]
    end

    test "changeset requires name not to be empty string" do
      attrs = %{
        name: "",
        model_pool: ["gpt-4o"],
        capability_groups: []
      }

      cs = changeset(new_profile(), attrs)

      refute cs.valid?
      # Either "can't be blank" or length validation error
      assert errors_on(cs)[:name] != nil
    end

    # R3: Name Format Validation
    test "changeset validates name format" do
      attrs = %{
        name: "invalid name!",
        model_pool: ["gpt-4o"],
        capability_groups: []
      }

      cs = changeset(new_profile(), attrs)

      refute cs.valid?
      assert errors_on(cs)[:name] == ["must be alphanumeric with hyphens/underscores"]
    end

    test "changeset accepts valid name formats" do
      valid_names = ["my-profile", "my_profile", "MyProfile123", "profile-1_test"]

      for name <- valid_names do
        attrs = %{
          name: name,
          model_pool: ["gpt-4o"],
          capability_groups: []
        }

        cs = changeset(new_profile(), attrs)
        assert cs.valid?, "Expected #{name} to be valid"
      end
    end

    test "changeset rejects invalid name formats" do
      invalid_names = ["has space", "has@symbol", "has.dot", "has/slash", "name!"]

      for name <- invalid_names do
        attrs = %{
          name: name,
          model_pool: ["gpt-4o"],
          capability_groups: []
        }

        cs = changeset(new_profile(), attrs)
        refute cs.valid?, "Expected #{name} to be invalid"
        assert errors_on(cs)[:name] != nil
      end
    end

    test "changeset validates name max length" do
      long_name = String.duplicate("a", 51)

      attrs = %{
        name: long_name,
        model_pool: ["gpt-4o"],
        capability_groups: []
      }

      cs = changeset(new_profile(), attrs)

      refute cs.valid?
      assert errors_on(cs)[:name] != nil
    end

    # R5: Model_Pool Required
    test "changeset requires model_pool" do
      attrs = %{
        name: "test-profile",
        capability_groups: []
      }

      cs = changeset(new_profile(), attrs)

      refute cs.valid?
      assert errors_on(cs)[:model_pool] == ["can't be blank"]
    end

    # R6: Model_Pool Minimum Length
    test "model_pool must have at least one model" do
      attrs = %{
        name: "test-profile",
        model_pool: [],
        capability_groups: []
      }

      cs = changeset(new_profile(), attrs)

      refute cs.valid?
      assert errors_on(cs)[:model_pool] == ["must have at least one model"]
    end

    test "model_pool validates all entries are strings" do
      attrs = %{
        name: "test-profile",
        model_pool: ["valid", 123, :atom],
        capability_groups: []
      }

      cs = changeset(new_profile(), attrs)

      refute cs.valid?
      # Ecto array cast fails before custom validation - returns "is invalid"
      assert errors_on(cs)[:model_pool] == ["is invalid"]
    end

    # R7: Capability_Groups Optional
    test "capability_groups is optional and defaults to empty list" do
      attrs = %{
        name: "test-profile",
        model_pool: ["gpt-4o"]
        # No capability_groups provided
      }

      cs = changeset(new_profile(), attrs)

      assert cs.valid?
      # Default should be empty list
      assert Ecto.Changeset.get_field(cs, :capability_groups) == []
    end

    # R8: Capability_Groups Validation
    test "capability_groups validates group names" do
      attrs = %{
        name: "test-profile",
        model_pool: ["gpt-4o"],
        capability_groups: ["invalid_group"]
      }

      cs = changeset(new_profile(), attrs)

      refute cs.valid?
      assert errors_on(cs)[:capability_groups] != nil
    end

    test "capability_groups rejects mixed valid and invalid groups" do
      attrs = %{
        name: "test-profile",
        model_pool: ["gpt-4o"],
        capability_groups: ["hierarchy", "not_a_group", "file_read"]
      }

      cs = changeset(new_profile(), attrs)

      refute cs.valid?
      errors = errors_on(cs)[:capability_groups]
      assert errors != nil
      # Error message should mention the invalid group
      assert Enum.any?(errors, &(&1 =~ "not_a_group"))
    end

    # R9: Valid Capability_Groups
    test "valid capability_groups produce valid changeset" do
      valid_groups = ["hierarchy", "local_execution", "file_read", "file_write", "external_api"]

      attrs = %{
        name: "valid-profile",
        description: "A valid test profile",
        model_pool: ["gpt-4o", "claude-opus"],
        capability_groups: valid_groups
      }

      cs = changeset(new_profile(), attrs)

      assert cs.valid?
    end

    test "single valid capability_group produces valid changeset" do
      for group <- ["hierarchy", "local_execution", "file_read", "file_write", "external_api"] do
        attrs = %{
          name: "test-#{group}",
          model_pool: ["gpt-4o"],
          capability_groups: [group]
        }

        cs = changeset(new_profile(), attrs)
        assert cs.valid?, "Expected capability_group #{group} to be valid"
      end
    end

    # R10: Description Optional
    test "description is optional" do
      attrs = %{
        name: "no-description",
        model_pool: ["gpt-4o"],
        capability_groups: []
        # No description
      }

      cs = changeset(new_profile(), attrs)

      assert cs.valid?
    end

    test "description max length validation" do
      long_description = String.duplicate("a", 501)

      attrs = %{
        name: "test-profile",
        description: long_description,
        model_pool: ["gpt-4o"],
        capability_groups: []
      }

      cs = changeset(new_profile(), attrs)

      refute cs.valid?
      assert errors_on(cs)[:description] != nil
    end
  end

  describe "capability_groups_as_atoms/1" do
    # R11: Capability_Groups As Atoms
    test "capability_groups_as_atoms converts strings to atoms" do
      # Create a profile struct with string capability_groups
      profile = %{
        new_profile()
        | capability_groups: ["hierarchy", "file_read", "local_execution"]
      }

      atoms = table_profiles_module().capability_groups_as_atoms(profile)

      assert atoms == [:hierarchy, :file_read, :local_execution]
      assert Enum.all?(atoms, &is_atom/1)
    end

    test "capability_groups_as_atoms returns empty list for nil" do
      profile = %{new_profile() | capability_groups: nil}

      atoms = table_profiles_module().capability_groups_as_atoms(profile)

      assert atoms == []
    end

    test "capability_groups_as_atoms returns empty list for empty groups" do
      profile = %{new_profile() | capability_groups: []}

      atoms = table_profiles_module().capability_groups_as_atoms(profile)

      assert atoms == []
    end

    test "capability_groups_as_atoms handles all valid group names" do
      all_groups = ["hierarchy", "local_execution", "file_read", "file_write", "external_api"]
      profile = %{new_profile() | capability_groups: all_groups}

      atoms = table_profiles_module().capability_groups_as_atoms(profile)

      assert length(atoms) == 5
      assert :hierarchy in atoms
      assert :local_execution in atoms
      assert :file_read in atoms
      assert :file_write in atoms
      assert :external_api in atoms
    end
  end

  describe "database operations" do
    test "inserts valid profile with capability_groups" do
      attrs = %{
        name: "db-test-profile",
        description: "Test profile for DB operations",
        model_pool: ["gpt-4o", "claude-opus"],
        capability_groups: ["hierarchy", "file_read"]
      }

      cs = changeset(new_profile(), attrs)
      {:ok, profile} = Repo.insert(cs)

      assert profile.id != nil
      assert profile.name == "db-test-profile"
      assert profile.description == "Test profile for DB operations"
      assert profile.model_pool == ["gpt-4o", "claude-opus"]
      assert profile.capability_groups == ["hierarchy", "file_read"]
      assert profile.inserted_at != nil
      assert profile.updated_at != nil
    end

    test "inserts profile with empty capability_groups" do
      attrs = %{
        name: "empty-groups-profile",
        model_pool: ["gpt-4o"],
        capability_groups: []
      }

      cs = changeset(new_profile(), attrs)
      {:ok, profile} = Repo.insert(cs)

      assert profile.capability_groups == []
    end

    # R4: Name Uniqueness
    test "name must be unique" do
      attrs = %{
        name: "unique-test",
        model_pool: ["gpt-4o"],
        capability_groups: []
      }

      {:ok, _first} =
        new_profile()
        |> changeset(attrs)
        |> Repo.insert()

      {:error, cs} =
        new_profile()
        |> changeset(attrs)
        |> Repo.insert()

      assert errors_on(cs)[:name] == ["has already been taken"]
    end

    test "retrieves profile with correct types" do
      attrs = %{
        name: "retrieve-test",
        model_pool: ["model-1", "model-2"],
        capability_groups: ["hierarchy", "external_api"]
      }

      {:ok, inserted} =
        new_profile()
        |> changeset(attrs)
        |> Repo.insert()

      fetched = Repo.get!(table_profiles_module(), inserted.id)

      assert fetched.name == "retrieve-test"
      assert fetched.model_pool == ["model-1", "model-2"]
      assert fetched.capability_groups == ["hierarchy", "external_api"]
    end

    test "updates profile capability_groups" do
      {:ok, profile} =
        new_profile()
        |> changeset(%{
          name: "update-test",
          model_pool: ["original"],
          capability_groups: ["hierarchy"]
        })
        |> Repo.insert()

      {:ok, updated} =
        profile
        |> changeset(%{
          model_pool: ["updated-1", "updated-2"],
          capability_groups: ["file_read", "file_write", "external_api"]
        })
        |> Repo.update()

      assert updated.model_pool == ["updated-1", "updated-2"]
      assert updated.capability_groups == ["file_read", "file_write", "external_api"]
    end

    test "deletes profile" do
      {:ok, profile} =
        new_profile()
        |> changeset(%{
          name: "delete-test",
          model_pool: ["gpt-4o"],
          capability_groups: []
        })
        |> Repo.insert()

      {:ok, _deleted} = Repo.delete(profile)

      assert Repo.get(table_profiles_module(), profile.id) == nil
    end
  end
end
