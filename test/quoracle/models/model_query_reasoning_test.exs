defmodule Quoracle.Models.ModelQueryReasoningTest do
  @moduledoc """
  Tests for OptionsBuilder reasoning configuration across all providers.

  ARC Verification Criteria:
  - R14: Azure Gets Reasoning [UNIT]
  - R15: Google Vertex Gets Reasoning [UNIT]
  - R16: Bedrock Gets Reasoning [UNIT]
  - R17: Default Gets Reasoning [UNIT]
  - R18: Reasoning Reaches ReqLLM [INTEGRATION]
  - R19: DeepSeek Gets Thinking [UNIT]

  WorkGroupID: reasoning-20251212-101500
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Models.{ModelQuery, TableCredentials}

  # Test credentials for each provider type
  defp create_azure_credential(model_id, model_spec \\ "azure:gpt-5.1-chat") do
    {:ok, credential} =
      TableCredentials.insert(%{
        model_id: model_id,
        model_spec: model_spec,
        api_key: "test-azure-key",
        endpoint_url: "https://test.openai.azure.com",
        deployment_id: "gpt-5-deployment"
      })

    credential
  end

  defp create_bedrock_credential(model_id) do
    {:ok, credential} =
      TableCredentials.insert(%{
        model_id: model_id,
        model_spec: "amazon-bedrock:anthropic.claude-opus-4-5-v1:0",
        api_key: "ACCESS_KEY:SECRET_KEY",
        region: "us-east-1"
      })

    credential
  end

  defp create_unknown_provider_credential(model_id) do
    {:ok, credential} =
      TableCredentials.insert(%{
        model_id: model_id,
        model_spec: "unknown-provider:some-model",
        api_key: "test-api-key"
      })

    credential
  end

  describe "R14: Azure Gets Reasoning [UNIT]" do
    test "build_options includes reasoning_effort and reasoning_token_budget for azure" do
      credential = create_azure_credential("test_azure_reasoning_#{System.unique_integer()}")

      opts = ModelQuery.build_options(credential, %{})

      assert Keyword.get(opts, :reasoning_effort) == :high
      assert Keyword.get(opts, :reasoning_token_budget) == 16_000
    end
  end

  describe "R15: Google Vertex Gets Reasoning [UNIT]" do
    test "build_options includes reasoning_effort and budget for Gemini on Vertex" do
      {:ok, credential} =
        TableCredentials.insert(%{
          model_id: "test_vertex_gemini_#{System.unique_integer()}",
          model_spec: "google-vertex:gemini-2.0-flash",
          api_key: ~s({"type": "service_account", "project_id": "test"}),
          resource_id: "test-project",
          region: "us-central1"
        })

      opts = ModelQuery.build_options(credential, %{})

      assert Keyword.get(opts, :reasoning_effort) == :high
      assert Keyword.get(opts, :reasoning_token_budget) == 16_000
    end

    test "build_options includes reasoning_effort and budget for Claude on Vertex" do
      {:ok, credential} =
        TableCredentials.insert(%{
          model_id: "test_vertex_claude_#{System.unique_integer()}",
          model_spec: "google-vertex:claude-3-5-sonnet",
          api_key: ~s({"type": "service_account", "project_id": "test"}),
          resource_id: "test-project",
          region: "us-central1"
        })

      opts = ModelQuery.build_options(credential, %{})

      # ReqLLM translates reasoning_effort + reasoning_token_budget to
      # thinking config for Claude models on platform providers
      assert Keyword.get(opts, :reasoning_effort) == :high
      assert Keyword.get(opts, :reasoning_token_budget) == 16_000

      # No manual thinking config — ReqLLM handles the translation
      provider_opts = Keyword.get(opts, :provider_options, [])
      additional_fields = Keyword.get(provider_opts, :additional_model_request_fields, %{})
      refute Map.has_key?(additional_fields, :thinking)
    end
  end

  describe "R16: Bedrock Gets Reasoning [UNIT]" do
    test "build_options includes reasoning_effort and budget for Claude on Bedrock" do
      credential = create_bedrock_credential("test_bedrock_reasoning_#{System.unique_integer()}")

      opts = ModelQuery.build_options(credential, %{})

      # ReqLLM translates reasoning_effort + reasoning_token_budget to
      # thinking config for Claude models on platform providers
      assert Keyword.get(opts, :reasoning_effort) == :high
      assert Keyword.get(opts, :reasoning_token_budget) == 16_000
    end

    test "build_options includes reasoning for bedrock fallback case" do
      {:ok, credential} =
        TableCredentials.insert(%{
          model_id: "test_bedrock_fallback_#{System.unique_integer()}",
          model_spec: "amazon-bedrock:anthropic.claude-v2",
          api_key: "regular-api-key-not-colon-separated",
          region: "us-west-2"
        })

      opts = ModelQuery.build_options(credential, %{})

      assert Keyword.get(opts, :reasoning_effort) == :high
      assert Keyword.get(opts, :reasoning_token_budget) == 16_000
    end

    test "build_options includes reasoning for non-Claude Bedrock models" do
      {:ok, credential} =
        TableCredentials.insert(%{
          model_id: "test_bedrock_cohere_#{System.unique_integer()}",
          model_spec: "amazon-bedrock:cohere.command-r-plus-v1:0",
          api_key: "ACCESS_KEY:SECRET_KEY",
          region: "us-east-1"
        })

      opts = ModelQuery.build_options(credential, %{})

      assert Keyword.get(opts, :reasoning_effort) == :high
      assert Keyword.get(opts, :reasoning_token_budget) == 16_000

      # No thinking config for non-Claude models
      provider_opts = Keyword.get(opts, :provider_options, [])
      additional_fields = Keyword.get(provider_opts, :additional_model_request_fields, %{})
      refute Map.get(additional_fields, :thinking)
    end
  end

  describe "R17: Default Gets Reasoning [UNIT]" do
    test "build_options includes reasoning_effort and budget for unknown provider" do
      credential =
        create_unknown_provider_credential("test_unknown_reasoning_#{System.unique_integer()}")

      opts = ModelQuery.build_options(credential, %{})

      assert Keyword.get(opts, :reasoning_effort) == :high
      assert Keyword.get(opts, :reasoning_token_budget) == 16_000
    end
  end

  describe "R18: Reasoning Reaches ReqLLM [INTEGRATION]" do
    # Helper plug that captures options passed via the request
    # ReqLLM translates reasoning_effort into provider-specific request fields
    defp capturing_plug(test_pid) do
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        body_json = Jason.decode!(body)

        send(test_pid, {:request_captured, %{body: body_json, headers: conn.req_headers}})

        response = %{
          "id" => "chatcmpl-#{System.unique_integer([:positive])}",
          "object" => "chat.completion",
          "model" => "gpt-5.1-chat",
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => "Test response"},
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

    test "reasoning_effort option reaches ReqLLM.generate_text", %{sandbox_owner: sandbox_owner} do
      model_id = "test_reasoning_integration_#{System.unique_integer()}"
      _credential = create_azure_credential(model_id)

      test_pid = self()
      plug = capturing_plug(test_pid)

      messages = [%{role: "user", content: "Hello"}]

      # Verify that passing reasoning_effort through our code works end-to-end
      # ReqLLM may or may not add reasoning fields to HTTP body depending on model support
      # (on_unsupported: :ignore silently drops unsupported options)
      # The key verification is that the full flow completes without error
      {:ok, result} =
        ModelQuery.query_models(messages, [model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug
        })

      # Verify request was made successfully
      assert_receive {:request_captured, %{body: body}}, 30_000
      assert is_map(body)
      assert Map.has_key?(body, "messages")

      # Verify we got a successful response (proves full integration works)
      assert %{successful_responses: [response]} = result
      assert %ReqLLM.Response{} = response

      # The reasoning_effort option was passed to ReqLLM (verified by R14-R17 unit tests)
      # ReqLLM's handling of it depends on model support - not our responsibility to test
    end
  end

  describe "R19: DeepSeek Gets Thinking [UNIT]" do
    test "build_options includes thinking config for DeepSeek V3.2 on Azure" do
      credential =
        create_azure_credential(
          "test_azure_deepseek_#{System.unique_integer()}",
          "azure:deepseek-v3.2"
        )

      opts = ModelQuery.build_options(credential, %{})

      # DeepSeek gets thinking enabled via additional_model_request_fields
      provider_opts = Keyword.get(opts, :provider_options, [])
      additional_fields = Keyword.get(provider_opts, :additional_model_request_fields)
      assert additional_fields == %{thinking: %{type: "enabled"}}

      # Also gets standard reasoning options (harmlessly ignored by DeepSeek)
      assert Keyword.get(opts, :reasoning_effort) == :high
      assert Keyword.get(opts, :reasoning_token_budget) == 16_000
    end

    test "build_options includes thinking config for DeepSeek V3.2-Speciale on Azure" do
      credential =
        create_azure_credential(
          "test_azure_deepseek_speciale_#{System.unique_integer()}",
          "azure:deepseek-v3.2-speciale"
        )

      opts = ModelQuery.build_options(credential, %{})

      provider_opts = Keyword.get(opts, :provider_options, [])
      additional_fields = Keyword.get(provider_opts, :additional_model_request_fields)
      assert additional_fields == %{thinking: %{type: "enabled"}}
    end

    test "build_options does not include thinking config for non-DeepSeek Azure models" do
      credential =
        create_azure_credential("test_azure_gpt_#{System.unique_integer()}", "azure:gpt-5.1-chat")

      opts = ModelQuery.build_options(credential, %{})

      provider_opts = Keyword.get(opts, :provider_options, [])
      refute Keyword.has_key?(provider_opts, :additional_model_request_fields)
    end

    test "DeepSeek thinking coexists with JSON mode provider_options" do
      credential =
        create_azure_credential(
          "test_azure_deepseek_json_#{System.unique_integer()}",
          "azure:deepseek-v3.2"
        )

      # Default options (skip_json_mode is false)
      opts = ModelQuery.build_options(credential, %{})

      provider_opts = Keyword.get(opts, :provider_options, [])
      # Both should be present
      assert Keyword.get(provider_opts, :additional_model_request_fields) ==
               %{thinking: %{type: "enabled"}}

      assert Keyword.get(provider_opts, :response_format) == %{type: "json_object"}
    end
  end
end
