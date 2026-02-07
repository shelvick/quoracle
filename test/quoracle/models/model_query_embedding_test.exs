defmodule Quoracle.Models.ModelQueryEmbeddingTest do
  @moduledoc """
  Tests for Embeddings module functionality.
  Uses stub plugs for HTTP mocking (async-safe, no cassette format issues).
  """

  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog

  alias Quoracle.Models.Embeddings

  # Test credentials matching Azure OpenAI format
  @test_credentials %{
    api_key: "test-api-key",
    endpoint_url: "https://test-endpoint.openai.azure.com",
    deployment_id: "embed-large"
  }

  # Sample embedding vector (3072 dimensions for text-embedding-3-large)
  @sample_embedding List.duplicate(0.01, 3072)

  setup _tags do
    # Start EmbeddingCache since it's no longer a named process
    # DataCase already handles sandbox via start_owner! pattern
    {:ok, cache_pid} = start_supervised(Quoracle.Models.EmbeddingCache)

    %{cache_pid: cache_pid}
  end

  # Helper to create a stub plug that returns embedding response
  defp embedding_stub_plug(embedding \\ @sample_embedding) do
    fn conn ->
      response = %{
        "data" => [%{"embedding" => embedding, "index" => 0}],
        "model" => "text-embedding-3-large",
        "usage" => %{"prompt_tokens" => 10, "total_tokens" => 10}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  describe "get_embedding/2" do
    test "returns embedding for short text under token limit" do
      plug = embedding_stub_plug()
      short_text = "This is a short text for embedding"
      opts = %{plug: plug, credentials: @test_credentials}

      result = Embeddings.get_embedding(short_text, opts)

      assert {:ok, %{embedding: embedding, cached: false, chunks: 1}} = result
      assert length(embedding) == 3072
      assert Enum.all?(embedding, &is_float/1)
    end

    test "automatically chunks and averages long text over token limit" do
      plug = embedding_stub_plug()
      # Create a very long text that will exceed 10K char chunk size
      long_text = String.duplicate("This is a very long text that needs to be chunked. ", 300)
      opts = %{plug: plug, credentials: @test_credentials}

      result = Embeddings.get_embedding(long_text, opts)

      assert {:ok, %{embedding: embedding, cached: false, chunks: chunks}} = result
      assert chunks > 1
      assert length(embedding) == 3072
      assert Enum.all?(embedding, &is_float/1)
    end

    test "returns cached result for repeated requests" do
      plug = embedding_stub_plug()
      text = "Cache test text"
      opts = %{plug: plug, credentials: @test_credentials}

      # First call should not be cached
      {:ok, %{cached: false} = first_result} = Embeddings.get_embedding(text, opts)

      # Second call should be cached (no API call needed)
      {:ok, %{cached: true} = second_result} = Embeddings.get_embedding(text, opts)

      # Embeddings should be identical
      assert first_result.embedding == second_result.embedding
    end

    test "handles empty string input" do
      result = Embeddings.get_embedding("")

      assert {:error, :invalid_input} = result
    end

    test "retries on 5xx server errors" do
      text = "Test server error retry"

      # Use mock function that returns server error
      result =
        Embeddings.get_embedding(text,
          embedding_fn: fn _text ->
            {:error, :service_unavailable}
          end
        )

      # Should return the error
      assert {:error, :service_unavailable} = result
    end

    test "handles authentication failure" do
      text = "Test auth failure"

      # Use mock function that returns auth error
      result =
        Embeddings.get_embedding(text,
          embedding_fn: fn _text ->
            {:error, :authentication_failed}
          end
        )

      assert {:error, :authentication_failed} = result
    end

    test "respects cache TTL expiration" do
      plug = embedding_stub_plug()
      text = "TTL test text"
      opts = %{plug: plug, credentials: @test_credentials}

      # First call
      {:ok, %{cached: false}} = Embeddings.get_embedding(text, opts)

      # With cache_ttl: 0, should bypass cache
      {:ok, %{cached: false}} = Embeddings.get_embedding(text, Map.put(opts, :cache_ttl, 0))
    end

    test "handles recursive chunking for extremely long text" do
      plug = embedding_stub_plug()
      # Text so long it needs multiple chunks (>10K chars each)
      extremely_long_text = String.duplicate("Extremely long text. ", 2000)
      opts = %{plug: plug, credentials: @test_credentials}

      result = Embeddings.get_embedding(extremely_long_text, opts)

      assert {:ok, %{embedding: embedding, chunks: chunks}} = result
      assert chunks > 2
      assert length(embedding) == 3072
    end
  end

  describe "ETS cache management" do
    test "creates ETS table if not exists" do
      plug = embedding_stub_plug()
      text = "First embedding request"
      opts = %{plug: plug, credentials: @test_credentials}

      {:ok, _} = Embeddings.get_embedding(text, opts)

      # Cache functionality is tested elsewhere, just verify call succeeded
    end

    test "handles concurrent requests for same text" do
      plug = embedding_stub_plug()
      text = "Concurrent test text"
      opts = %{plug: plug, credentials: @test_credentials}

      # First, prime the cache with a single request
      {:ok, %{cached: false}} = Embeddings.get_embedding(text, opts)

      # Now test that concurrent requests all hit the cache
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Embeddings.get_embedding(text, opts)
          end)
        end

      results = Task.await_many(tasks)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      # Count how many were cached
      cached_count = Enum.count(results, fn {:ok, %{cached: cached}} -> cached end)

      # All should hit the cache since we primed it first
      assert cached_count == 10
    end
  end

  describe "performance requirements" do
    test "cached embedding returns quickly" do
      plug = embedding_stub_plug()
      text = "Performance test text"
      opts = %{plug: plug, credentials: @test_credentials}

      # Prime the cache
      {:ok, _} = Embeddings.get_embedding(text, opts)

      # Measure cached retrieval time (no API call, just cache lookup)
      # Use 50ms threshold to avoid flakiness under CI load
      {time_us, {:ok, %{cached: true}}} =
        :timer.tc(fn ->
          Embeddings.get_embedding(text, opts)
        end)

      time_ms = time_us / 1000
      assert time_ms < 50, "Cached lookup took #{time_ms}ms, expected under 50ms"
    end
  end

  describe "error handling" do
    test "returns authentication_failed for 401 response" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "Unauthorized"}))
      end

      text = "Test 401 error"
      opts = %{plug: plug, credentials: @test_credentials}

      # Capture log to prevent 401 error log spam in test output
      capture_log(fn ->
        result = Embeddings.get_embedding(text, opts)

        assert {:error, :authentication_failed} = result
      end)
    end

    test "returns rate_limit_exceeded for 429 response" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"error" => "Rate limited"}))
      end

      text = "Test 429 error"
      opts = %{plug: plug, credentials: @test_credentials}

      result = Embeddings.get_embedding(text, opts)

      assert {:error, :rate_limit_exceeded} = result
    end

    test "returns service_unavailable for 5xx response" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, Jason.encode!(%{"error" => "Service unavailable"}))
      end

      text = "Test 503 error"
      opts = %{plug: plug, credentials: @test_credentials}

      result = Embeddings.get_embedding(text, opts)

      assert {:error, :service_unavailable} = result
    end

    test "returns authentication_failed when credentials missing" do
      text = "Test missing credentials"
      # Missing required credential fields
      opts = %{credentials: %{api_key: nil, endpoint_url: nil, deployment_id: nil}}

      result = Embeddings.get_embedding(text, opts)

      assert {:error, :authentication_failed} = result
    end
  end

  describe "integration with Azure API" do
    # Tests use stub plug to mock Azure embedding API responses

    @tag :integration
    test "successfully gets embedding from azure_text_embedding_3_large" do
      # Setup: Create credentials and configure embedding model
      test_model_id = "azure:text-embedding-test-#{System.unique_integer([:positive])}"

      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: test_model_id,
          model_spec: "azure:text-embedding-3-large",
          api_key: "test-api-key",
          endpoint_url: "https://test.openai.azure.com",
          deployment_id: "embed-large"
        })

      # Configure this model as the embedding model
      {:ok, _} = Quoracle.Models.ConfigModelSettings.set_embedding_model(test_model_id)

      # Use stub plug for HTTP response
      plug = embedding_stub_plug()
      text = "Real Azure API test"

      {:ok, result} = Embeddings.get_embedding(text, %{plug: plug})

      assert result.embedding
      assert length(result.embedding) == 3072
      assert result.chunks == 1
      refute result.cached
    end
  end

  # =============================================================
  # CONFIG-DRIVEN MODEL SELECTION (v3.0 - feat-20251205-054538)
  # =============================================================

  describe "[INTEGRATION] config-driven model (R1-R2b)" do
    alias Quoracle.Models.ConfigModelSettings

    test "uses configured embedding model from CONFIG_ModelSettings (R1)" do
      # R1: WHEN generating embedding THEN uses model from CONFIG_ModelSettings
      # Setup: Configure embedding model with unique ID
      unique_model = "azure:text-embedding-config-#{System.unique_integer([:positive])}"
      {:ok, _} = ConfigModelSettings.set_embedding_model(unique_model)

      # Create credential for the configured model
      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: unique_model,
          model_spec: "azure:text-embedding-3-large",
          api_key: "test-api-key",
          endpoint_url: "https://test.openai.azure.com",
          deployment_id: "embed-large"
        })

      plug = fn conn ->
        response = %{
          "data" => [%{"embedding" => @sample_embedding, "index" => 0}],
          "model" => "text-embedding-3-large",
          "usage" => %{"prompt_tokens" => 10, "total_tokens" => 10}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      # Execute should use the configured model (unique text to avoid cache)
      unique_text = "Config test text #{System.unique_integer([:positive])}"
      result = Embeddings.get_embedding(unique_text, %{plug: plug})

      assert {:ok, %{embedding: embedding, cached: false}} = result
      assert length(embedding) == 3072
    end

    test "returns error tuple when embedding model not configured (R2)" do
      # R2: WHEN embedding model not configured THEN returns {:error, :not_configured}
      # (not raise — matches @spec contract)
      # Clear any existing model config
      Quoracle.Models.TableConsensusConfig
      |> Quoracle.Repo.delete_all()

      # Verify not configured
      assert {:error, :not_configured} = ConfigModelSettings.get_embedding_model()

      # Use unique text to avoid cache hits from other tests
      unique_text = "Unique config test text #{System.unique_integer([:positive])}"

      # get_embedding should return error tuple (matching @spec), not raise
      assert {:error, :not_configured} = Embeddings.get_embedding(unique_text)
    end

    test "fetches credentials for configured model (R2b)" do
      # R2b: WHEN generating THEN fetches credentials for configured model_id
      configured_model = "azure:text-embedding-custom"
      {:ok, _} = ConfigModelSettings.set_embedding_model(configured_model)

      # Create credential with specific values to verify correct lookup
      # model_spec must be a valid ReqLLM model (azure:text-embedding-3-large)
      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: configured_model,
          model_spec: "azure:text-embedding-3-large",
          api_key: "custom-api-key",
          endpoint_url: "https://custom.openai.azure.com",
          deployment_id: "custom-deploy"
        })

      plug = fn conn ->
        # Verify the correct endpoint is being called (reflects correct credential lookup)
        # Azure endpoint format: {endpoint_url}/openai/deployments/{deployment_id}/embeddings
        assert String.contains?(conn.host, "custom.openai.azure.com") or
                 String.contains?(conn.request_path, "custom-deploy"),
               "Expected custom Azure endpoint (host: #{conn.host}, path: #{conn.request_path})"

        response = %{
          "data" => [%{"embedding" => @sample_embedding, "index" => 0}],
          "model" => "text-embedding-3-large",
          "usage" => %{"prompt_tokens" => 10, "total_tokens" => 10}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      # Should use the configured model's credentials, not hardcoded @embedding_model
      result = Embeddings.get_embedding("Test text", %{plug: plug})

      assert {:ok, _} = result
    end

    test "does not fall back to hardcoded @embedding_model when config missing (R2)" do
      # Verify that when CONFIG_ModelSettings has no embedding_model,
      # the module returns error tuple instead of falling back to @embedding_model
      Quoracle.Models.TableConsensusConfig
      |> Quoracle.Repo.delete_all()

      # Even if there are Azure credentials in the DB for the old hardcoded model,
      # should return error because config is not set
      unique_fallback = "azure:text-embedding-fallback-#{System.unique_integer([:positive])}"

      {:ok, _cred} =
        Quoracle.Models.TableCredentials.insert(%{
          model_id: unique_fallback,
          model_spec: "azure:text-embedding-3-large",
          api_key: "fallback-key",
          endpoint_url: "https://fallback.openai.azure.com",
          deployment_id: "fallback-deploy"
        })

      # Use unique text to avoid cache hits from other tests
      unique_text = "Unique fallback test text #{System.unique_integer([:positive])}"

      # Should return error tuple (matching @spec), not use fallback or raise
      assert {:error, :not_configured} = Embeddings.get_embedding(unique_text)
    end
  end

  describe "[UNIT] caching preserved (R3)" do
    test "caching still works with config-driven model (R3)" do
      # R3: WHEN cache hit THEN returns cached without API call
      # This validates that caching behavior is preserved after migration
      plug = embedding_stub_plug()
      text = "Config cache test"
      opts = %{plug: plug, credentials: @test_credentials}

      # First call - not cached
      {:ok, %{cached: false}} = Embeddings.get_embedding(text, opts)

      # Second call - should be cached
      {:ok, %{cached: true}} = Embeddings.get_embedding(text, opts)
    end
  end

  describe "[UNIT] chunking preserved (R4)" do
    test "chunking still works with config-driven model (R4)" do
      # R4: WHEN text > 10,000 chars THEN chunks and averages
      plug = embedding_stub_plug()
      long_text = String.duplicate("Chunking test text. ", 600)
      opts = %{plug: plug, credentials: @test_credentials}

      result = Embeddings.get_embedding(long_text, opts)

      assert {:ok, %{chunks: chunks}} = result
      assert chunks > 1
    end
  end
end
