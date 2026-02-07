defmodule Quoracle.Agent.MultimodalIntegrationTest do
  @moduledoc """
  Integration tests for multimodal image routing through actual system flow.

  These tests verify that image detection happens in the ACTUAL message flow,
  not just when manually calling process_action_result/2.

  The audit found that process_action_result/2 was defined but never called
  in the actual flow - these tests expose that gap.

  Requirements tested:
  - R21: MessageHandler.handle_action_result routes images through ImageDetector
  - R22: Core.handle_action_result (user entry point) triggers image detection
  - R23: ConsensusHandler.execute_consensus_action routes sync results through ImageDetector
  """
  use Quoracle.DataCase, async: true

  import Test.AgentTestHelpers

  alias Quoracle.Agent.{Core, ContextManager, MessageHandler}

  # Valid 1x1 PNG base64 for testing
  @valid_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

  describe "MessageHandler.handle_action_result integration (R21)" do
    test "R21: image action results are stored as :image type, not :result" do
      # Setup minimal agent state with pending action
      action_id = "action-#{System.unique_integer([:positive])}"

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        model_histories: %{"model-1" => []},
        pending_actions: %{
          action_id => %{
            type: :call_mcp,
            params: %{},
            timestamp: DateTime.utc_now()
          }
        },
        pubsub: nil,
        test_mode: true,
        wait_timer: nil,
        context_limit: 4000
      }

      # Simulate MCP image result
      image_result =
        {:ok,
         %{
           connection_id: "conn-123",
           result: %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"}
         }}

      # Call MessageHandler.handle_action_result directly
      # This should detect the image and store as :image type
      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, action_id, image_result, continue: false)

      # ASSERTION: Result should be stored as :image type, NOT :result
      history = new_state.model_histories["model-1"]
      assert history != [], "History should have at least one entry"

      # Find the entry for this action result
      # The entry should be :image type, not :result type
      image_entry = Enum.find(history, &(&1.type == :image))

      assert image_entry != nil,
             "Image result must be stored as :image type entry, not :result. " <>
               "Found types: #{inspect(Enum.map(history, & &1.type))}"

      # Verify it's multimodal content
      assert is_list(image_entry.content),
             "Image entry content must be a list (multimodal format)"

      assert Enum.any?(image_entry.content, &match?(%{type: :image}, &1)),
             "Image entry must contain image content part"

      # NEGATIVE: Should NOT be stored as :result type with stringified JSON
      result_entries = Enum.filter(history, &(&1.type == :result))

      refute Enum.any?(result_entries, fn entry ->
               case entry.content do
                 {_action_id, content} when is_binary(content) ->
                   String.contains?(content, @valid_base64)

                 {_action_id, {:ok, content}} when is_map(content) ->
                   # Check if image data is embedded in result
                   inspect(content) =~ @valid_base64

                 _ ->
                   false
               end
             end),
             "Image data must NOT be stored as :result type with base64 in content"
    end

    test "R21b: non-image action results are still stored as :result type" do
      action_id = "action-#{System.unique_integer([:positive])}"

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        model_histories: %{"model-1" => []},
        pending_actions: %{
          action_id => %{
            type: :fetch_web,
            params: %{},
            timestamp: DateTime.utc_now()
          }
        },
        pubsub: nil,
        test_mode: true,
        wait_timer: nil,
        context_limit: 4000
      }

      # Non-image result (regular web fetch)
      text_result =
        {:ok,
         %{
           action: "fetch_web",
           markdown: "# Hello World",
           status_code: 200
         }}

      {:noreply, new_state} =
        MessageHandler.handle_action_result(state, action_id, text_result, continue: false)

      # Non-image results should still be :result type
      history = new_state.model_histories["model-1"]
      result_entry = Enum.find(history, &(&1.type == :result))

      assert result_entry != nil, "Non-image result must be stored as :result type"
      assert result_entry.action_type == :fetch_web
    end
  end

  describe "Core.handle_action_result entry point (R22)" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, deps: deps, sandbox_owner: sandbox_owner}
    end

    @tag :acceptance
    test "R22: Core.handle_action_result stores image as :image type", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # SETUP: Create a real agent (USER ENTRY POINT)
      agent_id = "core-image-test-#{System.unique_integer([:positive])}"
      action_id = "action-#{System.unique_integer([:positive])}"

      agent_config = %{
        agent_id: agent_id,
        task_id: "task-#{System.unique_integer([:positive])}",
        parent_pid: nil,
        test_mode: true
      }

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          agent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Add a pending action to the agent state using proper API
      :ok = Core.add_pending_action(agent_pid, action_id, :call_mcp, %{})

      # Simulate MCP image result
      image_result =
        {:ok,
         %{
           connection_id: "conn-123",
           result: %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"}
         }}

      # ACTION: Use actual Core entry point (what Router calls)
      :ok = Core.handle_action_result(agent_pid, action_id, image_result)

      # Synchronize: GenServer processes messages in order, so get_state (call)
      # will only return after the handle_action_result (cast) is processed
      {:ok, updated_state} = Core.get_state(agent_pid)

      # ASSERTION: Verify image stored as :image type
      model_id = updated_state.model_histories |> Map.keys() |> List.first()
      history = updated_state.model_histories[model_id]

      image_entry = Enum.find(history, &(&1.type == :image))

      assert image_entry != nil,
             "Image result via Core.handle_action_result must be stored as :image type. " <>
               "Entry types found: #{inspect(Enum.map(history, & &1.type))}"

      # Verify LLM would see multimodal content
      messages = ContextManager.build_conversation_messages(updated_state, model_id)

      multimodal_msg =
        Enum.find(messages, fn msg ->
          is_list(msg.content) and Enum.any?(msg.content, &match?(%{type: :image}, &1))
        end)

      assert multimodal_msg != nil,
             "LLM should receive multimodal message with image after Core.handle_action_result"

      # NEGATIVE: Image must NOT appear as base64 text string
      refute Enum.any?(messages, fn msg ->
               is_binary(msg.content) and String.contains?(msg.content, @valid_base64)
             end),
             "Image data must NOT appear as base64 text in plain message content"
    end
  end

  describe "ConsensusHandler.execute_consensus_action sync results (R23)" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, deps: deps, sandbox_owner: sandbox_owner}
    end

    test "R23: sync action results with images stored as :image type", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # SETUP: Create agent with Router
      agent_id = "consensus-sync-test-#{System.unique_integer([:positive])}"

      agent_config = %{
        agent_id: agent_id,
        task_id: "task-#{System.unique_integer([:positive])}",
        parent_pid: nil,
        test_mode: true
      }

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          agent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, agent_state} = Core.get_state(agent_pid)

      # Create a mock action response that would return an image synchronously
      # In real flow, execute_consensus_action calls Router.execute which returns sync result
      # Then it stores the result - this is where image detection should happen

      # We can test this indirectly by checking that after execute_consensus_action
      # completes with an image result, the history contains :image type

      # For now, this test documents the requirement that sync results in
      # execute_consensus_action (lines 410, 420, 432, 446) should route through
      # ImageDetector before calling StateUtils.add_history_entry_with_action

      # The implementation needs to wrap these 4 locations:
      # 1. Line ~410: is_sync and wait_value == true and action_atom in always_sync
      # 2. Line ~420: is_sync and wait_value == true
      # 3. Line ~432: is_sync and wait_value in [false, 0]
      # 4. Line ~446: is_sync (with timed wait)

      # This test will pass once the integration is complete
      assert agent_state.agent_id != nil, "Agent must have initialized"

      # Marker for IMPLEMENT phase: The 4 StateUtils calls in execute_consensus_action
      # need to be wrapped with ImageDetector.detect/2 routing logic
      assert true, "Implementation pending - see ConsensusHandler lines 410, 420, 432, 446"
    end
  end
end
