defmodule Quoracle.Models.IntegrationAuditFindingsTest do
  @moduledoc """
  Tests for integration audit findings from feat-20260219-local-model-support.

  Addresses five audit findings:
  - Finding 1 (High): Authenticated local models misclassified as non-local
  - Finding 2 (High): Custom provider values crash query flow
  - Finding 3 (Medium): Acceptance tests should use route entry
  - Finding 4 (Medium): Azure bypass behavior spec-fidelity drift
  - Finding 5 (Medium): Edit flow breaks local credential semantics

  All tests follow TDD: written to fail against current implementation,
  will pass after IMPLEMENT phase fixes.
  """

  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import ExUnit.CaptureLog

  alias Quoracle.Models.{ModelQuery, TableCredentials, Embeddings}
  alias QuoracleWeb.SecretManagementLive.ModelConfigHelpers

  setup do
    # Create isolated PubSub for each test
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    %{pubsub: pubsub}
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  # Stub plug that returns a successful chat completion response
  defp success_plug(content \\ "Test response") do
    fn conn ->
      response = %{
        "id" => "chatcmpl-#{System.unique_integer([:positive])}",
        "object" => "chat.completion",
        "model" => "test-model",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => content},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  defp embedding_stub_plug do
    sample_embedding = List.duplicate(0.01, 3072)

    fn conn ->
      response = %{
        "data" => [%{"embedding" => sample_embedding, "index" => 0}],
        "model" => "test-embed",
        "usage" => %{"prompt_tokens" => 10, "total_tokens" => 10}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  # ============================================================================
  # FINDING 1 (HIGH): Authenticated Local Models Misclassified
  #
  # local_model?/1 requires endpoint_url AND blank api_key.
  # Models with both endpoint_url AND api_key (valid per TABLE_Credentials R13)
  # lose "(local)" labeling and can be filtered out of image-model selection.
  # Spec at UI_SecretManagement.md:708-710 says local_model? should check
  # only endpoint_url presence, not api_key.
  # ============================================================================

  describe "F1: auth local model classification" do
    test "local_model? true with endpoint_url and api_key" do
      # TABLE_Credentials R13 says: credential with both endpoint_url and api_key is valid.
      # UI_SecretManagement spec says: local_model? checks endpoint_url != nil and != "".
      # Current implementation INCORRECTLY requires blank api_key.
      unique = System.unique_integer([:positive])

      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: "auth_local_#{unique}",
          model_spec: "vllm:llama3",
          api_key: "local-auth-key-#{unique}",
          endpoint_url: "http://localhost:11434/v1"
        })

      # load_credentialed_models should label this as "(local)" since it has endpoint_url
      models = ModelConfigHelpers.load_credentialed_models()

      matching =
        Enum.find(models, fn {_label, model_id} ->
          model_id == "auth_local_#{unique}"
        end)

      assert matching != nil, "Authenticated local model should appear in credentialed models"

      {label, _model_id} = matching

      assert label =~ "(local)",
             "Authenticated local model should have (local) suffix but got: #{label}"
    end

    test "auth local model in image generation dropdown" do
      # When a local model has both endpoint_url and api_key, it should still
      # bypass the LLMDB filter in filter_image_models/2.
      unique = System.unique_integer([:positive])

      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: "auth_local_img_#{unique}",
          model_spec: "vllm:llama3",
          api_key: "local-auth-key-img-#{unique}",
          endpoint_url: "http://localhost:11434/v1"
        })

      credentialed_models = ModelConfigHelpers.load_credentialed_models()
      image_capable_models = ModelConfigHelpers.load_image_capable_models()

      filtered = ModelConfigHelpers.filter_image_models(credentialed_models, image_capable_models)

      matching_in_filtered =
        Enum.any?(filtered, fn {_label, model_id} ->
          model_id == "auth_local_img_#{unique}"
        end)

      assert matching_in_filtered,
             "Authenticated local model with endpoint_url should bypass LLMDB filter for image models"
    end

    test "cloud model without endpoint_url NOT labeled local" do
      # Regression guard: cloud models (no endpoint_url) should never be labeled local
      unique = System.unique_integer([:positive])

      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: "cloud_not_local_#{unique}",
          model_spec: "openai:gpt-4o-mini",
          api_key: "sk-test-cloud-key-#{unique}"
        })

      models = ModelConfigHelpers.load_credentialed_models()

      matching =
        Enum.find(models, fn {_label, model_id} ->
          model_id == "cloud_not_local_#{unique}"
        end)

      assert matching != nil
      {label, _} = matching
      refute label =~ "(local)", "Cloud model without endpoint_url should NOT have (local) suffix"
    end
  end

  # ============================================================================
  # FINDING 2 (HIGH): Custom Provider Values Crash Query Flow
  #
  # Both model_query.ex:246 and embeddings.ex:387 fall back to
  # String.to_existing_atom/1 for provider conversion. For unknown/typo
  # providers this raises ArgumentError (unhandled), which is a reliability
  # gap given custom model_spec is accepted from UI input.
  # ============================================================================

  describe "F2: custom provider crash ModelQuery" do
    test "unknown provider returns error tuple, not raise" do
      # Create a credential with a provider that is NOT in @local_providers
      # and NOT a pre-existing atom (simulates a UI typo).
      # After fix: should return {:ok, _} or {:error, _}, not raise.
      unique = System.unique_integer([:positive])
      model_id = "typo_provider_mq_#{unique}"

      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: model_id,
          model_spec: "notarealprovidername#{unique}:some-model",
          endpoint_url: "http://localhost:9999/v1"
        })

      messages = [%{role: "user", content: "Hello"}]

      # After IMPLEMENT: this should NOT raise. It should return a result tuple.
      # Currently raises ArgumentError from String.to_existing_atom/1.
      result =
        ModelQuery.query_models(messages, [model_id], %{
          execution_mode: :sequential,
          plug: success_plug()
        })

      # After fix, we should reach here with an error or success tuple
      assert match?({:ok, _}, result) or match?({:error, _}, result),
             "Unknown provider should return a tuple, not crash"
    end
  end

  describe "F2: custom provider crash Embeddings" do
    setup do
      {:ok, _cache_pid} = start_supervised(Quoracle.Models.EmbeddingCache)
      :ok
    end

    test "unknown embed provider not :authentication_failed" do
      # embeddings.ex:387 has String.to_existing_atom/1 which raises ArgumentError.
      # The rescue clause catches ArgumentError but returns :authentication_failed.
      # After fix: should return a provider-specific error like :invalid_provider
      # or succeed with String.to_atom/1 for custom providers.
      unique = System.unique_integer([:positive])

      unknown_creds = %{
        model_spec: "customlocalprovider#{unique}:some-embed-model",
        api_key: nil,
        endpoint_url: "http://localhost:9999/v1"
      }

      unique_text = "Unknown provider embed test #{unique}"

      # Capture the actual return value from get_embedding
      _log =
        capture_log(fn ->
          result =
            Embeddings.get_embedding(unique_text, %{
              plug: embedding_stub_plug(),
              credentials: unknown_creds
            })

          send(self(), {:embed_result, result})
        end)

      assert_receive {:embed_result, result}

      # The embeddings rescue clause catches ArgumentError and returns
      # {:error, :authentication_failed} which is misleading.
      # After fix, it should either succeed (if using String.to_atom) or
      # return {:error, :invalid_provider} or similar. The key point is
      # it should NOT return :authentication_failed for a provider typo.
      refute result == {:error, :authentication_failed},
             "Unknown provider should not return :authentication_failed"
    end
  end

  # ============================================================================
  # FINDING 3 (MEDIUM): True Acceptance Tests via Route Entry
  #
  # Existing integration tests mount via live_isolated/3 instead of
  # live(conn, "/settings"), so router/session pipeline integration is
  # not fully verified. These tests use the actual route entry point.
  # ============================================================================

  describe "F3: route-based acceptance [SYSTEM]" do
    @tag :acceptance
    test "local cred via /settings appears in model config", %{
      conn: conn
    } do
      # 1. ENTRY POINT: Use real route, NOT live_isolated
      {:ok, view, _html} = live(conn, "/settings")

      # 2. USER ACTION: Create local model credential through the real UI
      # Credentials tab is the default active tab
      view
      |> element("button", "Add Credential")
      |> render_click()

      unique = System.unique_integer([:positive])
      model_id = "route_test_local_#{unique}"

      view
      |> form("#credential-form", %{
        credential: %{
          model_id: model_id,
          model_spec: "vllm:llama3",
          endpoint_url: "http://localhost:11434/v1"
        }
      })
      |> render_submit()

      # 3. POSITIVE ASSERTION: Credential persisted and visible
      {:ok, cred} = TableCredentials.get_by_model_id(model_id)
      assert cred.model_spec == "vllm:llama3"
      assert cred.endpoint_url == "http://localhost:11434/v1"

      # Switch to Model Config tab and verify local model appears
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      html = render(view)

      assert html =~ model_id,
             "Local model should appear in Model Config dropdowns via route entry"

      # 4. NEGATIVE ASSERTION: No errors
      refute html =~ "Error"
    end

    @tag :acceptance
    test "auth local model labeled (local) via /settings", %{
      conn: conn
    } do
      unique = System.unique_integer([:positive])

      # Pre-create authenticated local model credential
      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: "route_auth_local_#{unique}",
          model_spec: "vllm:llama3",
          api_key: "local-key-#{unique}",
          endpoint_url: "http://localhost:11434/v1"
        })

      # 1. ENTRY POINT: Real route
      {:ok, view, _html} = live(conn, "/settings")

      # 2. USER ACTION: Navigate to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      html = render(view)

      # 3. POSITIVE ASSERTION: Authenticated local model has (local) label
      assert html =~ "route_auth_local_#{unique} (local)",
             "Authenticated local model should have (local) indicator via route entry"

      # 4. NEGATIVE ASSERTION
      refute html =~ "Error"
    end

    @tag :acceptance
    test "cloud model unlabeled via /settings route", %{
      conn: conn
    } do
      unique = System.unique_integer([:positive])

      # Pre-create cloud model
      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: "route_cloud_#{unique}",
          model_spec: "openai:gpt-4o-mini",
          api_key: "sk-cloud-key-#{unique}"
        })

      # 1. ENTRY POINT: Real route
      {:ok, view, _html} = live(conn, "/settings")

      # 2. USER ACTION: Navigate to model config tab
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      html = render(view)

      # 3. POSITIVE ASSERTION: Cloud model appears without (local)
      assert html =~ "route_cloud_#{unique}"

      # 4. NEGATIVE ASSERTION: No (local) label on cloud model
      refute html =~ "route_cloud_#{unique} (local)",
             "Cloud model should NOT have (local) indicator"
    end
  end

  # ============================================================================
  # FINDING 4 (MEDIUM): Azure Bypass Behavior Spec-Fidelity
  #
  # Implementation branches on endpoint_url alone for LLMDB bypass
  # (model_query.ex:242, embeddings.ex:383), while spec (MODEL_Query.md:1962)
  # says Azure endpoint_url should use Azure branch, not local bypass.
  # Azure credentials have endpoint_url as a standard field, so they should
  # NOT trigger the local model bypass path.
  #
  # The bypass constructs a map model_ref and tries String.to_existing_atom
  # on the provider prefix, which fails for Azure (and is wrong conceptually).
  # After fix: bypass should check provider prefix and skip for known cloud
  # providers (azure, google-vertex, amazon-bedrock).
  # ============================================================================

  describe "F4: Azure string path, not map bypass" do
    test "Azure with endpoint_url uses string model_spec" do
      # MODEL_Query R57: Azure credentials use Azure branch (not local model bypass).
      # Currently, the bypass at model_query.ex:242 checks ONLY endpoint_url.
      # Azure credentials always have endpoint_url but should use the Azure provider
      # branch which routes via string model_spec through LLMDB.
      #
      # Bug: Azure model_spec "azure:gpt-4o" with endpoint_url triggers the bypass,
      # which calls split_model_spec then String.to_existing_atom("azure").
      # "azure" atom exists so it doesn't crash for "azure:" prefix, but conceptually
      # it constructs a wrong model_ref map instead of using string path.
      unique = System.unique_integer([:positive])
      model_id = "azure_no_bypass_#{unique}"

      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: model_id,
          model_spec: "azure:gpt-4o",
          api_key: "test-azure-key-#{unique}",
          endpoint_url: "https://my-resource.openai.azure.com",
          deployment_id: "gpt-4o-deploy"
        })

      messages = [%{role: "user", content: "Hello"}]
      test_pid = self()

      # Use capturing plug that records the request path.
      # Azure deployment requests go to /openai/deployments/{id}/chat/completions
      # Map bypass requests go to /v1/chat/completions (generic OpenAI)
      capturing_plug = fn conn ->
        send(test_pid, {:request_path, conn.request_path})

        response = %{
          "id" => "chatcmpl-#{System.unique_integer([:positive])}",
          "object" => "chat.completion",
          "model" => "gpt-4o",
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => "Azure"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{
            "prompt_tokens" => 10,
            "completion_tokens" => 20,
            "total_tokens" => 30
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      capture_log(fn ->
        {:ok, result} =
          ModelQuery.query_models(messages, [model_id], %{
            execution_mode: :sequential,
            plug: capturing_plug
          })

        assert %{successful_responses: [_response]} = result
      end)

      # Verify the request path uses Azure deployment format
      # With map bypass: request goes to /v1/chat/completions (wrong)
      # With string path: request goes to /openai/deployments/... (correct)
      assert_receive {:request_path, path}, 5000

      assert path =~ "deployments",
             "Azure should use deployment path, got: #{path}"
    end

    test "Azure-OpenAI prefix with endpoint_url no crash" do
      # More explicit variant: "azure-openai:gpt-4o" is another valid Azure format.
      # The bypass tries String.to_existing_atom("azure-openai") which crashes
      # because the atom doesn't exist. This proves the bypass fires for Azure.
      # After fix: Azure provider prefixes should skip the bypass entirely.
      unique = System.unique_integer([:positive])
      model_id = "azure_openai_prefix_#{unique}"

      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: model_id,
          model_spec: "azure_openai:gpt-4o",
          api_key: "test-azure-key-#{unique}",
          endpoint_url: "https://my-resource.openai.azure.com",
          deployment_id: "gpt-4o-deploy"
        })

      messages = [%{role: "user", content: "Test Azure path"}]

      # After fix: should NOT raise. Currently crashes with ArgumentError
      # because String.to_existing_atom("azure-openai") fails (azure_openai
      # becomes azure-openai via get_provider_prefix normalization, and that
      # atom doesn't exist).
      result =
        ModelQuery.query_models(messages, [model_id], %{
          execution_mode: :sequential,
          plug: success_plug("Azure response")
        })

      assert match?({:ok, _}, result) or match?({:error, _}, result),
             "Azure-OpenAI credential should not crash the query flow"
    end
  end

  describe "F4: Azure embed string path" do
    setup do
      {:ok, _cache_pid} = start_supervised(Quoracle.Models.EmbeddingCache)
      :ok
    end

    test "Azure embed cred no map bypass" do
      # Same issue in embeddings.ex:383 - Azure credentials have endpoint_url
      # but should NOT trigger the local model bypass.
      test_pid = self()

      # Capturing plug that records the request path
      capturing_plug = fn conn ->
        send(test_pid, {:embed_path, conn.request_path})

        sample_embedding = List.duplicate(0.01, 3072)

        response = %{
          "data" => [%{"embedding" => sample_embedding, "index" => 0}],
          "model" => "text-embedding-3-large",
          "usage" => %{"prompt_tokens" => 10, "total_tokens" => 10}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      azure_embed_creds = %{
        model_spec: "azure:text-embedding-3-large",
        api_key: "test-azure-key",
        endpoint_url: "https://test.openai.azure.com",
        deployment_id: "embed-large"
      }

      unique_text = "Azure embed bypass #{System.unique_integer([:positive])}"

      capture_log(fn ->
        result =
          Embeddings.get_embedding(unique_text, %{
            plug: capturing_plug,
            credentials: azure_embed_creds
          })

        assert {:ok, %{embedding: embedding}} = result
        assert length(embedding) == 3072
      end)

      # Verify the request uses Azure deployment path format
      # Map bypass: /v1/embeddings (generic OpenAI)
      # String path: /openai/deployments/embed-large/embeddings (Azure)
      assert_receive {:embed_path, path}, 5000

      assert path =~ "deployments",
             "Azure embed should use deployment path, got: #{path}"
    end
  end

  # ============================================================================
  # FINDING 5 (MEDIUM): Edit Flow Breaks Local Credential Semantics
  #
  # The edit credential modal gates endpoint_url behind Azure-only UI
  # (@selected_provider == "azure"). When editing a local model credential
  # (provider "vllm"), the endpoint_url field is hidden, so submitting
  # the edit form clears endpoint_url to nil, breaking local model routing.
  #
  # Spec says: "endpoint_url always visible" (UI_SecretManagement.md:653).
  # This applies to both NEW and EDIT forms.
  # ============================================================================

  describe "F5: edit flow preserves local credential endpoint_url" do
    @tag :acceptance
    test "edit modal shows endpoint_url for local model credential", %{conn: conn} do
      # Pre-create local model credential
      unique = System.unique_integer([:positive])
      model_id = "edit_local_#{unique}"

      {:ok, cred} =
        TableCredentials.insert(%{
          model_id: model_id,
          model_spec: "vllm:llama3",
          endpoint_url: "http://localhost:11434/v1"
        })

      # Navigate to settings, credentials tab
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      # Click edit on the local model credential
      view
      |> element("[data-action='edit'][data-id='#{cred.id}']")
      |> render_click()

      # The edit modal should show the endpoint_url field with its current value
      html = render(view)

      assert has_element?(view, "input[name='credential[endpoint_url]']"),
             "Edit modal should show endpoint_url field for local model credentials"

      assert html =~ "http://localhost:11434/v1",
             "Edit modal endpoint_url should be populated with existing value"

      # Negative: no application error messages
      refute has_element?(view, ".error-message")
    end

    @tag :acceptance
    test "editing local model credential preserves endpoint_url", %{conn: conn} do
      # Pre-create local model credential
      unique = System.unique_integer([:positive])
      model_id = "edit_preserve_#{unique}"

      {:ok, cred} =
        TableCredentials.insert(%{
          model_id: model_id,
          model_spec: "vllm:llama3",
          endpoint_url: "http://localhost:11434/v1"
        })

      # Navigate to settings, credentials tab
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      # Click edit on the local model credential
      view
      |> element("[data-action='edit'][data-id='#{cred.id}']")
      |> render_click()

      # Submit the edit form (changing only the model_id, keeping endpoint_url)
      view
      |> form("#credential-form", %{
        credential: %{
          model_id: model_id,
          model_spec: "vllm:llama3",
          endpoint_url: "http://localhost:11434/v1"
        }
      })
      |> render_submit()

      # Verify endpoint_url is preserved in database
      {:ok, updated} = TableCredentials.get_by_model_id(model_id)

      assert updated.endpoint_url == "http://localhost:11434/v1",
             "Editing local model should preserve endpoint_url, got: #{inspect(updated.endpoint_url)}"

      # Negative: endpoint_url must not be nil/cleared
      refute is_nil(updated.endpoint_url)
    end

    @tag :acceptance
    test "editing local model credential can update endpoint_url", %{conn: conn} do
      # Pre-create local model credential
      unique = System.unique_integer([:positive])
      model_id = "edit_update_url_#{unique}"

      {:ok, cred} =
        TableCredentials.insert(%{
          model_id: model_id,
          model_spec: "vllm:llama3",
          endpoint_url: "http://localhost:11434/v1"
        })

      # Navigate to settings, credentials tab
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      # Click edit
      view
      |> element("[data-action='edit'][data-id='#{cred.id}']")
      |> render_click()

      # Submit the edit form with a changed endpoint_url
      view
      |> form("#credential-form", %{
        credential: %{
          model_id: model_id,
          model_spec: "vllm:llama3",
          endpoint_url: "http://localhost:8000/v1"
        }
      })
      |> render_submit()

      # Verify endpoint_url was updated
      {:ok, updated} = TableCredentials.get_by_model_id(model_id)

      assert updated.endpoint_url == "http://localhost:8000/v1",
             "Should be able to change endpoint_url during edit, got: #{inspect(updated.endpoint_url)}"

      # Negative: old URL should be gone
      refute updated.endpoint_url == "http://localhost:11434/v1"
    end
  end
end
