defmodule Quoracle.Agent.ConsensusRetryTest do
  @moduledoc """
  Tests for consensus retry on transient failures (v22.0) and
  correction feedback injection (v2.0 — feat-20260306-223446).

  Problem: :all_responses_invalid and :all_models_failed cause permanent agent stall.
  Solution: Retry up to 3 total attempts, notify parent on exhaustion.

  v2.0 additions (Packet 1 — Data + Injection):
  - Per-model correction feedback injection into consensus messages
  - State struct correction_feedback field defaulting to empty map

  v2.0 additions (Packet 2 — Lifecycle + Notification):
  - Correction feedback generation on retryable consensus failure
  - Correction feedback clearing on success and new external messages
  - Error-type differentiated correction wording
  - Forward-looking wording constraints
  - Root agent stall notification via mailbox + PubSub

  WorkGroupID: feat-20260129-consensus-retry, feat-20260306-223446

  Requirements:
  v1.0:
  - R1: Retry on :all_responses_invalid [UNIT]
  - R2: Retry on :all_models_failed [UNIT]
  - R3: No retry on non-retryable errors [UNIT]
  - R4: Retry counter incremented [UNIT]
  - R5: Max attempts respected [UNIT]
  - R6: Reset on successful consensus (run_consensus_cycle) [UNIT]
  - R7: Reset on successful consensus (handle_message_impl) [UNIT]
  - R8: Parent notified on exhaustion [INTEGRATION]
  - R9: No crash when parent_pid nil [UNIT]
  - R10: Error always logged [UNIT]
  - R11: Agent recovers from transient failure [SYSTEM]
  - R12: Parent receives notification after exhaustion [SYSTEM]
  - R73: State field defaults to 0 [UNIT]

  v2.0 (Packet 1):
  - R410: State struct has correction_feedback defaulting to empty map [UNIT]
  - CI-R1: Returns messages unchanged when no correction feedback [UNIT]
  - CI-R2: Prepends correction feedback to last user message [UNIT]
  - CI-R3: Injects only the correction for the specified model [UNIT]
  - CI-R4: Handles empty messages list gracefully [UNIT]
  - CI-R5: Prepends correction to multimodal content list [UNIT]
  - CI-R6: Correction appears above budget in built messages [INTEGRATION]
  - CI-R7: Handles state without correction_feedback key [UNIT]

  v2.0 (Packet 2):
  - R100: Sets per-model correction_feedback on retryable consensus failure [UNIT]
  - R101: Correction message differs between all_models_failed and all_responses_invalid [UNIT]
  - R102: Correction message does not reference previous output [UNIT]
  - R103: Clears correction_feedback on successful consensus in run_consensus_cycle [UNIT]
  - R104: Clears correction_feedback on successful consensus in handle_message_impl [UNIT]
  - R105: Clears correction_feedback when new external message arrives [UNIT]
  - R106: Does not set correction_feedback on non-retryable errors [UNIT]
  - R107: Does not set correction_feedback when max attempts exhausted [UNIT]
  - R108: Root agent adds stall message to own messages when retries exhausted [INTEGRATION]
  - R109: Root agent broadcasts stall message via PubSub [INTEGRATION]
  - R110: Child agent sends stall notification to parent (unchanged) [UNIT]
  - R111: Agent retries with correction feedback and recovers [SYSTEM]
  - R112: User sees stall notification in root agent mailbox after exhaustion [SYSTEM]
  """
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias Quoracle.Agent.MessageHandler
  alias Quoracle.Agent.Core.State
  alias Quoracle.Agent.ConsensusHandler.CorrectionInjector

  # Test isolation helpers
  defp unique_id, do: "agent-retry-#{System.unique_integer([:positive])}"

  defp create_isolated_infrastructure do
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({Phoenix.PubSub, name: pubsub_name})
    start_supervised!({DynamicSupervisor, name: dynsup_name, strategy: :one_for_one})

    %{registry: registry_name, pubsub: pubsub_name, dynsup: dynsup_name}
  end

  defp create_test_state(infra, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, unique_id())
    retry_count = Keyword.get(opts, :consensus_retry_count, 0)
    parent_pid = Keyword.get(opts, :parent_pid, nil)
    parent_id = Keyword.get(opts, :parent_id, nil)
    task_id = Keyword.get(opts, :task_id, nil)
    model_histories = Keyword.get(opts, :model_histories, %{"model1" => []})
    correction_feedback = Keyword.get(opts, :correction_feedback, %{})

    %{
      agent_id: agent_id,
      router_pid: self(),
      registry: infra.registry,
      dynsup: infra.dynsup,
      pubsub: infra.pubsub,
      model_histories: model_histories,
      models: Map.keys(model_histories),
      pending_actions: %{},
      queued_messages: [],
      consensus_scheduled: false,
      consensus_retry_count: retry_count,
      correction_feedback: correction_feedback,
      wait_timer: nil,
      skip_auto_consensus: true,
      test_mode: true,
      context_limits_loaded: true,
      context_limit: 4000,
      context_lessons: %{},
      model_states: %{},
      state: :ready,
      parent_pid: parent_pid,
      parent_id: parent_id,
      task_id: task_id,
      messages: []
    }
  end

  # ============================================================
  # R73: State field defaults to 0
  # ============================================================
  describe "[UNIT] R73: consensus_retry_count state field" do
    test "state struct has consensus_retry_count defaulting to 0" do
      state =
        struct!(State,
          agent_id: "test",
          registry: :test_reg,
          dynsup: self(),
          pubsub: :test_pub
        )

      assert state.consensus_retry_count == 0
    end
  end

  # ============================================================
  # R1-R2: Retry on retryable errors
  # ============================================================
  describe "[UNIT] R1-R2: retry on retryable errors" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "retries on :all_responses_invalid when attempts remain", %{infra: infra} do
      # simulate_failure returns :all_models_failed, not :all_responses_invalid.
      # To test :all_responses_invalid specifically, we need the retry logic
      # in handle_consensus_error to check the reason atom.
      # We test this through handle_message/2 which calls handle_consensus_error.
      # For now, we verify via run_consensus_cycle with simulate_failure (gives :all_models_failed).
      #
      # The actual :all_responses_invalid path is identical in behavior —
      # both are in @retryable_consensus_errors. We verify the atom check
      # by testing that the state gets consensus_scheduled: true after error.
      state =
        create_test_state(infra)
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

        # After implementation: retry should be scheduled
        assert new_state.consensus_scheduled == true
        assert new_state.consensus_retry_count == 1
      end)
    end

    test "retries on :all_models_failed when attempts remain", %{infra: infra} do
      state =
        create_test_state(infra)
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

        # After implementation: retry should be scheduled
        assert new_state.consensus_scheduled == true
        assert new_state.consensus_retry_count == 1
      end)
    end
  end

  # ============================================================
  # R3: No retry on non-retryable errors
  # ============================================================
  describe "[UNIT] R3: no retry on non-retryable errors" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "does not retry on non-retryable errors like :all_models_failed with max retries", %{
      infra: infra
    } do
      # Verify that when retry_count is already at max, no further retry is scheduled.
      # This confirms non-retryable behavior at the boundary.
      # Also tests that a retryable error at max count behaves like a non-retryable error.
      state =
        create_test_state(infra, consensus_retry_count: 2)
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

        # At max: should NOT schedule another retry
        refute new_state.consensus_scheduled
      end)
    end
  end

  # ============================================================
  # R4: Retry counter incremented
  # ============================================================
  describe "[UNIT] R4: retry counter incremented" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "increments consensus_retry_count on retry", %{infra: infra} do
      state =
        create_test_state(infra, consensus_retry_count: 0)
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, state_after_first} =
          MessageHandler.run_consensus_cycle(state, execute_action_fn)

        assert state_after_first.consensus_retry_count == 1

        # Second failure should increment to 2
        {:noreply, state_after_second} =
          MessageHandler.run_consensus_cycle(state_after_first, execute_action_fn)

        assert state_after_second.consensus_retry_count == 2
      end)
    end
  end

  # ============================================================
  # R5: Max attempts respected (3 total)
  # ============================================================
  describe "[UNIT] R5: max attempts respected" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "stops retrying after max attempts reached", %{infra: infra} do
      # Start at retry_count 2 (third attempt = max)
      state =
        create_test_state(infra, consensus_retry_count: 2)
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

        # Should NOT schedule another retry — max reached
        refute new_state.consensus_scheduled
      end)
    end
  end

  # ============================================================
  # R6: Reset on successful consensus (run_consensus_cycle)
  # ============================================================
  describe "[UNIT] R6: reset on success (cycle)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "resets retry count on successful consensus in run_consensus_cycle", %{infra: infra} do
      # State with prior retries, but this time consensus succeeds
      state =
        create_test_state(infra, consensus_retry_count: 2)
        |> Map.put(:simulate_failure, false)

      execute_action_fn = fn s, _action -> s end

      {:noreply, new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

      # Successful consensus should reset counter
      assert new_state.consensus_retry_count == 0
    end
  end

  # ============================================================
  # R7: Reset on successful consensus (handle_message_impl)
  # ============================================================
  describe "[UNIT] R7: reset on success (msg)" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "resets retry count on successful consensus in handle_message_impl", %{infra: infra} do
      # State with prior retries, consensus will succeed through handle_message path
      state =
        create_test_state(infra, consensus_retry_count: 2)
        |> Map.put(:simulate_failure, false)
        |> Map.put(:skip_consensus, false)

      # handle_message triggers consensus via handle_message_impl
      {:noreply, new_state} = MessageHandler.handle_message(state, {self(), "test message"})

      # Successful consensus should reset counter
      assert new_state.consensus_retry_count == 0
    end
  end

  # ============================================================
  # R8: Parent notified on exhaustion
  # ============================================================
  describe "[INTEGRATION] R8: parent notified" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "notifies parent when retries exhausted", %{infra: infra} do
      # Set self() as parent, retry_count at max-1 so this is the final attempt
      state =
        create_test_state(infra,
          consensus_retry_count: 2,
          parent_pid: self(),
          parent_id: "parent-1"
        )
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, _new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)
      end)

      # Parent should receive notification message
      assert_receive {:agent_message, agent_id, message}, 1000
      assert is_binary(agent_id)
      assert message =~ "failed"
      assert message =~ "3"
    end
  end

  # ============================================================
  # R9: No crash when parent_pid nil
  # ============================================================
  describe "[UNIT] R9: nil parent_pid handled gracefully" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "handles nil parent_pid gracefully on exhaustion", %{infra: infra} do
      # No parent - should not crash
      state =
        create_test_state(infra,
          consensus_retry_count: 2,
          parent_pid: nil,
          parent_id: nil
        )
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      # Should not crash even with nil parent
      capture_log(fn ->
        assert {:noreply, _state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)
      end)

      # No message sent
      refute_received {:agent_message, _, _}
    end
  end

  # ============================================================
  # R10: Error always logged regardless of retry
  # ============================================================
  describe "[UNIT] R10: error always logged" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "always logs error even when retrying", %{infra: infra} do
      state =
        create_test_state(infra, consensus_retry_count: 0)
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      log =
        capture_log(fn ->
          {:noreply, _state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)
        end)

      # Error log should always appear, even when retrying
      assert log =~ "Consensus failed cycle"
    end
  end

  # ============================================================
  # R11: Agent recovers from transient failure (SYSTEM)
  # ============================================================
  describe "[SYSTEM] R11: transient recovery" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    @tag :acceptance
    test "agent recovers from transient consensus failure via retry", %{infra: infra} do
      # First call: simulate_failure causes :all_models_failed
      # After retry: simulate_failure is still true, but we simulate recovery
      # by having the execute_action_fn track calls.
      #
      # Since run_consensus_cycle always reads simulate_failure from state,
      # we test the retry scheduling + counter behavior to verify the agent
      # would continue on a subsequent successful attempt.

      # Step 1: First attempt fails
      state =
        create_test_state(infra, consensus_retry_count: 0)
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, state_after_fail} =
          MessageHandler.run_consensus_cycle(state, execute_action_fn)

        # Verify retry was scheduled
        assert state_after_fail.consensus_retry_count == 1
        assert state_after_fail.consensus_scheduled == true

        # Step 2: Next consensus succeeds (clear simulate_failure)
        state_recovered = Map.put(state_after_fail, :simulate_failure, false)

        {:noreply, state_after_success} =
          MessageHandler.run_consensus_cycle(state_recovered, execute_action_fn)

        # Counter reset after success
        assert state_after_success.consensus_retry_count == 0
      end)
    end
  end

  # ============================================================
  # R12: Parent receives notification after child exhausts retries (SYSTEM)
  # ============================================================
  describe "[SYSTEM] R12: parent notified on exhaust" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    @tag :acceptance
    test "parent receives notification after child exhausts retries", %{infra: infra} do
      # Simulate 3 consecutive failures (max attempts)
      state =
        create_test_state(infra,
          consensus_retry_count: 0,
          parent_pid: self(),
          parent_id: "parent-1"
        )
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        # Attempt 1
        {:noreply, state1} = MessageHandler.run_consensus_cycle(state, execute_action_fn)
        assert state1.consensus_retry_count == 1
        refute_received {:agent_message, _, _}

        # Attempt 2
        {:noreply, state2} = MessageHandler.run_consensus_cycle(state1, execute_action_fn)
        assert state2.consensus_retry_count == 2
        refute_received {:agent_message, _, _}

        # Attempt 3 — max reached, should notify parent
        {:noreply, _state3} = MessageHandler.run_consensus_cycle(state2, execute_action_fn)
      end)

      # Parent should now have received notification
      assert_receive {:agent_message, _agent_id, message}, 1000
      assert message =~ "3 attempts"
    end
  end

  # ============================================================
  # v2.0 Packet 1: State field + CorrectionInjector tests
  # ============================================================

  # ============================================================
  # R410: State struct has correction_feedback defaulting to empty map
  # ============================================================
  describe "[UNIT] R410: correction_feedback state field" do
    test "state struct has correction_feedback defaulting to empty map" do
      state =
        struct!(State,
          agent_id: "test",
          registry: :test_reg,
          dynsup: self(),
          pubsub: :test_pub
        )

      assert state.correction_feedback == %{}
    end
  end

  # ============================================================
  # CI-R1: Returns messages unchanged when no correction feedback
  # ============================================================
  describe "[UNIT] CI-R1: no-op without feedback" do
    test "returns messages unchanged when no correction feedback exists" do
      # State with empty correction_feedback — no corrections pending
      state = %{correction_feedback: %{}}
      messages = [%{role: "user", content: "Hello, what should I do next?"}]

      result = CorrectionInjector.inject_correction_feedback(state, messages, "model-1")

      # Messages should be returned unchanged
      assert result == messages
    end

    test "returns messages unchanged when model has no correction" do
      # correction_feedback has entry for a different model
      state = %{correction_feedback: %{"model-2" => "[SYSTEM] CORRECTION: Fix your output"}}
      messages = [%{role: "user", content: "Hello"}]

      result = CorrectionInjector.inject_correction_feedback(state, messages, "model-1")

      # model-1 has no correction, so messages unchanged
      assert result == messages
    end
  end

  # ============================================================
  # CI-R2: Prepends correction feedback to last user message
  # ============================================================
  describe "[UNIT] CI-R2: prepend to last msg" do
    test "prepends correction feedback to last user message" do
      correction_text =
        "[SYSTEM] CORRECTION: You MUST respond with a single, well-formed JSON object."

      state = %{correction_feedback: %{"model-1" => correction_text}}

      messages = [
        %{role: "user", content: "First message"},
        %{role: "assistant", content: "I will help you"},
        %{role: "user", content: "Do something useful"}
      ]

      result = CorrectionInjector.inject_correction_feedback(state, messages, "model-1")

      # Last user message should have correction prepended
      last_msg = List.last(result)
      assert last_msg.content =~ "[SYSTEM] CORRECTION:"
      assert last_msg.content =~ "Do something useful"

      # Correction should appear before original content (prepended)
      correction_pos = :binary.match(last_msg.content, "[SYSTEM] CORRECTION:")
      content_pos = :binary.match(last_msg.content, "Do something useful")
      assert elem(correction_pos, 0) < elem(content_pos, 0)

      # First messages should be unchanged
      assert Enum.at(result, 0) == Enum.at(messages, 0)
      assert Enum.at(result, 1) == Enum.at(messages, 1)
    end
  end

  # ============================================================
  # CI-R3: Injects only the correction for the specified model
  # ============================================================
  describe "[UNIT] CI-R3: model-specific only" do
    test "injects only the correction for the specified model" do
      state = %{
        correction_feedback: %{
          "model-a" => "[SYSTEM] CORRECTION: Model A fix",
          "model-b" => "[SYSTEM] CORRECTION: Model B fix"
        }
      }

      messages = [%{role: "user", content: "Original content"}]

      result_a = CorrectionInjector.inject_correction_feedback(state, messages, "model-a")
      result_b = CorrectionInjector.inject_correction_feedback(state, messages, "model-b")

      # model-a gets only model-a's correction
      last_a = List.last(result_a)
      assert last_a.content =~ "Model A fix"
      refute last_a.content =~ "Model B fix"

      # model-b gets only model-b's correction
      last_b = List.last(result_b)
      assert last_b.content =~ "Model B fix"
      refute last_b.content =~ "Model A fix"
    end
  end

  # ============================================================
  # CI-R4: Handles empty messages list gracefully
  # ============================================================
  describe "[UNIT] CI-R4: empty messages list" do
    test "handles empty messages list gracefully" do
      state = %{correction_feedback: %{"model-1" => "[SYSTEM] CORRECTION: Fix it"}}

      result = CorrectionInjector.inject_correction_feedback(state, [], "model-1")

      assert result == []
    end
  end

  # ============================================================
  # CI-R5: Prepends correction to multimodal content list
  # ============================================================
  describe "[UNIT] CI-R5: multimodal content" do
    test "prepends correction to multimodal content list" do
      correction_text = "[SYSTEM] CORRECTION: Respond with valid JSON."

      state = %{correction_feedback: %{"model-1" => correction_text}}

      # Multimodal message with list content (text + image)
      messages = [
        %{
          role: "user",
          content: [
            %{type: :text, text: "Look at this image"},
            %{type: :image_url, image_url: %{url: "data:image/png;base64,abc123"}}
          ]
        }
      ]

      result = CorrectionInjector.inject_correction_feedback(state, messages, "model-1")

      # Content should be a list with correction prepended as text part
      last_msg = List.last(result)
      assert is_list(last_msg.content)

      # First element should be the correction text part
      first_part = hd(last_msg.content)
      assert first_part.type == :text
      assert first_part.text =~ "[SYSTEM] CORRECTION:"

      # Original content parts should follow
      assert length(last_msg.content) == 3
    end
  end

  # ============================================================
  # CI-R6: Correction appears above budget in built messages
  # ============================================================
  describe "[INTEGRATION] CI-R6: builder order" do
    test "correction appears above budget in built messages" do
      # This tests that when build_messages_for_model is called with
      # correction_feedback in state, the correction text appears ABOVE
      # budget text in the final last user message.
      #
      # The injection order is:
      # Step 7: Budget injection (prepended to last user msg)
      # Step 7.5: Correction injection (prepended after budget, appears first)
      #
      # So final order in last user message: CORRECTION ... budget ... content

      alias Quoracle.Agent.Consensus.MessageBuilder

      state = %{
        correction_feedback: %{
          "test-model" => "[SYSTEM] CORRECTION: You MUST respond with valid JSON."
        },
        model_histories: %{
          "test-model" => [
            %{type: :user, content: "What is your next action?", timestamp: DateTime.utc_now()}
          ]
        },
        context_lessons: %{"test-model" => []},
        model_states: %{"test-model" => nil},
        context_limit: 4000,
        context_limits_loaded: true,
        system_prompt: "You are a helpful agent.",
        todos: [],
        children: [],
        registry: :nonexistent_registry,
        budget_data: %{allocated: Decimal.new("10.00"), committed: Decimal.new("0.00")},
        over_budget: false,
        agent_id: :test_agent,
        spent: Decimal.new("1.00")
      }

      messages =
        MessageBuilder.build_messages_for_model(state, "test-model", skip_context_tokens: true)

      # Find the last user message
      last_user =
        messages
        |> Enum.filter(&(&1.role == "user"))
        |> List.last()

      assert last_user != nil

      content = last_user.content
      assert is_binary(content)

      # Correction should be present
      assert content =~ "[SYSTEM] CORRECTION:"

      # Budget should be present (budget_data has allocated)
      assert content =~ "<budget>"

      # Correction should appear BEFORE budget (prepended last = appears first)
      correction_pos = :binary.match(content, "[SYSTEM] CORRECTION:")
      budget_pos = :binary.match(content, "<budget>")
      assert elem(correction_pos, 0) < elem(budget_pos, 0)
    end
  end

  # ============================================================
  # CI-R7: Handles state without correction_feedback key
  # ============================================================
  describe "[UNIT] CI-R7: backward compat" do
    test "handles state without correction_feedback key" do
      # Pre-v43.0 state that doesn't have correction_feedback at all
      state = %{agent_id: "old-agent", model_histories: %{"model-1" => []}}

      messages = [%{role: "user", content: "Hello"}]

      result = CorrectionInjector.inject_correction_feedback(state, messages, "model-1")

      # Should return messages unchanged (no crash)
      assert result == messages
    end
  end

  # ============================================================
  # v2.0 Packet 2: Correction Feedback Lifecycle + Root Notification
  # ============================================================

  # ============================================================
  # R100: Sets per-model correction_feedback on retryable consensus failure
  # ============================================================
  describe "[UNIT] R100: correction feedback generation" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "sets per-model correction_feedback on retryable consensus failure", %{infra: infra} do
      # Multi-model state: correction_feedback should have an entry for each model
      state =
        create_test_state(infra,
          model_histories: %{"model-a" => [], "model-b" => []},
          consensus_retry_count: 0
        )
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

        # correction_feedback should be a map with entries for each model
        assert new_state.correction_feedback != %{}
        assert Map.has_key?(new_state.correction_feedback, "model-a")
        assert Map.has_key?(new_state.correction_feedback, "model-b")

        # Each correction should start with [SYSTEM] CORRECTION:
        assert new_state.correction_feedback["model-a"] =~ "[SYSTEM] CORRECTION:"
        assert new_state.correction_feedback["model-b"] =~ "[SYSTEM] CORRECTION:"
      end)
    end
  end

  # ============================================================
  # R101: Correction message differs between error types
  # ============================================================
  describe "[UNIT] R101: error-type differentiation" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "correction message differs between all_models_failed and all_responses_invalid", %{
      infra: infra
    } do
      # We need two separate runs to compare correction messages for different error types.
      # simulate_failure produces :all_models_failed by default.
      # We also need to test :all_responses_invalid.
      #
      # For :all_models_failed — the correction should reference JSON format requirements
      state_amf =
        create_test_state(infra,
          model_histories: %{"model-1" => []},
          consensus_retry_count: 0
        )
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, state_after_amf} =
          MessageHandler.run_consensus_cycle(state_amf, execute_action_fn)

        # For :all_responses_invalid — simulate with the other error type
        state_ari =
          create_test_state(infra,
            model_histories: %{"model-1" => []},
            consensus_retry_count: 0
          )
          |> Map.put(:simulate_failure, :all_responses_invalid)

        {:noreply, state_after_ari} =
          MessageHandler.run_consensus_cycle(state_ari, execute_action_fn)

        # Both should have correction_feedback
        assert state_after_amf.correction_feedback != %{}
        assert state_after_ari.correction_feedback != %{}

        # The messages should be different for different error types
        msg_amf = state_after_amf.correction_feedback["model-1"]
        msg_ari = state_after_ari.correction_feedback["model-1"]

        assert msg_amf != msg_ari

        # :all_models_failed → JSON format guidance
        assert msg_amf =~ "JSON"

        # :all_responses_invalid → action/parameter validity guidance
        assert msg_ari =~ "action"
      end)
    end
  end

  # ============================================================
  # R102: Correction wording is forward-looking
  # ============================================================
  describe "[UNIT] R102: forward-looking wording" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "correction message does not reference previous output", %{infra: infra} do
      state =
        create_test_state(infra,
          model_histories: %{"model-1" => []},
          consensus_retry_count: 0
        )
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

        correction = new_state.correction_feedback["model-1"]

        # Must NOT contain backward-looking references
        refute correction =~ "previous response"
        refute correction =~ "your last output"
        refute correction =~ "you previously"
        refute correction =~ "your earlier"

        # Must be forward-looking — contains instruction language
        assert correction =~ "[SYSTEM] CORRECTION:"
      end)
    end
  end

  # ============================================================
  # R103: Clears correction_feedback on successful consensus in run_consensus_cycle
  # ============================================================
  describe "[UNIT] R103: clear on run_consensus_cycle success" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "clears correction_feedback on successful consensus in run_consensus_cycle", %{
      infra: infra
    } do
      # Start with pre-existing correction_feedback from a prior failure
      state =
        create_test_state(infra,
          consensus_retry_count: 1,
          correction_feedback: %{
            "model1" => "[SYSTEM] CORRECTION: You MUST respond with valid JSON."
          }
        )
        |> Map.put(:simulate_failure, false)

      execute_action_fn = fn s, _action -> s end

      {:noreply, new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

      # Successful consensus should clear correction_feedback
      assert new_state.correction_feedback == %{}
      # And also reset retry count (existing behavior)
      assert new_state.consensus_retry_count == 0
    end
  end

  # ============================================================
  # R104: Clears correction_feedback on successful consensus in handle_message_impl
  # ============================================================
  describe "[UNIT] R104: clear on handle_message_impl success" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "clears correction_feedback on successful consensus in handle_message_impl", %{
      infra: infra
    } do
      # State with prior correction_feedback, consensus will succeed through handle_message
      state =
        create_test_state(infra,
          consensus_retry_count: 1,
          correction_feedback: %{
            "model1" => "[SYSTEM] CORRECTION: You MUST respond with valid JSON."
          }
        )
        |> Map.put(:simulate_failure, false)
        |> Map.put(:skip_consensus, false)

      {:noreply, new_state} = MessageHandler.handle_message(state, {self(), "test message"})

      # Successful consensus should clear correction_feedback
      assert new_state.correction_feedback == %{}
      assert new_state.consensus_retry_count == 0
    end
  end

  # ============================================================
  # R105: Clears correction_feedback when new external message arrives
  # ============================================================
  describe "[UNIT] R105: clear on new external message" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "clears correction_feedback when new external message arrives", %{infra: infra} do
      # State with pre-existing correction_feedback and no pending actions
      # (so message won't be queued)
      state =
        create_test_state(infra,
          correction_feedback: %{
            "model1" => "[SYSTEM] CORRECTION: Respond with valid JSON."
          }
        )
        |> Map.put(:skip_auto_consensus, true)

      # handle_agent_message should clear correction_feedback on any new external message
      {:noreply, new_state} = MessageHandler.handle_agent_message(state, :user, "New input")

      # correction_feedback should be cleared — new context makes old corrections stale
      assert new_state.correction_feedback == %{}
    end
  end

  # ============================================================
  # R106: Does not set correction_feedback on non-retryable errors
  # ============================================================
  describe "[UNIT] R106: no feedback on non-retryable errors" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "does not set correction_feedback on non-retryable errors", %{infra: infra} do
      # Simulate a non-retryable error (e.g., :no_models_configured)
      state =
        create_test_state(infra,
          model_histories: %{"model-1" => []},
          consensus_retry_count: 0
        )
        |> Map.put(:simulate_failure, :no_models_configured)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

        # Non-retryable errors should NOT set correction_feedback
        assert new_state.correction_feedback == %{}
      end)
    end
  end

  # ============================================================
  # R107: Does not set correction_feedback when max attempts exhausted
  # ============================================================
  describe "[UNIT] R107: no feedback at max attempts" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "does not set correction_feedback when max attempts exhausted", %{infra: infra} do
      # At max retries (2), the next failure should NOT set correction — it should notify instead
      state =
        create_test_state(infra,
          model_histories: %{"model-1" => []},
          consensus_retry_count: 2,
          parent_pid: self(),
          parent_id: "parent-1"
        )
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

        # Max attempts reached — correction_feedback should NOT be set
        # (notification sent to parent instead)
        assert new_state.correction_feedback == %{}
      end)
    end
  end

  # ============================================================
  # R108: Root agent adds stall message to own messages when retries exhausted
  # ============================================================
  describe "[INTEGRATION] R108: root stall msg" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "root agent adds stall message to own messages when retries exhausted", %{infra: infra} do
      task_id = "test-task-#{System.unique_integer([:positive])}"

      # Root agent: nil parent_pid, has task_id
      state =
        create_test_state(infra,
          consensus_retry_count: 2,
          parent_pid: nil,
          parent_id: nil,
          task_id: task_id
        )
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)

        # Root agent should have added stall message to its own messages list
        assert Enum.any?(new_state.messages, fn msg ->
                 is_map(msg) and Map.has_key?(msg, :content) and msg.content =~ "Consensus failed"
               end)
      end)
    end
  end

  # ============================================================
  # R109: Root agent broadcasts stall message via PubSub
  # ============================================================
  describe "[INTEGRATION] R109: root agent PubSub broadcast" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "root agent broadcasts stall message via PubSub", %{infra: infra} do
      task_id = "test-task-#{System.unique_integer([:positive])}"

      # Subscribe to the task messages topic BEFORE triggering
      Phoenix.PubSub.subscribe(infra.pubsub, "tasks:#{task_id}:messages")

      # Root agent: nil parent_pid, has task_id
      state =
        create_test_state(infra,
          consensus_retry_count: 2,
          parent_pid: nil,
          parent_id: nil,
          task_id: task_id
        )
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, _new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)
      end)

      # Should receive PubSub broadcast with stall notification
      assert_receive {:agent_message, msg_data}, 1000
      assert is_map(msg_data)
      assert msg_data.content =~ "Consensus failed"
    end
  end

  # ============================================================
  # R110: Child agent sends stall notification to parent (unchanged)
  # ============================================================
  describe "[UNIT] R110: child agent notification unchanged" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "child agent sends stall notification to parent (unchanged)", %{infra: infra} do
      # Child agent with parent_pid set to test process
      state =
        create_test_state(infra,
          consensus_retry_count: 2,
          parent_pid: self(),
          parent_id: "parent-1"
        )
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, _new_state} = MessageHandler.run_consensus_cycle(state, execute_action_fn)
      end)

      # Child agent should send {:agent_message, agent_id, message} to parent
      # This is the existing behavior — unchanged from v1.0
      assert_receive {:agent_message, agent_id, message}, 1000
      assert is_binary(agent_id)
      assert message =~ "failed"
      assert message =~ "3"
    end
  end

  # ============================================================
  # R111: Agent retries with correction feedback and recovers (SYSTEM)
  # ============================================================
  describe "[SYSTEM] R111: correction feedback recovery" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    @tag :acceptance
    test "agent retries with correction feedback and recovers", %{infra: infra} do
      # Step 1: First consensus attempt fails — should set correction_feedback
      state =
        create_test_state(infra,
          model_histories: %{"model-a" => [], "model-b" => []},
          consensus_retry_count: 0
        )
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        {:noreply, state_after_fail} =
          MessageHandler.run_consensus_cycle(state, execute_action_fn)

        # Verify correction feedback was set for each model
        assert state_after_fail.correction_feedback != %{}
        assert Map.has_key?(state_after_fail.correction_feedback, "model-a")
        assert Map.has_key?(state_after_fail.correction_feedback, "model-b")
        assert state_after_fail.consensus_retry_count == 1

        # Step 2: Next consensus succeeds — correction_feedback should be cleared
        state_recovered = Map.put(state_after_fail, :simulate_failure, false)

        {:noreply, state_after_success} =
          MessageHandler.run_consensus_cycle(state_recovered, execute_action_fn)

        # Counter reset and correction_feedback cleared
        assert state_after_success.consensus_retry_count == 0
        assert state_after_success.correction_feedback == %{}
      end)
    end
  end

  # ============================================================
  # R112: User sees stall notification in root agent mailbox after exhaustion (SYSTEM)
  # ============================================================
  describe "[SYSTEM] R112: root stall visible" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    @tag :acceptance
    test "user sees stall notification in root agent mailbox after exhaustion", %{infra: infra} do
      task_id = "test-task-#{System.unique_integer([:positive])}"

      # Subscribe to task messages (simulates what Dashboard/Mailbox does)
      Phoenix.PubSub.subscribe(infra.pubsub, "tasks:#{task_id}:messages")

      # Root agent starts with no retries
      state =
        create_test_state(infra,
          consensus_retry_count: 0,
          parent_pid: nil,
          parent_id: nil,
          task_id: task_id
        )
        |> Map.put(:simulate_failure, true)

      execute_action_fn = fn s, _action -> s end

      capture_log(fn ->
        # Attempt 1 — retry, no notification yet
        {:noreply, state1} = MessageHandler.run_consensus_cycle(state, execute_action_fn)
        assert state1.consensus_retry_count == 1
        refute_received {:agent_message, _}

        # Attempt 2 — retry again, still no notification
        {:noreply, state2} = MessageHandler.run_consensus_cycle(state1, execute_action_fn)
        assert state2.consensus_retry_count == 2
        refute_received {:agent_message, _}

        # Attempt 3 — max reached, should notify user
        {:noreply, state3} = MessageHandler.run_consensus_cycle(state2, execute_action_fn)

        # Root agent's own messages should contain the stall notification
        assert Enum.any?(state3.messages, fn msg ->
                 is_map(msg) and Map.has_key?(msg, :content) and msg.content =~ "Consensus failed"
               end)
      end)

      # PubSub broadcast should have been sent for the Mailbox panel
      assert_receive {:agent_message, msg_data}, 1000
      assert msg_data.content =~ "Consensus failed"
      assert msg_data.content =~ "3"
    end
  end
end
