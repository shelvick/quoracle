defmodule Quoracle.Models.ConfigModelSettingsTest do
  @moduledoc """
  Tests for CONFIG_ModelSettings business logic functions.

  Note: Simple getters/setters (get_embedding_model, set_embedding_model, etc.)
  are thin wrappers over TableConsensusConfig and don't need separate coverage.
  Only functions with business logic are tested here:
  - configured?/0: Checks all 3 required settings are present
  - get_all/0: Aggregates all settings into a map
  - validate_model_pool/1: Validates model IDs against credentials
  - set_image_generation_models/1: Input validation for model list
  """

  # Ecto.Sandbox provides transaction isolation per test
  use Quoracle.DataCase, async: true

  alias Quoracle.Models.ConfigModelSettings
  alias Quoracle.Models.TableConsensusConfig
  alias Quoracle.Models.TableCredentials

  describe "configured?/0" do
    # R8: WHEN all settings configured THEN configured? returns true
    test "returns true when all required settings present" do
      {:ok, _} =
        TableConsensusConfig.upsert("embedding_model", %{"model_id" => "embed"})

      {:ok, _} =
        TableConsensusConfig.upsert("answer_engine_model", %{"model_id" => "answer"})

      {:ok, _} =
        TableConsensusConfig.upsert("summarization_model", %{"model_id" => "summarize"})

      assert ConfigModelSettings.configured?() == true
    end

    # R9: WHEN any setting missing THEN configured? returns false
    test "returns false when any setting missing" do
      # Only configure one setting
      {:ok, _} =
        TableConsensusConfig.upsert("embedding_model", %{"model_id" => "embed"})

      assert ConfigModelSettings.configured?() == false
    end

    # R10: WHEN summarization_model not set THEN configured? returns false
    test "returns false when summarization_model missing" do
      {:ok, _} =
        TableConsensusConfig.upsert("embedding_model", %{"model_id" => "embed"})

      {:ok, _} =
        TableConsensusConfig.upsert("answer_engine_model", %{"model_id" => "answer"})

      # Note: summarization_model NOT configured
      assert ConfigModelSettings.configured?() == false
    end
  end

  describe "get_all/0" do
    test "returns map with all configured settings" do
      {:ok, _} =
        TableConsensusConfig.upsert("embedding_model", %{"model_id" => "embed-model"})

      {:ok, _} =
        TableConsensusConfig.upsert("answer_engine_model", %{"model_id" => "answer-model"})

      {:ok, _} =
        TableConsensusConfig.upsert("summarization_model", %{"model_id" => "sum-model"})

      result = ConfigModelSettings.get_all()

      assert result.embedding_model == "embed-model"
      assert result.answer_engine_model == "answer-model"
      assert result.summarization_model == "sum-model"
    end

    test "returns nil for unconfigured settings" do
      result = ConfigModelSettings.get_all()

      assert result.embedding_model == nil
      assert result.answer_engine_model == nil
      assert result.summarization_model == nil
    end
  end

  describe "set_image_generation_models/1" do
    test "rejects non-string elements" do
      assert {:error, :invalid_model_ids} =
               ConfigModelSettings.set_image_generation_models([123, :atom])
    end
  end

  describe "validate_model_pool/1" do
    # R27: WHEN all model IDs exist in credentials THEN returns :ok
    test "returns :ok for valid models" do
      {:ok, _} =
        TableCredentials.insert(%{
          model_id: "valid-model-a",
          model_spec: "test:model-a",
          api_key: "key-a"
        })

      {:ok, _} =
        TableCredentials.insert(%{
          model_id: "valid-model-b",
          model_spec: "test:model-b",
          api_key: "key-b"
        })

      assert :ok = ConfigModelSettings.validate_model_pool(["valid-model-a", "valid-model-b"])
    end

    # R28: WHEN any model_id not in credentials THEN returns {:error, :invalid_models}
    test "returns error for invalid model" do
      assert {:error, :invalid_models} =
               ConfigModelSettings.validate_model_pool(["nonexistent/fake-model"])
    end

    # R29: WHEN model_pool is empty THEN returns {:error, :invalid_models}
    test "returns error for empty pool" do
      assert {:error, :invalid_models} = ConfigModelSettings.validate_model_pool([])
    end

    # R30: WHEN pool contains mix of valid and invalid THEN returns {:error, :invalid_models}
    test "returns error when any model invalid" do
      {:ok, _} =
        TableCredentials.insert(%{
          model_id: "mixed-valid",
          model_spec: "test:valid",
          api_key: "key-valid"
        })

      assert {:error, :invalid_models} =
               ConfigModelSettings.validate_model_pool(["mixed-valid", "mixed-invalid"])
    end
  end
end
