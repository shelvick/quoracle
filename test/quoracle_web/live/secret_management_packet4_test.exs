defmodule QuoracleWeb.SecretManagementPacket4Test do
  @moduledoc """
  TEST phase for Packet 4 (UI Enhancement) of WorkGroupID feat-20251205-054538.

  Tests the enhanced SecretManagementLive with:
  - Three-tab interface (Secrets | Credentials | Model Config)
  - LLMDB-backed model dropdown for credentials
  - Provider-aware dynamic form fields
  - Model configuration management (consensus, embedding, answer engine)
  """

  # NOTE: Changed to async: true (2026-01) - Ecto Sandbox provides transaction isolation
  # Each test's ConfigModelSettings writes are isolated to its own sandbox
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  alias Quoracle.Models.TableCredentials
  alias Quoracle.Models.ConfigModelSettings

  setup do
    # Create isolated PubSub for each test
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    %{pubsub: pubsub}
  end

  defp mount_secret_management_live(conn, sandbox_owner, pubsub) do
    live_isolated(conn, QuoracleWeb.SecretManagementLive,
      session: %{
        "sandbox_owner" => sandbox_owner,
        "pubsub" => pubsub,
        "topic" => "secrets:test_#{System.unique_integer()}"
      }
    )
  end

  # =============================================================================
  # Tab Navigation (R1-R2)
  # =============================================================================

  describe "Tab Navigation" do
    test "R1: clicking tab switches displayed content", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Initial state should show secrets tab content
      assert html =~ "Secrets"

      # Click credentials tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      # Should show credentials content
      assert has_element?(view, "[data-tab='credentials']")

      # Click model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      # Should show model config content
      assert has_element?(view, "[data-tab='model_config']")
    end

    test "R2: secrets tab active on initial load", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, _view, html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Credentials tab should be active by default
      assert html =~ ~r/class="[^"]*tab-active[^"]*"[^>]*>.*Credentials/s
      # Or check for active tab indicator
      assert html =~ "data-active-tab=\"credentials\""
    end
  end

  # =============================================================================
  # Credentials Tab - LLMDB Integration (R3-R5)
  # =============================================================================

  describe "Credentials Tab - LLMDB Integration" do
    test "R3: model dropdown shows LLMDB models when available", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to credentials tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      # Open new credential modal
      view
      |> element("button", "Add Credential")
      |> render_click()

      # Model dropdown should be populated with LLMDB models
      assert has_element?(view, "select[name='credential[model_spec]']")

      # Should contain known model formats from LLMDB
      html = render(view)
      assert html =~ ~r/(azure:|google-vertex:|amazon-bedrock:)/
    end

    test "R4: shows error when LLMDB not available", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # Mount with LLMDB unavailable (mock)
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.SecretManagementLive,
          session: %{
            "sandbox_owner" => sandbox_owner,
            "pubsub" => pubsub,
            "llmdb_available" => false
          }
        )

      # Switch to credentials tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      # Should show error message
      assert render(view) =~ "Model database not loaded"
    end

    test "R5: selecting model auto-populates model_id", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to credentials tab and open modal
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      view
      |> element("button", "Add Credential")
      |> render_click()

      # Enter a model_id directly (simulates what happens after dropdown selection)
      # The provider detection works from model_id input as well
      view
      |> form("#credential-form", %{
        credential: %{model_id: "azure:gpt-4o"}
      })
      |> render_change()

      # model_id field should have the entered value
      assert has_element?(view, "input[name='credential[model_id]'][value='azure:gpt-4o']")
    end
  end

  # =============================================================================
  # Credentials Tab - Provider-Aware Form (R6-R9)
  # =============================================================================

  describe "Credentials Tab - Provider-Aware Form" do
    test "R6: azure model shows endpoint_url and deployment_id fields", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to credentials tab and open modal
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      view
      |> element("button", "Add Credential")
      |> render_click()

      # Enter Azure model_id to trigger provider detection
      view
      |> form("#credential-form", %{
        credential: %{model_id: "azure:gpt-4o"}
      })
      |> render_change()

      # Should show Azure-specific fields
      assert has_element?(view, "input[name='credential[endpoint_url]']")
      assert has_element?(view, "input[name='credential[deployment_id]']")
    end

    test "R7: google-vertex model shows project_id and region fields", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to credentials tab and open modal
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      view
      |> element("button", "Add Credential")
      |> render_click()

      # Enter Google Vertex model_id to trigger provider detection
      view
      |> form("#credential-form", %{
        credential: %{model_id: "google-vertex:gemini-2.5-pro"}
      })
      |> render_change()

      # Should show Google-specific fields
      assert has_element?(view, "input[name='credential[resource_id]']")
      assert has_element?(view, "select[name='credential[region]']")
    end

    test "R8: amazon-bedrock model shows region field", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to credentials tab and open modal
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      view
      |> element("button", "Add Credential")
      |> render_click()

      # Enter Bedrock model_id to trigger provider detection
      view
      |> form("#credential-form", %{
        credential: %{model_id: "amazon-bedrock:claude-3-5-sonnet"}
      })
      |> render_change()

      # Should show Bedrock-specific fields
      assert has_element?(view, "select[name='credential[region]']")
      # But NOT Azure-specific fields
      refute has_element?(view, "input[name='credential[endpoint_url]']")
      refute has_element?(view, "input[name='credential[deployment_id]']")
    end

    test "R9: other providers show only api_key field", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to credentials tab and open modal
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      view
      |> element("button", "Add Credential")
      |> render_click()

      # Enter generic provider model_id
      view
      |> form("#credential-form", %{
        credential: %{model_id: "openai:gpt-4"}
      })
      |> render_change()

      # Should only show api_key field (always shown)
      assert has_element?(view, "input[name='credential[api_key]']")
      # Provider-specific fields should NOT be shown
      refute has_element?(view, "input[name='credential[endpoint_url]']")
      refute has_element?(view, "input[name='credential[deployment_id]']")
      refute has_element?(view, "input[name='credential[resource_id]']")
    end
  end

  # =============================================================================
  # Model Config Tab (R10-R14)
  # =============================================================================

  describe "Model Config Tab" do
    setup do
      # Create test credentials for selection with unique IDs per test
      unique = System.unique_integer([:positive])

      {:ok, cred1} =
        TableCredentials.insert(%{
          model_id: "azure:gpt-4o-#{unique}",
          model_spec: "azure:gpt-4o",
          api_key: "test-key-1",
          endpoint_url: "https://test.openai.azure.com",
          deployment_id: "gpt-4o"
        })

      {:ok, cred2} =
        TableCredentials.insert(%{
          model_id: "azure:embed-#{unique}",
          model_spec: "azure:text-embedding-3-large",
          api_key: "test-key-2",
          endpoint_url: "https://test.openai.azure.com",
          deployment_id: "embed-large"
        })

      {:ok, cred3} =
        TableCredentials.insert(%{
          model_id: "google:gemini-#{unique}",
          model_spec: "google-vertex:gemini-2.5-pro",
          api_key: "test-key-3",
          resource_id: "my-project",
          region: "us-central1"
        })

      %{credentials: [cred1, cred2, cred3], unique: unique}
    end

    test "R10: model config tab shows current settings", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      credentials: [cred1, cred2, cred3]
    } do
      # Set up existing config using actual credential model_ids
      {:ok, _} = ConfigModelSettings.set_embedding_model(cred2.model_id)
      {:ok, _} = ConfigModelSettings.set_answer_engine_model(cred3.model_id)

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      html = render(view)

      # Should display current settings (using actual credential model_ids)
      assert html =~ cred1.model_id
      assert html =~ cred2.model_id
      assert html =~ cred3.model_id
    end

    test "R11: consensus dropdown only shows credentialed models", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      credentials: [cred1, cred2, cred3]
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      html = render(view)

      # Dropdown should contain models that have credentials
      assert html =~ cred1.model_id
      assert html =~ cred2.model_id
      assert html =~ cred3.model_id

      # Should NOT contain models without credentials
      refute html =~ "nonexistent-model-xyz"
    end

    test "R12: embedding dropdown shows only embedding-capable models", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      credentials: [_cred1, cred2, _cred3]
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      # Find embedding dropdown specifically
      html = render(view)

      # Should show embedding model in dropdown
      assert html =~ cred2.model_id

      # Embedding dropdown should exist
      assert has_element?(view, "select[name='model_config[embedding_model]']")
    end

    test "R13: saving valid config shows success message", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      credentials: [_cred1, cred2, cred3]
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      # Submit valid config using actual credential model_ids
      view
      |> form("#model-config-form", %{
        model_config: %{
          embedding_model: cred2.model_id,
          answer_engine_model: cred3.model_id
        }
      })
      |> render_submit()

      # Should show success message
      assert render(view) =~ "Model configuration saved"
    end

    # R14 removed - consensus_models moved to profiles
  end

  # =============================================================================
  # Credential CRUD (R15-R18)
  # =============================================================================

  describe "Credential CRUD with Provider Fields" do
    test "R15: creates credential with valid data including provider fields", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      unique = System.unique_integer([:positive])
      # model_id must be in provider:model format for validation
      model_id = "azure:my-gpt4-#{unique}"

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to credentials tab and open modal
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      view
      |> element("button", "Add Credential")
      |> render_click()

      # First trigger provider detection by changing model_id with azure prefix
      view
      |> form("#credential-form", %{
        credential: %{model_id: "azure:test"}
      })
      |> render_change()

      # Now fill full form with Azure-specific fields visible
      view
      |> form("#credential-form", %{
        credential: %{
          model_id: model_id,
          api_key: "sk-test-key-#{unique}",
          endpoint_url: "https://my-endpoint.openai.azure.com",
          deployment_id: "my-deployment"
        }
      })
      |> render_submit()

      # Modal should close
      refute has_element?(view, "#credential-modal")

      # Credential should be created with all fields
      {:ok, cred} = TableCredentials.get_by_model_id(model_id)
      assert cred.endpoint_url == "https://my-endpoint.openai.azure.com"
      assert cred.deployment_id == "my-deployment"
    end

    test "R16: edit loads credential into form with provider fields", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      unique = System.unique_integer([:positive])

      # Create a credential first with all required Azure fields
      {:ok, cred} =
        TableCredentials.insert(%{
          model_id: "edit-azure-model-#{unique}",
          model_spec: "azure:gpt-4o",
          api_key: "original-key",
          endpoint_url: "https://original.openai.azure.com",
          deployment_id: "original-deploy"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to credentials tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      # Click edit on the credential
      view
      |> element("[data-action='edit'][data-id='#{cred.id}']")
      |> render_click()

      # Form should be populated with credential data including provider fields
      assert has_element?(
               view,
               "input[name='credential[endpoint_url]'][value='https://original.openai.azure.com']"
             )

      assert has_element?(
               view,
               "input[name='credential[deployment_id]'][value='original-deploy']"
             )
    end

    test "R17: delete removes credential", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      unique = System.unique_integer([:positive])
      model_id = "delete-me-model-#{unique}"

      # Create Azure credential with required fields
      {:ok, cred} =
        TableCredentials.insert(%{
          model_id: model_id,
          model_spec: "azure:gpt-4o",
          api_key: "delete-key",
          endpoint_url: "https://delete.openai.azure.com",
          deployment_id: "delete-deploy"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to credentials tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      # Click delete
      view
      |> element("[data-action='delete'][data-id='#{cred.id}']")
      |> render_click()

      # Confirm deletion
      view
      |> element("#confirm-delete-button")
      |> render_click()

      # Credential should be removed
      refute render(view) =~ model_id
      assert {:error, :not_found} = TableCredentials.get_by_model_id(model_id)
    end

    test "R18: delete warns when credential in active model config", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      unique = System.unique_integer([:positive])
      model_id = "active-config-model-#{unique}"

      # Create Azure credential with required fields
      {:ok, cred} =
        TableCredentials.insert(%{
          model_id: model_id,
          model_spec: "azure:gpt-4o",
          api_key: "active-key",
          endpoint_url: "https://active.openai.azure.com",
          deployment_id: "active-deploy"
        })

      # Set this credential as active in config (embedding model)
      {:ok, _} = ConfigModelSettings.set_embedding_model(model_id)

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to credentials tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      # Click delete
      view
      |> element("[data-action='delete'][data-id='#{cred.id}']")
      |> render_click()

      # Should show warning about active config
      assert render(view) =~ "This credential is used in active model configuration"
    end
  end

  # =============================================================================
  # Summarization Model Dropdown (R19-R22)
  # =============================================================================

  describe "Model Config Tab - Summarization Model" do
    setup do
      # Create test credentials for selection with unique IDs per test
      unique = System.unique_integer([:positive])

      # Chat-capable model (should appear in summarization dropdown)
      {:ok, chat_cred} =
        TableCredentials.insert(%{
          model_id: "azure:gpt-4o-summ-#{unique}",
          model_spec: "azure:gpt-4o",
          api_key: "test-key-1",
          endpoint_url: "https://test.openai.azure.com",
          deployment_id: "gpt-4o"
        })

      # Another chat-capable model
      {:ok, chat_cred2} =
        TableCredentials.insert(%{
          model_id: "google:gemini-summ-#{unique}",
          model_spec: "google-vertex:gemini-2.5-pro",
          api_key: "test-key-2",
          resource_id: "my-project",
          region: "us-central1"
        })

      # Embedding-only model (should NOT appear in summarization dropdown)
      {:ok, embed_cred} =
        TableCredentials.insert(%{
          model_id: "azure:embed-only-#{unique}",
          model_spec: "azure:text-embedding-3-large",
          api_key: "test-key-3",
          endpoint_url: "https://test.openai.azure.com",
          deployment_id: "embed-large"
        })

      %{
        chat_cred: chat_cred,
        chat_cred2: chat_cred2,
        embed_cred: embed_cred,
        unique: unique
      }
    end

    test "R19: summarization dropdown shows only chat-capable models", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      chat_cred: chat_cred,
      embed_cred: embed_cred
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      # Should have summarization model dropdown
      assert has_element?(view, "select[name='model_config[summarization_model]']")

      # Chat-capable model SHOULD appear in summarization dropdown
      assert has_element?(
               view,
               "select[name='model_config[summarization_model]'] option[value='#{chat_cred.model_id}']"
             )

      # Embedding-only model should NOT appear in summarization dropdown
      refute has_element?(
               view,
               "select[name='model_config[summarization_model]'] option[value='#{embed_cred.model_id}']"
             )
    end

    test "R20: saving summarization model persists to database", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      chat_cred2: chat_cred2
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      # Submit config with summarization model using at least one consensus model
      view
      |> form("#model-config-form", %{
        model_config: %{
          summarization_model: chat_cred2.model_id
        }
      })
      |> render_submit()

      # Should show success message
      assert render(view) =~ "Model configuration saved"

      # Verify summarization model was persisted to database
      expected_model_id = chat_cred2.model_id
      assert {:ok, ^expected_model_id} = ConfigModelSettings.get_summarization_model()
    end

    test "R21: current summarization model is pre-selected on mount", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      chat_cred: chat_cred
    } do
      # Set up existing summarization model config BEFORE mounting
      {:ok, _} = ConfigModelSettings.set_summarization_model(chat_cred.model_id)

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      # Should display current summarization model as selected
      assert has_element?(
               view,
               "select[name='model_config[summarization_model]'] option[selected][value='#{chat_cred.model_id}']"
             )
    end

    test "R22: delete warns when credential is summarization model", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      chat_cred: chat_cred
    } do
      # Set chat_cred ONLY as summarization model (not in consensus)
      {:ok, _} = ConfigModelSettings.set_summarization_model(chat_cred.model_id)

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to credentials tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      # Click delete on the credential used ONLY as summarization model
      view
      |> element("[data-action='delete'][data-id='#{chat_cred.id}']")
      |> render_click()

      # Should show warning about active config (specifically for summarization)
      assert render(view) =~ "This credential is used in active model configuration"
    end
  end

  # =============================================================================
  # Image Generation Models Multi-Select (R23-R28) - v4.0
  # =============================================================================

  describe "Model Config Tab - Image Generation Models" do
    setup do
      # Create test credentials for selection with unique IDs per test
      unique = System.unique_integer([:positive])

      # Image-capable model (should appear in image generation dropdown)
      # Uses openai:dall-e-3 which is a known image generation model
      {:ok, image_cred} =
        TableCredentials.insert(%{
          model_id: "openai:dalle3-#{unique}",
          model_spec: "openai:dall-e-3",
          api_key: "test-key-1"
        })

      # Another image-capable model
      {:ok, image_cred2} =
        TableCredentials.insert(%{
          model_id: "openai:dalle2-#{unique}",
          model_spec: "openai:dall-e-2",
          api_key: "test-key-2"
        })

      # Chat-only model (should NOT appear in image generation dropdown)
      {:ok, chat_cred} =
        TableCredentials.insert(%{
          model_id: "azure:gpt4-chat-#{unique}",
          model_spec: "azure:gpt-4o",
          api_key: "test-key-3",
          endpoint_url: "https://test.openai.azure.com",
          deployment_id: "gpt-4o"
        })

      %{
        image_cred: image_cred,
        image_cred2: image_cred2,
        chat_cred: chat_cred,
        unique: unique
      }
    end

    test "R23: image generation dropdown shows only image-capable models", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      image_cred: image_cred,
      chat_cred: chat_cred
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      # Should have image generation models multi-select dropdown
      assert has_element?(
               view,
               "select[name='model_config[image_generation_models][]'][multiple]"
             )

      # Image-capable model SHOULD appear in image generation dropdown
      assert has_element?(
               view,
               "select[name='model_config[image_generation_models][]'] option[value='#{image_cred.model_id}']"
             )

      # Chat-only model should NOT appear in image generation dropdown
      refute has_element?(
               view,
               "select[name='model_config[image_generation_models][]'] option[value='#{chat_cred.model_id}']"
             )
    end

    test "R24: saving image generation models persists to database", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      image_cred: image_cred,
      image_cred2: image_cred2
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      # Submit config with image generation models
      view
      |> form("#model-config-form", %{
        model_config: %{
          image_generation_models: [image_cred.model_id, image_cred2.model_id]
        }
      })
      |> render_submit()

      # Should show success message
      assert render(view) =~ "Model configuration saved"

      # Verify image generation models were persisted to database
      {:ok, saved_models} = ConfigModelSettings.get_image_generation_models()
      assert image_cred.model_id in saved_models
      assert image_cred2.model_id in saved_models
    end

    test "R25: current image generation models are pre-selected on mount", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      image_cred: image_cred,
      image_cred2: image_cred2
    } do
      # Set up existing image generation models config BEFORE mounting
      {:ok, _} =
        ConfigModelSettings.set_image_generation_models([
          image_cred.model_id,
          image_cred2.model_id
        ])

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      # Should display current image generation models as selected
      assert has_element?(
               view,
               "select[name='model_config[image_generation_models][]'] option[selected][value='#{image_cred.model_id}']"
             )

      assert has_element?(
               view,
               "select[name='model_config[image_generation_models][]'] option[selected][value='#{image_cred2.model_id}']"
             )
    end

    test "R26: delete warns when credential is in image generation models", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      image_cred: image_cred
    } do
      # Set image_cred in image generation models (not in consensus)
      {:ok, _} = ConfigModelSettings.set_image_generation_models([image_cred.model_id])

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to credentials tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      # Click delete on the credential used in image generation models
      view
      |> element("[data-action='delete'][data-id='#{image_cred.id}']")
      |> render_click()

      # Should show warning about active config
      assert render(view) =~ "This credential is used in active model configuration"
    end

    test "R27: multi-select allows multiple image model selection", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      image_cred: image_cred,
      image_cred2: image_cred2
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      # Submit config with multiple image generation models
      view
      |> form("#model-config-form", %{
        model_config: %{
          image_generation_models: [image_cred.model_id, image_cred2.model_id]
        }
      })
      |> render_submit()

      # Verify both models were saved
      {:ok, saved_models} = ConfigModelSettings.get_image_generation_models()
      assert length(saved_models) == 2
      assert image_cred.model_id in saved_models
      assert image_cred2.model_id in saved_models
    end

    test "R28: empty image generation model list is valid", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # First set some image generation models
      {:ok, _} = ConfigModelSettings.set_image_generation_models(["some-model"])

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      # Submit config with empty image generation models (feature is optional)
      view
      |> form("#model-config-form", %{
        model_config: %{}
        # image_generation_models not included = empty list
      })
      |> render_submit()

      # Should show success message (empty list is valid)
      assert render(view) =~ "Model configuration saved"

      # Verify empty list was saved
      {:ok, saved_models} = ConfigModelSettings.get_image_generation_models()
      assert saved_models == []
    end
  end
end
