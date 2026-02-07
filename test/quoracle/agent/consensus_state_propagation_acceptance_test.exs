defmodule Quoracle.Agent.ConsensusStatePropagationAcceptanceTest do
  @moduledoc """
  Acceptance tests for v12.0 Condensation State Propagation fix.

  WorkGroupID: fix-20260103-condensation-state
  Packet 1: AGENT_Consensus - Acceptance Test

  User-Observable Behavior:
  - User does: Agent runs for many turns until context limit reached
  - User expects: Condensation happens once, history stays condensed

  This test verifies the complete flow from consensus call through condensation
  to GenServer state update, ensuring the in-memory state is synchronized.
  """

  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog
  import Test.IsolationHelpers
  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core
  alias Quoracle.Tasks.Task
  alias Quoracle.Repo

  # Force ActionList to load
  alias Quoracle.Actions.Schema.ActionList
  _ = ActionList.actions()

  describe "Acceptance: Condensation State Propagation" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      [
        deps: deps,
        task_id: task.id,
        sandbox_owner: sandbox_owner
      ]
    end

    @tag :acceptance
    @tag :integration
    test "condensation updates GenServer state preventing repeated condensation", %{
      deps: deps,
      task_id: task_id,
      sandbox_owner: sandbox_owner
    } do
      # 1. ENTRY POINT: Create an agent with a large history that will trigger condensation
      agent_id = "acceptance-condensation-#{System.unique_integer([:positive])}"

      # Build a history large enough to trigger condensation on a small-context model
      large_history = build_large_history(100)
      initial_history_length = length(large_history)

      config = %{
        agent_id: agent_id,
        task_id: task_id,
        task: "Test condensation state propagation",
        models: ["openai:gpt-3.5-turbo-0613"],
        model_pool: ["openai:gpt-3.5-turbo-0613"],
        model_histories: %{"openai:gpt-3.5-turbo-0613" => large_history},
        context_lessons: %{"openai:gpt-3.5-turbo-0613" => []},
        model_states: %{"openai:gpt-3.5-turbo-0613" => nil},
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub,
        sandbox_owner: sandbox_owner,
        test_mode: true,
        # force_condense bypasses token threshold check for test isolation
        force_condense: true
      }

      # Spawn agent with cleanup (uses spawn_agent_with_cleanup helper)
      {:ok, agent_pid} = spawn_agent_with_cleanup(deps.dynsup, config, registry: deps.registry)

      # Wait for agent to be ready
      :ok = Core.wait_for_ready(agent_pid)

      # 2. USER ACTION: Trigger consensus (which should condense and update state)
      # First consensus call - should trigger condensation
      capture_log(fn ->
        Core.handle_message(agent_pid, "First message after large history")
      end)

      # Sync barrier: get_state ensures handle_message completes
      {:ok, state_after_first} = Core.get_state(agent_pid)

      history_after_first =
        state_after_first.model_histories["openai:gpt-3.5-turbo-0613"]

      # 3. BEHAVIOR ASSERTION: History should be condensed in GenServer state
      assert length(history_after_first) < initial_history_length,
             "Expected history to be condensed from #{initial_history_length} to fewer entries, " <>
               "but got #{length(history_after_first)}"

      history_length_after_first = length(history_after_first)

      # Second consensus call - should NOT trigger condensation again
      capture_log(fn ->
        Core.handle_message(agent_pid, "Second message after condensation")
      end)

      {:ok, state_after_second} = Core.get_state(agent_pid)

      history_after_second =
        state_after_second.model_histories["openai:gpt-3.5-turbo-0613"]

      # 4. BEHAVIOR ASSERTION: History should not have been re-condensed
      # After first condensation, state is updated. Second call adds 1-2 entries max.
      # If bug exists, history would be condensed again (growing from re-inflation).
      assert length(history_after_second) <= history_length_after_first + 2,
             "History grew unexpectedly after second consensus: " <>
               "was #{history_length_after_first}, now #{length(history_after_second)}. " <>
               "This indicates GenServer state was not updated with condensed history."
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp build_large_history(count) do
    Enum.map(1..count, fn i ->
      %{
        type: :event,
        content:
          "Message #{i} with substantial content to consume tokens and trigger condensation when the context limit is reached",
        timestamp: DateTime.utc_now()
      }
    end)
  end
end
