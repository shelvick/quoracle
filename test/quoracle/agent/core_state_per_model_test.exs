defmodule Quoracle.Agent.Core.StatePerModelTest do
  @moduledoc """
  Tests for AGENT_Core per-model histories (Packet 1).
  WorkGroupID: feat-20251207-022443

  Tests R1-R4 from AGENT_Core_PerModelHistories.md spec.
  (R5-R6 are INTEGRATION tests for persistence, covered in later packet)
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.Core.State

  # Helper to create a minimal state struct
  defp create_test_state do
    State.new(%{
      agent_id: "test-agent",
      registry: :test_registry,
      dynsup: self(),
      pubsub: :test_pubsub
    })
  end

  describe "model_histories field (R1-R4)" do
    # R1: Model Histories Field Exists
    test "state struct has model_histories field defaulting to empty map" do
      state = create_test_state()

      # Field must exist
      assert Map.has_key?(state, :model_histories),
             "State struct must have :model_histories field"

      # Default must be empty map
      assert state.model_histories == %{},
             "model_histories must default to empty map"
    end

    # R2: Model Histories Is Map
    test "model_histories field is a map" do
      state = create_test_state()

      assert is_map(state.model_histories),
             "model_histories must be a map type"
    end

    # R3: Conversation History Removed
    test "conversation_history field is removed from state struct" do
      state = create_test_state()

      # The struct should NOT have conversation_history field
      refute Map.has_key?(state, :conversation_history),
             "conversation_history field must be removed from State struct"
    end

    # R4: History Entry Structure Preserved
    test "history entries preserve existing structure within model_histories" do
      entry = %{
        type: :user,
        content: "test message",
        timestamp: DateTime.utc_now()
      }

      # Create state with model_histories containing an entry
      # This requires model_histories to be a valid struct field
      state =
        State.new(%{
          agent_id: "test-agent",
          registry: :test_registry,
          dynsup: self(),
          pubsub: :test_pubsub,
          model_histories: %{
            "anthropic:claude-sonnet-4" => [entry]
          }
        })

      # Verify the entry structure is preserved
      assert Map.has_key?(state, :model_histories),
             "model_histories field must exist in struct"

      [stored_entry] = state.model_histories["anthropic:claude-sonnet-4"]
      assert stored_entry.type == :user
      assert stored_entry.content == "test message"
      assert %DateTime{} = stored_entry.timestamp
    end
  end

  describe "State.new/1 with model_histories" do
    test "new/1 initializes model_histories from config" do
      config = %{
        agent_id: "test-agent",
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub,
        model_histories: %{
          "model-a" => [],
          "model-b" => []
        }
      }

      state = State.new(config)

      assert Map.has_key?(state, :model_histories),
             "State.new/1 must support model_histories in config"

      assert state.model_histories == %{"model-a" => [], "model-b" => []},
             "State.new/1 must preserve model_histories from config"
    end

    test "new/1 defaults model_histories to empty map when not provided" do
      config = %{
        agent_id: "test-agent",
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub
      }

      state = State.new(config)

      assert Map.has_key?(state, :model_histories),
             "model_histories field must exist even when not in config"

      assert state.model_histories == %{},
             "model_histories must default to empty map"
    end

    test "new/1 does not initialize conversation_history" do
      config = %{
        agent_id: "test-agent",
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub
      }

      state = State.new(config)

      # conversation_history should not be a field
      refute Map.has_key?(state, :conversation_history),
             "conversation_history must not exist in new state"
    end
  end
end
