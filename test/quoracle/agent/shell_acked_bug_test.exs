defmodule Quoracle.Agent.ShellAckedBugTest do
  @moduledoc """
  Tests for async shell `:acked` fix.

  BUG: Async shell commands (>100ms) were adding entries to `pending_actions` WITHOUT
  the `:acked` field, causing MessageHandler to queue ALL incoming messages silently.

  FIX: action_result_handler.ex Phase 1 branch now sets acked: true on the pending
  action entry so messages flow during async shell execution.
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.MessageHandler
  alias Quoracle.Agent.MessageHandler.ActionResultHandler

  defp unique_id, do: "agent-#{System.unique_integer([:positive])}"

  defp create_isolated_infrastructure do
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({Phoenix.PubSub, name: pubsub_name})
    start_supervised!({DynamicSupervisor, name: dynsup_name, strategy: :one_for_one})

    %{registry: registry_name, pubsub: pubsub_name, dynsup: dynsup_name}
  end

  defp create_test_state(infra, opts) do
    %{
      agent_id: Keyword.get(opts, :agent_id, unique_id()),
      task_id: unique_id(),
      router_pid: self(),
      parent_pid: nil,
      registry: infra.registry,
      dynsup: infra.dynsup,
      pubsub: infra.pubsub,
      model_histories: %{"model1" => []},
      models: ["model1"],
      pending_actions: Keyword.get(opts, :pending_actions, %{}),
      action_counter: 0,
      skip_auto_consensus: true,
      test_mode: true,
      wait_timer: nil,
      queued_messages: [],
      consensus_scheduled: false,
      context_limits_loaded: true,
      context_limit: 4000,
      children: [],
      budget_data: nil,
      over_budget: false,
      dismissing: false,
      active_routers: %{},
      shell_routers: %{},
      consensus_retry_count: 0,
      correction_feedback: %{}
    }
  end

  # Async shell Phase 1 result shape (command went async)
  defp phase1_result(command_id) do
    {:ok, %{status: :running, command_id: command_id, sync: false, pid: self()}}
  end

  describe "async shell :acked behavior" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "Phase 1 result sets acked on pending action", %{infra: infra} do
      action_id = "action_shell_1"
      command_id = "cmd-#{System.unique_integer([:positive])}"

      pending_actions = %{
        action_id => %{
          type: :execute_shell,
          params: %{command: "sleep 10"},
          timestamp: DateTime.utc_now()
        }
      }

      state = create_test_state(infra, pending_actions: pending_actions)

      # Process async shell Phase 1 result through the real code path
      {:noreply, new_state} =
        ActionResultHandler.handle_action_result(
          state,
          action_id,
          phase1_result(command_id),
          action_atom: :execute_shell,
          wait_value: true,
          always_sync: false
        )

      # Pending action should still exist (kept for Phase 2)
      assert Map.has_key?(new_state.pending_actions, action_id)

      # AND it should now have acked: true
      assert new_state.pending_actions[action_id].acked == true
    end

    test "messages flow after Phase 1 acks the pending action", %{infra: infra} do
      action_id = "action_shell_1"
      command_id = "cmd-#{System.unique_integer([:positive])}"

      pending_actions = %{
        action_id => %{
          type: :execute_shell,
          params: %{command: "sleep 10"},
          timestamp: DateTime.utc_now()
        }
      }

      state = create_test_state(infra, pending_actions: pending_actions)

      # First: process Phase 1 result
      {:noreply, state_after_phase1} =
        ActionResultHandler.handle_action_result(
          state,
          action_id,
          phase1_result(command_id),
          action_atom: :execute_shell,
          wait_value: true,
          always_sync: false
        )

      # Clear consensus_scheduled (in a real agent, :trigger_consensus would have
      # been processed already). We're testing the acked field's effect specifically.
      state_after_phase1 = %{state_after_phase1 | consensus_scheduled: false}

      # Now: send a message — should NOT be queued because action is acked
      {:noreply, state_after_msg} =
        MessageHandler.handle_agent_message(state_after_phase1, :parent, "Hello!")

      assert state_after_msg.queued_messages == [],
             "Messages should flow when pending action has acked: true"
    end

    test "unacked pending action queues messages (baseline)", %{infra: infra} do
      # Baseline: verify that WITHOUT :acked, messages ARE queued
      pending_actions = %{
        "action_shell_1" => %{
          type: :execute_shell,
          params: %{command: "sleep 10"},
          timestamp: DateTime.utc_now()
          # No :acked field — this is the bug state
        }
      }

      state = create_test_state(infra, pending_actions: pending_actions)

      {:noreply, new_state} =
        MessageHandler.handle_agent_message(state, :parent, "Hello!")

      assert length(new_state.queued_messages) == 1,
             "Messages should be queued when pending action lacks acked: true"
    end

    test "mixed acked/unacked — any unacked blocks messages", %{infra: infra} do
      pending_actions = %{
        "action_acked" => %{
          type: :execute_shell,
          params: %{command: "echo ok"},
          timestamp: DateTime.utc_now(),
          acked: true
        },
        "action_unacked" => %{
          type: :call_api,
          params: %{url: "http://example.com"},
          timestamp: DateTime.utc_now()
        }
      }

      state = create_test_state(infra, pending_actions: pending_actions)

      {:noreply, new_state} =
        MessageHandler.handle_agent_message(state, :parent, "Hello!")

      assert length(new_state.queued_messages) == 1,
             "Any unacked action should block messages"
    end
  end
end
