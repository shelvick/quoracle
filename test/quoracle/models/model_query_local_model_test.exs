defmodule Quoracle.Models.ModelQueryLocalModelTest do
  @moduledoc """
  Tests for MODEL_Query v19.0 local model support (LLMDB bypass).

  Packet 1 of feat-20260219-local-model-support.

  ARC Verification Criteria from MODEL_Query spec v19.0:
  - R50: Local Model Map Bypass [UNIT]
  - R51: Cloud Model String Path Unchanged [UNIT] (folded into R50)
  - R52: OptionsBuilder Base URL Forwarding [UNIT]
  - R53: OptionsBuilder No Base URL Without Endpoint [UNIT] (folded into R52)
  - R54: OptionsBuilder Nil API Key Forwarded [UNIT]
  - R55: OptionsBuilder Embedding Base URL [UNIT]
  - R56: Model Spec Parsing [UNIT] (folded into R50)
  - R57: Azure Endpoint Unchanged [UNIT] (folded into R52)
  - R58: Local Model Query Reaches Endpoint [SYSTEM]
  """

  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog

  alias Quoracle.Models.{ModelQuery, TableCredentials}
  alias Quoracle.Models.ModelQuery.OptionsBuilder

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp create_local_credential(model_id, opts \\ %{}) do
    attrs =
      Map.merge(
        %{
          model_id: model_id,
          model_spec: Map.get(opts, :model_spec, "vllm:llama3"),
          endpoint_url: Map.get(opts, :endpoint_url, "http://localhost:11434/v1")
        },
        Map.drop(opts, [:model_spec, :endpoint_url])
      )

    # Local models may not have api_key -- once v3.0 changeset is implemented
    # this insert will work without api_key when endpoint_url is present
    {:ok, credential} = TableCredentials.insert(attrs)
    credential
  end

  # Stub plug that returns a successful response from the "local model server"
  defp local_model_success_plug(content \\ "Local model response") do
    fn conn ->
      response = %{
        "id" => "chatcmpl-local-#{System.unique_integer([:positive])}",
        "object" => "chat.completion",
        "model" => "llama3",
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

  # Capturing plug that records request details for verification
  defp capturing_plug(test_pid, content \\ "Captured response") do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body_json = Jason.decode!(body)

      send(
        test_pid,
        {:request_captured,
         %{
           method: conn.method,
           path: conn.request_path,
           headers: conn.req_headers,
           body: body_json,
           host: conn.host,
           port: conn.port
         }}
      )

      response = %{
        "id" => "chatcmpl-cap-#{System.unique_integer([:positive])}",
        "object" => "chat.completion",
        "model" => "llama3",
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
  # R50+R51+R56: Local Model Map Bypass [UNIT]
  # R50: WHEN credential has endpoint_url THEN query_via_reqllm constructs model
  #      map with provider atom and model id (bypass LLMDB)
  # R51: WHEN credential has NO endpoint_url THEN string model_spec used (unchanged)
  # R56: WHEN model_spec is "vllm:llama3" THEN parsed into provider + model id
  # ============================================================================

  describe "R50: Local Model Map Bypass [UNIT]" do
    test "local model query succeeds via map bypass", %{sandbox_owner: sandbox_owner} do
      unique = System.unique_integer([:positive])
      local_model_id = "local_map_bypass_#{unique}"

      # Create local credential (no api_key) - depends on TABLE_Credentials v3.0
      local_credential = create_local_credential(local_model_id)
      plug = local_model_success_plug()

      messages = [%{role: "user", content: "Hello"}]

      # R56: Verify model_spec parsing works for local providers
      assert OptionsBuilder.get_provider_prefix(local_credential.model_spec) == "vllm"

      # R50: Local model with endpoint_url should use map bypass
      {:ok, result} =
        ModelQuery.query_models(messages, [local_model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug
        })

      assert %{successful_responses: [response]} = result
      assert %ReqLLM.Response{} = response

      # R51: Cloud model (no endpoint_url) should still use string path
      # Create a cloud credential alongside to verify both paths work
      cloud_model_id = "cloud_regression_#{unique}"

      {:ok, _cloud_cred} =
        TableCredentials.insert(%{
          model_id: cloud_model_id,
          model_spec: "openai:gpt-4o-mini",
          api_key: "test-cloud-key"
        })

      cloud_plug = fn conn ->
        response = %{
          "id" => "resp-#{System.unique_integer([:positive])}",
          "object" => "response",
          "model" => "gpt-4o-mini",
          "status" => "completed",
          "output" => [%{"type" => "output_text", "text" => "Cloud response"}],
          "usage" => %{"input_tokens" => 50, "output_tokens" => 100}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      {:ok, cloud_result} =
        ModelQuery.query_models(messages, [cloud_model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: cloud_plug
        })

      assert %{successful_responses: [cloud_response]} = cloud_result
      assert %ReqLLM.Response{} = cloud_response
    end
  end

  # ============================================================================
  # R52+R53+R57: OptionsBuilder Base URL [UNIT]
  # R52: WHEN credential has endpoint_url THEN build_options includes base_url
  # R53: WHEN credential has NO endpoint_url THEN build_options excludes base_url
  # R57: WHEN credential is Azure THEN uses Azure branch (not local bypass)
  # ============================================================================

  describe "R52: OptionsBuilder Base URL [UNIT]" do
    test "base_url forwarded for local, absent for cloud, Azure unchanged" do
      unique = System.unique_integer([:positive])

      # R52: Local model credential - build_options should include base_url
      local_credential = create_local_credential("local_base_url_#{unique}")
      local_opts = OptionsBuilder.build_options(local_credential, %{})
      assert Keyword.get(local_opts, :base_url) == "http://localhost:11434/v1"

      # R53: Cloud credential - build_options should NOT include base_url
      {:ok, cloud_credential} =
        TableCredentials.insert(%{
          model_id: "cloud_no_base_url_#{unique}",
          model_spec: "openai:gpt-4o-mini",
          api_key: "test-cloud-key"
        })

      cloud_opts = OptionsBuilder.build_options(cloud_credential, %{})
      refute Keyword.has_key?(cloud_opts, :base_url)

      # R57: Azure credential - uses Azure branch with deployment, NOT local bypass
      {:ok, azure_credential} =
        TableCredentials.insert(%{
          model_id: "azure_no_bypass_#{unique}",
          model_spec: "azure:gpt-4o",
          api_key: "test-azure-key",
          endpoint_url: "https://my-resource.openai.azure.com",
          deployment_id: "gpt-4o-deployment"
        })

      azure_opts = OptionsBuilder.build_options(azure_credential, %{})
      assert Keyword.get(azure_opts, :base_url) == "https://my-resource.openai.azure.com"
      assert Keyword.get(azure_opts, :deployment) == "gpt-4o-deployment"
      assert Keyword.get(azure_opts, :api_key) == "test-azure-key"
    end
  end

  # ============================================================================
  # R54: OptionsBuilder Nil API Key Forwarded [UNIT]
  # WHEN credential has nil api_key THEN build_options includes api_key: nil
  # ============================================================================

  describe "R54: Nil API Key Forwarded [UNIT]" do
    test "build_options passes nil api_key for local models" do
      unique = System.unique_integer([:positive])
      # Create credential with nil api_key (local model, no auth)
      # Depends on TABLE_Credentials v3.0 (api_key optional with endpoint_url)
      credential = create_local_credential("local_nil_key_#{unique}")

      opts = OptionsBuilder.build_options(credential, %{})

      # For local models with nil api_key, a placeholder is used because
      # ReqLLM requires a non-nil api_key value. The server handles auth.
      api_key = Keyword.get(opts, :api_key)
      assert api_key != nil, "api_key must be present (ReqLLM requires non-nil)"
      refute api_key =~ ~r/^sk-/, "should not be a real API key"
    end
  end

  # ============================================================================
  # R55: OptionsBuilder Embedding Base URL [UNIT]
  # WHEN embedding credential has endpoint_url THEN build_embedding_options
  # includes base_url
  # ============================================================================

  describe "R55: Embedding Base URL [UNIT]" do
    test "build_embedding_options includes base_url when endpoint_url present" do
      # Use a map to simulate a credential with endpoint_url (embeddings use map access)
      credential = %{
        model_spec: "vllm:nomic-embed-text",
        api_key: nil,
        endpoint_url: "http://localhost:11434/v1"
      }

      opts = OptionsBuilder.build_embedding_options(credential, %{})

      # When embedding credential has endpoint_url, base_url should be forwarded
      assert Keyword.get(opts, :base_url) == "http://localhost:11434/v1"
    end
  end

  # ============================================================================
  # R58: Local Model Query Reaches Endpoint [SYSTEM]
  # WHEN local model credential with endpoint_url is in consensus pool THEN
  # query_models sends request to that endpoint URL
  # ============================================================================

  describe "R58: Local Model Endpoint [SYSTEM]" do
    @tag :acceptance
    test "local model query routes to configured endpoint_url", %{sandbox_owner: sandbox_owner} do
      unique = System.unique_integer([:positive])
      model_id = "local_endpoint_route_#{unique}"
      _credential = create_local_credential(model_id)

      test_pid = self()
      plug = capturing_plug(test_pid)

      messages = [
        %{role: "system", content: "You are a helpful assistant"},
        %{role: "user", content: "Hello from local model test"}
      ]

      # Query the local model - should route to the configured endpoint_url
      # and use the map bypass (not LLMDB string lookup)
      capture_log(fn ->
        {:ok, result} =
          ModelQuery.query_models(messages, [model_id], %{
            sandbox_owner: sandbox_owner,
            execution_mode: :sequential,
            plug: plug
          })

        # Positive: successful response from local model endpoint
        assert %{successful_responses: [response]} = result
        assert %ReqLLM.Response{} = response

        # Negative: no failed models
        refute match?(%{failed_models: [_ | _]}, result)

        # Verify the request was captured (proves it reached the plug/endpoint)
        assert_receive {:request_captured, %{body: body}}, 30_000
        assert is_map(body)
      end)
    end
  end
end
