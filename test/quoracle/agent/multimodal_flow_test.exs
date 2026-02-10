defmodule Quoracle.Agent.MultimodalFlowTest do
  @moduledoc """
  Integration and system tests for multimodal image routing (R13-R20).
  Tests the flow from action results through ConsensusHandler to LLM queries.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.ImageDetector
  alias Quoracle.Agent.ContextManager
  alias Quoracle.Agent.StateUtils

  # Valid 1x1 PNG base64 for testing
  @valid_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  # Raw bytes (decoded) - ImageDetector decodes base64 to raw bytes for ReqLLM
  @raw_image_bytes Base.decode64!(@valid_base64)

  describe "ConsensusHandler image routing (R13-R15)" do
    test "R13: image result stored as :image type in history" do
      # Setup agent state with model_histories
      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        model_histories: %{"model-1" => []}
      }

      # Simulate image action result
      image_result =
        {:ok,
         %{
           connection_id: "conn-123",
           result: %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"}
         }}

      # Detect image content
      {:image, multimodal_content} = ImageDetector.detect(image_result, :call_mcp)

      # Store as :image type
      new_state = StateUtils.add_history_entry(state, :image, multimodal_content)

      # Verify :image type stored
      [entry | _] = new_state.model_histories["model-1"]
      assert entry.type == :image
      assert is_list(entry.content)
      assert Enum.any?(entry.content, &match?(%{type: :image}, &1))
    end

    test "R14: non-image result stored as :result type unchanged" do
      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        model_histories: %{"model-1" => []}
      }

      # Non-image action result
      text_result =
        {:ok,
         %{
           action: "fetch_web",
           markdown: "# Hello World",
           status_code: 200
         }}

      # Detect should return :text
      {:text, original_result} = ImageDetector.detect(text_result, :fetch_web)

      # Store as :result type with action tracking
      new_state =
        StateUtils.add_history_entry_with_action(
          state,
          :result,
          {"action-123", original_result},
          :fetch_web
        )

      # Verify :result type stored
      [entry | _] = new_state.model_histories["model-1"]
      assert entry.type == :result
    end

    test "R15: image entry added to all model histories" do
      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        model_histories: %{
          "model-1" => [],
          "model-2" => [],
          "model-3" => []
        }
      }

      image_result =
        {:ok, %{result: %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"}}}

      {:image, multimodal_content} = ImageDetector.detect(image_result, :call_mcp)
      new_state = StateUtils.add_history_entry(state, :image, multimodal_content)

      # Verify all model histories have the image entry
      for {_model_id, history} <- new_state.model_histories do
        assert length(history) == 1
        [entry | _] = history
        assert entry.type == :image
      end
    end
  end

  describe "ContextManager image handling (R16-R17)" do
    test "R16: image entry flows through ContextManager as multimodal" do
      model_id = "test-model-#{System.unique_integer([:positive])}"

      # Create state with image entry in history
      image_content = [
        %{type: :text, text: ~s({"result":"[Image Attachment]"})},
        %{type: :image, data: @raw_image_bytes, media_type: "image/png"}
      ]

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        model_histories: %{
          model_id => [
            %{type: :image, content: image_content, timestamp: DateTime.utc_now()}
          ]
        },
        prompt_fields: %{injected: %{}, provided: %{}, transformed: %{}}
      }

      # Build conversation messages
      messages = ContextManager.build_conversation_messages(state, model_id)

      # Find the image message
      image_message =
        Enum.find(messages, fn msg ->
          is_list(msg.content) and Enum.any?(msg.content, &match?(%{type: :image}, &1))
        end)

      assert image_message != nil
      assert image_message.role == "user"
      assert is_list(image_message.content)
    end

    test "R17: timestamp prepended to image content list" do
      model_id = "test-model-#{System.unique_integer([:positive])}"
      timestamp = DateTime.utc_now()

      image_content = [
        %{type: :text, text: ~s({"result":"[Image Attachment]"})},
        %{type: :image, data: @raw_image_bytes, media_type: "image/png"}
      ]

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        model_histories: %{
          model_id => [
            %{type: :image, content: image_content, timestamp: timestamp}
          ]
        },
        prompt_fields: %{injected: %{}, provided: %{}, transformed: %{}}
      }

      messages = ContextManager.build_conversation_messages(state, model_id)

      image_message =
        Enum.find(messages, fn msg ->
          is_list(msg.content) and Enum.any?(msg.content, &match?(%{type: :image}, &1))
        end)

      assert image_message != nil
      # First element should be timestamp text
      [first_part | _rest] = image_message.content
      assert first_part.type == :text
      assert first_part.text =~ "["
      assert first_part.text =~ "]"
    end
  end

  describe "Full flow integration (R18)" do
    test "R18: ModelQuery receives multimodal content for image entry" do
      model_id = "test-model-#{System.unique_integer([:positive])}"

      image_content = [
        %{type: :text, text: ~s({"connection_id":"conn-123","result":"[Image Attachment]"})},
        %{type: :image, data: @raw_image_bytes, media_type: "image/png"}
      ]

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        model_histories: %{
          model_id => [
            %{type: :image, content: image_content, timestamp: DateTime.utc_now()}
          ]
        },
        prompt_fields: %{injected: %{}, provided: %{}, transformed: %{}}
      }

      messages = ContextManager.build_conversation_messages(state, model_id)

      # Verify messages contain multimodal content
      multimodal_message =
        Enum.find(messages, fn msg ->
          is_list(msg.content)
        end)

      assert multimodal_message != nil

      # Verify image part present
      image_part = Enum.find(multimodal_message.content, &match?(%{type: :image}, &1))
      assert image_part != nil
      assert image_part.data == @raw_image_bytes
      assert image_part.media_type == "image/png"
    end
  end

  describe "End-to-end system tests (R19-R20)" do
    import Test.AgentTestHelpers

    alias Quoracle.Agent.Core

    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, deps: deps, sandbox_owner: sandbox_owner}
    end

    @tag :acceptance
    test "R19: MCP screenshot flows through to LLM as image", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # SETUP: Create a real agent with real Router (USER ENTRY POINT)
      agent_id = "mcp-image-test-#{System.unique_integer([:positive])}"
      action_id = "action-mcp-#{System.unique_integer([:positive])}"

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

      # Get agent state
      {:ok, agent_state} = Core.get_state(agent_pid)
      assert agent_state.agent_id != nil, "Agent must have initialized"

      # Add pending action to agent state (simulating action dispatch)
      :ok = Core.add_pending_action(agent_pid, action_id, :call_mcp, %{})

      # Simulate MCP action result with image (what Router would return)
      mcp_image_result =
        {:ok,
         %{
           connection_id: "conn-123",
           result: %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"}
         }}

      # ACTION: Use ACTUAL entry point - Core.handle_action_result
      # This is what Router calls when action completes
      # The integration must route through ImageDetector.detect/2
      :ok = Core.handle_action_result(agent_pid, action_id, mcp_image_result)

      # Synchronize: GenServer processes messages in order, so get_state (call)
      # will only return after the handle_action_result (cast) is processed
      {:ok, updated_state} = Core.get_state(agent_pid)

      # ASSERTION: Verify LLM would see multimodal content (USER OBSERVABLE OUTCOME)
      model_id = updated_state.model_histories |> Map.keys() |> List.first()
      messages = ContextManager.build_conversation_messages(updated_state, model_id)

      multimodal_msg =
        Enum.find(messages, fn msg ->
          is_list(msg.content) and Enum.any?(msg.content, &match?(%{type: :image}, &1))
        end)

      assert multimodal_msg != nil,
             "LLM should receive multimodal message with image after MCP screenshot. " <>
               "Entry types in history: #{inspect(Enum.map(updated_state.model_histories[model_id], & &1.type))}"

      assert multimodal_msg.role == "user"

      # Verify image data is preserved
      image_part = Enum.find(multimodal_msg.content, &match?(%{type: :image}, &1))
      assert image_part.data == @raw_image_bytes
      assert image_part.media_type == "image/png"

      # NEGATIVE ASSERTIONS: Verify image is NOT stored as JSON-stringified text
      # Spec says: "actual image, not base64 text string"
      refute Enum.any?(messages, fn msg ->
               is_binary(msg.content) and String.contains?(msg.content, @valid_base64)
             end),
             "Image data must NOT appear as base64 text in plain message content"

      # Verify entry type is :image, NOT :result
      history_entries = updated_state.model_histories[model_id]
      image_entry = Enum.find(history_entries, &(&1.type == :image))
      assert image_entry != nil, "Image must be stored as :image type entry"

      refute Enum.any?(history_entries, fn entry ->
               entry.type == :result and is_binary(entry.content) and
                 String.contains?(entry.content, "\"type\":\"image\"")
             end),
             "Image must NOT be stored as :result type with JSON-stringified content"
    end

    @tag :acceptance
    test "R20: API image response flows through to LLM", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # SETUP: Create a real agent (USER ENTRY POINT)
      agent_id = "api-image-test-#{System.unique_integer([:positive])}"
      action_id = "action-api-#{System.unique_integer([:positive])}"

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

      {:ok, _agent_state} = Core.get_state(agent_pid)

      # Add pending action to agent state (simulating action dispatch)
      :ok = Core.add_pending_action(agent_pid, action_id, :call_api, %{})

      # Simulate API action result with JPEG image
      api_image_result =
        {:ok,
         %{
           status: 200,
           result: %{type: "image", data: @valid_base64, mimeType: "image/jpeg"}
         }}

      # ACTION: Use ACTUAL entry point - Core.handle_action_result
      :ok = Core.handle_action_result(agent_pid, action_id, api_image_result)

      # Synchronize: GenServer processes messages in order, so get_state (call)
      # will only return after the handle_action_result (cast) is processed
      {:ok, updated_state} = Core.get_state(agent_pid)

      # ASSERTION: Verify LLM sees image in conversation (USER OBSERVABLE OUTCOME)
      model_id = updated_state.model_histories |> Map.keys() |> List.first()
      messages = ContextManager.build_conversation_messages(updated_state, model_id)

      has_image_message =
        Enum.any?(messages, fn msg ->
          is_list(msg.content) and Enum.any?(msg.content, &match?(%{type: :image}, &1))
        end)

      assert has_image_message,
             "LLM should see JPEG image in conversation context after API response. " <>
               "Entry types in history: #{inspect(Enum.map(updated_state.model_histories[model_id], & &1.type))}"

      # Verify JPEG media type preserved
      multimodal_msg =
        Enum.find(messages, fn msg ->
          is_list(msg.content) and Enum.any?(msg.content, &match?(%{type: :image}, &1))
        end)

      image_part = Enum.find(multimodal_msg.content, &match?(%{type: :image}, &1))
      assert image_part.media_type == "image/jpeg"

      # NEGATIVE ASSERTIONS: Verify image is NOT stored as JSON-stringified text
      # Spec says: "actual image, not base64 text string"
      refute Enum.any?(messages, fn msg ->
               is_binary(msg.content) and String.contains?(msg.content, @valid_base64)
             end),
             "Image data must NOT appear as base64 text in plain message content"

      # Verify entry type is :image, NOT :result
      history_entries = updated_state.model_histories[model_id]
      image_entry = Enum.find(history_entries, &(&1.type == :image))
      assert image_entry != nil, "Image must be stored as :image type entry"

      refute Enum.any?(history_entries, fn entry ->
               entry.type == :result and is_binary(entry.content) and
                 String.contains?(entry.content, "\"type\":\"image\"")
             end),
             "Image must NOT be stored as :result type with JSON-stringified content"
    end
  end
end
