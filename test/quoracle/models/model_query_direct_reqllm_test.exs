defmodule Quoracle.Models.ModelQueryDirectReqLLMTest do
  @moduledoc """
  Tests for MODEL_Query direct ReqLLM integration (Packet 2).

  These tests verify the refactor to call ReqLLM directly with model_spec,
  eliminating the Provider abstraction layer.

  ARC Verification Criteria from MODEL_Query spec v6.0:
  - R1: Direct ReqLLM Call [UNIT]
  - R2: Credential Lookup [UNIT]
  - R3: Message Building [UNIT]
  - R4: Response Passthrough [UNIT]
  - R5: Error Passthrough [UNIT]
  - R6: Provider Options [UNIT]
  - R7: Parallel Execution [INTEGRATION]
  - R8: Partial Success [INTEGRATION]

  Uses stub plugs to mock HTTP responses (async-safe, no meck dependency).
  """

  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog

  alias Quoracle.Models.{ModelQuery, TableCredentials}

  # Test model_spec values - using real provider prefixes that exist in LLMDB
  @test_model_id "test_direct_reqllm"
  @test_model_spec "openai:gpt-4o-mini"
  @azure_model_id "test_azure_direct"
  @azure_model_spec "azure:gpt-4o"

  # Helper to create test credential with model_spec
  defp create_test_credential(model_id, model_spec, extra_fields \\ %{}) do
    base_attrs = %{
      model_id: model_id,
      model_spec: model_spec,
      api_key: "test-api-key-#{model_id}"
    }

    {:ok, credential} = TableCredentials.insert(Map.merge(base_attrs, extra_fields))
    credential
  end

  # Helper to build a stub plug that returns a successful Responses API response
  defp success_plug(content \\ "Test response") do
    fn conn ->
      response = %{
        "id" => "resp-#{System.unique_integer([:positive])}",
        "object" => "response",
        "model" => "gpt-4o-mini",
        "status" => "completed",
        "output" => [
          %{"type" => "output_text", "text" => content}
        ],
        "usage" => %{
          "input_tokens" => 50,
          "output_tokens" => 100
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  # Helper to build a stub plug that returns an error response
  defp error_plug(status, message) do
    fn conn ->
      response = %{
        "error" => %{
          "message" => message,
          "type" => "api_error",
          "code" => to_string(status)
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(response))
    end
  end

  # Helper to build a plug that captures request details and sends them to test process
  defp capturing_plug(test_pid, content \\ "Test response") do
    fn conn ->
      # Read and parse the request body
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body_json = Jason.decode!(body)

      # Send captured details to test process
      send(
        test_pid,
        {:request_captured,
         %{
           method: conn.method,
           path: conn.request_path,
           headers: conn.req_headers,
           body: body_json
         }}
      )

      # Return success response (Responses API format)
      response = %{
        "id" => "resp-#{System.unique_integer([:positive])}",
        "object" => "response",
        "model" => "gpt-4o-mini",
        "status" => "completed",
        "output" => [
          %{"type" => "output_text", "text" => content}
        ],
        "usage" => %{
          "input_tokens" => 50,
          "output_tokens" => 100
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  describe "R1: Direct ReqLLM Call [UNIT]" do
    test "calls ReqLLM with credential.model_spec", %{sandbox_owner: sandbox_owner} do
      _credential = create_test_credential(@test_model_id, @test_model_spec)
      plug = success_plug()

      messages = [%{role: "user", content: "Hello"}]

      {:ok, result} =
        ModelQuery.query_models(messages, [@test_model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug
        })

      # Verify we got a successful response (proves ReqLLM was called with correct model_spec)
      assert %{successful_responses: [response]} = result
      assert %ReqLLM.Response{} = response
    end
  end

  describe "R2: Credential Lookup [UNIT]" do
    test "fetches credential via CredentialManager.get_credentials", %{
      sandbox_owner: sandbox_owner
    } do
      _credential = create_test_credential(@test_model_id, @test_model_spec)
      plug = success_plug()

      messages = [%{role: "user", content: "Hello"}]

      {:ok, result} =
        ModelQuery.query_models(messages, [@test_model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug
        })

      # Verify credential was used (response is ReqLLM.Response struct)
      assert %{successful_responses: [response]} = result
      assert %ReqLLM.Response{} = response
      assert response.model != nil
    end
  end

  describe "R3: Message Building [UNIT]" do
    test "builds messages with correct roles in request body", %{sandbox_owner: sandbox_owner} do
      _credential = create_test_credential(@test_model_id, @test_model_spec)
      test_pid = self()
      plug = capturing_plug(test_pid)

      # Send multi-role messages
      messages = [
        %{role: "system", content: "You are helpful"},
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there"},
        %{role: "user", content: "How are you?"}
      ]

      {:ok, _result} =
        ModelQuery.query_models(messages, [@test_model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug
        })

      # Verify messages were sent in the request body (Responses API uses "input")
      assert_receive {:request_captured, %{body: body}}, 30_000
      assert Map.has_key?(body, "input")
      req_input = body["input"]
      assert length(req_input) == 4

      # Verify roles are correct
      roles = Enum.map(req_input, & &1["role"])
      assert roles == ["system", "user", "assistant", "user"]
    end
  end

  describe "R4: Response Passthrough [UNIT]" do
    test "returns ReqLLM.Response with expected content", %{sandbox_owner: sandbox_owner} do
      _credential = create_test_credential(@test_model_id, @test_model_spec)
      plug = success_plug("Exact response content")

      messages = [%{role: "user", content: "Hello"}]

      {:ok, result} =
        ModelQuery.query_models(messages, [@test_model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug
        })

      # Verify the ReqLLM.Response struct contains expected data
      assert %{successful_responses: [response]} = result
      assert %ReqLLM.Response{} = response
      assert ReqLLM.Response.text(response) == "Exact response content"
      assert response.usage.input_tokens == 50
      assert response.usage.output_tokens == 100
    end
  end

  describe "R5: Error Passthrough [UNIT]" do
    test "returns error for failed API calls", %{sandbox_owner: sandbox_owner} do
      unique = System.unique_integer([:positive])
      success_model = "error_test_success_#{unique}"
      fail_model = "error_test_fail_#{unique}"
      _cred_success = create_test_credential(success_model, @test_model_spec)
      _cred_fail = create_test_credential(fail_model, @test_model_spec)

      # Use 401 (permanent error) to test error passthrough without triggering retries
      # v8.0: 429/5xx are now retried infinitely, so we use permanent errors for this test
      # Need one success to avoid :all_models_unavailable
      call_count = :atomics.new(1, signed: false)

      plug = fn conn ->
        count = :atomics.add_get(call_count, 1, 1)

        if count == 1 do
          # First call succeeds
          success_plug("Success").(conn)
        else
          # Second call fails with permanent error
          error_plug(401, "Authentication failed").(conn)
        end
      end

      messages = [%{role: "user", content: "Hello"}]

      # Capture log to prevent 401 error log spam in test output
      capture_log(fn ->
        {:ok, result} =
          ModelQuery.query_models(messages, [success_model, fail_model], %{
            sandbox_owner: sandbox_owner,
            execution_mode: :sequential,
            plug: plug
          })

        # Verify error is captured alongside success
        # RetryHelper converts 401 to :authentication_failed atom
        assert %{
                 failed_models: [{^fail_model, :authentication_failed}],
                 successful_responses: [_]
               } =
                 result
      end)
    end
  end

  describe "R6: Provider Options [UNIT]" do
    test "includes api_key in authorization header", %{sandbox_owner: sandbox_owner} do
      credential = create_test_credential(@test_model_id, @test_model_spec)
      test_pid = self()
      plug = capturing_plug(test_pid)

      messages = [%{role: "user", content: "Hello"}]

      {:ok, _result} =
        ModelQuery.query_models(messages, [@test_model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug
        })

      assert_receive {:request_captured, %{headers: headers}}, 30_000
      # API key should be in authorization header
      auth_header = List.keyfind(headers, "authorization", 0)
      assert auth_header != nil
      {_, auth_value} = auth_header
      assert String.contains?(auth_value, credential.api_key)
    end

    test "includes Azure-specific options for azure provider", %{sandbox_owner: sandbox_owner} do
      _credential =
        create_test_credential(@azure_model_id, @azure_model_spec, %{
          deployment_id: "gpt-4o-deployment",
          resource_id: "my-azure-resource",
          endpoint_url: "https://my-azure-resource.openai.azure.com"
        })

      test_pid = self()
      plug = capturing_plug(test_pid)

      messages = [%{role: "user", content: "Hello"}]

      {:ok, _result} =
        ModelQuery.query_models(messages, [@azure_model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug
        })

      assert_receive {:request_captured, %{headers: headers}}, 30_000
      # Azure uses api-key header instead of Authorization Bearer
      api_key_header = List.keyfind(headers, "api-key", 0)
      assert api_key_header != nil
    end
  end

  describe "R7: Parallel Execution [INTEGRATION]" do
    test "queries multiple models in parallel", %{sandbox_owner: sandbox_owner} do
      # Create multiple test credentials with unique IDs
      unique = System.unique_integer([:positive])
      _cred1 = create_test_credential("model_parallel_1_#{unique}", @test_model_spec)
      _cred2 = create_test_credential("model_parallel_2_#{unique}", @test_model_spec)
      _cred3 = create_test_credential("model_parallel_3_#{unique}", @test_model_spec)

      plug = success_plug("Parallel response")

      messages = [%{role: "user", content: "Hello"}]

      model_ids = [
        "model_parallel_1_#{unique}",
        "model_parallel_2_#{unique}",
        "model_parallel_3_#{unique}"
      ]

      {:ok, result} =
        ModelQuery.query_models(messages, model_ids, %{
          sandbox_owner: sandbox_owner,
          plug: plug
          # Default is parallel execution
        })

      # All three should succeed
      assert %{successful_responses: responses} = result
      assert length(responses) == 3
    end
  end

  describe "R8: Partial Success [INTEGRATION]" do
    test "returns partial results on mixed success/failure", %{sandbox_owner: sandbox_owner} do
      # Create two test credentials with unique IDs
      unique = System.unique_integer([:positive])
      _cred_success = create_test_credential("model_success_#{unique}", @test_model_spec)
      _cred_fail = create_test_credential("model_fail_#{unique}", @test_model_spec)

      # Plug that succeeds or fails based on a counter
      call_count = :atomics.new(1, signed: false)

      plug = fn conn ->
        count = :atomics.add_get(call_count, 1, 1)

        if count == 1 do
          # First call succeeds (Responses API format)
          response = %{
            "id" => "resp-success",
            "object" => "response",
            "model" => "gpt-4o-mini",
            "status" => "completed",
            "output" => [
              %{"type" => "output_text", "text" => "Success"}
            ],
            "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(response))
        else
          # Second call fails with permanent error (401)
          # v8.0: 429/5xx are retried infinitely, use permanent error for partial failure test
          response = %{
            "error" => %{"message" => "Auth failed", "type" => "api_error", "code" => "401"}
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(401, Jason.encode!(response))
        end
      end

      messages = [%{role: "user", content: "Hello"}]

      # Capture log to prevent 401 error log spam in test output
      capture_log(fn ->
        {:ok, result} =
          ModelQuery.query_models(
            messages,
            ["model_success_#{unique}", "model_fail_#{unique}"],
            %{
              sandbox_owner: sandbox_owner,
              execution_mode: :sequential,
              plug: plug
            }
          )

        # Should have one success and one failure
        assert %{successful_responses: successes, failed_models: failures} = result
        assert length(successes) == 1
        assert length(failures) == 1

        # Verify success contains ReqLLM.Response
        [success_response] = successes
        assert %ReqLLM.Response{} = success_response

        # Verify failure contains model_id and error
        # RetryHelper converts 401 to :authentication_failed atom
        [{_model_id, :authentication_failed}] = failures
      end)
    end

    test "returns error tuple when all models fail with permanent errors", %{
      sandbox_owner: sandbox_owner
    } do
      unique = System.unique_integer([:positive])
      _cred1 = create_test_credential("perm_fail_1_#{unique}", @test_model_spec)
      _cred2 = create_test_credential("perm_fail_2_#{unique}", @test_model_spec)

      plug = error_plug(401, "Authentication failed")

      messages = [%{role: "user", content: "Hello"}]

      # Capture log to prevent 401 error log spam in test output
      capture_log(fn ->
        result =
          ModelQuery.query_models(messages, ["perm_fail_1_#{unique}", "perm_fail_2_#{unique}"], %{
            sandbox_owner: sandbox_owner,
            execution_mode: :sequential,
            plug: plug
          })

        # When all fail with permanent errors, returns :all_models_unavailable
        assert {:error, :all_models_unavailable} = result
      end)
    end
  end

  describe "Usage Aggregation with ReqLLM.Response" do
    test "calculates aggregate usage from ReqLLM.Response structs", %{
      sandbox_owner: sandbox_owner
    } do
      unique = System.unique_integer([:positive])
      _cred1 = create_test_credential("usage_model_1_#{unique}", @test_model_spec)
      _cred2 = create_test_credential("usage_model_2_#{unique}", @test_model_spec)

      # Plug that returns different usage for each call
      call_count = :atomics.new(1, signed: false)

      plug = fn conn ->
        count = :atomics.add_get(call_count, 1, 1)

        usage =
          if count == 1 do
            %{"input_tokens" => 100, "output_tokens" => 200}
          else
            %{"input_tokens" => 150, "output_tokens" => 250}
          end

        response = %{
          "id" => "resp-#{count}",
          "object" => "response",
          "model" => "gpt-4o-mini",
          "status" => "completed",
          "output" => [
            %{"type" => "output_text", "text" => "Test"}
          ],
          "usage" => usage
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      messages = [%{role: "user", content: "Hello"}]

      {:ok, result} =
        ModelQuery.query_models(
          messages,
          ["usage_model_1_#{unique}", "usage_model_2_#{unique}"],
          %{
            sandbox_owner: sandbox_owner,
            execution_mode: :sequential,
            plug: plug
          }
        )

      # Aggregate usage should sum up
      assert %{aggregate_usage: usage} = result
      # 100 + 150
      assert usage.input_tokens == 250
      # 200 + 250
      assert usage.output_tokens == 450
    end
  end
end
