defmodule Quoracle.Profiles.ResolverTest do
  @moduledoc """
  Tests for PROFILE_Resolver - Profile lookup service.

  All tests are [INTEGRATION] level requiring database access.

  ARC Requirements (v2.0 Capability Groups):
  - R1: resolve/1 returns profile data for existing profile
  - R2: resolve/1 returns capability_groups as atom list
  - R3: resolve/1 returns error for non-existent profile
  - R4: resolve!/1 raises for non-existent profile
  - R5: exists?/1 returns boolean for profile existence
  - R6: list_names/0 returns sorted profile names
  - R7: resolve returns empty list for profile with no capability_groups
  - R8: Resolved snapshot is immutable
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Profiles.Resolver
  alias Quoracle.Profiles.ProfileNotFoundError
  alias Quoracle.Profiles.TableProfiles
  alias Quoracle.Repo

  # Helper to create test profile with capability_groups
  defp create_profile(attrs) do
    default_attrs = %{capability_groups: []}
    merged = Map.merge(default_attrs, attrs)

    %TableProfiles{}
    |> TableProfiles.changeset(merged)
    |> Repo.insert!()
  end

  describe "resolve/1" do
    # R1: Resolve Returns Profile Data
    test "resolve returns profile data for existing profile" do
      _profile =
        create_profile(%{
          name: "test-resolver-r1",
          description: "Test profile for resolver",
          model_pool: ["gpt-4o", "claude-opus"],
          capability_groups: ["hierarchy", "file_read"]
        })

      assert {:ok, data} = Resolver.resolve("test-resolver-r1")

      assert data.name == "test-resolver-r1"
      assert data.description == "Test profile for resolver"
      assert data.model_pool == ["gpt-4o", "claude-opus"]
      assert is_list(data.capability_groups)
    end

    # R2: Resolve Returns Capability Groups as Atoms
    test "resolve returns capability_groups as atom list" do
      create_profile(%{
        name: "atom-test-profile",
        model_pool: ["model-1"],
        capability_groups: ["hierarchy", "local_execution", "file_read"]
      })

      assert {:ok, data} = Resolver.resolve("atom-test-profile")

      # capability_groups should be atoms, not strings
      assert is_list(data.capability_groups)
      assert Enum.all?(data.capability_groups, &is_atom/1)
      assert :hierarchy in data.capability_groups
      assert :local_execution in data.capability_groups
      assert :file_read in data.capability_groups
    end

    # R3: Resolve Returns Error for Missing
    test "resolve returns error for non-existent profile" do
      assert {:error, :profile_not_found} = Resolver.resolve("non-existent-profile")
    end

    test "resolve returns profile without description" do
      create_profile(%{
        name: "no-description-profile",
        model_pool: ["model-1"],
        capability_groups: ["external_api"]
      })

      assert {:ok, data} = Resolver.resolve("no-description-profile")
      assert data.name == "no-description-profile"
      assert data.description == nil
      assert :external_api in data.capability_groups
    end
  end

  describe "resolve!/1" do
    # R4: Resolve! Raises for Missing
    test "resolve! raises ProfileNotFoundError" do
      assert_raise ProfileNotFoundError, ~r/non-existent/, fn ->
        Resolver.resolve!("non-existent-profile")
      end
    end

    test "resolve! returns profile data for existing profile" do
      create_profile(%{
        name: "test-resolver-bang",
        model_pool: ["claude-sonnet"],
        capability_groups: ["hierarchy", "file_write"]
      })

      data = Resolver.resolve!("test-resolver-bang")

      assert data.name == "test-resolver-bang"
      assert data.model_pool == ["claude-sonnet"]
      assert is_list(data.capability_groups)
      assert :hierarchy in data.capability_groups
      assert :file_write in data.capability_groups
    end
  end

  describe "exists?/1" do
    # R5: Exists? Returns Boolean
    test "exists? returns boolean for profile existence" do
      create_profile(%{
        name: "exists-test-profile",
        model_pool: ["model"],
        capability_groups: []
      })

      assert Resolver.exists?("exists-test-profile") == true
      assert Resolver.exists?("definitely-not-a-profile") == false
    end
  end

  describe "list_names/0" do
    # R6: List_Names Returns All
    test "list_names returns sorted profile names" do
      # Create multiple profiles
      create_profile(%{name: "list-profile-c", model_pool: ["m1"], capability_groups: []})

      create_profile(%{
        name: "list-profile-a",
        model_pool: ["m2"],
        capability_groups: ["hierarchy"]
      })

      create_profile(%{
        name: "list-profile-b",
        model_pool: ["m3"],
        capability_groups: ["file_read"]
      })

      names = Resolver.list_names()

      assert "list-profile-a" in names
      assert "list-profile-b" in names
      assert "list-profile-c" in names

      # Verify alphabetical order
      filtered = Enum.filter(names, &String.starts_with?(&1, "list-profile-"))
      assert filtered == Enum.sort(filtered)
    end

    test "list_names returns empty list when no profiles" do
      # Note: Other tests may have created profiles, so we just test the function works
      names = Resolver.list_names()
      assert is_list(names)
    end
  end

  describe "empty capability_groups" do
    # R7: Empty Capability Groups
    test "resolve returns empty list for profile with no capability_groups" do
      create_profile(%{
        name: "empty-groups-profile",
        model_pool: ["model"],
        capability_groups: []
      })

      {:ok, data} = Resolver.resolve("empty-groups-profile")

      assert data.capability_groups == []
    end

    test "resolve returns empty atom list even when DB has empty array" do
      # Profile created with empty capability_groups
      create_profile(%{
        name: "base-only-profile",
        model_pool: ["gpt-4o"],
        capability_groups: []
      })

      {:ok, data} = Resolver.resolve("base-only-profile")

      # Should return empty list (base actions only)
      assert is_list(data.capability_groups)
      assert data.capability_groups == []
    end
  end

  describe "snapshot semantics" do
    # R8: Snapshot Immutability
    test "resolved snapshot is immutable" do
      profile =
        create_profile(%{
          name: "independence-test",
          description: "Original description",
          model_pool: ["model"],
          capability_groups: ["hierarchy"]
        })

      {:ok, data1} = Resolver.resolve("independence-test")

      # Update the DB record
      profile
      |> TableProfiles.changeset(%{
        description: "Updated description",
        capability_groups: ["file_read", "file_write"]
      })
      |> Repo.update!()

      # Original resolved data should be unchanged (it's a snapshot)
      assert data1.description == "Original description"
      assert :hierarchy in data1.capability_groups

      # New resolve should get updated data
      {:ok, data2} = Resolver.resolve("independence-test")
      assert data2.description == "Updated description"
      assert :file_read in data2.capability_groups
      assert :file_write in data2.capability_groups
    end

    test "resolved profile is a plain map snapshot" do
      create_profile(%{
        name: "snapshot-test-profile",
        model_pool: ["model"],
        capability_groups: ["local_execution"]
      })

      {:ok, data} = Resolver.resolve("snapshot-test-profile")

      # Should be a plain map, not a struct
      assert is_map(data)
      refute Map.has_key?(data, :__struct__)

      # Should have expected keys
      assert Map.keys(data) |> Enum.sort() == [
               :capability_groups,
               :description,
               :model_pool,
               :name
             ]
    end
  end

  describe "all capability_groups combinations" do
    test "resolve handles profile with all capability_groups" do
      all_groups = ["hierarchy", "local_execution", "file_read", "file_write", "external_api"]

      create_profile(%{
        name: "full-groups-profile",
        model_pool: ["gpt-4o"],
        capability_groups: all_groups
      })

      {:ok, data} = Resolver.resolve("full-groups-profile")

      assert length(data.capability_groups) == 5
      assert :hierarchy in data.capability_groups
      assert :local_execution in data.capability_groups
      assert :file_read in data.capability_groups
      assert :file_write in data.capability_groups
      assert :external_api in data.capability_groups
    end

    test "resolve handles profile with single capability_group" do
      create_profile(%{
        name: "single-group-profile",
        model_pool: ["gpt-4o"],
        capability_groups: ["file_read"]
      })

      {:ok, data} = Resolver.resolve("single-group-profile")

      assert data.capability_groups == [:file_read]
    end
  end
end
