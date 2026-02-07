defmodule Quoracle.Actions.GenerateImagesTest do
  @moduledoc """
  Tests for ACTION_GenerateImages (parallel image generation action).
  Part of Packet 3: Action Integration.
  WorkGroupID: feat-20251229-052855

  Tests verify:
  - Parameter validation (prompt required, must be string)
  - Successful generation returns images array with model attribution
  - Error handling (no models configured, all models fail)
  - Optional source_image for editing mode
  - Cost recording integration

  All tests use mocked MODEL_ImageQuery - no real ReqLLM calls.
  """

  use Quoracle.DataCase, async: true

  import Ecto.Query

  alias Quoracle.Actions.GenerateImages
  alias Quoracle.Tasks.Task
  alias Quoracle.Repo

  # Test image data (1x1 transparent PNG)
  @test_image_binary <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1,
                       0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84,
                       120, 218, 99, 252, 207, 192, 0, 0, 0, 3, 0, 1, 0, 5, 254, 211, 196, 0, 0,
                       0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

  # Helper to build a plug that returns a successful image generation response
  # Uses plain function format (not {Req.Test, fn}) to work with Task.async_stream
  defp image_success_plug(image_data \\ @test_image_binary) do
    fn conn ->
      response = %{
        "created" => 1_234_567_890,
        "data" => [%{"b64_json" => Base.encode64(image_data)}]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  # Helper to build a plug that returns an error response
  defp error_plug(status, message) do
    fn conn ->
      response = %{"error" => %{"message" => message}}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(response))
    end
  end

  # Helper to build a capturing plug that sends request info to test process
  defp capturing_plug(test_pid, image_data \\ @test_image_binary) do
    fn conn ->
      send(test_pid, {:request_captured, conn.body_params})

      response = %{
        "created" => 1_234_567_890,
        "data" => [%{"b64_json" => Base.encode64(image_data)}]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  describe "[UNIT] parameter validation" do
    # R1: Prompt Required
    test "returns error when prompt is missing" do
      # [UNIT] - WHEN execute called IF prompt missing THEN returns {:error, :missing_required_param}
      result = GenerateImages.execute(%{}, "agent-123", [])
      assert {:error, :missing_required_param} = result
    end

    # R3: Empty Prompt Rejected
    test "returns error when prompt is empty string" do
      # [UNIT] - WHEN execute called IF prompt is empty string THEN returns {:error, :missing_required_param}
      result = GenerateImages.execute(%{prompt: ""}, "agent-123", [])
      assert {:error, :missing_required_param} = result
    end

    # R1: Prompt Required (nil case)
    test "returns error when prompt is nil" do
      # [UNIT] - WHEN execute called IF prompt is nil THEN returns {:error, :missing_required_param}
      result = GenerateImages.execute(%{prompt: nil}, "agent-123", [])
      assert {:error, :missing_required_param} = result
    end

    # R2: Prompt Must Be String
    test "returns error when prompt is not a string" do
      # [UNIT] - WHEN execute called IF prompt not string THEN returns {:error, :invalid_param_type}
      result = GenerateImages.execute(%{prompt: 123}, "agent-123", [])
      assert {:error, :invalid_param_type} = result

      result = GenerateImages.execute(%{prompt: %{}}, "agent-123", [])
      assert {:error, :invalid_param_type} = result

      result = GenerateImages.execute(%{prompt: [:list]}, "agent-123", [])
      assert {:error, :invalid_param_type} = result
    end
  end

  describe "[INTEGRATION] successful generation" do
    # R4: Returns Image Array
    test "returns array of generated images on success", %{sandbox_owner: sandbox_owner} do
      # [INTEGRATION] - WHEN generation succeeds THEN returns {:ok, %{images: [...]}} with array of results
      # Setup: Create credentials for test models
      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_image_model",
          model_spec: "openai:dall-e-3",
          api_key: "test-api-key"
        })

      # Configure image generation models (required for ImageQuery to find models)
      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["test_image_model"])

      # Use plain function plug (not {Req.Test, fn}) to work with Task.async_stream
      plug = image_success_plug()

      result =
        GenerateImages.execute(
          %{prompt: "A beautiful sunset"},
          "agent-123",
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      assert {:ok, response} = result
      assert response.action == "generate_images"
      assert is_list(response.images)
      assert response.images != []
    end

    # R5: Model Attribution
    test "each image result includes model attribution", %{sandbox_owner: sandbox_owner} do
      # [UNIT] - WHEN image generated THEN result includes model: model_spec field
      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_model_attr",
          model_spec: "openai:dall-e-3",
          api_key: "test-api-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["test_model_attr"])

      plug = image_success_plug()

      {:ok, response} =
        GenerateImages.execute(
          %{prompt: "Test prompt"},
          "agent-123",
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      [first_image | _] = response.images
      assert Map.has_key?(first_image, :model)
      assert is_binary(first_image.model)
    end

    # R6: Success Status
    test "successful images have status success", %{sandbox_owner: sandbox_owner} do
      # [UNIT] - WHEN image generated THEN result includes status: "success"
      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_model_status",
          model_spec: "openai:dall-e-3",
          api_key: "test-api-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["test_model_status"])

      plug = image_success_plug()

      {:ok, response} =
        GenerateImages.execute(
          %{prompt: "Test prompt"},
          "agent-123",
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      [first_image | _] = response.images
      assert first_image.status == "success"
    end
  end

  describe "[INTEGRATION] error handling" do
    # R8: No Models Configured
    test "returns error when no image models configured" do
      # [INTEGRATION] - WHEN no image models configured THEN returns {:error, :no_models_configured}
      # Don't create any credentials - simulate no models configured
      result =
        GenerateImages.execute(
          %{prompt: "Test prompt"},
          "agent-123",
          []
        )

      assert {:error, :no_models_configured} = result
    end

    # R9: All Models Fail
    test "returns error when all models fail", %{sandbox_owner: sandbox_owner} do
      # [INTEGRATION] - WHEN all models fail THEN returns {:error, :no_images_generated}
      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_model_fail",
          model_spec: "openai:dall-e-3",
          api_key: "test-api-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["test_model_fail"])

      # Plug returns error response
      plug = error_plug(500, "API Error")

      result =
        GenerateImages.execute(
          %{prompt: "Test prompt"},
          "agent-123",
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      assert {:error, :no_images_generated} = result
    end

    # R10: Partial Failure Format
    test "failed model results include error message", %{sandbox_owner: sandbox_owner} do
      # [INTEGRATION] - WHEN some models fail THEN failed results include status: "error" and error message
      # Create two models - one will succeed, one will fail
      {:ok, _cred1} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_model_partial_1",
          model_spec: "openai:dall-e-3",
          api_key: "test-api-key"
        })

      {:ok, _cred2} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_model_partial_2",
          model_spec: "openai:dall-e-2",
          api_key: "test-api-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models([
          "test_model_partial_1",
          "test_model_partial_2"
        ])

      # Plug that succeeds for dall-e-3 but fails for dall-e-2
      # Use plain function format to work with Task.async_stream
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        if String.contains?(body, "dall-e-3") do
          response = %{
            "created" => 1_234_567_890,
            "data" => [%{"b64_json" => Base.encode64(@test_image_binary)}]
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(response))
        else
          response = %{"error" => %{"message" => "Model unavailable"}}

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(500, Jason.encode!(response))
        end
      end

      {:ok, response} =
        GenerateImages.execute(
          %{prompt: "Test prompt"},
          "agent-123",
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      # Assert partial failure actually occurred (not conditional - must happen)
      success_results = Enum.filter(response.images, &(&1.status == "success"))
      error_results = Enum.filter(response.images, &(&1.status == "error"))

      assert success_results != [], "Expected at least one model to succeed"
      assert error_results != [], "Expected at least one model to fail"

      # Verify error result format
      [error_result | _] = error_results
      assert error_result.status == "error"
      assert Map.has_key?(error_result, :error)
    end
  end

  describe "[INTEGRATION] image editing" do
    # R11: Source Image Passed
    test "passes source image for editing mode", %{sandbox_owner: sandbox_owner} do
      # [INTEGRATION] - WHEN source_image in params THEN passes to ImageQuery for editing
      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_model_edit",
          model_spec: "openai:dall-e-3",
          api_key: "test-api-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["test_model_edit"])

      test_pid = self()
      source_image_b64 = Base.encode64(@test_image_binary)

      plug = capturing_plug(test_pid)

      result =
        GenerateImages.execute(
          %{prompt: "Edit this image", source_image: source_image_b64},
          "agent-123",
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      assert {:ok, _response} = result
    end

    # R12: Source Image Optional
    test "source image is optional", %{sandbox_owner: sandbox_owner} do
      # [UNIT] - WHEN no source_image THEN proceeds with text-only generation
      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_model_no_edit",
          model_spec: "openai:dall-e-3",
          api_key: "test-api-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["test_model_no_edit"])

      plug = image_success_plug()

      # No source_image - should work fine
      result =
        GenerateImages.execute(
          %{prompt: "Generate new image"},
          "agent-123",
          sandbox_owner: sandbox_owner,
          plug: plug
        )

      assert {:ok, response} = result
      assert response.action == "generate_images"
    end
  end

  describe "[INTEGRATION] cost recording" do
    # R13: Records Cost on Success
    test "records image generation cost on success", %{sandbox_owner: sandbox_owner} do
      # [INTEGRATION] - WHEN action succeeds with recording context THEN records cost via CostRecorder
      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_model_cost",
          model_spec: "openai:dall-e-3",
          api_key: "test-api-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["test_model_cost"])

      plug = image_success_plug()

      # Create isolated PubSub for cost recording
      pubsub_name = :"test_pubsub_cost_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      # Create real task (required by AgentCost FK constraint)
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      # Subscribe to cost events (CostRecorder broadcasts to "tasks:{task_id}:costs")
      Phoenix.PubSub.subscribe(pubsub_name, "tasks:#{task.id}:costs")

      # Execute with full recording context
      result =
        GenerateImages.execute(
          %{prompt: "Test prompt"},
          "agent-123",
          sandbox_owner: sandbox_owner,
          plug: plug,
          agent_id: "agent-123",
          task_id: task.id,
          pubsub: pubsub_name
        )

      assert {:ok, _response} = result

      # Should receive cost recording event
      assert_receive {:cost_recorded, cost_data}, 30_000
      assert cost_data.cost_type == "image_generation"
      assert cost_data.agent_id == "agent-123"
      assert cost_data.task_id == task.id
    end

    # R14: Skips Recording Without Context
    test "skips recording when context not provided", %{sandbox_owner: sandbox_owner} do
      # [INTEGRATION] - WHEN agent_id/task_id missing THEN does not record cost
      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_model_no_cost",
          model_spec: "openai:dall-e-3",
          api_key: "test-api-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["test_model_no_cost"])

      plug = image_success_plug()

      # Execute without task_id/pubsub - should succeed without recording
      result =
        GenerateImages.execute(
          %{prompt: "Test prompt"},
          "agent-123",
          sandbox_owner: sandbox_owner,
          plug: plug
          # Note: no task_id, no pubsub
        )

      # Should succeed even without cost recording context
      assert {:ok, _response} = result
    end

    # R15: Cost Metadata
    test "cost metadata includes model counts", %{sandbox_owner: sandbox_owner} do
      # [UNIT] - WHEN recording cost THEN includes models_queried, models_succeeded in metadata
      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_model_meta",
          model_spec: "openai:dall-e-3",
          api_key: "test-api-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["test_model_meta"])

      plug = image_success_plug()

      # Create isolated PubSub for cost recording
      pubsub_name = :"test_pubsub_meta_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      # Create real task (required by AgentCost FK constraint)
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      # Subscribe to cost events (CostRecorder broadcasts to "tasks:{task_id}:costs")
      Phoenix.PubSub.subscribe(pubsub_name, "tasks:#{task.id}:costs")

      # Execute with full recording context
      result =
        GenerateImages.execute(
          %{prompt: "Test prompt"},
          "agent-123",
          sandbox_owner: sandbox_owner,
          plug: plug,
          agent_id: "agent-123",
          task_id: task.id,
          pubsub: pubsub_name
        )

      assert {:ok, _response} = result

      # Should receive cost recording event
      assert_receive {:cost_recorded, _cost_data}, 30_000

      # Verify metadata in DB (CostRecorder.format_cost_event doesn't include full metadata)
      [cost_record] = Repo.all(Quoracle.Costs.AgentCost)
      assert Map.has_key?(cost_record.metadata, "models_queried")
      assert Map.has_key?(cost_record.metadata, "models_succeeded")
      assert is_integer(cost_record.metadata["models_queried"])
      assert is_integer(cost_record.metadata["models_succeeded"])
    end
  end

  # === v2.0 Per-Model Cost Records (fix-costs-20260129) ===

  describe "[INTEGRATION] per-model cost records (R18-R22)" do
    # R18: Per-Model Cost Records
    test "records one cost entry per successful model", %{sandbox_owner: sandbox_owner} do
      # Setup two image models
      {:ok, _} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "img_model_a",
          model_spec: "openai:dall-e-3",
          api_key: "test-key-a"
        })

      {:ok, _} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "img_model_b",
          model_spec: "openai:gpt-image-1",
          api_key: "test-key-b"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models([
          "img_model_a",
          "img_model_b"
        ])

      plug = image_success_plug()

      pubsub_name = :"test_pubsub_permodel_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      agent_id = "agent-permodel-#{System.unique_integer([:positive])}"

      {:ok, _response} =
        GenerateImages.execute(
          %{prompt: "Test prompt"},
          agent_id,
          sandbox_owner: sandbox_owner,
          plug: plug,
          agent_id: agent_id,
          task_id: task.id,
          pubsub: pubsub_name
        )

      # Should have one cost record per successful model (2 models)
      costs = Repo.all(from(c in Quoracle.Costs.AgentCost, where: c.agent_id == ^agent_id))
      assert length(costs) == 2
    end

    # R20: model_spec in Metadata
    test "cost metadata includes model_spec", %{sandbox_owner: sandbox_owner} do
      {:ok, _} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "img_model_spec",
          model_spec: "openai:dall-e-3",
          api_key: "test-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["img_model_spec"])

      plug = image_success_plug()

      pubsub_name = :"test_pubsub_modelspec_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      agent_id = "agent-modelspec-#{System.unique_integer([:positive])}"

      {:ok, _response} =
        GenerateImages.execute(
          %{prompt: "Test prompt"},
          agent_id,
          sandbox_owner: sandbox_owner,
          plug: plug,
          agent_id: agent_id,
          task_id: task.id,
          pubsub: pubsub_name
        )

      [cost] = Repo.all(from(c in Quoracle.Costs.AgentCost, where: c.agent_id == ^agent_id))
      assert cost.metadata["model_spec"] != nil
      assert is_binary(cost.metadata["model_spec"])
    end

    # R22: Failed Models Not Recorded
    test "does not record cost for failed models", %{sandbox_owner: sandbox_owner} do
      {:ok, _} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "img_model_fail",
          model_spec: "openai:dall-e-3",
          api_key: "test-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["img_model_fail"])

      # Use error plug — model fails
      plug = error_plug(500, "Internal error")

      pubsub_name = :"test_pubsub_fail_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      agent_id = "agent-fail-#{System.unique_integer([:positive])}"

      # Execute — will fail (all models error)
      _result =
        GenerateImages.execute(
          %{prompt: "Test prompt"},
          agent_id,
          sandbox_owner: sandbox_owner,
          plug: plug,
          agent_id: agent_id,
          task_id: task.id,
          pubsub: pubsub_name
        )

      # No cost records for failed models
      costs = Repo.all(from(c in Quoracle.Costs.AgentCost, where: c.agent_id == ^agent_id))
      assert costs == []
    end
  end

  # === v3.0 Image Cost Computation (fix-costs-20260129 audit fix) ===

  describe "[UNIT] image cost lookup (R30)" do
    # R30: compute_image_cost/1 looks up LLMDB model.cost.image
    test "compute_image_cost returns nil for model without LLMDB pricing" do
      # openai:dall-e-3 has cost: nil in LLMDB — no image pricing available
      result = GenerateImages.compute_image_cost("openai:dall-e-3")
      assert result == nil
    end
  end
end
