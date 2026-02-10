defmodule QuoracleWeb.ProfileManagementLiveTest do
  @moduledoc """
  Tests for profile management with capability groups (Packet 5).

  WorkGroupID: feat-20260107-capability-groups

  ARC Requirements:
  - R1-R8: Integration tests for profile CRUD with capability groups
  - R9-R12: Unit tests for validation and display formatting
  - R13: Acceptance test for full CRUD flow
  """
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  alias Quoracle.Profiles.TableProfiles
  alias Quoracle.Repo
  alias QuoracleWeb.SecretManagementLive.ProfileHelpers

  setup do
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    # Insert credential so the model_pool select has options
    %Quoracle.Models.TableCredentials{}
    |> Quoracle.Models.TableCredentials.changeset(%{
      model_id: "azure:o1",
      model_spec: "azure:o1",
      api_key: "test-key",
      deployment_id: "o1"
    })
    |> Quoracle.Repo.insert(on_conflict: :nothing, conflict_target: :model_id)

    %{pubsub: pubsub}
  end

  defp mount_profile_management(conn, sandbox_owner, pubsub) do
    live_isolated(conn, QuoracleWeb.SecretManagementLive,
      session: %{
        "sandbox_owner" => sandbox_owner,
        "pubsub" => pubsub
      }
    )
  end

  defp switch_to_profiles_tab(view) do
    view
    |> element("[phx-click='switch_tab'][phx-value-tab='profiles']")
    |> render_click()

    view
  end

  # =============================================================================
  # Unit Tests (R9-R12)
  # =============================================================================

  describe "ProfileHelpers.format_groups_display/1 (R11)" do
    # R11: Groups Display Format [UNIT]
    test "returns 'all' when all 5 groups selected" do
      all_groups = [:file_read, :file_write, :external_api, :hierarchy, :local_execution]
      assert ProfileHelpers.format_groups_display(all_groups) == "all"
    end

    test "returns 'none (base only)' when no groups selected" do
      assert ProfileHelpers.format_groups_display([]) == "none (base only)"
    end

    test "returns comma-separated list for partial selection" do
      groups = [:file_read, :external_api]
      result = ProfileHelpers.format_groups_display(groups)
      assert result == "file_read, external_api"
    end

    test "handles string inputs by converting to display" do
      groups = ["file_read", "file_write"]
      result = ProfileHelpers.format_groups_display(groups)
      assert result == "file_read, file_write"
    end
  end

  describe "ProfileHelpers.ordered_capability_groups/0 (R12)" do
    # R12: Checkbox Order [UNIT]
    test "returns groups ordered by risk level (safest first)" do
      groups = ProfileHelpers.ordered_capability_groups()

      # Expected order: file_read → file_write → external_api → hierarchy → local_execution
      assert length(groups) == 5
      assert Enum.at(groups, 0) |> elem(0) == :file_read
      assert Enum.at(groups, 1) |> elem(0) == :file_write
      assert Enum.at(groups, 2) |> elem(0) == :external_api
      assert Enum.at(groups, 3) |> elem(0) == :hierarchy
      assert Enum.at(groups, 4) |> elem(0) == :local_execution
    end

    test "each group has a description" do
      groups = ProfileHelpers.ordered_capability_groups()

      for {name, description} <- groups do
        assert is_atom(name)
        assert is_binary(description)
        assert String.length(description) > 0
      end
    end
  end

  describe "Profile validation (R9, R10)" do
    # R9: Model Selection Required [UNIT]
    test "changeset invalid without model_pool", %{sandbox_owner: _owner} do
      params = %{
        "name" => "test_profile",
        "model_pool" => [],
        "capability_groups" => ["file_read"]
      }

      changeset = TableProfiles.changeset(%TableProfiles{}, params)
      refute changeset.valid?
      assert {:model_pool, _} = Enum.find(changeset.errors, fn {k, _} -> k == :model_pool end)
    end

    # R10: Empty Groups Valid [UNIT]
    test "changeset valid with empty capability_groups", %{sandbox_owner: _owner} do
      params = %{
        "name" => "restricted_profile",
        "model_pool" => ["azure:o1"],
        "capability_groups" => []
      }

      changeset = TableProfiles.changeset(%TableProfiles{}, params)
      # Should be valid - empty groups means base actions only
      assert changeset.valid?
    end
  end

  # =============================================================================
  # Integration Tests (R1-R8)
  # =============================================================================

  describe "Profile list rendering (R1)" do
    # R1: Profile List Renders [INTEGRATION]
    test "profiles section shows all profiles with groups display", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # Create profile with capability groups (strings for DB)
      {:ok, _profile} =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "test_profile",
          description: "Test description",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read", "external_api"]
        })
        |> Repo.insert()

      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      html = render(view)

      # Profile should be visible
      assert html =~ "test_profile"
      assert html =~ "Test description"

      # Groups should be displayed per spec Section 4.3 format
      assert html =~ "file_read, external_api"
    end

    test "profile card shows 'all' when all groups selected", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, _profile} =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "full_profile",
          model_pool: ["azure:o1"],
          capability_groups: [
            "file_read",
            "file_write",
            "external_api",
            "hierarchy",
            "local_execution"
          ]
        })
        |> Repo.insert()

      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      html = render(view)
      # Spec Section 4.3: "Groups: all" when all 5 groups selected
      assert html =~ "all"
    end

    test "profile card shows 'none (base only)' when no groups selected", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, _profile} =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "restricted_profile",
          model_pool: ["azure:o1"],
          capability_groups: []
        })
        |> Repo.insert()

      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      html = render(view)
      # Spec Section 4.3: "Groups: none (base only)" when empty
      assert html =~ "none (base only)"
    end
  end

  describe "New profile form (R2)" do
    # R2: New Profile Button [INTEGRATION]
    test "new profile button opens form with capability checkboxes", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      # Click New Profile button
      view
      |> element("button", "New Profile")
      |> render_click()

      html = render(view)

      # Modal should be visible
      assert has_element?(view, "#profile-modal")

      # Should have checkboxes for capability groups
      assert html =~ "Capability Groups"
      # Checkbox input with name capability_groups[]
      assert html =~ ~r/type="checkbox".*name="profile\[capability_groups\]\[\]"/s
    end

    test "capability checkboxes are ordered safest to most dangerous", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      view
      |> element("button", "New Profile")
      |> render_click()

      html = render(view)

      # Check order: file_read appears before local_execution (per spec Section 4.2)
      file_read_pos = :binary.match(html, "file_read")
      local_exec_pos = :binary.match(html, "local_execution")

      assert file_read_pos != :nomatch, "file_read checkbox should exist"
      assert local_exec_pos != :nomatch, "local_execution checkbox should exist"

      {fr_start, _} = file_read_pos
      {le_start, _} = local_exec_pos
      assert fr_start < le_start, "file_read should appear before local_execution"
    end
  end

  describe "Create profile (R3)" do
    # R3: Create Profile with Groups [INTEGRATION]
    test "create profile with capability groups", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      view
      |> element("button", "New Profile")
      |> render_click()

      # Submit form with capability groups
      view
      |> form("#profile-form", %{
        profile: %{
          name: "new_profile",
          description: "Created with groups",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read", "external_api"]
        }
      })
      |> render_submit()

      # Modal should close
      refute has_element?(view, "#profile-modal")

      # Profile should appear in list
      html = render(view)
      assert html =~ "new_profile"

      # Verify in database
      profile = Repo.get_by(TableProfiles, name: "new_profile")
      assert profile != nil
      assert "file_read" in profile.capability_groups
      assert "external_api" in profile.capability_groups
    end
  end

  describe "Validation errors (R4, R8)" do
    # R4: Validation Errors [INTEGRATION]
    test "invalid profile shows errors", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      view
      |> element("button", "New Profile")
      |> render_click()

      # Submit invalid form (empty name) - use render_change to trigger validation
      view
      |> form("#profile-form", %{
        profile: %{
          name: "",
          model_pool: ["azure:o1"]
        }
      })
      |> render_change()

      # Then submit to trigger server-side validation
      html =
        view
        |> form("#profile-form", %{
          profile: %{
            name: "",
            model_pool: ["azure:o1"]
          }
        })
        |> render_submit()

      # Modal should stay open on validation error
      assert has_element?(view, "#profile-modal")
      # Should show error message (check for "blank" to handle HTML escaping of apostrophe)
      assert html =~ "blank"
    end

    # R8: Unique Name Validation [INTEGRATION]
    test "duplicate name shows error", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # Create existing profile
      {:ok, _} =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "existing_profile",
          model_pool: ["azure:o1"]
        })
        |> Repo.insert()

      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      view
      |> element("button", "New Profile")
      |> render_click()

      # Try to create with same name
      html =
        view
        |> form("#profile-form", %{
          profile: %{
            name: "existing_profile",
            model_pool: ["azure:o1"]
          }
        })
        |> render_submit()

      # Should show unique constraint error
      assert html =~ "has already been taken"
    end
  end

  describe "Edit profile (R5, R6)" do
    # R5: Edit Profile Loads Groups [INTEGRATION]
    test "edit profile shows saved capability groups", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, profile} =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "edit_me",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read", "hierarchy"]
        })
        |> Repo.insert()

      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      # Click edit button
      view
      |> element("[phx-click='edit_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      html = render(view)

      # Modal should be visible
      assert has_element?(view, "#profile-modal")

      # Saved groups should be checked - verify checkbox with checked attribute
      assert html =~ ~r/value="file_read"[^>]*checked/s
      assert html =~ ~r/value="hierarchy"[^>]*checked/s
    end

    # R6: Update Profile Groups [INTEGRATION]
    test "update profile saves capability group changes", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, profile} =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "update_me",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read"]
        })
        |> Repo.insert()

      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      view
      |> element("[phx-click='edit_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      # Update with different groups
      view
      |> form("#profile-form", %{
        profile: %{
          name: "update_me",
          model_pool: ["azure:o1"],
          capability_groups: ["file_write", "local_execution"]
        }
      })
      |> render_submit()

      # Verify database updated
      updated = Repo.get!(TableProfiles, profile.id)
      assert "file_write" in updated.capability_groups
      assert "local_execution" in updated.capability_groups
      refute "file_read" in updated.capability_groups
    end
  end

  describe "Delete profile (R7)" do
    # R7: Delete Profile [INTEGRATION]
    test "delete profile removes from list", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, profile} =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "delete_me",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read"]
        })
        |> Repo.insert()

      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      # Verify profile exists
      assert render(view) =~ "delete_me"

      # Click delete button
      view
      |> element("[phx-click='delete_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      # Profile should be removed
      refute render(view) =~ "delete_me"

      # Verify deleted from database
      assert Repo.get(TableProfiles, profile.id) == nil
    end
  end

  # =============================================================================
  # Acceptance Test (R13)
  # =============================================================================

  describe "Max refinement rounds UI (R14-R19)" do
    @tag :integration
    test "profile form shows max_refinement_rounds number input", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      view
      |> element("button", "New Profile")
      |> render_click()

      html = render(view)
      assert has_element?(view, "#profile-modal")
      assert html =~ "Max Refinement Rounds"
      assert has_element?(view, "input[name='profile[max_refinement_rounds]'][type='number']")
    end

    @tag :integration
    test "new profile form defaults max_refinement_rounds to 4", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      view
      |> element("button", "New Profile")
      |> render_click()

      html = render(view)

      assert html =~ ~r/name="profile\[max_refinement_rounds\]"[^>]*value="4"/s
    end

    @tag :integration
    test "edit form loads current max_refinement_rounds value", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, profile} =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "rounds_edit_profile",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read"],
          max_refinement_rounds: 7
        })
        |> Repo.insert()

      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      view
      |> element("[phx-click='edit_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      html = render(view)

      assert html =~ ~r/name="profile\[max_refinement_rounds\]"[^>]*value="7"/s
    end

    @tag :integration
    test "save profile shows updated max_refinement_rounds in card", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, profile} =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "rounds_save_profile",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read"],
          max_refinement_rounds: 4
        })
        |> Repo.insert()

      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      view
      |> element("[phx-click='edit_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      view
      |> form("#profile-form", %{
        profile: %{
          name: "rounds_save_profile",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read"],
          max_refinement_rounds: 6
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Rounds: 6"

      updated = Repo.get!(TableProfiles, profile.id)
      assert updated.max_refinement_rounds == 6
    end

    @tag :integration
    test "profile card displays max_refinement_rounds", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, _profile} =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "rounds_display_profile",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read"],
          max_refinement_rounds: 8
        })
        |> Repo.insert()

      {:ok, view, _html} = mount_profile_management(conn, sandbox_owner, pubsub)
      switch_to_profiles_tab(view)

      html = render(view)

      assert html =~ "rounds_display_profile"
      assert html =~ "Rounds: 8"
    end

    @tag :acceptance
    test "user creates and edits profile max_refinement_rounds end-to-end", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='profiles']")
      |> render_click()

      view |> element("button", "New Profile") |> render_click()

      view
      |> form("#profile-form", %{
        profile: %{
          name: "acceptance_rounds_profile",
          description: "Max rounds acceptance",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read"],
          max_refinement_rounds: 2
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ "acceptance_rounds_profile"
      assert html =~ "Rounds: 2"
      refute html =~ "Rounds: N/A"
      refute html =~ "has already been taken"

      profile = Repo.get_by!(TableProfiles, name: "acceptance_rounds_profile")

      view
      |> element("[phx-click='edit_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      view
      |> form("#profile-form", %{
        profile: %{
          name: "acceptance_rounds_profile",
          description: "Max rounds acceptance updated",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read"],
          max_refinement_rounds: 7
        }
      })
      |> render_submit()

      updated_html = render(view)
      assert updated_html =~ "Rounds: 7"
      refute updated_html =~ "Rounds: N/A"
      refute updated_html =~ "has already been taken"

      updated = Repo.get!(TableProfiles, profile.id)
      assert updated.max_refinement_rounds == 7
    end
  end

  describe "Full CRUD flow (R13)" do
    # R13: Acceptance - Full CRUD Flow [SYSTEM]
    # Uses real route for acceptance test (not live_isolated)
    @tag :acceptance
    test "end-to-end profile management with capability groups", %{conn: conn} do
      # Use real route for acceptance test entry point
      {:ok, view, _html} = live(conn, "/settings")

      # Switch to profiles tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='profiles']")
      |> render_click()

      # ============= CREATE =============
      # Open new profile form
      view |> element("button", "New Profile") |> render_click()
      assert has_element?(view, "#profile-modal")

      # Create profile with capability groups
      view
      |> form("#profile-form", %{
        profile: %{
          name: "acceptance_test_profile",
          description: "Full CRUD test",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read", "file_write", "external_api"]
        }
      })
      |> render_submit()

      refute has_element?(view, "#profile-modal")
      html = render(view)
      assert html =~ "acceptance_test_profile"

      # Verify groups display correctly (spec Section 4.3 format)
      assert html =~ "file_read, file_write, external_api"

      # Verify in database
      profile = Repo.get_by!(TableProfiles, name: "acceptance_test_profile")
      assert length(profile.capability_groups) == 3

      # ============= READ =============
      # Verify profile appears in list with correct groups display
      assert html =~ "Full CRUD test"

      # ============= UPDATE =============
      # Edit the profile
      view
      |> element("[phx-click='edit_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      assert has_element?(view, "#profile-modal")

      # Change capability groups
      view
      |> form("#profile-form", %{
        profile: %{
          name: "acceptance_test_profile",
          description: "Updated description",
          model_pool: ["azure:o1"],
          capability_groups: ["hierarchy", "local_execution"]
        }
      })
      |> render_submit()

      refute has_element?(view, "#profile-modal")

      # Verify update in database
      updated = Repo.get!(TableProfiles, profile.id)
      assert updated.description == "Updated description"
      assert "hierarchy" in updated.capability_groups
      assert "local_execution" in updated.capability_groups
      refute "file_read" in updated.capability_groups

      # ============= DELETE =============
      # Delete the profile
      view
      |> element("[phx-click='delete_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      # Verify removed from UI
      refute render(view) =~ "acceptance_test_profile"

      # Verify deleted from database
      assert Repo.get(TableProfiles, profile.id) == nil
    end
  end
end
