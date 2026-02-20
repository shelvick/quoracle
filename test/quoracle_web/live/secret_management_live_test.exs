defmodule QuoracleWeb.SecretManagementLiveTest do
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  alias Quoracle.Models.TableSecrets
  alias Quoracle.Models.TableCredentials

  setup do
    # Create isolated PubSub for each test
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    %{pubsub: pubsub}
  end

  # Helper to mount LiveView with sandbox access
  defp mount_secret_management_live(conn, sandbox_owner, pubsub) do
    live_isolated(conn, QuoracleWeb.SecretManagementLive,
      session: %{
        "sandbox_owner" => sandbox_owner,
        "pubsub" => pubsub
      }
    )
  end

  describe "mount/3 - Initial Render" do
    # R1: List Display [INTEGRATION]
    test "displays unified list of secrets and credentials", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # Create test data
      {:ok, _secret} =
        TableSecrets.create(%{
          name: "api_key",
          value: "secret123",
          description: "Test API key"
        })

      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: "claude-3-opus",
          model_spec: "openai:claude-3-opus",
          api_key: "cred123"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Header changed to "Settings" with tab interface (Packet 4)
      # Default tab is now Credentials; switch to Secrets
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      assert render(view) =~ "Settings"
      assert render(view) =~ "api_key"

      # Credential is on credentials tab now
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      assert render(view) =~ "claude-3-opus"
    end
  end

  describe "handle_event/3 - User Actions" do
    # R3: Create Secret [INTEGRATION]
    test "creates new secret via modal", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to secrets tab (credentials is now default)
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      # Open new secret modal
      view
      |> element("button", "Add Secret")
      |> render_click()

      assert has_element?(view, "#secret-modal")

      # Fill and submit form
      view
      |> form("#secret-form", %{
        secret: %{
          name: "new_secret",
          value: "secret_value",
          description: "A new secret"
        }
      })
      |> render_submit()

      # Verify secret created and modal closed
      refute has_element?(view, "#secret-modal")
      assert has_element?(view, "[data-name='new_secret']")

      # Check database
      assert {:ok, secret} = TableSecrets.get_by_name("new_secret")
      assert secret.description == "A new secret"
    end

    # R4: Create Credential [INTEGRATION]
    test "creates new model credential via modal", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # Create model_config first (foreign key requirement)

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Credentials tab is now the default

      # Open new credential modal
      view
      |> element("button", "Add Credential")
      |> render_click()

      assert has_element?(view, "#credential-modal")

      # Fill and submit form
      view
      |> form("#credential-form", %{
        credential: %{
          model_id: "openai:gpt-4",
          api_key: "sk-test123"
        }
      })
      |> render_submit()

      # Verify credential created
      refute has_element?(view, "#credential-modal")
      assert has_element?(view, "[data-model='openai:gpt-4']")

      # Check database
      creds = TableCredentials.list_all()
      assert Enum.any?(creds, &(&1.model_id == "openai:gpt-4"))
    end

    # R5: Edit Secret Value [INTEGRATION]
    test "updates existing secret value", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, secret} =
        TableSecrets.create(%{
          name: "edit_me",
          value: "old_value",
          description: "Original"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to secrets tab (credentials is now default)
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      # Click edit button
      view
      |> element("[data-action='edit'][data-id='#{secret.id}']")
      |> render_click()

      assert has_element?(view, "#edit-secret-modal")

      # Update the secret
      view
      |> form("#edit-secret-form", %{
        secret: %{
          value: "new_value",
          description: "Updated"
        }
      })
      |> render_submit()

      # Verify updated
      refute has_element?(view, "#edit-secret-modal")
      assert render(view) =~ "Updated"

      # Check database
      {:ok, updated} = TableSecrets.get_by_name("edit_me")
      assert updated.description == "Updated"
      # Value should be encrypted, not directly comparable
      assert updated.value != "old_value"
    end

    # R6: Delete Secret [INTEGRATION]
    test "deletes secret with confirmation", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, secret} =
        TableSecrets.create(%{
          name: "delete_me",
          value: "value",
          description: "To be deleted"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to secrets tab (credentials is now default)
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      # Click delete button
      view
      |> element("[data-action='delete'][data-id='#{secret.id}']")
      |> render_click()

      # Confirm deletion
      assert has_element?(view, "#confirm-delete-modal")

      view
      |> element("#confirm-delete-button")
      |> render_click()

      # Verify deleted
      refute has_element?(view, "[data-name='delete_me']")
      assert {:error, :not_found} = TableSecrets.get_by_name("delete_me")
    end

    # R7: Filter By Type [UNIT]
    test "filters list by type", %{conn: conn, sandbox_owner: sandbox_owner, pubsub: pubsub} do
      # Create mixed data
      {:ok, _} =
        TableSecrets.create(%{
          name: "secret1",
          value: "val1"
        })

      # Create model_config first (foreign key requirement)

      {:ok, _} =
        TableCredentials.insert(%{
          model_id: "model1",
          model_spec: "openai:model1",
          api_key: "key1"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Credentials tab is now default
      assert render(view) =~ "model1"
      refute render(view) =~ "secret1"

      # Switch to secrets tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      assert render(view) =~ "secret1"
      refute render(view) =~ "model1"

      # Switch back to credentials tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      refute render(view) =~ "secret1"
      assert render(view) =~ "model1"
    end

    # R8: Search Function [UNIT]
    test "searches items by name and description", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, _} =
        TableSecrets.create(%{
          name: "github_token",
          value: "val",
          description: "GitHub API access"
        })

      {:ok, _} =
        TableSecrets.create(%{
          name: "aws_key",
          value: "val",
          description: "Amazon Web Services"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to secrets tab (credentials is now default)
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      # Search for "github"
      view
      |> form("#search-form", %{search: %{term: "github"}})
      |> render_change()

      assert render(view) =~ "github_token"
      refute render(view) =~ "aws_key"

      # Search for "Amazon"
      view
      |> form("#search-form", %{search: %{term: "Amazon"}})
      |> render_change()

      refute render(view) =~ "github_token"
      assert render(view) =~ "aws_key"

      # Clear search
      view
      |> form("#search-form", %{search: %{term: ""}})
      |> render_change()

      assert render(view) =~ "github_token"
      assert render(view) =~ "aws_key"
    end

    # R11: Modal Management [UNIT]
    test "manages modal state correctly", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to secrets tab (credentials is now default)
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      # Open new secret modal
      view
      |> element("button", "Add Secret")
      |> render_click()

      assert has_element?(view, "#secret-modal")
      refute has_element?(view, "#credential-modal")

      # Switch to credentials tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      # Try to open credential modal (should close secret modal)
      view
      |> element("button", "Add Credential")
      |> render_click()

      refute has_element?(view, "#secret-modal")
      assert has_element?(view, "#credential-modal")

      # Close modal with Cancel button (more specific selector)
      view
      |> element("button[phx-click='close_modal']")
      |> render_click()

      refute has_element?(view, "#credential-modal")
      refute has_element?(view, "#secret-modal")
    end
  end

  describe "assign/2 - Visual Display" do
    # R2: Visual Distinction [UNIT]
    test "shows different badges for secrets vs credentials", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, _} =
        TableSecrets.create(%{
          name: "my_secret",
          value: "val"
        })

      # Create model_config first (foreign key requirement)

      {:ok, _} =
        TableCredentials.insert(%{
          model_id: "my_model",
          model_spec: "openai:my_model",
          api_key: "key"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Check for credential badge (credentials tab is now default)
      assert render(view) =~ ~r/<span[^>]*class="[^"]*badge-green[^"]*"[^>]*>CREDENTIAL<\/span>/

      # Switch to secrets tab to check secret badge
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      # Check for secret badge
      assert render(view) =~ ~r/<span[^>]*class="[^"]*badge-blue[^"]*"[^>]*>SECRET<\/span>/
    end

    # R10: No Value Display [UNIT]
    test "never shows actual secret values", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, _} =
        TableSecrets.create(%{
          name: "sensitive_secret",
          value: "super_secret_value_12345",
          description: "This is sensitive"
        })

      # Create model_config first (foreign key requirement)

      {:ok, _} =
        TableCredentials.insert(%{
          model_id: "model_with_key",
          model_spec: "openai:model_with_key",
          api_key: "sk-ant-secret-key-98765"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Credentials tab is now default - check credential values hidden
      creds_html = render(view)
      refute creds_html =~ "sk-ant-secret-key-98765"
      assert creds_html =~ "model_with_key"

      # Switch to secrets tab to check secret values hidden
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      secrets_html = render(view)
      refute secrets_html =~ "super_secret_value_12345"
      assert secrets_html =~ "sensitive_secret"
      assert secrets_html =~ "This is sensitive"
    end
  end

  describe "handle_event/3 - Validation" do
    # R9: Name Validation [UNIT]
    test "validates secret name format", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to secrets tab (credentials is now default)
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      # Open new secret modal
      view
      |> element("button", "Add Secret")
      |> render_click()

      # Try invalid names
      invalid_names = [
        # Empty
        "",
        # Too short
        "a",
        # Spaces not allowed
        "with spaces",
        # Special characters
        "special@chars!",
        # Too long
        String.duplicate("a", 65)
      ]

      for invalid_name <- invalid_names do
        html =
          view
          |> form("#secret-form", %{
            secret: %{
              name: invalid_name,
              value: "value"
            }
          })
          |> render_change()

        assert html =~ "error-message"
      end

      # Valid name should not show error
      view
      |> form("#secret-form", %{
        secret: %{
          name: "valid_name_123",
          value: "value"
        }
      })
      |> render_change()

      refute has_element?(view, ".error-message")
    end
  end

  describe "handle_info/2 - PubSub Updates" do
    # R12: Real-time Updates [INTEGRATION]
    test "updates list via PubSub events", %{conn: conn, pubsub: pubsub, sandbox_owner: owner} do
      # Pass pubsub and sandbox_owner through session
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.SecretManagementLive,
          session: %{"pubsub" => pubsub, "sandbox_owner" => owner}
        )

      # Switch to secrets tab (credentials is now default)
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      # Initially no secrets
      refute render(view) =~ "pubsub_secret"

      # Simulate PubSub broadcast for new secret using test-local instance
      Phoenix.PubSub.broadcast!(
        pubsub,
        "secrets:all",
        {:secret_created,
         %{
           id: "test-id",
           name: "pubsub_secret",
           description: "Created via PubSub"
         }}
      )

      # Force LiveView to process the message
      render(view)

      # Secret should appear
      assert render(view) =~ "pubsub_secret"
      assert render(view) =~ "Created via PubSub"

      # Simulate deletion
      Phoenix.PubSub.broadcast!(
        pubsub,
        "secrets:all",
        {:secret_deleted, %{id: "test-id"}}
      )

      render(view)

      # Secret should disappear
      refute render(view) =~ "pubsub_secret"
    end
  end

  describe "handle_event/3 - Error Handling" do
    # R13: Error Handling [INTEGRATION]
    test "handles database errors gracefully", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to secrets tab (credentials is now default)
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      # Open new secret modal
      view
      |> element("button", "Add Secret")
      |> render_click()

      # Mock a database error by trying to create duplicate name
      {:ok, _} =
        TableSecrets.create(%{
          name: "duplicate_name",
          value: "value1"
        })

      # Try to create another with same name
      view
      |> form("#secret-form", %{
        secret: %{
          name: "duplicate_name",
          value: "value2"
        }
      })
      |> render_submit()

      # Should show error message, not crash
      assert render(view) =~ "has already been taken"
      # Modal stays open
      assert has_element?(view, "#secret-modal")

      # Can recover by using different name
      view
      |> form("#secret-form", %{
        secret: %{
          name: "unique_name",
          value: "value2"
        }
      })
      |> render_submit()

      # Modal closes on success
      refute has_element?(view, "#secret-modal")
      assert render(view) =~ "unique_name"
    end

    test "handles credential validation errors", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Credentials tab is now the default

      # Open new credential modal
      view
      |> element("button", "Add Credential")
      |> render_click()

      # Submit with missing required field (empty model_id)
      view
      |> form("#credential-form", %{
        credential: %{
          model_id: "",
          api_key: "key"
        }
      })
      |> render_submit()

      # Modal should remain open due to validation failure
      assert has_element?(view, "#credential-modal")

      # No credential should be created with empty model_id
      creds = Quoracle.Models.TableCredentials.list_all()
      refute Enum.any?(creds, &(&1.model_id == ""))
    end
  end

  describe "Security" do
    test "sanitizes user input", %{conn: conn, sandbox_owner: sandbox_owner, pubsub: pubsub} do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to secrets tab (credentials is now default)
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      view
      |> element("button", "Add Secret")
      |> render_click()

      # Try XSS attack in description
      view
      |> form("#secret-form", %{
        secret: %{
          name: "test_xss",
          value: "value",
          description: "<script>alert('XSS')</script>"
        }
      })
      |> render_submit()

      html = render(view)

      # Script should be escaped
      refute html =~ "<script>alert('XSS')</script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "Credential-specific features" do
    test "shows provider information for credentials", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # Create model_config first (foreign key requirement)

      {:ok, _} =
        TableCredentials.insert(%{
          model_id: "claude-3-opus",
          model_spec: "openai:claude-3-opus",
          api_key: "key"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Credentials tab is now the default
      assert render(view) =~ "claude-3-opus"
    end

    test "validates credential format based on provider", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # Create model_config first (foreign key requirement)

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Credentials tab is now the default

      view
      |> element("button", "Add Credential")
      |> render_click()

      # Test that form accepts valid credential
      view
      |> form("#credential-form", %{
        credential: %{
          model_id: "anthropic:claude",
          api_key: "sk-ant-api03-valid-key"
        }
      })
      |> render_change()

      # Form should be present and accept input
      assert has_element?(view, "#credential-form")
    end
  end

  # ===========================================================================
  # LOCAL MODEL SUPPORT (v6.0 - feat-20260219-local-model-support)
  # Packet 3: UI Layer (R35-R45)
  # ===========================================================================

  describe "Local model credential form (R35-R36)" do
    # R35: Custom Model Spec Input Shown [INTEGRATION]
    # WHEN credentials tab active THEN custom model_spec text input shown
    # alongside LLMDB dropdown
    test "credential form shows custom model_spec text input", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Credentials tab is default - open new credential modal
      view
      |> element("button", "Add Credential")
      |> render_click()

      assert has_element?(view, "#credential-modal")

      # R35: Custom model_spec text input must be present
      # This is a text input allowing manual entry like "vllm:llama3"
      assert has_element?(view, "input[name='credential[model_spec]']"),
             "Expected model_spec text input to be present in credential form"
    end

    # R36: Endpoint URL Always Visible [INTEGRATION]
    # WHEN credentials tab active THEN endpoint_url field shown for all
    # providers (not just Azure)
    test "endpoint_url field shown for all providers not just Azure", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Open new credential modal (default tab is credentials)
      view
      |> element("button", "Add Credential")
      |> render_click()

      # R36: endpoint_url must be visible WITHOUT selecting Azure provider
      # Currently it's only shown when @selected_provider == "azure"
      # After implementation, it should always be shown
      assert has_element?(view, "input[name='credential[endpoint_url]']"),
             "Expected endpoint_url field to be visible for all providers, " <>
               "not just Azure. Currently only shown for Azure."
    end
  end

  describe "Local model credential save (R37-R40)" do
    # R37: Save Local Model Credential [SYSTEM]
    # WHEN user enters vllm model_spec and endpoint_url without api_key and
    # saves THEN credential persisted and shown in list
    @tag :acceptance
    test "user can save local model credential without api_key", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Open new credential modal
      view
      |> element("button", "Add Credential")
      |> render_click()

      assert has_element?(view, "#credential-modal")

      # Fill in local model credential: model_spec + endpoint_url, NO api_key
      unique = System.unique_integer([:positive])
      model_id = "vllm_local_#{unique}"

      view
      |> form("#credential-form", %{
        credential: %{
          model_id: model_id,
          model_spec: "vllm:llama3",
          endpoint_url: "http://localhost:11434/v1"
          # api_key intentionally omitted - local models don't need it
        }
      })
      |> render_submit()

      # Positive: credential saved and modal closed
      refute has_element?(view, "#credential-modal"),
             "Modal should close after successful save"

      assert has_element?(view, "[data-model='#{model_id}']"),
             "Local model credential should appear in credentials list"

      # Verify in database
      {:ok, cred} = TableCredentials.get_by_model_id(model_id)
      assert cred.model_spec == "vllm:llama3"
      assert cred.endpoint_url == "http://localhost:11434/v1"
      assert is_nil(cred.api_key)

      # Negative: no error messages shown (check for error-message class,
      # not bare "error" which matches Phoenix layout client-error/server-error divs)
      refute has_element?(view, ".error-message")
    end

    # R38: API Key Not Required With Endpoint URL [INTEGRATION]
    # WHEN endpoint_url present THEN api_key field not marked as required
    test "api_key validation passes when endpoint_url present", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      view
      |> element("button", "Add Credential")
      |> render_click()

      unique = System.unique_integer([:positive])

      # Validate with endpoint_url but no api_key - should not show error
      html =
        view
        |> form("#credential-form", %{
          credential: %{
            model_id: "local_nokey_#{unique}",
            model_spec: "vllm:llama3",
            endpoint_url: "http://localhost:11434/v1"
          }
        })
        |> render_change()

      # R38: No "required" or "can't be blank" error on api_key
      refute html =~ "api_key is required",
             "api_key should not be required when endpoint_url is present"

      refute html =~ "Invalid API key format",
             "api_key format should not be validated when endpoint_url is present"
    end

    # R39: API Key Format Skip For Local Models [UNIT]
    # WHEN endpoint_url present THEN api_key format validation skipped
    # Tests that build_credential_changeset conditionally skips api_key
    # requirement when endpoint_url is present
    test "api_key format validation skipped when endpoint_url present" do
      alias QuoracleWeb.SecretManagementLive.ValidationHelpers

      # R39: build_credential_changeset should NOT require api_key when
      # endpoint_url is present. Currently it always calls
      # validate_required([:model_id, :api_key]) unconditionally.
      # After Packet 3 implementation, it should call
      # validate_api_key_requirement() which conditionally requires api_key.
      changeset =
        ValidationHelpers.build_credential_changeset(nil, %{
          "model_id" => "vllm_format_skip",
          "model_spec" => "vllm:llama3",
          "endpoint_url" => "http://localhost:11434/v1"
          # api_key intentionally omitted
        })

      # After implementation: changeset should be valid (no api_key error)
      # Currently fails because validate_required([:model_id, :api_key]) rejects it
      refute Keyword.has_key?(changeset.errors, :api_key),
             "build_credential_changeset should not require api_key when endpoint_url is present"
    end

    # R40: Cloud Model Validation Unchanged [INTEGRATION]
    # WHEN no endpoint_url THEN api_key required with specific error message
    # Tests that build_credential_changeset uses the NEW conditional validation
    # which produces a specific error message for missing api_key
    test "cloud model credential still requires valid api_key" do
      alias QuoracleWeb.SecretManagementLive.ValidationHelpers

      # R40: build_credential_changeset should produce specific error message
      # "api_key is required when no endpoint_url is provided"
      # (matching TABLE_Credentials v3.0 error message)
      # Currently produces "can't be blank" from validate_required
      changeset =
        ValidationHelpers.build_credential_changeset(nil, %{
          "model_id" => "cloud_nokey_test",
          "model_spec" => "openai:gpt-4o"
          # No api_key and no endpoint_url
        })

      assert Keyword.has_key?(changeset.errors, :api_key),
             "Cloud model without api_key should have api_key error"

      # After implementation: error message should be the specific conditional one
      {error_msg, _} = changeset.errors[:api_key]

      assert error_msg == "api_key is required when no endpoint_url is provided",
             "Expected specific error message from conditional validation, " <>
               "got: #{inspect(error_msg)}"
    end
  end

  describe "Local model in Model Config (R41-R43)" do
    # R41: Local Model in Consensus Dropdown [INTEGRATION]
    # WHEN local model credential saved THEN appears in Model Config
    # answer engine / consensus dropdown with "(local)" indicator
    test "local model shows local indicator in dropdown", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # Create a local model credential
      unique = System.unique_integer([:positive])
      model_id = "vllm_consensus_#{unique}"

      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: model_id,
          model_spec: "vllm:llama3",
          endpoint_url: "http://localhost:11434/v1"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to Model Config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      html = render(view)

      # R41: Local model should appear with a "(local)" indicator
      # to distinguish it from cloud models in the dropdown.
      # Currently credentialed_models just shows model_id without any
      # local indicator. After Packet 3 implementation, local models
      # (those with endpoint_url) should show "(local)" label.
      assert html =~ "#{model_id} (local)",
             "Local model #{model_id} should show '(local)' indicator in dropdown"
    end

    # R42: Local Model in Embedding Dropdown [INTEGRATION]
    # WHEN local model credential saved THEN appears in Model Config
    # embedding dropdown with "(local)" indicator
    test "local embedding model shows local indicator", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      unique = System.unique_integer([:positive])
      model_id = "vllm_embedding_#{unique}"

      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: model_id,
          model_spec: "vllm:nomic-embed-text",
          endpoint_url: "http://localhost:11434/v1"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to Model Config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      html = render(view)

      # R42: Local embedding model should show "(local)" indicator
      assert html =~ "#{model_id} (local)",
             "Local embedding model should show '(local)' indicator"
    end

    # R43: Local Model in Image Dropdown [INTEGRATION]
    # WHEN local model credential with endpoint_url saved THEN appears
    # in image generation dropdown (bypasses LLMDB filter)
    test "local model in image generation dropdown", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      unique = System.unique_integer([:positive])
      model_id = "vllm_imagegen_#{unique}"

      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: model_id,
          model_spec: "vllm:sd-turbo",
          endpoint_url: "http://localhost:11434/v1"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to Model Config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      # R43: Local model with endpoint_url should be included in image
      # generation dropdown. Currently filter_image_models only checks
      # LLMDB image_specs -- local models not in LLMDB are excluded.
      # After Packet 3 implementation, credentials with endpoint_url
      # bypass the LLMDB filter and are included.
      #
      # Check the image generation multi-select specifically
      assert has_element?(
               view,
               "select[name='model_config[image_generation_models][]'] option[value='#{model_id}']"
             ),
             "Local model #{model_id} with endpoint_url should appear in " <>
               "image generation dropdown (bypasses LLMDB filter)"
    end
  end

  describe "Known model dropdown and full journey (R44-R45)" do
    # R44: Known Model Dropdown Still Works [INTEGRATION]
    # WHEN user selects from LLMDB dropdown THEN populates model_spec
    # text input (the new custom text input added in Packet 3)
    test "selecting known model from dropdown populates model_spec input", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Open new credential modal
      view
      |> element("button", "Add Credential")
      |> render_click()

      # R44: After Packet 3 implementation, there should be BOTH a
      # select dropdown (LLMDB known models) AND a text input
      # (custom model_spec). Selecting from the dropdown should
      # populate the text input.
      #
      # Currently the form only has a <select> for model_spec.
      # After implementation, a separate text input will exist.
      # Verify the text input element exists first.
      assert has_element?(view, "input[name='credential[model_spec]']"),
             "Expected custom model_spec text input alongside LLMDB dropdown"

      # Verify the LLMDB dropdown also exists (kept as optional helper)
      assert has_element?(view, "select[name='credential[known_model_spec]']"),
             "Expected LLMDB dropdown alongside custom model_spec text input"
    end

    # R45: Full Local Model Setup Journey [SYSTEM]
    # WHEN user adds local model credential with endpoint_url THEN can
    # select it in Model Config AND save config successfully
    @tag :acceptance
    test "full journey: add local model credential then configure in model config", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Step 1: Add local model credential
      view
      |> element("button", "Add Credential")
      |> render_click()

      unique = System.unique_integer([:positive])
      model_id = "vllm_journey_#{unique}"

      view
      |> form("#credential-form", %{
        credential: %{
          model_id: model_id,
          model_spec: "vllm:llama3",
          endpoint_url: "http://localhost:11434/v1"
        }
      })
      |> render_submit()

      # Verify credential saved (modal closed)
      refute has_element?(view, "#credential-modal"),
             "Credential modal should close after successful save"

      # Step 2: Switch to Model Config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      html = render(view)

      # Step 3: Local model should appear in dropdown options
      assert html =~ model_id,
             "Local model should be available in Model Config after creation"

      # Step 4: Select local model as embedding model and save
      view
      |> form("#model-config-form", %{
        model_config: %{
          embedding_model: model_id
        }
      })
      |> render_submit()

      # R45 Positive: Config saved successfully
      assert render(view) =~ "Model configuration saved",
             "Model config should save successfully with local model selected"

      # R45 Negative: No error messages
      refute render(view) =~ "Error saving"
    end
  end

  describe "Sorting and pagination" do
    test "sorts items by creation date", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # Create secrets with explicit timestamps for deterministic ordering
      now = DateTime.utc_now()
      # 1 hour ago
      earlier = DateTime.add(now, -3600, :second)

      {:ok, _old} =
        TableSecrets.create(%{
          name: "old_secret",
          value: "val",
          inserted_at: earlier
        })

      {:ok, _new} =
        TableSecrets.create(%{
          name: "new_secret",
          value: "val",
          inserted_at: now
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to secrets tab (credentials is now default)
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      # Newer items should appear first
      assert render(view) =~ ~r/new_secret.*old_secret/s
    end

    test "paginates large lists", %{conn: conn, sandbox_owner: sandbox_owner, pubsub: pubsub} do
      # Create 25 secrets
      for i <- 1..25 do
        TableSecrets.create(%{
          name: "secret_#{i}",
          value: "value_#{i}"
        })
      end

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to secrets tab (credentials is now default)
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      # Should show first 20 by default
      assert render(view) =~ "secret_1"
      refute render(view) =~ "secret_25"

      # Should have pagination controls
      assert has_element?(view, "[phx-click='next_page']")

      # Go to next page
      view
      |> element("[phx-click='next_page']")
      |> render_click()

      assert render(view) =~ "secret_25"
    end
  end
end
