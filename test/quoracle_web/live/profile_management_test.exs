defmodule QuoracleWeb.ProfileManagementTest do
  @moduledoc """
  Tests for profile management UI in SecretManagementLive.

  ARC Requirements (feat-20260105-profiles, Packet 5):
  - R1: Profile List Renders [INTEGRATION]
  - R2: New Profile Button [INTEGRATION]
  - R3: Create Profile [INTEGRATION]
  - R4: Validation Errors [INTEGRATION]
  - R5: Edit Profile [INTEGRATION]
  - R6: Update Profile [INTEGRATION]
  - R7: Delete Profile [INTEGRATION]
  - R8: Unique Name Validation [INTEGRATION]
  - R9: Model Selection Required [UNIT]
  - R10: Acceptance - Full CRUD Flow [SYSTEM]
  """

  use QuoracleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  alias Quoracle.Profiles.TableProfiles
  alias Quoracle.Repo

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated PubSub for each test
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    # Insert credentials so the model_pool select has options
    for {id, deployment} <- [{"azure:o1", "o1"}, {"azure:deepseek-r1", "DeepSeek-R1"}] do
      %Quoracle.Models.TableCredentials{}
      |> Quoracle.Models.TableCredentials.changeset(%{
        model_id: id,
        model_spec: id,
        api_key: "test-key",
        deployment_id: deployment
      })
      |> Quoracle.Repo.insert(on_conflict: :nothing, conflict_target: :model_id)
    end

    %{pubsub: pubsub, sandbox_owner: sandbox_owner}
  end

  # Helper to mount SecretManagementLive with sandbox access
  defp mount_secrets_live(conn, sandbox_owner, pubsub) do
    live_isolated(conn, QuoracleWeb.SecretManagementLive,
      session: %{
        "sandbox_owner" => sandbox_owner,
        "pubsub" => pubsub
      }
    )
  end

  # Helper to create test profile
  defp create_profile(attrs) do
    default_attrs = %{
      name: "test-profile-#{System.unique_integer([:positive])}",
      model_pool: ["azure:o1"],
      capability_groups: [
        "hierarchy",
        "local_execution",
        "file_read",
        "file_write",
        "external_api"
      ]
    }

    merged = Map.merge(default_attrs, attrs)

    %TableProfiles{}
    |> TableProfiles.changeset(merged)
    |> Repo.insert!()
  end

  # Helper to switch to profiles tab
  defp switch_to_profiles_tab(view) do
    view
    |> element("[phx-click='switch_tab'][phx-value-tab='profiles']")
    |> render_click()

    view
  end

  describe "R1: Profile list renders" do
    @tag :integration
    test "profiles section shows all profiles", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # Create test profiles
      profile1 =
        create_profile(%{
          name: "profile-alpha",
          capability_groups: [
            "hierarchy",
            "local_execution",
            "file_read",
            "file_write",
            "external_api"
          ]
        })

      profile2 = create_profile(%{name: "profile-beta", capability_groups: []})

      {:ok, view, _html} = mount_secrets_live(conn, sandbox_owner, pubsub)

      # Switch to profiles tab
      view = switch_to_profiles_tab(view)
      html = render(view)

      # Both profiles should be visible
      assert html =~ profile1.name
      assert html =~ profile2.name

      # Should show capability groups display
      # profile1 (full) = "all", profile2 (restricted) = "none (base only)"
      assert html =~ "all"
      assert html =~ "none (base only)"
    end

    @tag :integration
    test "profiles section has Profiles header", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secrets_live(conn, sandbox_owner, pubsub)

      view = switch_to_profiles_tab(view)
      html = render(view)

      assert html =~ "Profiles"
    end
  end

  describe "R2: New profile button" do
    @tag :integration
    test "new profile button opens form", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secrets_live(conn, sandbox_owner, pubsub)

      view = switch_to_profiles_tab(view)

      # Click new profile button
      view
      |> element("button", "New Profile")
      |> render_click()

      # Modal should open with form
      assert has_element?(view, "#profile-modal")
      assert has_element?(view, "#profile-form")

      # Form should have required fields
      html = render(view)
      assert html =~ "Name"
      assert html =~ "Capability Groups"
      assert html =~ "Models"
    end
  end

  describe "R3: Create profile" do
    @tag :integration
    test "create profile adds to list", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secrets_live(conn, sandbox_owner, pubsub)

      view = switch_to_profiles_tab(view)

      # Open modal
      view
      |> element("button", "New Profile")
      |> render_click()

      # Submit form with valid data
      view
      |> form("#profile-form", %{
        profile: %{
          name: "new-test-profile",
          description: "A test profile",
          model_pool: ["azure:o1"],
          capability_groups: [
            "file_read",
            "file_write",
            "external_api",
            "hierarchy",
            "local_execution"
          ]
        }
      })
      |> render_submit()

      # Modal should close
      refute has_element?(view, "#profile-modal")

      # Profile should appear in list
      html = render(view)
      assert html =~ "new-test-profile"

      # Verify in database
      assert Repo.get_by(TableProfiles, name: "new-test-profile") != nil
    end
  end

  describe "R4: Validation errors" do
    @tag :integration
    test "invalid profile shows errors", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secrets_live(conn, sandbox_owner, pubsub)

      view = switch_to_profiles_tab(view)

      # Open modal
      view
      |> element("button", "New Profile")
      |> render_click()

      # Verify modal opened
      assert has_element?(view, "#profile-modal")

      # Submit form with empty name - should fail validation and keep modal open
      view
      |> form("#profile-form", %{
        profile: %{
          name: "",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read"]
        }
      })
      |> render_submit()

      # Force synchronization and get HTML
      html = render(view)

      # Should show validation error (HTML-escaped)
      assert html =~ "can&#39;t be blank"

      # Modal should still be open
      assert has_element?(view, "#profile-modal")
    end
  end

  describe "R5: Edit profile" do
    @tag :integration
    test "edit profile populates form", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      profile =
        create_profile(%{
          name: "editable-profile",
          description: "Original description",
          capability_groups: ["local_execution", "file_read", "file_write", "external_api"]
        })

      {:ok, view, _html} = mount_secrets_live(conn, sandbox_owner, pubsub)

      view = switch_to_profiles_tab(view)

      # Click edit button for the profile
      view
      |> element("[phx-click='edit_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      # Form should be populated
      html = render(view)
      assert html =~ "editable-profile"
      assert html =~ "Original description"

      # Should have edit modal open
      assert has_element?(view, "#profile-modal")
    end
  end

  describe "R6: Update profile" do
    @tag :integration
    test "update profile saves changes", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      profile = create_profile(%{name: "update-test", description: "Old description"})

      {:ok, view, _html} = mount_secrets_live(conn, sandbox_owner, pubsub)

      view = switch_to_profiles_tab(view)

      # Click edit
      view
      |> element("[phx-click='edit_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      # Update the description
      view
      |> form("#profile-form", %{
        profile: %{
          name: "update-test",
          description: "New description",
          model_pool: ["azure:o1"],
          capability_groups: [
            "file_read",
            "file_write",
            "external_api",
            "hierarchy",
            "local_execution"
          ]
        }
      })
      |> render_submit()

      # Modal should close
      refute has_element?(view, "#profile-modal")

      # Verify in database
      updated = Repo.get!(TableProfiles, profile.id)
      assert updated.description == "New description"
    end
  end

  describe "R7: Delete profile" do
    @tag :integration
    test "delete profile removes from list", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      profile = create_profile(%{name: "delete-me"})

      {:ok, view, _html} = mount_secrets_live(conn, sandbox_owner, pubsub)

      view = switch_to_profiles_tab(view)

      # Verify profile is in list
      assert render(view) =~ "delete-me"

      # Click delete button (direct deletion, no confirmation)
      view
      |> element("[phx-click='delete_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      # Profile should be removed from list
      refute render(view) =~ "delete-me"

      # Verify in database
      assert Repo.get(TableProfiles, profile.id) == nil
    end
  end

  describe "R8: Unique name validation" do
    @tag :integration
    test "duplicate name shows error", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # Create existing profile
      create_profile(%{name: "existing-profile"})

      {:ok, view, _html} = mount_secrets_live(conn, sandbox_owner, pubsub)

      view = switch_to_profiles_tab(view)

      # Open modal
      view
      |> element("button", "New Profile")
      |> render_click()

      # Try to create profile with same name
      view
      |> form("#profile-form", %{
        profile: %{
          name: "existing-profile",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read"]
        }
      })
      |> render_submit()

      # Should show unique constraint error (Ecto standard message)
      html = render(view)
      assert html =~ "has already been taken"

      # Modal should still be open
      assert has_element?(view, "#profile-modal")
    end
  end

  describe "R9: Model selection required" do
    @tag :unit
    test "empty model pool shows error", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secrets_live(conn, sandbox_owner, pubsub)

      view = switch_to_profiles_tab(view)

      # Open modal
      view
      |> element("button", "New Profile")
      |> render_click()

      # Submit with empty model_pool
      view
      |> form("#profile-form", %{
        profile: %{
          name: "no-models-profile",
          model_pool: [],
          capability_groups: ["file_read"]
        }
      })
      |> render_submit()

      # Should show model pool required error (custom validation message)
      html = render(view)
      assert html =~ "at least one model"
    end
  end

  describe "R10: Acceptance - Full CRUD flow" do
    @tag :acceptance
    @tag :system
    test "end-to-end profile management", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # 1. User visits /settings page with isolated dependencies via session
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "sandbox_owner" => sandbox_owner,
          "pubsub" => pubsub
        })

      {:ok, view, _html} = live(conn, "/settings")

      # 2. User switches to Profiles tab
      view = switch_to_profiles_tab(view)

      # 3. User clicks "New Profile"
      view
      |> element("button", "New Profile")
      |> render_click()

      assert has_element?(view, "#profile-modal")

      # 4. User fills out and submits form (CREATE)
      # Form uses capability_groups checkboxes (no_spawn = local_execution + file + external_api, no hierarchy)
      view
      |> form("#profile-form", %{
        profile: %{
          name: "acceptance-test-profile",
          description: "Created in acceptance test",
          model_pool: ["azure:o1"],
          capability_groups: ["local_execution", "file_read", "file_write", "external_api"]
        }
      })
      |> render_submit()

      # Verify creation
      html = render(view)
      assert html =~ "acceptance-test-profile"
      refute has_element?(view, "#profile-modal")

      profile = Repo.get_by!(TableProfiles, name: "acceptance-test-profile")
      # no_spawn = local_execution + file + external_api (no hierarchy)
      assert "local_execution" in profile.capability_groups
      assert "external_api" in profile.capability_groups
      refute "hierarchy" in profile.capability_groups

      # 5. User clicks Edit (READ + UPDATE)
      view
      |> element("[phx-click='edit_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      assert has_element?(view, "#profile-modal")

      # 6. User updates and saves
      # Update to different capability groups (add hierarchy)
      view
      |> form("#profile-form", %{
        profile: %{
          name: "acceptance-test-profile",
          description: "Updated in acceptance test",
          model_pool: ["azure:o1", "azure:deepseek-r1"],
          capability_groups: [
            "local_execution",
            "file_read",
            "file_write",
            "external_api",
            "hierarchy"
          ]
        }
      })
      |> render_submit()

      # Verify update
      updated = Repo.get!(TableProfiles, profile.id)
      assert updated.description == "Updated in acceptance test"
      # Now has hierarchy added
      assert "hierarchy" in updated.capability_groups
      assert "azure:deepseek-r1" in updated.model_pool

      # 7. User clicks Delete (direct deletion, no confirmation)
      view
      |> element("[phx-click='delete_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      # Verify deletion
      refute render(view) =~ "acceptance-test-profile"
      assert Repo.get(TableProfiles, profile.id) == nil

      # 8. Negative assertion - no error messages in profile UI
      html = render(view)
      refute html =~ "can't be blank"
      refute html =~ "has already been taken"
    end
  end
end
