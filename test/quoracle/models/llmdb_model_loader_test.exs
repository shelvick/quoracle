defmodule Quoracle.Models.LLMDBModelLoaderTest do
  @moduledoc """
  Tests for LLMDB_ModelLoader - Helper module to query LLMDB and format for UI.

  ARC Verification Criteria:
  - R1-R4: Model Listing
  - R5-R6: Availability
  - R7-R9: Formatting
  - R10-R13: Image Generation Models Filter - NEW v1.2
  """

  use ExUnit.Case, async: true

  alias Quoracle.Models.LLMDBModelLoader

  # Fixture models for testing
  defp fixture_models do
    [
      %LLMDB.Model{
        id: "gpt-4o",
        provider: :openai,
        name: "GPT-4o",
        capabilities: %{chat: true, embeddings: false}
      },
      %LLMDB.Model{
        id: "gpt-4o-mini",
        provider: :openai,
        name: "GPT-4o Mini",
        capabilities: %{chat: true, embeddings: false}
      },
      %LLMDB.Model{
        id: "text-embedding-3-small",
        provider: :openai,
        name: "Text Embedding 3 Small",
        capabilities: %{chat: false, embeddings: %{default_dimensions: 1536}}
      },
      %LLMDB.Model{
        id: "claude-3-5-sonnet",
        provider: :anthropic,
        name: "Claude 3.5 Sonnet",
        capabilities: %{chat: true, embeddings: false}
      },
      %LLMDB.Model{
        id: "gemini-1.5-pro",
        provider: :google,
        name: "Gemini 1.5 Pro",
        capabilities: %{chat: true, embeddings: false}
      },
      %LLMDB.Model{
        id: "text-embedding-004",
        provider: :google,
        name: "Text Embedding 004",
        capabilities: %{chat: false, embeddings: %{default_dimensions: 768}}
      }
    ]
  end

  describe "all_models/1" do
    # R1: WHEN all_models called IF LLMDB loaded THEN returns list of {label, spec} tuples
    test "returns formatted tuples when LLMDB has models" do
      models = fixture_models()

      result = LLMDBModelLoader.all_models(models)

      assert is_list(result)
      assert length(result) == 6

      # Each tuple should be {label, spec}
      Enum.each(result, fn {label, spec} ->
        assert is_binary(label)
        assert is_binary(spec)
        assert String.contains?(spec, ":")
      end)
    end

    test "returns empty list when no models" do
      result = LLMDBModelLoader.all_models([])

      assert result == []
    end
  end

  describe "chat_models/1" do
    # R2: WHEN chat_models called THEN returns only models with chat: true capability
    test "excludes embedding-only models" do
      models = fixture_models()

      result = LLMDBModelLoader.chat_models(models)

      # Should have 4 chat models (gpt-4o, gpt-4o-mini, claude-3-5-sonnet, gemini-1.5-pro)
      assert length(result) == 4

      # Verify no embedding-only models
      specs = Enum.map(result, fn {_label, spec} -> spec end)
      refute "openai:text-embedding-3-small" in specs
      refute "google:text-embedding-004" in specs

      # Verify chat models are included
      assert "openai:gpt-4o" in specs
      assert "anthropic:claude-3-5-sonnet" in specs
    end
  end

  describe "embedding_models/1" do
    # R3: WHEN embedding_models called THEN returns only models with embeddings capability
    test "returns only embedding-capable models" do
      models = fixture_models()

      result = LLMDBModelLoader.embedding_models(models)

      # Should have 2 embedding models
      assert length(result) == 2

      specs = Enum.map(result, fn {_label, spec} -> spec end)
      assert "openai:text-embedding-3-small" in specs
      assert "google:text-embedding-004" in specs

      # Verify no chat-only models
      refute "openai:gpt-4o" in specs
      refute "anthropic:claude-3-5-sonnet" in specs
    end
  end

  describe "models_by_provider/1" do
    # R4: WHEN models_by_provider called THEN returns map keyed by provider name
    test "groups by provider" do
      models = fixture_models()

      result = LLMDBModelLoader.models_by_provider(models)

      assert is_map(result)
      assert Map.has_key?(result, "Openai")
      assert Map.has_key?(result, "Anthropic")
      assert Map.has_key?(result, "Google")

      # OpenAI should have 3 models
      assert length(result["Openai"]) == 3

      # Anthropic should have 1 model
      assert length(result["Anthropic"]) == 1

      # Google should have 2 models
      assert length(result["Google"]) == 2
    end
  end

  describe "available?/1" do
    # R5: WHEN LLMDB has models THEN available? returns true
    test "returns true when models exist" do
      assert LLMDBModelLoader.available?(fixture_models()) == true
    end

    # R6: WHEN LLMDB empty THEN available? returns false
    test "returns false when no models" do
      assert LLMDBModelLoader.available?([]) == false
    end
  end

  describe "formatting" do
    # R7: WHEN model formatted THEN spec is "provider:model_id" format
    test "format_model produces valid model_spec string" do
      model = %LLMDB.Model{
        id: "gpt-4o",
        provider: :openai,
        name: "GPT-4o",
        capabilities: %{chat: true}
      }

      {_label, spec} = LLMDBModelLoader.format_model(model)

      assert spec == "openai:gpt-4o"
    end

    # R8: WHEN model formatted THEN label is "Provider: Model Name"
    test "format_model produces human-readable label" do
      model = %LLMDB.Model{
        id: "gpt-4o",
        provider: :openai,
        name: "GPT-4o",
        capabilities: %{chat: true}
      }

      {label, _spec} = LLMDBModelLoader.format_model(model)

      assert label == "Openai: GPT-4o"
    end

    test "format_model uses id when name is nil" do
      model = %LLMDB.Model{
        id: "some-model",
        provider: :azure_openai,
        name: nil,
        capabilities: %{chat: true}
      }

      {label, _spec} = LLMDBModelLoader.format_model(model)

      assert label == "Azure Openai: some-model"
    end
  end

  describe "sorting" do
    # R9: WHEN models returned THEN sorted alphabetically by label
    test "models are sorted alphabetically" do
      models = fixture_models()

      result = LLMDBModelLoader.all_models(models)

      labels = Enum.map(result, fn {label, _spec} -> label end)

      assert labels == Enum.sort(labels)
    end

    test "chat_models are sorted alphabetically" do
      models = fixture_models()

      result = LLMDBModelLoader.chat_models(models)

      labels = Enum.map(result, fn {label, _spec} -> label end)

      assert labels == Enum.sort(labels)
    end

    test "embedding_models are sorted alphabetically" do
      models = fixture_models()

      result = LLMDBModelLoader.embedding_models(models)

      labels = Enum.map(result, fn {label, _spec} -> label end)

      assert labels == Enum.sort(labels)
    end
  end

  # =============================================================
  # Image Generation Models Filter (R10-R13) - NEW v1.2
  # =============================================================

  # Fixture with image-capable models for testing
  defp fixture_models_with_images do
    [
      # Chat-only model (no image capability)
      %LLMDB.Model{
        id: "gpt-4o",
        provider: :openai,
        name: "GPT-4o",
        capabilities: %{chat: true, embeddings: false}
      },
      # Image model with explicit capability
      %LLMDB.Model{
        id: "dall-e-3",
        provider: :openai,
        name: "DALL-E 3",
        capabilities: %{chat: false, images: true}
      },
      # Image model detected by name heuristic
      %LLMDB.Model{
        id: "imagen-3",
        provider: :google,
        name: "Imagen 3",
        capabilities: %{chat: false}
      },
      # Embedding-only model (no image capability)
      %LLMDB.Model{
        id: "text-embedding-3-small",
        provider: :openai,
        name: "Text Embedding 3 Small",
        capabilities: %{chat: false, embeddings: %{default_dimensions: 1536}}
      },
      # Another chat model
      %LLMDB.Model{
        id: "claude-3-5-sonnet",
        provider: :anthropic,
        name: "Claude 3.5 Sonnet",
        capabilities: %{chat: true, embeddings: false}
      }
    ]
  end

  describe "image_generation_models/1" do
    # R10: WHEN image_generation_models called THEN returns only image-capable models
    test "returns only image-capable models" do
      models = fixture_models_with_images()

      result = LLMDBModelLoader.image_generation_models(models)

      # Should include models with images: true or name heuristic
      specs = Enum.map(result, fn {_label, spec} -> spec end)

      # DALL-E 3 has images: true capability
      assert "openai:dall-e-3" in specs

      # Imagen 3 matches name heuristic
      assert "google:imagen-3" in specs

      # Chat-only and embedding-only should be excluded
      refute "openai:gpt-4o" in specs
      refute "openai:text-embedding-3-small" in specs
      refute "anthropic:claude-3-5-sonnet" in specs
    end

    # R11: WHEN no image-capable models THEN image_generation_models returns empty list
    test "returns empty list when no image models" do
      # Only chat and embedding models, no image models
      models = [
        %LLMDB.Model{
          id: "gpt-4o",
          provider: :openai,
          name: "GPT-4o",
          capabilities: %{chat: true}
        },
        %LLMDB.Model{
          id: "text-embedding-3-small",
          provider: :openai,
          name: "Text Embedding 3 Small",
          capabilities: %{embeddings: %{default_dimensions: 1536}}
        }
      ]

      result = LLMDBModelLoader.image_generation_models(models)

      assert result == []
    end

    # R12: WHEN model in ReqLLM.Images.supported_models THEN included in results
    test "includes ReqLLM supported models" do
      # Model that's in ReqLLM.Images.supported_models() but without explicit capability
      # ReqLLM.Images.supported_models/0 includes "openai:dall-e-3"
      models = [
        %LLMDB.Model{
          id: "dall-e-3",
          provider: :openai,
          name: "DALL-E 3",
          # Note: no images capability in LLMDB metadata
          capabilities: %{chat: false}
        }
      ]

      result = LLMDBModelLoader.image_generation_models(models)

      specs = Enum.map(result, fn {_label, spec} -> spec end)
      assert "openai:dall-e-3" in specs
    end

    # R13: WHEN model name contains 'image' or 'dall-e' THEN included in results
    test "uses name heuristic as fallback" do
      models = [
        # Model with "image" in name
        %LLMDB.Model{
          id: "custom-image-gen",
          provider: :custom,
          name: "Custom Image Generator",
          capabilities: %{}
        },
        # Model with "imagen" in id
        %LLMDB.Model{
          id: "imagen-3-fast",
          provider: :google,
          name: "Imagen 3 Fast",
          capabilities: %{}
        },
        # Model with "dall-e" in id
        %LLMDB.Model{
          id: "dall-e-2",
          provider: :openai,
          name: "DALL-E 2",
          capabilities: %{}
        },
        # Model without any image indicators
        %LLMDB.Model{
          id: "gpt-4",
          provider: :openai,
          name: "GPT-4",
          capabilities: %{chat: true}
        }
      ]

      result = LLMDBModelLoader.image_generation_models(models)

      specs = Enum.map(result, fn {_label, spec} -> spec end)

      # All image-related models should be included via heuristic
      assert "custom:custom-image-gen" in specs
      assert "google:imagen-3-fast" in specs
      assert "openai:dall-e-2" in specs

      # Non-image model should be excluded
      refute "openai:gpt-4" in specs
    end

    test "image_generation_models are sorted alphabetically" do
      models = fixture_models_with_images()

      result = LLMDBModelLoader.image_generation_models(models)

      labels = Enum.map(result, fn {label, _spec} -> label end)

      assert labels == Enum.sort(labels)
    end
  end
end
