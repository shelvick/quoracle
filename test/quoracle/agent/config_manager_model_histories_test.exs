defmodule Quoracle.Agent.ConfigManagerModelHistoriesTest do
  @moduledoc """
  Tests for AGENT_ConfigManager per-model histories initialization (Packet 2).
  WorkGroupID: feat-20251207-022443

  Tests R1-R7 from AGENT_ConfigManager_PerModelHistories.md spec.
  """
  # Use DataCase for R5 integration test (needs DB access)
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.ConfigManager
  alias Quoracle.Consensus.Manager

  describe "normalize_config/1 model_histories initialization (R1-R4, R6-R7)" do
    # R1: Initialize From Model Pool
    test "initializes model_histories from consensus model pool" do
      config = %{
        agent_id: "test-model-init",
        test_mode: true
      }

      normalized = ConfigManager.normalize_config(config)

      # Should have model_histories populated from model pool
      assert Map.has_key?(normalized, :model_histories)
      assert is_map(normalized.model_histories)

      # Should have 3 mock models from test_model_pool
      expected_models = Manager.test_model_pool()
      assert map_size(normalized.model_histories) == length(expected_models)
    end

    # R2: Empty History Lists
    test "each model starts with empty history list" do
      config = %{
        agent_id: "test-empty-histories",
        test_mode: true
      }

      normalized = ConfigManager.normalize_config(config)

      # Each model should have an empty list
      for {_model_id, history} <- normalized.model_histories do
        assert history == []
      end
    end

    # R3: Test Mode Isolation
    test "uses test model pool in test mode" do
      config = %{
        agent_id: "test-mode-pool",
        test_mode: true
      }

      normalized = ConfigManager.normalize_config(config)

      # Should use Manager.test_model_pool() models
      expected_models = Manager.test_model_pool()

      for model_id <- expected_models do
        assert Map.has_key?(normalized.model_histories, model_id),
               "Expected model #{model_id} in model_histories"
      end
    end

    # R4: Explicit Model Pool Injection
    test "uses explicit model_pool from config when provided" do
      custom_models = ["custom:model-a", "custom:model-b"]

      config = %{
        agent_id: "test-explicit-pool",
        model_pool: custom_models
      }

      normalized = ConfigManager.normalize_config(config)

      # Should use the explicit model_pool, not query Manager
      assert map_size(normalized.model_histories) == 2
      assert Map.has_key?(normalized.model_histories, "custom:model-a")
      assert Map.has_key?(normalized.model_histories, "custom:model-b")
    end

    # R6: Preserves Other Config Fields
    test "preserves all existing config fields" do
      config = %{
        agent_id: "test-preserve-fields",
        parent_pid: self(),
        task: "Test task",
        model_id: "test-model",
        test_mode: true,
        profile_name: "test-profile"
      }

      normalized = ConfigManager.normalize_config(config)

      # All original fields should be preserved
      assert normalized.agent_id == "test-preserve-fields"
      assert normalized.parent_pid == self()
      assert normalized.task == "Test task"
      assert normalized.model_id == "test-model"
      assert normalized.test_mode == true
      assert normalized.profile_name == "test-profile"

      # And model_histories should also be present
      assert Map.has_key?(normalized, :model_histories)
    end

    # R7: Model Pool Order Preserved
    test "all models from pool present in model_histories" do
      expected_models = Manager.test_model_pool()

      config = %{
        agent_id: "test-all-models",
        test_mode: true
      }

      normalized = ConfigManager.normalize_config(config)

      # All models from pool should be present
      for model_id <- expected_models do
        assert Map.has_key?(normalized.model_histories, model_id),
               "Model #{model_id} missing from model_histories"
      end

      # No extra models
      assert map_size(normalized.model_histories) == length(expected_models)
    end

    # Edge case: explicit empty model_pool
    test "handles empty explicit model_pool" do
      config = %{
        agent_id: "test-empty-pool",
        model_pool: []
      }

      normalized = ConfigManager.normalize_config(config)

      # Should have empty model_histories map
      assert normalized.model_histories == %{}
    end

    # Edge case: single model in pool
    test "handles single model in pool" do
      config = %{
        agent_id: "test-single-model",
        model_pool: ["single:model"]
      }

      normalized = ConfigManager.normalize_config(config)

      assert map_size(normalized.model_histories) == 1
      assert Map.has_key?(normalized.model_histories, "single:model")
      assert normalized.model_histories["single:model"] == []
    end

    # Tuple config format (legacy test format)
    test "initializes model_histories for tuple config with test_mode" do
      config = {self(), "test prompt", [test_mode: true]}

      normalized = ConfigManager.normalize_config(config)

      # Should have model_histories from test pool
      assert Map.has_key?(normalized, :model_histories)
      assert is_map(normalized.model_histories)
    end

    # Tuple config with explicit model_pool
    test "initializes model_histories for tuple config with explicit pool" do
      custom_models = ["tuple:model-1", "tuple:model-2"]
      config = {self(), "test prompt", [model_pool: custom_models]}

      normalized = ConfigManager.normalize_config(config)

      assert Map.has_key?(normalized, :model_histories)
      assert map_size(normalized.model_histories) == 2
      assert Map.has_key?(normalized.model_histories, "tuple:model-1")
    end
  end

  describe "normalize_config/1 production mode (R5)" do
    # R5: Production Model Pool
    # Note: This is an INTEGRATION test that would query the database
    # In unit tests, we verify the path is taken but mock the DB query

    test "queries model pool from config in production mode" do
      # Without test_mode and without explicit model_pool,
      # normalize_config should query Manager.get_model_pool()
      # This will raise because model_pool must be provided via opts (profile required)
      config = %{
        agent_id: "test-production-mode",
        test_mode: false
        # No model_pool - should raise (profile is required)
      }

      # In production mode without model_pool, Manager.get_model_pool raises
      # So normalize_config should propagate this error
      assert_raise RuntimeError, ~r/model_pool not provided.*Profile is required/, fn ->
        ConfigManager.normalize_config(config)
      end
    end
  end
end
