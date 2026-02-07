defmodule Quoracle.Consensus.PromptBuilderBatchSyncTest do
  @moduledoc """
  Tests for CONSENSUS_PromptBuilder v17.0 - batch_sync Action Documentation.
  WorkGroupID: feat-20260123-batch-sync
  Packet: 3 (Prompt Integration)

  Tests that batch_sync action is properly documented in system prompts:
  - R75-R79: Action schema and description
  - R80-R82: Usage guidance in guidelines section
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Consensus.PromptBuilder
  alias Quoracle.Actions.Schema.Metadata

  @moduletag :batch_sync

  # ===========================================================================
  # R75-R79: Action Schema and Description
  # ===========================================================================
  describe "batch_sync action documentation" do
    # R75: batch_sync Schema in Prompt
    test "batch_sync action appears in system prompt" do
      # [UNIT] - WHEN system prompt built THEN batch_sync action schema included
      prompt = PromptBuilder.build_system_prompt()

      assert prompt =~ "batch_sync"
      # Should show as an action in the Available Actions section
      assert prompt =~ ~r/batch_sync.*action/is
    end

    # R76: batch_sync Description
    test "batch_sync description explains batching use case" do
      # [UNIT] - WHEN action_descriptions() called THEN batch_sync explains batching use case
      description = Metadata.action_descriptions()[:batch_sync]

      assert is_binary(description)
      assert description =~ ~r/batch|multiple/i
      assert description =~ ~r/action/i
      # Should explain WHEN to use
      assert description =~ "WHEN"
      # Should explain HOW to use
      assert description =~ "HOW"
    end

    # R77: Batchable Actions Listed
    test "batch_sync docs list batchable actions" do
      # [UNIT] - WHEN batch_sync documented THEN lists all batchable action types
      description = Metadata.action_descriptions()[:batch_sync]

      # Should list key batchable actions
      assert description =~ "file_read"
      assert description =~ "todo"
      assert description =~ "orient"
      assert description =~ "send_message"
    end

    # R78: Non-Batchable Clarified
    test "batch_sync docs clarify non-batchable actions" do
      # [UNIT] - WHEN batch_sync documented THEN clarifies wait and batch_sync not batchable
      description = Metadata.action_descriptions()[:batch_sync]

      # Should explicitly say what's NOT batchable
      assert description =~ ~r/not\s*batchable|excluded|cannot/i
      assert description =~ "wait"
      # No nesting
      assert description =~ ~r/nest|batch_sync/i
    end

    # R79: Stop-on-Error Documented
    test "batch_sync docs explain error handling" do
      # [UNIT] - WHEN batch_sync documented THEN explains stop-on-first-error behavior
      description = Metadata.action_descriptions()[:batch_sync]

      # Should explain what happens on error
      assert description =~ ~r/stop|error|fail/i
    end
  end

  # ===========================================================================
  # R80-R82: Usage Guidance in Guidelines
  # ===========================================================================
  describe "batch_sync usage guidance" do
    # R80: Batch Guidance in Guidelines
    test "guidelines include batch_sync usage guidance" do
      # [UNIT] - WHEN guidelines section built THEN includes batch_sync usage guidance
      prompt = PromptBuilder.build_system_prompt()

      # Should have a section about batching
      assert prompt =~ ~r/batch|batching/i
      # Should show example usage
      assert prompt =~ ~r/"action":\s*"batch_sync"/
    end

    # R81: When-to-Batch Examples
    test "batch guidance includes examples" do
      # [UNIT] - WHEN batch guidance shown THEN includes concrete examples
      prompt = PromptBuilder.build_system_prompt()

      # Should have batch guidance (sync vs async descriptions)
      assert prompt =~ ~r/batch_sync|batch_async/
      # Should show the params.actions structure
      assert prompt =~ ~r/"actions":\s*\[/
    end

    # R82: When-NOT-to-Batch Guidance
    test "batch guidance warns against dependent actions" do
      # [UNIT] - WHEN batch guidance shown THEN warns against dependent actions
      prompt = PromptBuilder.build_system_prompt()

      # Should warn about not batching when actions depend on previous results
      # Must have explicit guidance like "do not batch" or "avoid batching" with dependency context
      assert prompt =~ ~r/do\s+not\s+batch|avoid\s+batch|don't\s+batch/i
      # Should mention result/output dependencies between actions
      assert prompt =~
               ~r/result\s+(of|from)|output\s+(of|from)|depends?\s+on\s+(the\s+)?(result|output)/i
    end
  end

  # ===========================================================================
  # Integration: Full Prompt Generation
  # ===========================================================================
  describe "integration" do
    test "batch_sync fully integrated in system prompt" do
      # [INTEGRATION] - WHEN full system prompt built THEN batch_sync documentation complete
      prompt = PromptBuilder.build_system_prompt()

      # Should have batch_sync in Available Actions
      assert prompt =~ "batch_sync"

      # Should have params.actions schema
      assert prompt =~ "actions"

      # Prompt should be well-formed (not empty, not erroring)
      assert String.length(prompt) > 1000
    end
  end
end
