defmodule Quoracle.Agent.InitialPromptConsensusTest do
  @moduledoc """
  Tests for initial prompt flow in consensus.

  HISTORY: This file previously tested a bug where user_prompt injection was needed
  because skip_initial_prompt logic prevented messages from being added to history.

  FIX (v14.0, WorkGroupID: fix-20260106-user-prompt-removal):
  - Removed skip_initial_prompt logic from MessageHandler
  - Initial message now flows through history like all other messages
  - Removed user_prompt injection from SystemPromptInjector (no longer needed)

  Tests R1-R2 were deleted because they tested the old workaround (user_prompt injection).
  The new behavior is tested in:
  - test/quoracle/agent/message_handler_user_prompt_removal_test.exs
  - test/quoracle/agent/consensus/system_prompt_injector_user_prompt_removal_test.exs
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.StateUtils

  describe "Initial prompt - StateUtils behavior" do
    @tag :integration
    test "WHEN add_history_entry called with empty model_histories THEN entries are added" do
      # Verify that StateUtils.add_history_entry works correctly with empty histories
      state = %{
        model_histories: %{
          "model-a" => [],
          "model-b" => []
        }
      }

      # Add an entry
      updated_state = StateUtils.add_history_entry(state, :event, "Test message")

      # Verify entries were added to ALL model histories
      for {_model_id, history} <- updated_state.model_histories do
        assert length(history) == 1, "Entry should be added to each model's history"
        [entry] = history
        assert entry.type == :event
        assert entry.content == "Test message"
      end
    end
  end
end
