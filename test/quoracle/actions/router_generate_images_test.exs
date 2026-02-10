defmodule Quoracle.Actions.RouterGenerateImagesTest do
  @moduledoc """
  Tests for ACTION_Router generate_images routing (v20.0).
  Part of Packet 3: Action Integration.
  WorkGroupID: feat-20251229-052855

  Tests Router's ability to:
  - Route generate_images action to GenerateImages module
  - Allow access to any agent with appropriate profile
  - Execute successfully with mocked MODEL_ImageQuery
  """

  use Quoracle.DataCase, async: true
  alias Quoracle.Actions.Router

  # Test image data (1x1 transparent PNG)
  @test_image_binary <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1,
                       0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84,
                       120, 218, 99, 252, 207, 192, 0, 0, 0, 3, 0, 1, 0, 5, 254, 211, 196, 0, 0,
                       0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

  # Helper to build a plug that returns a successful image generation response
  # Uses plain function format (not {Req.Test, fn}) to work with Task.async_stream
  defp image_success_plug do
    fn conn ->
      response = %{
        "created" => 1_234_567_890,
        "data" => [%{"b64_json" => Base.encode64(@test_image_binary)}]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated PubSub and Registry
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0)
    {:ok, router_pid} =
      Router.start_link(
        action_type: :generate_images,
        action_id: "action-#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub_name,
        sandbox_owner: sandbox_owner
      )

    on_exit(fn ->
      if Process.alive?(router_pid) do
        try do
          GenServer.stop(router_pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{
      router: router_pid,
      pubsub: pubsub_name,
      registry: registry_name,
      agent_id: agent_id,
      sandbox_owner: sandbox_owner
    }
  end

  describe "generate_images routing (v20.0)" do
    # R3: No Access Control for generate_images
    test "generate_images accessible to all agents", %{
      pubsub: pubsub,
      registry: registry,
      agent_id: agent_id,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN execute called for generate_images THEN proceeds normally
      config = %{
        agent_id: agent_id
      }

      Registry.register(registry, {:agent, agent_id}, config)

      # Create test credential and configure model settings
      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_router_model",
          model_spec: "openai:dall-e-3",
          api_key: "test-api-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["test_router_model"])

      # Use plain function plug (not {Req.Test, fn}) to work with Task.async_stream
      plug = image_success_plug()

      action_id = "action-123"

      # Per-action Router (v28.0): spawn dedicated Router for this action
      {:ok, router} =
        Router.start_link(
          action_type: :generate_images,
          action_id: action_id,
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      opts = [
        registry: registry,
        action_id: action_id,
        sandbox_owner: sandbox_owner,
        plug: plug,
        agent_pid: self()
      ]

      params = %{"prompt" => "A beautiful landscape"}

      # Subscribe to action events for async result notification
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      # Should succeed for generalist (no permission check)
      result = Router.execute(router, :generate_images, params, agent_id, opts)

      # Per-action Router (v28.0): await_result not supported, use PubSub for async results
      response =
        case result do
          {:ok, resp} ->
            resp

          {:async, _ref} ->
            receive do
              {:action_completed, %{result: {:ok, resp}}} -> resp
              {:action_completed, %{result: resp}} -> resp
            after
              5000 -> flunk("No action completion message received")
            end

          {:async, _ref, _ack} ->
            receive do
              {:action_completed, %{result: {:ok, resp}}} -> resp
              {:action_completed, %{result: resp}} -> resp
            after
              5000 -> flunk("No action completion message received")
            end
        end

      # Must return generate_images result - proves no access control blocks generalists
      assert response.action == "generate_images"
      assert is_list(response.images)
    end

    # R2: generate_images Routing End-to-End
    test "Router correctly routes generate_images action to module", %{
      pubsub: pubsub,
      registry: registry,
      agent_id: agent_id,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN Router.execute called with generate_images action THEN routes to GenerateImages.execute/3
      config = %{
        agent_id: agent_id
      }

      Registry.register(registry, {:agent, agent_id}, config)

      # Create test credential and configure model settings
      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_route_model",
          model_spec: "openai:dall-e-3",
          api_key: "test-api-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["test_route_model"])

      # Use plain function plug (not {Req.Test, fn}) to work with Task.async_stream
      plug = image_success_plug()

      action_id = "action-456"

      # Per-action Router (v28.0): spawn dedicated Router for this action
      {:ok, router} =
        Router.start_link(
          action_type: :generate_images,
          action_id: action_id,
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      opts = [
        registry: registry,
        action_id: action_id,
        sandbox_owner: sandbox_owner,
        plug: plug,
        agent_pid: self()
      ]

      params = %{"prompt" => "Test prompt for routing"}

      # Subscribe to action events for async result notification
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      # Execute and verify it routes to GenerateImages module
      result = Router.execute(router, :generate_images, params, agent_id, opts)

      # Per-action Router (v28.0): await_result not supported, use PubSub for async results
      # Handle both success (action_completed) and error (action_error) broadcasts
      response =
        case result do
          {:ok, resp} ->
            resp

          {:async, _ref} ->
            receive do
              {:action_completed, %{result: {:ok, resp}}} -> resp
              {:action_completed, %{result: resp}} -> resp
              {:action_error, %{error: error}} -> flunk("Action failed: #{inspect(error)}")
            after
              10_000 -> flunk("No action completion message received within 10s")
            end

          {:async, _ref, _ack} ->
            receive do
              {:action_completed, %{result: {:ok, resp}}} -> resp
              {:action_completed, %{result: resp}} -> resp
              {:action_error, %{error: error}} -> flunk("Action failed: #{inspect(error)}")
            after
              10_000 -> flunk("No action completion message received within 10s")
            end
        end

      # Should return image generation result with correct format
      assert %{action: "generate_images", images: images} = response
      assert is_list(images)
    end

    # R4: Happy path - returns {:ok, %{images: [...]}}
    test "returns images array on successful generation", %{
      pubsub: pubsub,
      registry: registry,
      agent_id: agent_id,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN generation succeeds THEN returns {:ok, %{images: [...]}}
      config = %{agent_id: agent_id}
      Registry.register(registry, {:agent, agent_id}, config)

      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: "test_happy_model",
          model_spec: "openai:dall-e-3",
          api_key: "test-api-key"
        })

      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_image_generation_models(["test_happy_model"])

      # Use plain function plug (not {Req.Test, fn}) to work with Task.async_stream
      plug = image_success_plug()

      action_id = "action-happy"

      # Per-action Router (v28.0): spawn dedicated Router for this action
      {:ok, router} =
        Router.start_link(
          action_type: :generate_images,
          action_id: action_id,
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      opts = [
        registry: registry,
        action_id: action_id,
        sandbox_owner: sandbox_owner,
        plug: plug,
        agent_pid: self()
      ]

      params = %{"prompt" => "Generate a happy image"}

      # Subscribe to action events for async result notification
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      result = Router.execute(router, :generate_images, params, agent_id, opts)

      # Per-action Router (v28.0): await_result not supported, use PubSub for async results
      response =
        case result do
          {:ok, resp} ->
            resp

          {:async, _ref} ->
            receive do
              {:action_completed, %{result: {:ok, resp}}} -> resp
              {:action_completed, %{result: resp}} -> resp
              {:action_error, %{error: error}} -> {:error, error}
            after
              5000 -> flunk("No action completion message received")
            end

          {:async, _ref, _ack} ->
            receive do
              {:action_completed, %{result: {:ok, resp}}} -> resp
              {:action_completed, %{result: resp}} -> resp
              {:action_error, %{error: error}} -> {:error, error}
            after
              5000 -> flunk("No action completion message received")
            end
        end

      assert response.action == "generate_images"
      assert is_list(response.images)
      assert response.images != []

      [first_image | _] = response.images
      assert first_image.status == "success"
      assert Map.has_key?(first_image, :data)
      assert Map.has_key?(first_image, :model)
    end

    # R5: No image models configured returns meaningful error
    test "returns error when no image models configured", %{
      pubsub: pubsub,
      registry: registry,
      agent_id: agent_id,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN no image models configured THEN returns {:error, :no_models_configured}
      config = %{agent_id: agent_id}
      Registry.register(registry, {:agent, agent_id}, config)

      # Don't create any credentials - simulate no models configured

      action_id = "action-no-models"

      # Per-action Router (v28.0): spawn dedicated Router for this action
      {:ok, router} =
        Router.start_link(
          action_type: :generate_images,
          action_id: action_id,
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Subscribe to action events for async result notification
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      opts = [registry: registry, action_id: action_id, agent_pid: self()]
      params = %{"prompt" => "This should fail"}

      result = Router.execute(router, :generate_images, params, agent_id, opts)

      # Per-action Router (v28.0): await_result not supported, use PubSub for async results
      # Handle both sync and async result paths consistently
      final_result =
        case result do
          {:error, _} = err ->
            err

          {:async, _ref} ->
            receive do
              {:action_completed, %{result: async_result}} -> async_result
              {:action_error, %{error: {:error, _} = err}} -> err
              {:action_error, %{error: reason}} -> {:error, reason}
            after
              5000 -> flunk("No action completion message received")
            end

          {:async, _ref, _metadata} ->
            receive do
              {:action_completed, %{result: async_result}} -> async_result
              {:action_error, %{error: {:error, _} = err}} -> err
              {:action_error, %{error: reason}} -> {:error, reason}
            after
              5000 -> flunk("No action completion message received")
            end

          {:ok, resp} ->
            {:ok, resp}
        end

      # Should return meaningful error about no models
      assert final_result == {:error, :no_models_configured}
    end

    # Parameter validation through Router
    test "Router rejects missing prompt parameter", %{
      pubsub: pubsub,
      registry: registry,
      agent_id: agent_id,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN prompt missing THEN returns parameter validation error
      config = %{agent_id: agent_id}
      Registry.register(registry, {:agent, agent_id}, config)

      action_id = "action-no-prompt"

      # Per-action Router (v28.0): spawn dedicated Router for this action
      {:ok, router} =
        Router.start_link(
          action_type: :generate_images,
          action_id: action_id,
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Subscribe to action events for async result notification
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      opts = [registry: registry, action_id: action_id, agent_pid: self()]
      params = %{}

      result = Router.execute(router, :generate_images, params, agent_id, opts)

      # Per-action Router (v28.0): await_result not supported, use PubSub for async results
      error =
        case result do
          {:error, reason} ->
            reason

          {:async, _ref} ->
            receive do
              {:action_completed, %{result: {:error, reason}}} -> reason
              {:action_error, %{error: reason}} -> reason
            after
              5000 -> flunk("No action completion message received")
            end

          {:ok, _} ->
            :unexpected_success
        end

      assert error == :missing_required_param
    end
  end
end
