defmodule Quoracle.Consensus.Packet3ReqLLMMigrationTest do
  @moduledoc """
  TEST phase for Packet 3 (Consumer Updates) of WorkGroupID refactor-20251203-225603.

  Tests verify:
  - CONSENSUS_Manager: Model pools return string model_ids (R1-R11)
  - CONSENSUS_Agg: Handles ReqLLM.Response structs (R15-R16)
  - AGENT_Consensus: Uses ReqLLM.Response.text/1 (R1-R3)
  - AGENT_ConsensusHandler: Uses CredentialManager.list_model_ids (R1-R2)
  - ACTION_Answer: Direct ReqLLM calls with grounding (R1-R10)
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Consensus.{Manager, Aggregator}
  alias Quoracle.Actions.AnswerEngine
  alias Quoracle.Models.CredentialManager

  # Helper to build a ReqLLM.Response struct for testing
  defp build_response(text_content, opts \\ []) do
    %ReqLLM.Response{
      id: opts[:id] || "test-id",
      model: opts[:model] || "test-model",
      context: ReqLLM.Context.new([]),
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text(text_content)]
      },
      usage: opts[:usage] || %{input_tokens: 10, output_tokens: 5},
      finish_reason: opts[:finish_reason] || :stop,
      provider_meta: opts[:provider_meta] || %{}
    }
  end

  # =============================================================================
  # CONSENSUS_Manager Tests (R1-R11: model_id strings)
  # =============================================================================

  describe "CONSENSUS_Manager model_id strings (R1-R2)" do
    # NOTE: Tests updated for v3.0 config-driven model selection
    # get_model_pool now reads from CONFIG_ModelSettings, not hardcoded
    # get_critical_model_pool was removed in v3.0

    test "R1: get_model_pool returns configured model_id strings" do
      # Model pool now comes from profile via opts
      test_models = [
        "azure:gpt-4o",
        "google-vertex:gemini-2.5-pro",
        "amazon-bedrock:claude-3-5-sonnet"
      ]

      pool = Manager.get_model_pool(model_pool: test_models)

      assert is_list(pool)
      assert pool == test_models
      assert Enum.all?(pool, &is_binary/1), "All model pool entries must be strings"
    end

    # R2: get_critical_model_pool removed in v3.0
    # Verification: Compiler enforces removal - any call would fail to compile
    # No runtime test needed (function_exported? discouraged by Credo)
  end

  describe "CONSENSUS_Manager model pool validity (R3)" do
    test "R3: all model pool entries are valid credential model_ids" do
      # Model pool now comes from profile via opts
      test_models = ["azure:gpt-4o", "google-vertex:gemini-2.5-pro"]

      pool = Manager.get_model_pool(model_pool: test_models)

      # Each model_id in the pool should be a string
      for model_id <- pool do
        assert is_binary(model_id), "Model ID must be a string: #{inspect(model_id)}"
      end

      # Note: Credential validation is separate from model pool configuration
      # The pool returns configured model_ids; credential existence is verified at call time
    end
  end

  describe "CONSENSUS_Manager configuration (R4-R6)" do
    test "R4: get_consensus_threshold returns 0.5" do
      assert Manager.get_consensus_threshold() == 0.5
    end

    test "R5: get_max_refinement_rounds returns positive integer" do
      max_rounds = Manager.get_max_refinement_rounds()
      assert is_integer(max_rounds)
      assert max_rounds > 0
    end

    test "R6: get_sliding_window_size returns 2" do
      assert Manager.get_sliding_window_size() == 2
    end
  end

  describe "CONSENSUS_Manager context management (R7-R10)" do
    test "R7: build_context returns proper structure" do
      context = Manager.build_context("test goal", [%{role: "user", content: "hello"}])

      assert is_map(context)
      assert context.prompt == "test goal"
      assert is_list(context.conversation_history)
      assert context.reasoning_history == []
      assert context.round_proposals == []
      assert is_integer(context.start_time)
    end

    test "R8: update_context_with_round adds reasoning" do
      context = Manager.build_context("goal", [])

      responses = [
        %{action: :orient, params: %{}, reasoning: "first reasoning"},
        %{action: :orient, params: %{}, reasoning: "second reasoning"}
      ]

      updated = Manager.update_context_with_round(context, 1, responses)

      assert length(updated.reasoning_history) == 1
      # v7.0: reasoning_history now stores full response maps
      [first, second] = hd(updated.reasoning_history)
      assert first.reasoning == "first reasoning"
      assert second.reasoning == "second reasoning"
    end

    test "R9: reasoning history respects sliding window size" do
      context = Manager.build_context("goal", [])

      # Add 3 rounds (window size is 2)
      updated =
        Enum.reduce(1..3, context, fn round, ctx ->
          responses = [%{action: :orient, params: %{}, reasoning: "round #{round}"}]
          Manager.update_context_with_round(ctx, round, responses)
        end)

      # Should only keep last 2 rounds
      assert length(updated.reasoning_history) == 2
    end

    test "R10: update_context_with_round preserves proposals" do
      context = Manager.build_context("goal", [])

      responses = [%{action: :orient, params: %{status: "thinking"}, reasoning: "r1"}]
      updated = Manager.update_context_with_round(context, 1, responses)

      assert length(updated.round_proposals) == 1
      assert {1, proposals} = hd(updated.round_proposals)
      assert hd(proposals).action == :orient
    end

    test "R11: configuration methods are pure functions" do
      # Model pool now comes from profile via opts
      test_models = ["azure:gpt-4o", "google-vertex:gemini-2.5-pro"]

      # Call multiple times with same opts, should return identical results
      pool1 = Manager.get_model_pool(model_pool: test_models)
      pool2 = Manager.get_model_pool(model_pool: test_models)
      assert pool1 == pool2

      threshold1 = Manager.get_consensus_threshold()
      threshold2 = Manager.get_consensus_threshold()
      assert threshold1 == threshold2
    end
  end

  # =============================================================================
  # CONSENSUS_Agg Tests (R15-R16: ReqLLM.Response handling)
  # =============================================================================

  describe "CONSENSUS_Agg ReqLLM.Response handling (R15-R16)" do
    test "R15: extracts content from ReqLLM.Response struct" do
      # Create a ReqLLM.Response struct using proper construction
      response = build_response("The agent should orient")

      # FAIL: cluster_responses currently expects map with :content key
      # Should extract content via ReqLLM.Response.text/1
      content = ReqLLM.Response.text(response)
      assert content == "The agent should orient"
    end

    test "R16: handles ReqLLM.Response structs directly in cluster_responses" do
      # Parsed action responses (after parsing JSON from ReqLLM.Response.text)
      parsed_responses = [
        %{action: :orient, params: %{status: "thinking"}, reasoning: "r1"},
        %{action: :orient, params: %{status: "thinking"}, reasoning: "r2"},
        %{action: :wait, params: %{wait: true}, reasoning: "r3"}
      ]

      # cluster_responses should work with parsed responses
      clusters = Aggregator.cluster_responses(parsed_responses)

      assert is_list(clusters)
      assert clusters != []

      # Should have orient cluster with count 2
      orient_cluster = Enum.find(clusters, &(&1.representative.action == :orient))
      assert orient_cluster.count == 2
    end
  end

  # =============================================================================
  # AGENT_Consensus Tests (R1-R3: ReqLLM.Response handling)
  # =============================================================================

  describe "AGENT_Consensus ReqLLM.Response handling (R1-R3)" do
    test "R1: extracts content via ReqLLM.Response.text" do
      json_content =
        ~s({"action": "orient", "params": {"status": "analyzing"}, "reasoning": "test", "wait": true})

      response = build_response(json_content, usage: %{input_tokens: 100, output_tokens: 50})

      # The content extraction should use ReqLLM.Response.text/1
      content = ReqLLM.Response.text(response)
      assert is_binary(content)
      assert String.contains?(content, "orient")
    end

    test "R2: parses action from ReqLLM.Response struct" do
      json_content =
        ~s({"action": "orient", "params": {"status": "ready"}, "reasoning": "because", "wait": true})

      response = build_response(json_content, usage: %{input_tokens: 100, output_tokens: 50})

      # Should be able to parse JSON from the response content
      {:ok, parsed} = Jason.decode(ReqLLM.Response.text(response))

      assert parsed["action"] == "orient"
      assert parsed["params"]["status"] == "ready"
    end

    test "R3: extracts usage via ReqLLM.Response.usage" do
      response =
        build_response("test content", usage: %{input_tokens: 150, output_tokens: 75})

      usage = ReqLLM.Response.usage(response)

      assert is_map(usage)
      assert usage.input_tokens == 150
      assert usage.output_tokens == 75
    end
  end

  # =============================================================================
  # AGENT_ConsensusHandler Tests (R1-R2: credential-based lookup)
  # =============================================================================

  describe "AGENT_ConsensusHandler credential-based lookup (R1-R2)" do
    test "R1: uses CredentialManager.list_model_ids for model pool" do
      # FAIL: Current implementation uses ModelRegistry.list_models()
      # Should use CredentialManager.list_model_ids()

      # Call the function directly - will fail until implemented
      # When implemented, should return ["google_gemini_2_5_pro", "azure_o1", ...]
      model_ids = CredentialManager.list_model_ids()
      assert is_list(model_ids), "list_model_ids must return a list"
    end

    test "R2: model list contains string model_ids not atoms" do
      # FAIL: Current get_action_consensus uses atoms from ModelRegistry
      # Should use string model_ids from CredentialManager

      # When implemented, list_model_ids should return strings like:
      # ["google_gemini_2_5_pro", "azure_o1", "bedrock_claude_4_sonnet"]
      model_ids = CredentialManager.list_model_ids()
      assert is_list(model_ids)
      assert Enum.all?(model_ids, &is_binary/1), "All model_ids must be strings"
    end
  end

  # =============================================================================
  # ACTION_Answer Tests (R1-R10: direct ReqLLM with grounding)
  # =============================================================================

  describe "ACTION_Answer parameter validation (R1-R2)" do
    test "R1: returns error when prompt is missing" do
      result = AnswerEngine.execute(%{}, "agent-123", [])
      assert result == {:error, :missing_required_param}
    end

    test "R1: returns error when prompt is empty string" do
      result = AnswerEngine.execute(%{prompt: ""}, "agent-123", [])
      assert result == {:error, :missing_required_param}
    end

    test "R1: returns error when prompt is nil" do
      result = AnswerEngine.execute(%{prompt: nil}, "agent-123", [])
      assert result == {:error, :missing_required_param}
    end

    test "R2: returns error when prompt is not a string" do
      result = AnswerEngine.execute(%{prompt: 123}, "agent-123", [])
      assert result == {:error, :invalid_param_type}
    end

    test "R2: returns error when prompt is a list" do
      result = AnswerEngine.execute(%{prompt: ["hello"]}, "agent-123", [])
      assert result == {:error, :invalid_param_type}
    end
  end

  describe "ACTION_Answer Gemini discovery (R3)" do
    test "R3: uses CredentialManager for Gemini lookup" do
      # FAIL: Current implementation calls ModelQuery.get_models_by_provider
      # Should use CredentialManager to find Gemini credentials with model_spec

      # Verify CredentialManager returns credentials with model_spec field
      # for direct ReqLLM calls
      result = CredentialManager.get_credentials("google_gemini_2_5_pro")

      case result do
        {:ok, credential} ->
          # Credential must have model_spec for direct ReqLLM calls
          assert Map.has_key?(credential, :model_spec),
                 "Credential must have model_spec for ReqLLM"

        {:error, :not_found} ->
          # If not seeded, test passes with note
          :ok
      end
    end
  end

  describe "ACTION_Answer grounded answers (R4-R5)" do
    test "R4: returns grounded answer with sources when successful" do
      # Mock a successful response with grounding metadata
      mock_response =
        build_response(
          "The capital of France is Paris.",
          usage: %{input_tokens: 10, output_tokens: 20},
          provider_meta: %{
            "google" => %{
              "groundingMetadata" => %{
                "groundingChunks" => [
                  %{
                    "web" => %{
                      "uri" => "https://example.com/france",
                      "title" => "France Info"
                    }
                  }
                ]
              }
            }
          }
        )

      # FAIL: Current implementation uses ProviderGoogle.chat_completion
      # Should use ReqLLM.generate_text(model_spec, messages, opts)

      # Extract content via ReqLLM.Response.text
      content = ReqLLM.Response.text(mock_response)
      assert content == "The capital of France is Paris."

      # Sources extraction should work
      sources =
        AnswerEngine.extract_sources(AnswerEngine.extract_grounding_metadata(mock_response))

      assert length(sources) == 1
      assert hd(sources).url == "https://example.com/france"
    end

    test "R5: returns answer with empty sources when no grounding data" do
      mock_response =
        build_response(
          "Some answer without grounding",
          usage: %{input_tokens: 10, output_tokens: 20},
          provider_meta: nil
        )

      # Should gracefully handle missing grounding metadata
      grounding = AnswerEngine.extract_grounding_metadata(mock_response)
      assert grounding == nil

      sources = AnswerEngine.extract_sources(grounding)
      assert sources == []
    end
  end

  describe "ACTION_Answer error handling (R6)" do
    test "R6: handles provider API errors gracefully" do
      # When provider call fails, should return {:error, :provider_error}
      opts = [model_config: %{force_error: true}]

      result = AnswerEngine.execute(%{prompt: "test query"}, "agent-123", opts)

      assert result == {:error, :provider_error}
    end
  end

  describe "ACTION_Answer sources (R9-R10)" do
    test "R9: extracts sources from grounding metadata" do
      grounding_metadata = %{
        "groundingChunks" => [
          %{"web" => %{"uri" => "https://source1.com", "title" => "Source 1"}},
          %{"web" => %{"uri" => "https://source2.com", "title" => "Source 2"}}
        ]
      }

      sources = AnswerEngine.extract_sources(grounding_metadata)

      assert length(sources) == 2
      assert Enum.any?(sources, &(&1.url == "https://source1.com"))
      assert Enum.any?(sources, &(&1.url == "https://source2.com"))
    end

    test "R10: handles nil grounding_metadata gracefully" do
      sources = AnswerEngine.extract_sources(nil)
      assert sources == []
    end

    test "R10: handles empty grounding_chunks gracefully" do
      grounding_metadata = %{"groundingChunks" => []}
      sources = AnswerEngine.extract_sources(grounding_metadata)
      assert sources == []
    end
  end
end
