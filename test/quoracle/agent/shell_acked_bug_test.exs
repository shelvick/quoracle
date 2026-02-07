defmodule Quoracle.Agent.ShellAckedBugTest do
  @moduledoc """
  Tests for async shell `:acked` fix.

  BUG: Async shell commands (>100ms) were adding entries to `pending_actions` WITHOUT
  the `:acked` field, causing MessageHandler to queue ALL incoming messages silently.

  FIX: action_executor.ex async branch now sets acked: true so messages flow during
  async shell execution.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.MessageHandler

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
      context_limit: 4000
    }
  end

  describe "async shell :acked behavior" do
    setup do
      infra = create_isolated_infrastructure()
      %{infra: infra}
    end

    test "acked pending action allows messages to flow", %{infra: infra} do
      # After the fix, async shell results have acked: true
      # This test verifies that acked actions don't block messages
      pending_actions = %{
        "action_shell_1" => %{
          type: :execute_shell,
          params: %{command: "sleep 10"},
          timestamp: DateTime.utc_now(),
          acked: true
        }
      }

      state = create_test_state(infra, pending_actions: pending_actions)

      {:noreply, new_state} =
        MessageHandler.handle_agent_message(state, :parent, "Hello!")

      # Messages should NOT be queued when action is acked
      assert new_state.queued_messages == [],
             "Messages should flow when pending action has acked: true"
    end

    test "unacked pending action queues messages (baseline)", %{infra: infra} do
      # Baseline test: verify that WITHOUT :acked, messages ARE queued
      # This ensures the :acked field is actually meaningful
      pending_actions = %{
        "action_shell_1" => %{
          type: :execute_shell,
          params: %{command: "sleep 10"},
          timestamp: DateTime.utc_now()
          # No :acked field
        }
      }

      state = create_test_state(infra, pending_actions: pending_actions)

      {:noreply, new_state} =
        MessageHandler.handle_agent_message(state, :parent, "Hello!")

      # Messages SHOULD be queued when action is not acked
      assert length(new_state.queued_messages) == 1,
             "Messages should be queued when pending action lacks acked: true"
    end

    test "mixed acked/unacked - any unacked blocks messages", %{infra: infra} do
      # If there's ANY unacked action, messages should be queued
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
          # No :acked
        }
      }

      state = create_test_state(infra, pending_actions: pending_actions)

      {:noreply, new_state} =
        MessageHandler.handle_agent_message(state, :parent, "Hello!")

      assert length(new_state.queued_messages) == 1,
             "Any unacked action should block messages"
    end

    test "all actions acked allows messages through", %{infra: infra} do
      # Multiple acked actions should still allow messages
      pending_actions = %{
        "action_1" => %{
          type: :execute_shell,
          params: %{command: "sleep 5"},
          timestamp: DateTime.utc_now(),
          acked: true
        },
        "action_2" => %{
          type: :execute_shell,
          params: %{command: "sleep 10"},
          timestamp: DateTime.utc_now(),
          acked: true
        }
      }

      state = create_test_state(infra, pending_actions: pending_actions)

      {:noreply, new_state} =
        MessageHandler.handle_agent_message(state, :parent, "Hello!")

      assert new_state.queued_messages == [],
             "All acked actions should allow messages through"
    end
  end
end
