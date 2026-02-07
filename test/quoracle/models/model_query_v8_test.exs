defmodule Quoracle.Models.ModelQueryV8Test do
  @moduledoc """
  Tests for ModelQuery v8.0 changes.
  WorkGroupID: fix-20251209-035351
  Packet 2: Query Layer

  ARC Verification Criteria:
  - R9: 429 Not Permanent - permanent_error?/1 returns false for 429
  - R10: RetryHelper Wraps Query - query_single_model uses RetryHelper
  - R11: Retry-After Respected - uses Retry-After header value
  - R12: Infinite Retries for 429/5xx - no max_retries limit
  - R13: 5xx Also Retried - retries 5xx errors with backoff

  These tests verify that 429 rate limit errors are properly retried
  instead of being treated as permanent failures.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Models.{ModelQuery, TableCredentials}

  @test_model_id "test_retry_model"
  @test_model_spec "openai:gpt-4o-mini"

  # Helper to create test credential
  defp create_test_credential(model_id, model_spec) do
    {:ok, credential} =
      TableCredentials.insert(%{
        model_id: model_id,
        model_spec: model_spec,
        api_key: "test-api-key-#{model_id}"
      })

    credential
  end

  # Helper to build a plug that returns 429 rate limit error
  defp rate_limit_plug(retry_after \\ nil) do
    fn conn ->
      response = %{
        "error" => %{
          "message" => "Rate limit exceeded",
          "type" => "rate_limit_error",
          "code" => "rate_limit_exceeded"
        }
      }

      conn = Plug.Conn.put_resp_content_type(conn, "application/json")

      conn =
        if retry_after do
          Plug.Conn.put_resp_header(conn, "retry-after", to_string(retry_after))
        else
          conn
        end

      Plug.Conn.send_resp(conn, 429, Jason.encode!(response))
    end
  end

  # Helper to build a plug that returns 5xx server error
  defp server_error_plug(status) do
    fn conn ->
      response = %{
        "error" => %{
          "message" => "Service temporarily unavailable",
          "type" => "server_error"
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(response))
    end
  end

  # Helper to build a success response plug (Responses API format)
  defp success_plug(content) do
    fn conn ->
      response = %{
        "id" => "resp-#{System.unique_integer([:positive])}",
        "object" => "response",
        "model" => "gpt-4o-mini",
        "status" => "completed",
        "output" => [
          %{"type" => "output_text", "text" => content}
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  describe "R9: 429 Not Permanent" do
    test "permanent_error?/1 returns false for 429 status", %{sandbox_owner: _sandbox_owner} do
      # Create a 429 error struct matching ReqLLM.Error.API.Request format
      error_429 = %ReqLLM.Error.API.Request{
        status: 429,
        reason: "Rate limited",
        response_body: %{}
      }

      # In v8.0, 429 should NOT be permanent (it's transient, should retry)
      # Currently this FAILS because v7.x treats 429 as permanent
      refute ModelQuery.permanent_error?(error_429),
             "429 should NOT be a permanent error - it should be retried"
    end

    test "permanent_error?/1 returns true for 401 (authentication)", %{sandbox_owner: _} do
      # 401 is truly permanent - wrong API key
      error_401 = %ReqLLM.Error.API.Request{
        status: 401,
        reason: "Unauthorized",
        response_body: %{}
      }

      assert ModelQuery.permanent_error?(error_401),
             "401 should be a permanent error - no point retrying"
    end

    test "permanent_error?/1 returns true for 403 (forbidden)", %{sandbox_owner: _} do
      # 403 is truly permanent - access denied
      error_403 = %ReqLLM.Error.API.Request{
        status: 403,
        reason: "Forbidden",
        response_body: %{}
      }

      assert ModelQuery.permanent_error?(error_403),
             "403 should be a permanent error - no point retrying"
    end

    test "429 error does not cause :all_models_unavailable", %{sandbox_owner: sandbox_owner} do
      unique = System.unique_integer([:positive])
      model_id = "#{@test_model_id}_#{unique}"
      _credential = create_test_credential(model_id, @test_model_spec)

      # Track retry attempts
      attempts = :atomics.new(1, signed: false)

      # Plug that fails with 429 twice, then succeeds
      plug = fn conn ->
        count = :atomics.add_get(attempts, 1, 1)

        if count < 3 do
          response = %{
            "error" => %{
              "message" => "Rate limit exceeded",
              "type" => "rate_limit_error"
            }
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(429, Jason.encode!(response))
        else
          response = %{
            "id" => "resp-success",
            "object" => "response",
            "model" => "gpt-4o-mini",
            "status" => "completed",
            "output" => [
              %{"type" => "output_text", "text" => "Finally!"}
            ],
            "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(response))
        end
      end

      messages = [%{role: "user", content: "Hello"}]

      # In v8.0, this should retry and eventually succeed
      # In v7.x, it returns :all_models_unavailable because 429 is "permanent"
      result =
        ModelQuery.query_models(messages, [model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug,
          delay_fn: fn _ms -> :ok end
        })

      # Should succeed after retry (not fail with :all_models_unavailable)
      assert {:ok, %{successful_responses: [response]}} = result
      assert ReqLLM.Response.text(response) == "Finally!"

      # Should have retried (made 3 attempts total)
      assert :atomics.get(attempts, 1) == 3
    end
  end

  describe "R10: RetryHelper Wraps Query" do
    test "query_single_model retries on 429 error", %{sandbox_owner: sandbox_owner} do
      unique = System.unique_integer([:positive])
      model_id = "#{@test_model_id}_retry_#{unique}"
      _credential = create_test_credential(model_id, @test_model_spec)

      # Track how many times the API is called
      attempts = :atomics.new(1, signed: false)

      # Plug that fails twice with 429, then succeeds
      plug = fn conn ->
        count = :atomics.add_get(attempts, 1, 1)

        if count < 3 do
          rate_limit_plug().(conn)
        else
          success_plug("Retry success").(conn)
        end
      end

      messages = [%{role: "user", content: "Hello"}]

      result =
        ModelQuery.query_models(messages, [model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug,
          delay_fn: fn _ms -> :ok end
        })

      # Should succeed after retries
      assert {:ok, %{successful_responses: [response]}} = result
      assert ReqLLM.Response.text(response) == "Retry success"

      # Verify retries happened (3 attempts total)
      assert :atomics.get(attempts, 1) == 3
    end
  end

  describe "R11: Retry-After Respected" do
    test "uses Retry-After header value when present", %{sandbox_owner: sandbox_owner} do
      unique = System.unique_integer([:positive])
      model_id = "#{@test_model_id}_retryafter_#{unique}"
      _credential = create_test_credential(model_id, @test_model_spec)

      # Track delay values to verify Retry-After is used
      {:ok, delay_values} = Agent.start_link(fn -> [] end)
      attempts = :atomics.new(1, signed: false)

      # Plug that returns 429 with Retry-After header
      plug = fn conn ->
        count = :atomics.add_get(attempts, 1, 1)

        if count < 2 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.put_resp_header("retry-after", "1")
          |> Plug.Conn.send_resp(
            429,
            Jason.encode!(%{"error" => %{"message" => "Rate limited"}})
          )
        else
          success_plug("After retry").(conn)
        end
      end

      messages = [%{role: "user", content: "Hello"}]

      result =
        ModelQuery.query_models(messages, [model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug,
          delay_fn: fn ms -> Agent.update(delay_values, fn list -> [ms | list] end) end
        })

      # Should succeed
      assert {:ok, %{successful_responses: [_response]}} = result

      # Check that Retry-After value was used (1 second = 1000ms)
      delays = Agent.get(delay_values, & &1) |> Enum.reverse()
      Agent.stop(delay_values)

      assert delays != []
      [first_delay | _] = delays
      # Retry-After: 1 second should result in 1000ms delay
      assert first_delay == 1000, "Expected Retry-After of 1000ms, got #{first_delay}ms"
    end
  end

  describe "R12: Infinite Retries for 429/5xx" do
    test "continues retrying 429 without max limit", %{sandbox_owner: sandbox_owner} do
      unique = System.unique_integer([:positive])
      model_id = "#{@test_model_id}_infinite_#{unique}"
      _credential = create_test_credential(model_id, @test_model_spec)

      # Retry many times (more than old max_retries: 3)
      target_attempts = 7
      attempts = :atomics.new(1, signed: false)

      plug = fn conn ->
        count = :atomics.add_get(attempts, 1, 1)

        if count < target_attempts do
          rate_limit_plug().(conn)
        else
          success_plug("Success after #{count} attempts").(conn)
        end
      end

      messages = [%{role: "user", content: "Hello"}]

      result =
        ModelQuery.query_models(messages, [model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug,
          delay_fn: fn _ms -> :ok end
        })

      # Should succeed after many retries (no max_retries limit)
      assert {:ok, %{successful_responses: [response]}} = result
      assert ReqLLM.Response.text(response) =~ "Success after"

      # Verify we actually made that many attempts
      assert :atomics.get(attempts, 1) == target_attempts
    end
  end

  describe "R13: 5xx Also Retried" do
    test "retries 503 Service Unavailable with backoff", %{sandbox_owner: sandbox_owner} do
      unique = System.unique_integer([:positive])
      model_id = "#{@test_model_id}_5xx_#{unique}"
      _credential = create_test_credential(model_id, @test_model_spec)

      attempts = :atomics.new(1, signed: false)

      plug = fn conn ->
        count = :atomics.add_get(attempts, 1, 1)

        if count < 3 do
          server_error_plug(503).(conn)
        else
          success_plug("Recovered from 503").(conn)
        end
      end

      messages = [%{role: "user", content: "Hello"}]

      result =
        ModelQuery.query_models(messages, [model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug,
          delay_fn: fn _ms -> :ok end
        })

      # Should succeed after retrying 503
      assert {:ok, %{successful_responses: [response]}} = result
      assert ReqLLM.Response.text(response) == "Recovered from 503"
      assert :atomics.get(attempts, 1) == 3
    end

    test "retries all 5xx status codes", %{sandbox_owner: sandbox_owner} do
      for status <- [500, 502, 503, 504] do
        unique = System.unique_integer([:positive])
        model_id = "#{@test_model_id}_status#{status}_#{unique}"
        _credential = create_test_credential(model_id, @test_model_spec)

        attempts = :atomics.new(1, signed: false)

        plug = fn conn ->
          count = :atomics.add_get(attempts, 1, 1)

          if count < 2 do
            server_error_plug(status).(conn)
          else
            success_plug("Recovered from #{status}").(conn)
          end
        end

        messages = [%{role: "user", content: "Hello"}]

        result =
          ModelQuery.query_models(messages, [model_id], %{
            sandbox_owner: sandbox_owner,
            execution_mode: :sequential,
            plug: plug,
            delay_fn: fn _ms -> :ok end
          })

        # Should succeed after retry
        assert {:ok, %{successful_responses: [response]}} = result,
               "Should retry and recover from #{status} error"

        assert ReqLLM.Response.text(response) == "Recovered from #{status}"
      end
    end

    test "5xx errors use exponential backoff", %{sandbox_owner: sandbox_owner} do
      unique = System.unique_integer([:positive])
      model_id = "#{@test_model_id}_backoff_#{unique}"
      _credential = create_test_credential(model_id, @test_model_spec)

      # Track delay values to verify exponential backoff
      {:ok, delay_values} = Agent.start_link(fn -> [] end)
      attempts = :atomics.new(1, signed: false)

      plug = fn conn ->
        count = :atomics.add_get(attempts, 1, 1)

        if count < 4 do
          server_error_plug(503).(conn)
        else
          success_plug("Backoff success").(conn)
        end
      end

      messages = [%{role: "user", content: "Hello"}]

      result =
        ModelQuery.query_models(messages, [model_id], %{
          sandbox_owner: sandbox_owner,
          execution_mode: :sequential,
          plug: plug,
          delay_fn: fn ms -> Agent.update(delay_values, fn list -> [ms | list] end) end
        })

      assert {:ok, _} = result

      delays = Agent.get(delay_values, & &1) |> Enum.reverse()
      Agent.stop(delay_values)

      # With 4 attempts, we should have 3 delays
      # Exponential backoff: delay1, delay2 >= delay1, delay3 >= delay2
      assert length(delays) >= 2, "Expected at least 2 delays for backoff verification"
      [delay1, delay2 | _] = delays

      # Second delay should be >= first delay (exponential)
      assert delay2 >= delay1,
             "Expected exponential backoff: delay2 (#{delay2}ms) >= delay1 (#{delay1}ms)"
    end
  end
end
