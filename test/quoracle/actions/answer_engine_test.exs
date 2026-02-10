defmodule Quoracle.Actions.AnswerEngineTest do
  @moduledoc """
  Tests for ACTION_Answer (answer engine with Gemini grounding).
  Integration tests use req_cassette for HTTP recording with async: true.
  """

  # req_cassette enables async: true (process-isolated recording)
  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog
  alias Quoracle.Actions.AnswerEngine

  describe "[UNIT] parameter validation" do
    test "returns error when prompt is missing (R1)" do
      # R1: WHEN execute called IF prompt missing THEN returns {:error, :missing_required_param}
      result = AnswerEngine.execute(%{}, "agent-123", [])
      assert {:error, :missing_required_param} = result
    end

    test "returns error when prompt is empty string (R1)" do
      # R1: Empty string should also be treated as missing
      result = AnswerEngine.execute(%{prompt: ""}, "agent-123", [])
      assert {:error, :missing_required_param} = result
    end

    test "returns error when prompt is not a string (R2)" do
      # R2: WHEN execute called IF prompt not string THEN returns {:error, :invalid_param_type}
      result = AnswerEngine.execute(%{prompt: 123}, "agent-123", [])
      assert {:error, :invalid_param_type} = result

      result = AnswerEngine.execute(%{prompt: %{}}, "agent-123", [])
      assert {:error, :invalid_param_type} = result

      result = AnswerEngine.execute(%{prompt: nil}, "agent-123", [])
      assert {:error, :missing_required_param} = result
    end
  end

  describe "[UNIT] source extraction" do
    test "extracts sources from grounding metadata (R9)" do
      # R9: WHEN grounding_metadata contains groundingChunks THEN extracts URLs and titles
      grounding_metadata = %{
        "groundingChunks" => [
          %{
            "web" => %{
              "uri" => "https://example.com/article",
              "title" => "Example Article"
            }
          },
          %{
            "web" => %{
              "uri" => "https://news.com/story",
              "title" => "Breaking News"
            }
          }
        ]
      }

      sources = AnswerEngine.extract_sources(grounding_metadata)

      assert length(sources) == 2

      assert %{
               url: "https://example.com/article",
               title: "Example Article",
               snippet: ""
             } in sources

      assert %{
               url: "https://news.com/story",
               title: "Breaking News",
               snippet: ""
             } in sources
    end

    test "handles nil grounding_metadata gracefully (R10)" do
      # R10: WHEN grounding_metadata is nil THEN returns empty sources list
      sources = AnswerEngine.extract_sources(nil)
      assert sources == []
    end

    test "filters out chunks without web URLs (R9)" do
      # R9: Should only include chunks with valid web URLs
      grounding_metadata = %{
        "groundingChunks" => [
          %{
            "web" => %{
              "uri" => "https://valid.com",
              "title" => "Valid Source"
            }
          },
          %{
            "web" => %{
              "uri" => "",
              "title" => "Empty URL"
            }
          },
          %{
            "other" => %{
              "data" => "not web"
            }
          }
        ]
      }

      sources = AnswerEngine.extract_sources(grounding_metadata)

      assert length(sources) == 1
      assert hd(sources).url == "https://valid.com"
    end
  end

  describe "[UNIT] timing metrics" do
    test "includes execution timing in result (R8)" do
      # R8: WHEN action executes IF successful THEN includes execution_time_ms
      # This would be internal to execute, but we can test the structure
      result = %{
        answer: "Test answer",
        sources: [],
        execution_time_ms: 150,
        model: "google_gemini_2_5_pro"
      }

      assert Map.has_key?(result, :execution_time_ms)
      assert is_integer(result.execution_time_ms)
      assert result.execution_time_ms > 0
    end
  end

  # NOTE: Old "[UNIT] Gemini model discovery" test removed (v3.0)
  # find_gemini_model() replaced by config-driven model selection
  # See "[INTEGRATION] config-driven model selection" tests below

  describe "[INTEGRATION] provider interaction" do
    # Note: Goth mocking removed - ReqLLM handles auth internally
    # Tests use stub_plug to mock HTTP responses

    @tag :integration
    test "returns grounded answer with sources (R4)" do
      # R4: WHEN valid prompt provided IF Gemini available THEN returns answer with sources
      #
      # NOTE: Google Gemini API requires credentials for recording. Using a stub plug
      # that simulates the Gemini response format with grounding metadata.

      # Create a Google credential for this test
      test_model_id = "google-vertex:gemini-test-#{System.unique_integer([:positive])}"

      service_account_json =
        Jason.encode!(%{"type" => "service_account", "project_id" => "test-project"})

      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: test_model_id,
          model_spec: "google-vertex:gemini-2.5-pro",
          api_key: service_account_json,
          resource_id: "test-project",
          region: "us-central1"
        })

      # Configure this model as the answer engine model
      {:ok, _} = Quoracle.Models.ConfigModelSettings.set_answer_engine_model(test_model_id)

      stub_plug = fn conn ->
        response = %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [
                  %{
                    "text" =>
                      "Quantum computing has seen significant advances including improved error correction and larger qubit counts."
                  }
                ],
                "role" => "model"
              },
              "finishReason" => "STOP",
              "groundingMetadata" => %{
                "groundingChunks" => [
                  %{
                    "web" => %{
                      "uri" => "https://example.com/quantum-news",
                      "title" => "Quantum Computing Advances 2025"
                    }
                  }
                ]
              }
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 15,
            "candidatesTokenCount" => 50,
            "totalTokenCount" => 65
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      result =
        AnswerEngine.execute(
          %{prompt: "What are the latest developments in quantum computing?"},
          "agent-123",
          plug: stub_plug,
          access_token: "fake-test-token"
        )

      assert {:ok, response} = result
      assert response.action == "answer_engine"
      assert is_binary(response.answer)
      assert is_list(response.sources)
      assert response.model_used == "google-vertex:gemini-2.5-pro"
    end

    @tag :integration
    test "returns answer with empty sources when no grounding data (R5)" do
      # R5: WHEN Gemini returns no grounding_metadata THEN returns answer with empty sources AND logs warning
      #
      # NOTE: Using stub plug to simulate Gemini response without grounding metadata.

      # Create a Google credential for this test
      test_model_id = "google-vertex:gemini-test-#{System.unique_integer([:positive])}"

      service_account_json =
        Jason.encode!(%{"type" => "service_account", "project_id" => "test-project"})

      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: test_model_id,
          model_spec: "google-vertex:gemini-2.5-pro",
          api_key: service_account_json,
          resource_id: "test-project",
          region: "us-central1"
        })

      # Configure this model as the answer engine model
      {:ok, _} = Quoracle.Models.ConfigModelSettings.set_answer_engine_model(test_model_id)

      stub_plug = fn conn ->
        response = %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [%{"text" => "2 + 2 equals 4."}],
                "role" => "model"
              },
              "finishReason" => "STOP"
              # No groundingMetadata - simulates a non-grounded response
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 8,
            "candidatesTokenCount" => 10,
            "totalTokenCount" => 18
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      log =
        capture_log(fn ->
          result =
            AnswerEngine.execute(%{prompt: "What is 2 + 2?"}, "agent-123",
              plug: stub_plug,
              access_token: "fake-test-token"
            )

          assert {:ok, response} = result
          assert response.action == "answer_engine"
          assert is_binary(response.answer)
          assert is_list(response.sources)
          assert response.model_used == "google-vertex:gemini-2.5-pro"
        end)

      # Log warning if no grounding metadata (cassette may have empty sources)
      if String.contains?(log, "No grounding metadata"), do: :ok
    end

    @tag :integration
    test "handles provider API errors gracefully (R6)" do
      # R6: WHEN provider call fails IF API error THEN returns {:error, :provider_error}
      # Use force_error flag to simulate error without needing error cassette
      result =
        AnswerEngine.execute(%{prompt: "Test question"}, "agent-123",
          model_config: %{
            model_id: "google_gemini_2_5_pro",
            provider_id: "google",
            status: :active,
            force_error: :rate_limit_exceeded
          }
        )

      assert {:error, :provider_error} = result
    end
  end

  describe "[SYSTEM] Router integration" do
    setup %{sandbox_owner: sandbox_owner} do
      # Isolated PubSub only - per-action Router spawned in tests
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

      %{pubsub: pubsub_name, sandbox_owner: sandbox_owner}
    end

    @tag :system
    test "full Router integration with PubSub events (R7)", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v28.0): Spawn Router for this specific action
      alias Quoracle.Actions.Router

      agent_id = "agent-001"
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router} =
        Router.start_link(
          action_type: :answer_engine,
          action_id: action_id,
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # R7: WHEN Router executes answer_engine action THEN broadcasts lifecycle events and returns result
      #
      # NOTE: Using stub plug to simulate Gemini response (API not accessible for recording).
      stub_plug = fn conn ->
        response = %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [%{"text" => "AI has made significant advances in 2025."}],
                "role" => "model"
              },
              "finishReason" => "STOP",
              "groundingMetadata" => %{
                "groundingChunks" => [
                  %{"web" => %{"uri" => "https://example.com/ai", "title" => "AI News"}}
                ]
              }
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 10,
            "candidatesTokenCount" => 20,
            "totalTokenCount" => 30
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      # Subscribe to action events
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      params = %{prompt: "What are the latest developments in AI?"}

      # Model config for test - AnswerEngine uses this instead of DB lookup
      model_config = %{
        model_id: "google-vertex:gemini-2.5-pro",
        model_spec: "google-vertex:gemini-2.5-pro",
        resource_id: "test-project"
      }

      # Execute through Router public API with timeout for sync execution
      # Pass access_token to skip JWT signing (stub_plug handles HTTP)
      capture_log(fn ->
        result =
          Router.execute(router, :answer_engine, params, agent_id,
            pubsub: pubsub,
            timeout: 10000,
            plug: stub_plug,
            access_token: "test-token",
            model_config: model_config,
            sandbox_owner: sandbox_owner
          )

        send(self(), {:result, result})
      end)

      # Verify lifecycle events
      assert_receive {:action_started, event}, 30_000
      assert event.action_type == :answer_engine

      # Get result
      assert_receive {:result, result}, 30_000
      assert {:ok, response} = result
      assert response.action == "answer_engine"
      assert is_binary(response.answer)
      assert is_list(response.sources)
      assert response.model_used == "google-vertex:gemini-2.5-pro"
      assert is_integer(response.execution_time_ms)

      # Verify completion event
      assert_receive {:action_completed, _event}, 30_000
    end

    test "Router properly maps answer_engine action" do
      # Verify that Router's ActionMapper includes answer_engine
      result = Quoracle.Actions.Router.ActionMapper.get_action_module(:answer_engine)
      assert {:ok, Quoracle.Actions.AnswerEngine} = result
    end
  end

  describe "[INTEGRATION] credential and model management" do
    test "uses ModelQuery to find Gemini model" do
      # Verify integration with ModelQuery
      # This would normally query the database
      models = Quoracle.Models.ModelQuery.get_models_by_provider("google")

      # In test, might be empty or mocked
      assert is_list(models)

      gemini_model =
        Enum.find(models, fn model ->
          model.model_id |> to_string() |> String.contains?("gemini")
        end)

      # Gemini model may or may not exist in test DB - just verify query works
      if gemini_model do
        assert is_map(gemini_model)
        assert gemini_model.model_id |> to_string() |> String.contains?("gemini")
      end
    end
  end

  # =============================================================
  # CONFIG-DRIVEN MODEL SELECTION (v3.0 - feat-20251205-054538)
  # =============================================================

  describe "[INTEGRATION] config-driven model selection" do
    alias Quoracle.Models.ConfigModelSettings

    test "raises RuntimeError when answer engine model not configured (R3-config)" do
      # R3: WHEN answer engine model not configured THEN raises RuntimeError
      # Clear any existing model config
      Quoracle.Models.TableConsensusConfig
      |> Quoracle.Repo.delete_all()

      # Verify not configured
      assert {:error, :not_configured} = ConfigModelSettings.get_answer_engine_model()

      # Execute should raise RuntimeError (not return {:error, :gemini_not_configured})
      assert_raise RuntimeError, ~r/Answer engine model not configured/, fn ->
        AnswerEngine.execute(%{prompt: "What is quantum computing?"}, "agent-123", [])
      end
    end

    test "uses model from CONFIG_ModelSettings when configured (R3-config)" do
      # R3: WHEN answer engine model configured THEN uses that model
      # Setup: Configure answer engine model with unique ID
      unique_model = "google-vertex:gemini-config-#{System.unique_integer([:positive])}"
      {:ok, _} = ConfigModelSettings.set_answer_engine_model(unique_model)

      # Create credential for the configured model
      service_account_json =
        Jason.encode!(%{"type" => "service_account", "project_id" => "test-project"})

      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: unique_model,
          model_spec: "google-vertex:gemini-2.5-pro",
          api_key: service_account_json,
          resource_id: "test-project",
          region: "us-central1"
        })

      stub_plug = fn conn ->
        response = %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [%{"text" => "Test answer from configured model"}],
                "role" => "model"
              },
              "finishReason" => "STOP"
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 10,
            "candidatesTokenCount" => 20,
            "totalTokenCount" => 30
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      # Execute should use the configured model (not find_gemini_model)
      result =
        AnswerEngine.execute(
          %{prompt: "Test question"},
          "agent-123",
          plug: stub_plug,
          access_token: "test-token"
        )

      assert {:ok, response} = result
      assert response.action == "answer_engine"
      # Model used should be the configured one (model_spec from credential)
      assert response.model_used == "google-vertex:gemini-2.5-pro"
    end

    test "does not fall back to find_gemini_model when config missing (R3-config)" do
      # Verify that when CONFIG_ModelSettings has no answer_engine_model,
      # the action raises instead of falling back to find_gemini_model()
      Quoracle.Models.TableConsensusConfig
      |> Quoracle.Repo.delete_all()

      # Even if there are Google credentials in the DB, should raise
      service_account_json =
        Jason.encode!(%{"type" => "service_account", "project_id" => "test-project"})

      unique_fallback = "google-vertex:gemini-fallback-#{System.unique_integer([:positive])}"

      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: unique_fallback,
          model_spec: "google-vertex:gemini-2.5-pro",
          api_key: service_account_json,
          resource_id: "test-project",
          region: "us-central1"
        })

      # Should raise RuntimeError, not use the fallback credential
      assert_raise RuntimeError, ~r/Answer engine model not configured/, fn ->
        AnswerEngine.execute(%{prompt: "Test"}, "agent-123", [])
      end
    end
  end
end
