defmodule Quoracle.Models.LocalModelIntegrationTest do
  @moduledoc """
  Cross-cutting integration tests for local model support.

  Packet 3 of feat-20260219-local-model-support.

  ARC Verification Criteria from TEST_LocalModelSupport spec:
  - R1: End-to-End Local Model Credential Flow [SYSTEM]
  - R2: Cloud Model Regression Guard [SYSTEM]
  - R3: Mixed Model Pool Routing [INTEGRATION]
  """

  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  alias Quoracle.Models.{TableCredentials, ConfigModelSettings, ModelQuery}
  alias Quoracle.Models.ModelQuery.OptionsBuilder

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

  # Stub plug that returns a successful chat completion response
  defp success_plug(content) do
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

  # ============================================================================
  # R1: End-to-End Local Model Credential Flow [SYSTEM]
  # WHEN user creates vllm credential via Settings UI with endpoint_url and no
  # api_key THEN credential persisted AND appears in Model Config dropdowns AND
  # can be saved as consensus/embedding model
  # ============================================================================

  describe "R1: E2E credential flow [SYSTEM]" do
    @tag :acceptance
    test "e2e: create local model credential through UI to model config", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Step 1: Create local model credential via UI (Credentials tab is default)
      view
      |> element("button", "Add Credential")
      |> render_click()

      unique = System.unique_integer([:positive])
      model_id = "vllm_e2e_#{unique}"

      view
      |> form("#credential-form", %{
        credential: %{
          model_id: model_id,
          model_spec: "vllm:llama3",
          endpoint_url: "http://localhost:11434/v1"
        }
      })
      |> render_submit()

      # Step 2: Verify credential persisted in DB
      {:ok, cred} = TableCredentials.get_by_model_id(model_id)
      assert cred.model_spec == "vllm:llama3"
      assert cred.endpoint_url == "http://localhost:11434/v1"
      assert is_nil(cred.api_key)

      # Step 3: Switch to Model Config tab and verify local model appears
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      html = render(view)

      # Positive: Local model appears in at least one dropdown
      assert html =~ model_id,
             "Local model should appear in Model Config dropdowns after creation"

      # Step 4: Select local model as embedding model and save config
      view
      |> form("#model-config-form", %{
        model_config: %{
          embedding_model: model_id
        }
      })
      |> render_submit()

      # Positive: Config saved successfully (flash message)
      assert render(view) =~ "Model configuration saved"

      # Verify embedding model persisted
      settings = ConfigModelSettings.get_all()
      assert settings.embedding_model == model_id

      # Negative: No errors
      refute render(view) =~ "Error saving"
    end
  end

  # ============================================================================
  # R2: Cloud Model Regression Guard [SYSTEM]
  # WHEN existing cloud model credentials present AND local model support
  # changes deployed THEN cloud models continue to be queried successfully
  # and return responses
  # ============================================================================

  describe "R2: cloud model regression [SYSTEM]" do
    @tag :acceptance
    test "e2e: cloud model credentials unaffected by local model changes", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      unique = System.unique_integer([:positive])

      # Step 1: Create a cloud credential (standard OpenAI format)
      cloud_model_id = "cloud_regression_guard_#{unique}"

      {:ok, cloud_cred} =
        TableCredentials.insert(%{
          model_id: cloud_model_id,
          model_spec: "openai:gpt-4o-mini",
          api_key: "sk-test-cloud-key-#{unique}"
        })

      # Step 2: Also create a local model credential alongside
      local_model_id = "local_regression_guard_#{unique}"

      {:ok, _local_cred} =
        TableCredentials.insert(%{
          model_id: local_model_id,
          model_spec: "vllm:llama3",
          endpoint_url: "http://localhost:11434/v1"
        })

      # Step 3: Query the cloud model - should use string model_spec path
      messages = [%{role: "user", content: "Hello from regression test"}]
      plug = success_plug("Cloud model response")

      {:ok, result} =
        ModelQuery.query_models(messages, [cloud_model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug
        })

      # Positive: Cloud model query succeeds
      assert %{successful_responses: [response]} = result
      assert %ReqLLM.Response{} = response

      # Positive: Cloud credential uses string model_spec (not map)
      cloud_opts = OptionsBuilder.build_options(cloud_cred, %{})

      refute Keyword.has_key?(cloud_opts, :base_url),
             "Cloud model should NOT have base_url (no endpoint_url)"

      # Negative: No failed models
      refute match?(%{failed_models: [_ | _]}, result)

      # Step 4: Packet 3 UI regression - verify UI correctly shows
      # cloud credential WITHOUT "(local)" label
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      html = render(view)

      # Cloud model should appear in dropdown without "(local)" marker
      assert html =~ cloud_model_id
      # Local model should appear with "(local)" marker (Packet 3 change)
      assert html =~ "#{local_model_id} (local)",
             "Local model should have (local) indicator in dropdown"
    end
  end

  # ============================================================================
  # R3: Mixed Model Pool Routing [INTEGRATION]
  # WHEN consensus pool contains both cloud and local models THEN cloud models
  # use string model_spec path AND local models use map bypass path AND
  # image dropdown includes local models
  # ============================================================================

  describe "R3: mixed pool routing [INTEGRATION]" do
    test "mixed model pool routing and UI inclusion", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      unique = System.unique_integer([:positive])

      # Create both cloud and local credentials
      cloud_model_id = "cloud_mixed_#{unique}"

      {:ok, cloud_cred} =
        TableCredentials.insert(%{
          model_id: cloud_model_id,
          model_spec: "openai:gpt-4o-mini",
          api_key: "sk-test-mixed-cloud-#{unique}"
        })

      local_model_id = "local_mixed_#{unique}"

      {:ok, local_cred} =
        TableCredentials.insert(%{
          model_id: local_model_id,
          model_spec: "vllm:llama3",
          endpoint_url: "http://localhost:11434/v1"
        })

      # Verify routing paths are different based on endpoint_url presence

      # Cloud model: string model_spec path (no base_url)
      cloud_opts = OptionsBuilder.build_options(cloud_cred, %{})

      refute Keyword.has_key?(cloud_opts, :base_url),
             "Cloud model should use string path (no base_url)"

      # Local model: map bypass path (with base_url)
      local_opts = OptionsBuilder.build_options(local_cred, %{})

      assert Keyword.get(local_opts, :base_url) == "http://localhost:11434/v1",
             "Local model should use map bypass path (with base_url)"

      # Query both models in a mixed pool
      messages = [%{role: "user", content: "Hello from mixed pool test"}]
      plug = success_plug("Mixed pool response")

      {:ok, result} =
        ModelQuery.query_models(messages, [cloud_model_id, local_model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug
        })

      # Both models should succeed
      assert %{successful_responses: responses} = result
      assert length(responses) == 2, "Both cloud and local models should respond"

      # No failed models
      refute match?(%{failed_models: [_ | _]}, result)

      # Packet 3 cross-cutting: Verify UI shows local model in
      # image generation dropdown (requires filter_image_models bypass)
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      view
      |> element("[phx-click='switch_tab'][phx-value-tab='model_config']")
      |> render_click()

      # Local model should be in image dropdown (bypasses LLMDB filter)
      assert has_element?(
               view,
               "select[name='model_config[image_generation_models][]'] option[value='#{local_model_id}']"
             ),
             "Local model should appear in image generation dropdown"
    end
  end
end
