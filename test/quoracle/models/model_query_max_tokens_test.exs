defmodule Quoracle.Models.ModelQueryMaxTokensTest do
  @moduledoc """
  Tests for OptionsBuilder v16.0 max_tokens passthrough to ReqLLM.

  Verifies that when PerModelQuery calculates a dynamic max_tokens and passes
  it through the options map, OptionsBuilder includes it in the ReqLLM keyword
  list so ReqLLM uses it instead of injecting LLMDB limits.output.

  WorkGroupID: fix-20260210-dynamic-max-tokens
  Spec: CONSENSUS_DynamicMaxTokens v1.0, Section 8 (Integration Tests - OptionsBuilder)
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Models.{ModelQuery, TableCredentials}

  # Create a test credential for Azure provider
  defp create_azure_credential do
    model_id = "test_max_tokens_azure_#{System.unique_integer([:positive])}"

    {:ok, credential} =
      TableCredentials.insert(%{
        model_id: model_id,
        model_spec: "azure:gpt-5.1-chat",
        api_key: "test-azure-key",
        endpoint_url: "https://test.openai.azure.com",
        deployment_id: "gpt-5-deployment"
      })

    {model_id, credential}
  end

  # Create a test credential for default provider (OpenAI-compatible)
  defp create_default_credential do
    model_id = "test_max_tokens_default_#{System.unique_integer([:positive])}"

    {:ok, credential} =
      TableCredentials.insert(%{
        model_id: model_id,
        model_spec: "openai:gpt-4o",
        api_key: "test-openai-key"
      })

    {model_id, credential}
  end

  describe "max_tokens flows to ReqLLM" do
    test "max_tokens from options map included in ReqLLM keyword list" do
      {_model_id, credential} = create_azure_credential()

      # Pass max_tokens through the options map (as PerModelQuery will after fix)
      options = %{max_tokens: 65_536}

      # OptionsBuilder.build_options returns a keyword list for ReqLLM
      # After fix: max_tokens should appear in the keyword list
      # This function doesn't add max_tokens yet — will fail
      opts = ModelQuery.build_options(credential, options)

      # The keyword list should include max_tokens
      assert Keyword.has_key?(opts, :max_tokens),
             "max_tokens from options map should be included in ReqLLM keyword list"

      assert Keyword.get(opts, :max_tokens) == 65_536,
             "max_tokens value should match what was passed in options"
    end

    test "max_tokens absent when not provided in options" do
      {_model_id, credential} = create_default_credential()

      # No max_tokens in options map — ReqLLM should use its own default
      options = %{}

      opts = ModelQuery.build_options(credential, options)

      # When no max_tokens provided, it should NOT be in the keyword list
      # This allows ReqLLM to use LLMDB limits.output as its default
      refute Keyword.has_key?(opts, :max_tokens),
             "max_tokens should not be added when not provided — let ReqLLM default"
    end

    test "max_tokens reaches HTTP request via plug capture" do
      {model_id, _credential} = create_azure_credential()

      test_pid = self()

      # Plug that captures the request body to verify max_tokens
      capturing_plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        body_json = Jason.decode!(body)
        send(test_pid, {:request_body, body_json})

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

      messages = [%{role: "user", content: "Hello"}]

      # Pass max_tokens through options — should reach the HTTP body
      {:ok, _result} =
        ModelQuery.query_models(messages, [model_id], %{
          sandbox_owner: self(),
          execution_mode: :sequential,
          plug: capturing_plug,
          max_tokens: 42_000
        })

      # Verify the HTTP request body contains our max_tokens
      assert_receive {:request_body, body}, 30_000

      # After fix: our specific max_tokens value (42000) should appear in request
      # ReqLLM may use "max_tokens" or "max_completion_tokens" depending on model
      actual_max = Map.get(body, "max_tokens") || Map.get(body, "max_completion_tokens")

      assert actual_max == 42_000,
             "Our dynamic max_tokens (42000) should reach the HTTP request, " <>
               "got: #{inspect(actual_max)}"
    end
  end
end
