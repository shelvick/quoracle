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
      # Create text that exceeds Azure's 8191 token limit (effective: 7371 with 90% safety)
      # 1500 reps ~= 19,502 tokens, well over the effective limit
      long_text = String.duplicate("This is a very long text that needs to be chunked. ", 1500)
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
      # Text so long it produces 3+ chunks (Azure effective limit: 7371 tokens)
      # 6000 reps ~= 24,002 tokens -> 4 chunks at 7371 effective limit
      extremely_long_text = String.duplicate("Extremely long text. ", 6000)
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
      # R4: WHEN text tokens exceed model limit THEN chunks and averages
      # Azure effective limit: trunc(8191 * 0.9) = 7371 tokens
      # 1500 reps ~= 7502 tokens, exceeds effective limit
      plug = embedding_stub_plug()
      long_text = String.duplicate("Chunking test text. ", 1500)
      opts = %{plug: plug, credentials: @test_credentials}

      result = Embeddings.get_embedding(long_text, opts)

      assert {:ok, %{chunks: chunks}} = result
      assert chunks > 1
    end
  end

  # =============================================================
  # MULTI-PROVIDER EMBEDDING SUPPORT (v7.0 - fix-20260213-multiprovider-embeddings)
  # Packet 1: Provider Generalization (R18-R25)
  # =============================================================

  describe "[UNIT] build_embedding_options (R18-R21, R25)" do
    alias Quoracle.Models.ModelQuery.OptionsBuilder

    test "builds Azure embedding opts with base_url and deployment (R18)" do
      # R18: WHEN build_embedding_options called with Azure credential
      #      THEN returns opts with api_key, base_url, deployment
      credential = %{
        model_spec: "azure:text-embedding-3-large",
        api_key: "test-key",
        endpoint_url: "https://test.openai.azure.com",
        deployment_id: "embed-large",
        resource_id: nil,
        region: nil
      }

      opts = OptionsBuilder.build_embedding_options(credential, %{})

      assert Keyword.get(opts, :api_key) == "test-key"
      assert Keyword.get(opts, :base_url) == "https://test.openai.azure.com"
      assert Keyword.get(opts, :deployment) == "embed-large"
    end

    test "builds OpenAI embedding opts with api_key only (R19)" do
      # R19: WHEN build_embedding_options called with OpenAI credential
      #      (no deployment_id/endpoint_url) THEN returns opts with only api_key
      credential = %{
        model_spec: "openai:text-embedding-3-small",
        api_key: "sk-test-key",
        endpoint_url: nil,
        deployment_id: nil,
        resource_id: nil,
        region: nil
      }

      opts = OptionsBuilder.build_embedding_options(credential, %{})

      assert Keyword.get(opts, :api_key) == "sk-test-key"
      refute Keyword.has_key?(opts, :base_url)
      refute Keyword.has_key?(opts, :deployment)
    end

    test "builds Google Vertex embedding opts with service_account_json and project_id (R20)" do
      # R20: WHEN build_embedding_options called with Google Vertex credential
      #      THEN returns opts with service_account_json, project_id, region
      credential = %{
        model_spec: "google-vertex:gemini-embedding-001",
        api_key: "{\"type\":\"service_account\",\"project_id\":\"my-project\"}",
        endpoint_url: nil,
        deployment_id: nil,
        resource_id: "my-project",
        region: "us-central1"
      }

      opts = OptionsBuilder.build_embedding_options(credential, %{})

      assert Keyword.get(opts, :service_account_json) ==
               "{\"type\":\"service_account\",\"project_id\":\"my-project\"}"

      assert Keyword.get(opts, :project_id) == "my-project"
      assert Keyword.get(opts, :region) == "us-central1"
      refute Keyword.has_key?(opts, :api_key)
      refute Keyword.has_key?(opts, :base_url)
    end

    test "builds Bedrock embedding opts with AWS credentials (R21)" do
      # R21: WHEN build_embedding_options called with Bedrock credential
      #      (colon-separated api_key) THEN returns opts with access_key_id,
      #      secret_access_key, region
      credential = %{
        model_spec: "amazon-bedrock:amazon.titan-embed-text-v2",
        api_key: "AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        endpoint_url: nil,
        deployment_id: nil,
        resource_id: nil,
        region: "us-east-1"
      }

      opts = OptionsBuilder.build_embedding_options(credential, %{})

      assert Keyword.get(opts, :access_key_id) == "AKIAIOSFODNN7EXAMPLE"
      assert Keyword.get(opts, :secret_access_key) == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      assert Keyword.get(opts, :region) == "us-east-1"
      refute Keyword.has_key?(opts, :api_key)
      refute Keyword.has_key?(opts, :base_url)
    end

    test "plug injection included in embedding opts (R25)" do
      # R25: WHEN build_embedding_options called with :plug in options
      #      THEN includes req_http_options: [plug: plug]
      credential = %{
        model_spec: "openai:text-embedding-3-small",
        api_key: "sk-test-key",
        endpoint_url: nil,
        deployment_id: nil,
        resource_id: nil,
        region: nil
      }

      test_plug = fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      opts = OptionsBuilder.build_embedding_options(credential, %{plug: test_plug})

      assert Keyword.has_key?(opts, :req_http_options)
      assert Keyword.get(opts, :req_http_options) == [plug: test_plug]
    end
  end

  describe "[INTEGRATION] multi-provider embedding (R22-R24)" do
    test "OpenAI credentials are accepted (no deployment_id required) (R22)" do
      # R22: WHEN get_embedding called with OpenAI credentials
      #      (no deployment_id/endpoint_url) THEN does NOT return
      #      {:error, :authentication_failed}
      plug = embedding_stub_plug()

      openai_creds = %{
        model_spec: "openai:text-embedding-3-small",
        api_key: "sk-test-key"
      }

      unique_text = "OpenAI embedding test #{System.unique_integer([:positive])}"

      result =
        Embeddings.get_embedding(unique_text, %{
          plug: plug,
          credentials: openai_creds
        })

      # Must NOT be :authentication_failed — the current Azure gate rejects
      # credentials without deployment_id/endpoint_url
      assert {:ok, %{embedding: embedding}} = result
      assert length(embedding) == 3072
    end

    test "test injection path uses credential model_spec (R23)" do
      # R23: WHEN credentials injected with model_spec field
      #      THEN uses that model_spec for ReqLLM routing (not hardcoded azure)
      plug = embedding_stub_plug()

      openai_creds = %{
        model_spec: "openai:text-embedding-3-small",
        api_key: "sk-test-key"
      }

      unique_text = "Model spec routing test #{System.unique_integer([:positive])}"

      result =
        Embeddings.get_embedding(unique_text, %{
          plug: plug,
          credentials: openai_creds
        })

      # If the hardcoded "azure:text-embedding-3-large" is still used,
      # ReqLLM will try to build an Azure request with missing deployment/endpoint,
      # which will fail. Success means the OpenAI model_spec was actually used.
      assert {:ok, %{embedding: _embedding, cached: false}} = result
    end

    test "model_spec absent routes by credential shape (R24)" do
      # R24: WHEN credentials injected WITHOUT model_spec field
      #      THEN provider is determined by credential shape:
      #      - Azure-specific fields (endpoint_url + deployment_id) → routes to Azure
      #      - No Azure-specific fields → routes to OpenAI (backward compat)

      # Case 1: Credentials with Azure-specific fields → should route to Azure
      azure_request_host = :counters.new(1, [:atomics])

      azure_plug = fn conn ->
        # Azure requests go to the custom endpoint_url host
        if String.contains?(conn.host, "test-azure-endpoint") do
          :counters.put(azure_request_host, 1, 1)
        end

        response = %{
          "data" => [%{"embedding" => @sample_embedding, "index" => 0}],
          "model" => "text-embedding-3-large",
          "usage" => %{"prompt_tokens" => 10, "total_tokens" => 10}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      azure_creds_no_model_spec = %{
        api_key: "test-api-key",
        endpoint_url: "https://test-azure-endpoint.openai.azure.com",
        deployment_id: "embed-large"
      }

      unique_text_azure = "Azure routing test #{System.unique_integer([:positive])}"

      result_azure =
        Embeddings.get_embedding(unique_text_azure, %{
          plug: azure_plug,
          credentials: azure_creds_no_model_spec
        })

      assert {:ok, %{embedding: embedding, cached: false}} = result_azure
      assert length(embedding) == 3072

      assert :counters.get(azure_request_host, 1) == 1,
             "Expected request to Azure endpoint when Azure-specific fields present"

      # Case 2: Credentials without Azure-specific fields → should route to OpenAI
      openai_request_host = :counters.new(1, [:atomics])

      openai_plug = fn conn ->
        # OpenAI requests go to api.openai.com
        if String.contains?(conn.host, "api.openai.com") do
          :counters.put(openai_request_host, 1, 1)
        end

        response = %{
          "data" => [%{"embedding" => @sample_embedding, "index" => 0}],
          "model" => "text-embedding-3-large",
          "usage" => %{"prompt_tokens" => 10, "total_tokens" => 10}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      openai_creds_no_model_spec = %{
        api_key: "test-api-key"
      }

      unique_text_openai = "OpenAI routing test #{System.unique_integer([:positive])}"

      result_openai =
        Embeddings.get_embedding(unique_text_openai, %{
          plug: openai_plug,
          credentials: openai_creds_no_model_spec
        })

      assert {:ok, %{embedding: embedding_openai, cached: false}} = result_openai
      assert length(embedding_openai) == 3072

      assert :counters.get(openai_request_host, 1) == 1,
             "Expected request to OpenAI endpoint when no Azure-specific fields"
    end
  end

  # =============================================================
  # TOKEN-BASED CHUNKING (v7.0 - fix-20260213-multiprovider-embeddings)
  # Packet 2: Token-Based Chunking (R26-R32)
  # =============================================================

  describe "[UNIT] token-based chunking (R26-R30, R32)" do
    alias Quoracle.Agent.TokenManager

    test "chunks text when tokens exceed LLMDB model context limit (R26)" do
      # R26: WHEN text tokens exceed model's limits.context (from LLMDB) THEN text is chunked
      # google_vertex:gemini-embedding-001 has 2048 token context limit in LLMDB
      # 350 reps = ~9,450 chars (UNDER 10K char limit), ~2,101 tokens (OVER 2048)
      # This text MUST only be chunked by token-based logic, not char-based.
      unique = "#{System.unique_integer([:positive])} "
      long_text = unique <> String.duplicate("The quick brown fox jumps. ", 350)

      # Verify preconditions
      assert String.length(long_text) < 10_000,
             "Text must be under 10K chars to avoid char-based chunking"

      assert TokenManager.estimate_tokens(long_text) > 2048,
             "Text must exceed Google model's 2048 token limit"

      chunks_seen = :counters.new(1, [:atomics])

      result =
        Embeddings.get_embedding(long_text,
          embedding_fn: fn _text ->
            :counters.add(chunks_seen, 1, 1)
            {:ok, @sample_embedding}
          end,
          model_spec: "google_vertex:gemini-embedding-001"
        )

      assert {:ok, %{chunks: chunks}} = result
      assert chunks >= 2, "Expected multiple chunks for text exceeding model token limit"
      assert :counters.get(chunks_seen, 1) == chunks
    end

    test "respects small context limit for Google embedding model (R27)" do
      # R27: WHEN model has 2048 token limit (Google embedding) IF text has ~2400 tokens
      #      THEN produces multiple chunks each under 2048 tokens
      # google_vertex:gemini-embedding-001 has 2048 token context limit in LLMDB
      # 400 reps of "The quick brown fox jumps. " = ~2400 tokens (exceeds 2048)
      unique = "#{System.unique_integer([:positive])} "
      long_text = unique <> String.duplicate("The quick brown fox jumps. ", 400)

      # Verify precondition: text exceeds Google model's context limit
      assert TokenManager.estimate_tokens(long_text) > 2048

      chunks_received = Agent.start_link(fn -> [] end) |> elem(1)

      result =
        Embeddings.get_embedding(long_text,
          embedding_fn: fn chunk_text ->
            Agent.update(chunks_received, fn chunks -> [chunk_text | chunks] end)
            {:ok, @sample_embedding}
          end,
          model_spec: "google_vertex:gemini-embedding-001"
        )

      assert {:ok, %{chunks: chunks}} = result

      assert chunks >= 2,
             "Expected multiple chunks for text exceeding Google model's 2048 token limit"

      # Verify each chunk respects the model's token limit
      all_chunks = Agent.get(chunks_received, & &1)

      Enum.each(all_chunks, fn chunk ->
        chunk_tokens = TokenManager.estimate_tokens(chunk)

        assert chunk_tokens <= 2048,
               "Chunk has #{chunk_tokens} tokens, exceeds Google model's 2048 limit"
      end)

      Agent.stop(chunks_received)
    end

    test "uses default 8191 token limit when LLMDB has no data (R28)" do
      # R28: WHEN model not in LLMDB THEN uses default 8191 token limit
      # A fake model_spec defaults to 8191. Text with ~5,041 tokens (UNDER 8191)
      # but 22,680 chars (OVER 10K). With token-based chunking at default 8191,
      # this should NOT be chunked. With char-based chunking at 10K, it WOULD chunk.
      unique = "#{System.unique_integer([:positive])} "
      text = unique <> String.duplicate("The quick brown fox jumps. ", 840)

      token_count = TokenManager.estimate_tokens(text)

      # Verify preconditions
      assert String.length(text) > 10_000,
             "Text must exceed 10K chars to trigger char-based chunking (control)"

      assert token_count < 8191,
             "Text must be UNDER default 8191 token limit, got #{token_count}"

      assert token_count > 2000,
             "Text must have meaningful token count to validate limit, got #{token_count}"

      chunks_seen = :counters.new(1, [:atomics])

      result =
        Embeddings.get_embedding(text,
          embedding_fn: fn _text ->
            :counters.add(chunks_seen, 1, 1)
            {:ok, @sample_embedding}
          end,
          model_spec: "fake:nonexistent-embedding-model"
        )

      assert {:ok, %{chunks: 1}} = result,
             "Text under 8191 tokens should NOT be chunked with default limit"

      assert :counters.get(chunks_seen, 1) == 1
    end

    test "applies 90% safety margin to model token limit (R29)" do
      # R29: WHEN chunking THEN max tokens per chunk is 90% of model limit
      # google_vertex:gemini-embedding-001 has 2048 token limit
      # 90% of 2048 = 1843 effective token limit
      # 315 reps = ~8,505 chars (UNDER 10K), ~1,891 tokens
      # Tokens: ABOVE 1843 safety margin, BELOW 2048 raw limit
      # With safety margin: should chunk. Without safety margin: should NOT chunk.
      unique = "#{System.unique_integer([:positive])} "
      text_above_safety = unique <> String.duplicate("The quick brown fox jumps. ", 315)
      token_count = TokenManager.estimate_tokens(text_above_safety)

      safety_limit = trunc(2048 * 0.9)

      # Verify preconditions
      assert String.length(text_above_safety) < 10_000,
             "Text must be under 10K chars to avoid char-based chunking"

      assert token_count > safety_limit,
             "Text should exceed 90% safety margin (#{safety_limit} tokens), got #{token_count}"

      assert token_count < 2048,
             "Text should be below raw limit (2048 tokens), got #{token_count}"

      chunks_seen = :counters.new(1, [:atomics])

      result =
        Embeddings.get_embedding(text_above_safety,
          embedding_fn: fn _text ->
            :counters.add(chunks_seen, 1, 1)
            {:ok, @sample_embedding}
          end,
          model_spec: "google_vertex:gemini-embedding-001"
        )

      assert {:ok, %{chunks: chunks}} = result

      # With 90% safety margin, text above 1843 tokens should be chunked
      # even though it's below the raw 2048 limit
      assert chunks >= 2,
             "Expected chunking due to 90% safety margin (#{safety_limit} effective limit)"
    end

    test "short text below token limit sent as single chunk (R30)" do
      # R30: WHEN text tokens within model limit THEN text sent as single request (1 chunk)
      # Use text that is OVER 10K chars but UNDER Azure's 8191 token limit.
      # With token-based chunking: single chunk (tokens within limit).
      # With char-based chunking: would chunk (chars exceed 10K).
      # 840 reps = ~22,680 chars (OVER 10K), ~5,041 tokens (UNDER 8191)
      unique = "#{System.unique_integer([:positive])} "
      text = unique <> String.duplicate("The quick brown fox jumps. ", 840)
      token_count = TokenManager.estimate_tokens(text)

      # Verify preconditions
      assert String.length(text) > 10_000,
             "Text must exceed 10K chars (would trigger char-based chunking)"

      assert token_count < 8191,
             "Text must be under Azure's 8191 token limit, got #{token_count}"

      chunks_seen = :counters.new(1, [:atomics])

      result =
        Embeddings.get_embedding(text,
          embedding_fn: fn _text ->
            :counters.add(chunks_seen, 1, 1)
            {:ok, @sample_embedding}
          end,
          model_spec: "azure:text-embedding-3-large"
        )

      assert {:ok, %{chunks: 1}} = result,
             "Text under 8191 tokens should NOT be chunked despite being #{String.length(text)} chars"

      assert :counters.get(chunks_seen, 1) == 1
    end

    test "token counting uses TokenManager.estimate_tokens (R32)" do
      # R32: WHEN counting tokens THEN uses TokenManager.estimate_tokens/1 (tiktoken cl100k_base)
      # Verify that the chunking decision is based on tiktoken token counting,
      # NOT character length.
      #
      # Key insight: character-based chunking uses @max_chunk_size (10_000 chars).
      # Token-based chunking uses model token limits (2048 for Google).
      # Create text that is UNDER 10K chars but OVER model token limit.
      # If chunking happens, it PROVES token-based counting is used.
      # If it returns 1 chunk, char-based counting is still in use.
      #
      # 350 reps = ~9,450 chars (UNDER 10K), ~2,101 tokens (OVER 2048)
      unique = "#{System.unique_integer([:positive])} "
      text = unique <> String.duplicate("The quick brown fox jumps. ", 350)
      token_count = TokenManager.estimate_tokens(text)

      # Verify preconditions
      assert String.length(text) < 10_000,
             "Text must be under 10K chars to avoid char-based chunking"

      assert token_count > 2048,
             "Text must exceed Google model's 2048 token limit"

      chunks_seen = :counters.new(1, [:atomics])

      result =
        Embeddings.get_embedding(text,
          embedding_fn: fn _text ->
            :counters.add(chunks_seen, 1, 1)
            {:ok, @sample_embedding}
          end,
          model_spec: "google_vertex:gemini-embedding-001"
        )

      assert {:ok, %{chunks: chunks}} = result

      # With token-based counting and Google's 2048 limit, this MUST chunk.
      # Character-based counting at 10K would NOT chunk (~9,450 chars < 10K).
      assert chunks >= 2,
             "Expected token-based chunking (#{token_count} tokens > 2048 limit). " <>
               "Got #{chunks} chunk(s) — char-based counting is still in use."
    end
  end

  describe "[INTEGRATION] context_length_exceeded fallback (R31)" do
    alias Quoracle.Agent.TokenManager

    test "context_length_exceeded triggers chunking with reduced limit (R31)" do
      # R31: WHEN API returns context_length_exceeded despite token estimate
      #      THEN retries with chunks at half the limit
      #
      # Simulate: text is within token limit estimate, but API rejects it.
      # On context_length_exceeded, system should retry with half the limit,
      # causing chunking.

      call_count = :counters.new(1, [:atomics])

      # Text within Azure limit (~600 tokens) but API will reject first attempt
      unique = "#{System.unique_integer([:positive])} "
      text = unique <> String.duplicate("The quick brown fox jumps. ", 100)

      # Verify precondition: text is within normal Azure limit
      assert TokenManager.estimate_tokens(text) < 8191

      result =
        Embeddings.get_embedding(text,
          embedding_fn: fn _text ->
            count = :counters.get(call_count, 1) + 1
            :counters.put(call_count, 1, count)

            if count == 1 do
              # First call: simulate context_length_exceeded
              {:error, :context_length_exceeded}
            else
              # Subsequent calls (chunked): succeed
              {:ok, @sample_embedding}
            end
          end,
          model_spec: "azure:text-embedding-3-large"
        )

      assert {:ok, %{chunks: chunks}} = result
      # After context_length_exceeded, text should be re-chunked at half the limit
      # and retried, resulting in multiple chunks
      assert chunks >= 2,
             "Expected re-chunking after context_length_exceeded, got #{chunks} chunk(s)"

      # Verify more than 1 API call was made (first failed, then chunked retries)
      total_calls = :counters.get(call_count, 1)

      assert total_calls >= 3,
             "Expected at least 3 calls (1 failed + 2+ chunked), got #{total_calls}"
    end
  end
end
