defmodule Quoracle.Agent.WaitTrueRaceAcceptanceTest do
  @moduledoc """
  Acceptance test for Bug 1: wait:true Race Condition
  WorkGroupID: fix-20251211-051748

  Verifies that when an action executes with wait:true, the result is stored
  synchronously BEFORE returning, preventing race conditions where a child's
  immediate reply could be processed before the spawn result.

  This is a SYSTEM-level test using real agent processes to verify user-observable
  behavior: the parent's conversation history (as seen by the LLM) has the spawn
  result appear BEFORE any subsequent child messages.
  """
  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog
  import Test.AgentTestHelpers

  alias Quoracle.Agent.{Core, ContextManager, ConsensusHandler}

  describe "acceptance: wait:true result ordering in LLM context" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, deps: deps, sandbox_owner: sandbox_owner}
    end

    @tag :acceptance
    test "spawn result appears in history before immediate child message", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # SETUP: Create a real parent agent with a real Router
      parent_id = "parent-#{System.unique_integer([:positive])}"

      parent_config = %{
        agent_id: parent_id,
        task_id: "task-#{System.unique_integer([:positive])}",
        parent_pid: nil,
        test_mode: true
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Get parent state
      {:ok, parent_state} = Core.get_state(parent_pid)
      assert parent_state.agent_id != nil, "Parent must have initialized"

      # STEP 1: Execute an action with wait:true through ConsensusHandler
      # This simulates consensus selecting an action - the entry point after LLM decision
      action_response = %{
        action: :orient,
        params: %{"observations" => "Test observation for acceptance"},
        wait: true
      }

      # Execute through ConsensusHandler (uses real Router)
      # Capture expected auto-correction warning for orient with wait:true
      {updated_state, _log} =
        with_log(fn ->
          ConsensusHandler.execute_consensus_action(
            parent_state,
            action_response,
            parent_pid
          )
        end)

      # CRITICAL ASSERTION: Result must be in state immediately after execute returns
      # This is the core of Bug 1 - synchronous storage prevents race condition
      model_id = updated_state.model_histories |> Map.keys() |> List.first()
      history_after_action = updated_state.model_histories[model_id]

      result_entry = Enum.find(history_after_action, &(&1.type == :result))

      assert result_entry != nil,
             "BUG 1: wait:true result NOT in state after execute_consensus_action returned. " <>
               "Result was stored asynchronously (race condition vulnerable)"

      # STEP 2: Simulate immediate child reply (worst-case timing)
      # In production: child spawns and immediately sends message to parent
      child_agent_id = "child-immediate-#{System.unique_integer([:positive])}"
      child_message = "Hello parent, I started working!"

      # Apply child message to state (simulates MessageHandler processing)
      state_with_child_msg =
        Quoracle.Agent.StateUtils.add_history_entry(
          updated_state,
          :event,
          %{from: child_agent_id, content: child_message}
        )

      # STEP 3: Verify user-observable behavior
      # Build conversation messages as the LLM would see them
      messages = ContextManager.build_conversation_messages(state_with_child_msg, model_id)

      # Find positions in the conversation (messages are in chronological order for LLM)
      # The result should appear BEFORE the child message
      result_msg =
        Enum.find(messages, fn msg ->
          msg.role == "assistant" && msg.content =~ "orient"
        end)

      child_msg =
        Enum.find(messages, fn msg ->
          msg.role == "user" && msg.content =~ child_message
        end)

      assert result_msg != nil, "Action result not found in conversation"
      assert child_msg != nil, "Child message not found in conversation"

      result_idx = Enum.find_index(messages, &(&1 == result_msg))
      child_idx = Enum.find_index(messages, &(&1 == child_msg))

      # ACCEPTANCE CRITERION: Result must appear before child message in LLM context
      assert result_idx < child_idx,
             """
             BUG 1 ACCEPTANCE FAILURE: Child message appears before action result in LLM context!

             Expected order (what user expects):
               1. Action result (orient completed)
               2. Child message ("#{child_message}")

             Actual order in conversation:
               Result at index: #{result_idx}
               Child at index: #{child_idx}

             This means the LLM would see the child's message before knowing the spawn succeeded,
             which breaks causality and confuses the agent's decision making.
             """
    end

    @tag :acceptance
    test "multiple wait:true actions maintain correct ordering with interleaved messages", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # More complex scenario: multiple actions with messages in between
      parent_id = "parent-multi-#{System.unique_integer([:positive])}"

      parent_config = %{
        agent_id: parent_id,
        task_id: "task-#{System.unique_integer([:positive])}",
        parent_pid: nil,
        test_mode: true
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, state} = Core.get_state(parent_pid)

      # Action 1: orient with wait:true (capture expected auto-correction warning)
      action1 = %{action: :orient, params: %{"observations" => "First observation"}, wait: true}

      {state, _log} =
        with_log(fn ->
          ConsensusHandler.execute_consensus_action(state, action1, parent_pid)
        end)

      # Child 1 message (immediate reply to first action)
      state =
        Quoracle.Agent.StateUtils.add_history_entry(
          state,
          :event,
          %{from: "child-1", content: "Response to action 1"}
        )

      # Action 2: another orient with wait:true (capture expected auto-correction warning)
      action2 = %{action: :orient, params: %{"observations" => "Second observation"}, wait: true}

      {state, _log} =
        with_log(fn ->
          ConsensusHandler.execute_consensus_action(state, action2, parent_pid)
        end)

      # Child 2 message (immediate reply to second action)
      state =
        Quoracle.Agent.StateUtils.add_history_entry(
          state,
          :event,
          %{from: "child-2", content: "Response to action 2"}
        )

      # Verify ordering in LLM context
      model_id = state.model_histories |> Map.keys() |> List.first()
      messages = ContextManager.build_conversation_messages(state, model_id)

      # Extract indices
      indices =
        messages
        |> Enum.with_index()
        |> Enum.reduce(%{}, fn {msg, idx}, acc ->
          cond do
            msg.role == "assistant" && msg.content =~ "First observation" ->
              Map.put(acc, :action1, idx)

            msg.role == "user" && msg.content =~ "Response to action 1" ->
              Map.put(acc, :child1, idx)

            msg.role == "assistant" && msg.content =~ "Second observation" ->
              Map.put(acc, :action2, idx)

            msg.role == "user" && msg.content =~ "Response to action 2" ->
              Map.put(acc, :child2, idx)

            true ->
              acc
          end
        end)

      # Verify correct causal ordering
      assert indices[:action1] < indices[:child1],
             "Action 1 result must appear before Child 1 response"

      assert indices[:child1] < indices[:action2],
             "Child 1 response must appear before Action 2 result"

      assert indices[:action2] < indices[:child2],
             "Action 2 result must appear before Child 2 response"
    end
  end
end
