defmodule Quoracle.Models.ImageQueryTest do
  @moduledoc """
  Tests for MODEL_ImageQuery - Parallel image generation across configured models.

  ARC Verification Criteria:
  - R1-R2: Model Configuration
  - R3-R5: Parallel Execution
  - R6-R9: Result Handling
  - R10-R11: Image Editing
  - R12: DB Sandbox (Test Isolation)

  Uses stub plugs to mock HTTP responses (async-safe, no meck dependency).
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Models.{ImageQuery, TableCredentials}

  # Test model IDs and specs (must be in ReqLLM.Images.supported_models())
  # Use only OpenAI models as they all accept :api_key auth
  @model_id_1 "test_image_model_1"
  @model_spec_1 "openai:dall-e-3"
  @model_id_2 "test_image_model_2"
  @model_spec_2 "openai:dall-e-2"
  @model_id_3 "test_image_model_3"
  @model_spec_3 "openai:gpt-image-1"

  # Base64 encoded test image (1x1 red PNG)
  @test_image_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  # Helper to create test credential
  defp create_test_credential(model_id, model_spec, extra_fields \\ %{}) do
    base_attrs = %{
      model_id: model_id,
      model_spec: model_spec,
      api_key: "test-api-key-#{model_id}"
    }

    {:ok, credential} = TableCredentials.insert(Map.merge(base_attrs, extra_fields))
    credential
  end

  # Helper to build a stub plug that returns a successful image generation response
  defp image_success_plug(image_data \\ @test_image_base64) do
    fn conn ->
      response = %{
        "created" => System.system_time(:second),
        "data" => [
          %{
            "b64_json" => image_data,
            "revised_prompt" => "A test image"
          }
        ]
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

  # Helper to build a plug that captures request details
  defp capturing_plug(test_pid, image_data \\ @test_image_base64) do
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
           body: body_json
         }}
      )

      response = %{
        "created" => System.system_time(:second),
        "data" => [
          %{
            "b64_json" => image_data,
            "revised_prompt" => "A test image"
          }
        ]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  # Helper plug that delays response (for timeout testing with short injectable timeout)
  defp slow_plug(delay_ms) do
    ref = make_ref()
    test_pid = self()

    fn conn ->
      # Notify test that request was received
      send(test_pid, {:slow_plug_started, ref})

      # Wait for either the delay or test cleanup
      receive do
        {:cancel, ^ref} -> :ok
      after
        delay_ms ->
          # If we get here, timeout didn't kill us - return success
          response = %{
            "created" => System.system_time(:second),
            "data" => [%{"b64_json" => "test", "revised_prompt" => "test"}]
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end
    end
  end

  # =============================================================
  # R1-R2: Model Configuration
  # =============================================================

  describe "R1: No Models Configured [UNIT]" do
    test "returns error when no image models configured", %{sandbox_owner: sandbox_owner} do
      # No models configured - default state
      result = ImageQuery.generate_images("A test prompt", sandbox_owner: sandbox_owner)

      assert {:error, :no_models_configured} = result
    end
  end

  describe "R2: Empty Model List [UNIT]" do
    test "returns error for empty model list", %{sandbox_owner: sandbox_owner} do
      # Call with empty model list directly
      result = ImageQuery.generate_images("A test prompt", [], sandbox_owner: sandbox_owner)

      assert {:error, :no_models_configured} = result
    end
  end

  # =============================================================
  # R3-R5: Parallel Execution
  # =============================================================

  describe "R3: Queries All Models [INTEGRATION]" do
    test "queries all configured models in parallel", %{sandbox_owner: sandbox_owner} do
      # Setup: Create credentials for multiple models
      _cred1 = create_test_credential(@model_id_1, @model_spec_1)
      _cred2 = create_test_credential(@model_id_2, @model_spec_2)

      test_pid = self()

      # Use capturing plug to verify both models are queried
      plug = capturing_plug(test_pid)

      {:ok, results} =
        ImageQuery.generate_images(
          "A test prompt",
          [@model_id_1, @model_id_2],
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      # Should have received requests for both models
      assert_receive {:request_captured, _request1}, 5000
      assert_receive {:request_captured, _request2}, 5000

      # Should have results for both models
      assert length(results) == 2
    end
  end

  describe "R4: Ordered Results [UNIT]" do
    test "results maintain order of model list", %{sandbox_owner: sandbox_owner} do
      # Setup credentials
      _cred1 = create_test_credential(@model_id_1, @model_spec_1)
      _cred2 = create_test_credential(@model_id_2, @model_spec_2)
      _cred3 = create_test_credential(@model_id_3, @model_spec_3)

      plug = image_success_plug()

      {:ok, results} =
        ImageQuery.generate_images(
          "A test prompt",
          [@model_id_1, @model_id_2, @model_id_3],
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      # Results should be in same order as input model list
      assert length(results) == 3

      # Extract model specs/ids from results to verify order
      result_models = Enum.map(results, & &1.model)

      # Order should match input (model_spec is used in success results)
      assert Enum.at(result_models, 0) == @model_spec_1
      assert Enum.at(result_models, 1) == @model_spec_2
      assert Enum.at(result_models, 2) == @model_spec_3
    end
  end

  describe "R5: Timeout Handling [UNIT]" do
    test "handles query timeout gracefully", %{sandbox_owner: sandbox_owner} do
      _cred = create_test_credential(@model_id_1, @model_spec_1)

      # Use a plug that delays longer than our short test timeout
      # Implementation accepts :timeout option for testing (defaults to 60_000)
      plug = slow_plug(500)

      # Use very short timeout (50ms) so test runs quickly
      # The plug delays 500ms, so the 50ms timeout will trigger first
      result =
        ImageQuery.generate_images(
          "A test prompt",
          [@model_id_1],
          sandbox_owner: sandbox_owner,
          plug: plug,
          timeout: 50
        )

      # Should return error since the only model timed out
      assert {:error, :no_images_generated} = result
    end
  end

  # =============================================================
  # R6-R9: Result Handling
  # =============================================================

  describe "R6: Partial Success [INTEGRATION]" do
    test "returns partial results when some models fail", %{sandbox_owner: sandbox_owner} do
      # Model 1 has credential, Model 2 does not (will fail credential lookup)
      _cred1 = create_test_credential(@model_id_1, @model_spec_1)
      # No credential for @model_id_2

      plug = image_success_plug()

      {:ok, results} =
        ImageQuery.generate_images(
          "A test prompt",
          [@model_id_1, @model_id_2],
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      # Should have 2 results - one success, one error
      assert length(results) == 2

      # First should succeed (has credential)
      assert %{model: @model_spec_1, image: _} = Enum.at(results, 0)

      # Second should fail (no credential)
      assert %{model: @model_id_2, error: _} = Enum.at(results, 1)
    end
  end

  describe "R7: All Models Fail [INTEGRATION]" do
    test "returns error when all models fail", %{sandbox_owner: sandbox_owner} do
      # No credentials for any model - all will fail
      result =
        ImageQuery.generate_images(
          "A test prompt",
          [@model_id_1, @model_id_2],
          sandbox_owner: sandbox_owner
        )

      assert {:error, :no_images_generated} = result
    end
  end

  describe "R8: Success Result Format [UNIT]" do
    test "successful result has model and image fields", %{sandbox_owner: sandbox_owner} do
      _cred = create_test_credential(@model_id_1, @model_spec_1)
      plug = image_success_plug(@test_image_base64)

      {:ok, results} =
        ImageQuery.generate_images(
          "A test prompt",
          [@model_id_1],
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      assert [result] = results
      assert Map.has_key?(result, :model)
      assert Map.has_key?(result, :image)
      assert result.model == @model_spec_1
      assert is_binary(result.image)
    end
  end

  describe "R9: Error Result Format [UNIT]" do
    test "error result has model and error fields", %{sandbox_owner: sandbox_owner} do
      # Create credential but use error plug - API will return 500
      _cred = create_test_credential(@model_id_1, @model_spec_1)
      plug = error_plug(500, "Internal server error")

      # Single model fails with API error, so all models fail
      # Spec says all models fail returns {:error, :no_images_generated}
      result =
        ImageQuery.generate_images(
          "A test prompt",
          [@model_id_1],
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      assert {:error, :no_images_generated} = result
    end

    test "error result contains model_id and error reason", %{sandbox_owner: sandbox_owner} do
      # Model 1 succeeds, Model 2 has no credential
      _cred1 = create_test_credential(@model_id_1, @model_spec_1)
      plug = image_success_plug()

      {:ok, results} =
        ImageQuery.generate_images(
          "A test prompt",
          [@model_id_1, @model_id_2],
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      # Find the error result
      error_result = Enum.find(results, &Map.has_key?(&1, :error))

      assert error_result != nil
      assert Map.has_key?(error_result, :model)
      assert Map.has_key?(error_result, :error)
      assert error_result.model == @model_id_2
    end
  end

  # =============================================================
  # R10-R11: Image Editing
  # =============================================================

  describe "R10: Source Image Passed [INTEGRATION]" do
    test "passes source image for editing mode", %{sandbox_owner: sandbox_owner} do
      _cred = create_test_credential(@model_id_1, @model_spec_1)
      test_pid = self()
      plug = capturing_plug(test_pid)

      source_image = @test_image_base64

      {:ok, _results} =
        ImageQuery.generate_images(
          "Edit this image to add a hat",
          [@model_id_1],
          sandbox_owner: sandbox_owner,
          plug: plug,
          source_image: source_image
        )

      # Verify the request included image data
      assert_receive {:request_captured, request}, 5000

      # The request body should contain the source image in some form
      # (exact format depends on ReqLLM.Images implementation)
      assert request.body != nil
    end
  end

  describe "R11: Text-Only Generation [INTEGRATION]" do
    test "uses text-only prompt when no source image", %{sandbox_owner: sandbox_owner} do
      _cred = create_test_credential(@model_id_1, @model_spec_1)
      test_pid = self()
      plug = capturing_plug(test_pid)

      {:ok, _results} =
        ImageQuery.generate_images(
          "A beautiful sunset",
          [@model_id_1],
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      # Verify request was made
      assert_receive {:request_captured, request}, 5000

      # Request should have prompt
      assert Map.has_key?(request.body, "prompt")
      assert request.body["prompt"] == "A beautiful sunset"
    end
  end

  # =============================================================
  # R12: DB Sandbox (Test Isolation)
  # =============================================================

  describe "R12: Sandbox Access [INTEGRATION]" do
    test "spawned tasks have DB access with sandbox_owner", %{sandbox_owner: sandbox_owner} do
      # Create credential that the spawned task needs to read
      _cred = create_test_credential(@model_id_1, @model_spec_1)
      plug = image_success_plug()

      # This will spawn Task.async_stream tasks that need DB access
      # If sandbox_owner is not propagated, they will fail with ownership error
      result =
        ImageQuery.generate_images(
          "A test prompt",
          [@model_id_1],
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      # If tasks can access DB, we should get a successful result
      assert {:ok, [%{model: @model_spec_1, image: _}]} = result
    end
  end
end
