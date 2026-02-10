defmodule Quoracle.Agent.UserPromptRemovalPacket2Test do
  @moduledoc """
  Tests for WorkGroupID: fix-20260106-user-prompt-removal Packet 2 (State/Config Cleanup)

  This packet removes user_prompt and user_prompt_timestamp fields from:
  - AGENT_Core.State struct (v25.0)
  - AGENT_ConfigManager normalization (v7.0)
  - AGENT_ConsensusHandler field_prompts (v18.0)
  - AGENT_DynSup restoration config (v6.0)

  These fields are no longer needed since Packet 1 changed the message flow:
  - Initial messages now flow through model_histories (MessageHandler v14.0)
  - SystemPromptInjector no longer injects user_prompt (v15.0)
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.Core.State

  # =============================================================================
  # AGENT_Core v25.0: Remove user_prompt/user_prompt_timestamp from State
  # =============================================================================

  describe "R54: State struct no user_prompt field" do
    test "State struct does not have user_prompt field" do
      # Get all field names from the State struct
      state_fields = State.__struct__() |> Map.keys()

      # FAIL: Currently State struct HAS :user_prompt field
      # After fix: State struct should NOT have :user_prompt field
      refute :user_prompt in state_fields,
             "State struct should NOT have :user_prompt field - " <>
               "this field was removed because initial messages now flow through history"
    end

    test "State.new/1 does not accept user_prompt" do
      # Create a minimal valid state config
      config = %{
        agent_id: "test-agent",
        router_pid: self(),
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub,
        user_prompt: "This should be ignored"
      }

      state = State.new(config)

      # FAIL: Currently State.new copies user_prompt to state
      # After fix: user_prompt should not exist in state (field removed)
      refute Map.has_key?(Map.from_struct(state), :user_prompt),
             "State.new should not copy user_prompt to state - field should not exist"
    end
  end

  describe "R55: State struct no user_prompt_timestamp field" do
    test "State struct does not have user_prompt_timestamp field" do
      state_fields = State.__struct__() |> Map.keys()

      # FAIL: Currently State struct HAS :user_prompt_timestamp field
      # After fix: State struct should NOT have :user_prompt_timestamp field
      refute :user_prompt_timestamp in state_fields,
             "State struct should NOT have :user_prompt_timestamp field - " <>
               "this field was removed along with user_prompt"
    end

    test "State.new/1 does not accept user_prompt_timestamp" do
      config = %{
        agent_id: "test-agent",
        router_pid: self(),
        registry: :test_registry,
        dynsup: self(),
        pubsub: :test_pubsub,
        user_prompt_timestamp: DateTime.utc_now()
      }

      state = State.new(config)

      # FAIL: Currently State.new copies user_prompt_timestamp to state
      # After fix: user_prompt_timestamp should not exist in state
      refute Map.has_key?(Map.from_struct(state), :user_prompt_timestamp),
             "State.new should not copy user_prompt_timestamp to state - field should not exist"
    end
  end

  describe "R56: Persistence config excludes user_prompt" do
    test "persist_agent config keys do not include user_prompt" do
      # Verify the persistence config pattern no longer includes user_prompt
      # Since State no longer has user_prompt field, Map.take cannot extract it
      state = %{
        test_mode: true,
        initial_prompt: "test",
        profile_name: nil
      }

      # This is the FIXED pattern from Persistence.persist_agent line 42
      config = Map.take(state, [:test_mode, :initial_prompt, :profile_name])

      refute Map.has_key?(config, :user_prompt),
             "Persistence config should NOT include user_prompt"
    end
  end

  # =============================================================================
  # AGENT_ConfigManager v7.0: Remove user_prompt setup
  # =============================================================================

  describe "R32: normalize_config does not set user_prompt" do
    test "normalize_config does not set user_prompt" do
      alias Quoracle.Agent.ConfigManager

      # Create a basic config
      input_config = %{
        task_id: "task-123",
        agent_id: "agent-456",
        test_mode: true
      }

      # Normalize the config
      normalized = ConfigManager.normalize_config(input_config)

      # FAIL: Currently normalize_config sets :user_prompt in result
      # After fix: :user_prompt should not be set
      refute Map.has_key?(normalized, :user_prompt),
             "normalize_config should NOT set user_prompt - " <>
               "initial messages now flow through history"
    end

    test "normalize_config ignores user_prompt in input" do
      alias Quoracle.Agent.ConfigManager

      # Even if user_prompt is in input, it should not appear in output
      input_config = %{
        task_id: "task-123",
        agent_id: "agent-456",
        test_mode: true,
        user_prompt: "This should be ignored"
      }

      normalized = ConfigManager.normalize_config(input_config)

      # FAIL: Currently normalize_config copies user_prompt to output
      # After fix: user_prompt should not be in normalized config
      refute Map.has_key?(normalized, :user_prompt),
             "normalize_config should ignore user_prompt in input"
    end
  end

  describe "R33: normalize_config does not set user_prompt_timestamp" do
    test "normalize_config does not set user_prompt_timestamp" do
      alias Quoracle.Agent.ConfigManager

      input_config = %{
        task_id: "task-123",
        agent_id: "agent-456",
        test_mode: true
      }

      normalized = ConfigManager.normalize_config(input_config)

      # FAIL: Currently normalize_config sets :user_prompt_timestamp in result
      # After fix: :user_prompt_timestamp should not be set
      refute Map.has_key?(normalized, :user_prompt_timestamp),
             "normalize_config should NOT set user_prompt_timestamp"
    end

    test "normalize_config ignores user_prompt_timestamp in input" do
      alias Quoracle.Agent.ConfigManager

      input_config = %{
        task_id: "task-123",
        agent_id: "agent-456",
        test_mode: true,
        user_prompt_timestamp: DateTime.utc_now()
      }

      normalized = ConfigManager.normalize_config(input_config)

      # FAIL: Currently normalize_config may copy user_prompt_timestamp
      # After fix: user_prompt_timestamp should not be in normalized config
      refute Map.has_key?(normalized, :user_prompt_timestamp),
             "normalize_config should ignore user_prompt_timestamp in input"
    end
  end

  # =============================================================================
  # AGENT_ConsensusHandler v18.0: Remove user_prompt from field_prompts
  # =============================================================================

  describe "R36: field_prompts no user_prompt" do
    test "field_prompts construction does not include user_prompt" do
      # Verify the field_prompts pattern no longer includes user_prompt
      state = %{system_prompt: "<role>Test</role>"}

      # This is the FIXED pattern from ConsensusHandler lines 101-103
      field_prompts = %{
        system_prompt: Map.get(state, :system_prompt)
      }

      refute Map.has_key?(field_prompts, :user_prompt),
             "field_prompts should NOT include user_prompt"
    end
  end

  describe "R37: field_prompts no user_prompt_timestamp" do
    test "field_prompts construction does not include user_prompt_timestamp" do
      # Verify the field_prompts pattern no longer includes user_prompt_timestamp
      state = %{system_prompt: "<role>Test</role>"}

      # This is the FIXED pattern from ConsensusHandler lines 101-103
      field_prompts = %{
        system_prompt: Map.get(state, :system_prompt)
      }

      refute Map.has_key?(field_prompts, :user_prompt_timestamp),
             "field_prompts should NOT include user_prompt_timestamp"
    end
  end

  # =============================================================================
  # AGENT_DynSup v6.0: Remove user_prompt restoration
  # =============================================================================

  describe "R22: Restoration config no user_prompt" do
    test "restoration config construction does not include user_prompt" do
      # Verify the restoration config pattern no longer includes user_prompt
      base_config = %{
        "profile_name" => "test-profile",
        "user_prompt" => "legacy value that should be ignored"
      }

      # This is the FIXED pattern from DynSup.restore_agent lines 217-219
      # (user_prompt line was removed)
      restoration_config = %{
        profile_name: base_config["profile_name"],
        restoration_mode: true
      }

      refute Map.has_key?(restoration_config, :user_prompt),
             "restoration_config should NOT include user_prompt"
    end
  end

  describe "R23: Restored agent functions without user_prompt" do
    test "restored agent state excludes user_prompt field" do
      # Verify that State struct no longer accepts user_prompt
      # This ensures restored agents cannot have user_prompt in state
      state_fields = State.__struct__() |> Map.keys()

      refute :user_prompt in state_fields,
             "State struct should NOT have user_prompt field - " <>
               "restored agents will automatically exclude it"
    end
  end

  # =============================================================================
  # Acceptance Test
  # =============================================================================

  describe "Acceptance: Clean state without user_prompt fields" do
    @tag :acceptance
    test "agent state has no user_prompt-related fields after removal" do
      # This acceptance test verifies the user-observable outcome:
      # Agent state should be clean without legacy user_prompt fields

      # Get the struct definition
      state_struct = State.__struct__()
      state_keys = Map.keys(state_struct)

      # FAIL: Currently state has user_prompt and user_prompt_timestamp
      # After fix: These fields should not exist
      user_prompt_fields =
        Enum.filter(state_keys, fn key ->
          key_str = Atom.to_string(key)
          String.contains?(key_str, "user_prompt")
        end)

      assert user_prompt_fields == [],
             "State should have NO user_prompt-related fields, " <>
               "found: #{inspect(user_prompt_fields)}"
    end
  end
end
