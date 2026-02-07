defmodule Quoracle.Agent.CoreStateProfileTest do
  @moduledoc """
  Tests for AGENT_Core v24.0 - Profile state storage.

  ARC Requirements (v24.0):
  - R48: Profile fields in State struct
  - R49: Profile loaded from config

  ARC Requirements (v26.0 - capability_groups):
  - R57: capability_groups Field Exists [UNIT]
  - R58: capability_groups Default Empty List [UNIT]
  - R59: capability_groups From Config [UNIT]
  - R60: capability_groups Type [UNIT]

  WorkGroupID: fix-20260108-profile-injection
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.Core.State

  describe "profile fields in State struct" do
    # R48: Profile Fields in State
    test "state struct includes profile fields" do
      # Create minimal state with required fields
      state = %State{
        agent_id: "test-agent",
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub
      }

      # Verify profile fields exist and have correct defaults
      assert Map.has_key?(state, :profile_name)
      assert Map.has_key?(state, :profile_description)
      assert Map.has_key?(state, :model_pool)
      assert Map.has_key?(state, :capability_groups)
    end

    test "profile_name defaults to nil" do
      state = %State{
        agent_id: "test-agent",
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub
      }

      assert state.profile_name == nil
    end

    test "profile_description defaults to nil" do
      state = %State{
        agent_id: "test-agent",
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub
      }

      assert state.profile_description == nil
    end

    # NOTE: model_pool must default to nil (not []) to allow test_mode fallback
    # in ConsensusHandler. An empty list [] would be treated as explicit empty pool.
    test "model_pool defaults to nil (allows test_mode fallback)" do
      state = %State{
        agent_id: "test-agent",
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub
      }

      assert state.model_pool == nil
    end

    test "state accepts profile fields during creation" do
      # Create base state and add profile fields via Map.put
      # (avoids compile error when fields don't exist yet)
      base_state = %State{
        agent_id: "test-agent",
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub
      }

      # These assertions will fail until profile fields are added to State
      state =
        base_state
        |> Map.put(:profile_name, "custom-profile")
        |> Map.put(:profile_description, "A custom profile for testing")
        |> Map.put(:model_pool, ["gpt-4o", "claude-opus"])
        |> Map.put(:capability_groups, [:hierarchy, :file_read])

      # Verify fields were set (Map.put succeeds even for non-struct keys,
      # but the key existence checks above will fail if fields don't exist)
      assert state.profile_name == "custom-profile"
      assert state.profile_description == "A custom profile for testing"
      assert state.model_pool == ["gpt-4o", "claude-opus"]
      assert state.capability_groups == [:hierarchy, :file_read]
    end
  end

  describe "profile fields type validation" do
    test "model_pool accepts list of strings" do
      base_state = %State{
        agent_id: "test-agent",
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub
      }

      state = Map.put(base_state, :model_pool, ["model-a", "model-b", "model-c"])

      assert length(state.model_pool) == 3
      assert Enum.all?(state.model_pool, &is_binary/1)
    end
  end

  # ==========================================================================
  # v26.0 - capability_groups field (R57-R60)
  # ==========================================================================

  describe "capability_groups field (R57-R60)" do
    # R57: capability_groups Field Exists
    test "State struct has capability_groups field" do
      # UNIT: WHEN Core.State struct defined THEN has :capability_groups field
      state = %State{
        agent_id: "test-agent",
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub
      }

      assert Map.has_key?(state, :capability_groups),
             "State struct must have :capability_groups field"
    end

    # R58: capability_groups Default Empty List
    test "capability_groups defaults to empty list" do
      # UNIT: WHEN State.new called without capability_groups THEN defaults to []
      config = %{
        agent_id: "test-agent",
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub
        # No capability_groups provided
      }

      state = State.new(config)

      assert state.capability_groups == [],
             "capability_groups should default to empty list"
    end

    # R59: capability_groups From Config
    test "capability_groups populated from config" do
      # UNIT: WHEN config has capability_groups THEN stored in state
      config = %{
        agent_id: "test-agent",
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub,
        capability_groups: [:hierarchy, :file_read, :external_api]
      }

      state = State.new(config)

      assert state.capability_groups == [:hierarchy, :file_read, :external_api],
             "capability_groups should be populated from config"
    end

    # R60: capability_groups Type
    test "capability_groups is list of atoms" do
      # UNIT: WHEN capability_groups set THEN is list of atoms
      config = %{
        agent_id: "test-agent",
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub,
        capability_groups: [:web_access, :code_execution, :spawn_agents]
      }

      state = State.new(config)

      assert is_list(state.capability_groups), "capability_groups must be a list"

      assert Enum.all?(state.capability_groups, &is_atom/1),
             "All capability_groups entries must be atoms"
    end
  end
end
