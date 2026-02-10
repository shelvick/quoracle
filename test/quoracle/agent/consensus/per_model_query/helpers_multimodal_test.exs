defmodule Quoracle.Agent.Consensus.PerModelQuery.HelpersMultimodalTest do
  @moduledoc """
  Tests for multimodal content handling in format_content_for_reflection/1.

  WorkGroupID: fix-20260116-233700
  Packet: 1 (Primary crash fix)

  These tests verify that MCP multimodal content (lists of text/image parts)
  is properly stringified instead of crashing with ArgumentError.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Consensus.PerModelQuery
  alias Quoracle.Agent.Consensus.PerModelQuery.Helpers

  describe "format_content_for_reflection/1 with list content (R45-R53)" do
    # R45: List content handled
    test "handles list content without crashing" do
      content = [
        %{type: :text, text: "Hello from MCP"},
        %{type: :image, data: <<0, 1, 2>>, media_type: "image/png"}
      ]

      result = Helpers.format_content_for_reflection(content)

      assert is_binary(result)
      assert result =~ "Hello from MCP"
    end

    # R46: Text parts extracted
    test "extracts text from :text type parts" do
      content = [
        %{type: :text, text: "First message"},
        %{type: :text, text: "Second message"}
      ]

      result = Helpers.format_content_for_reflection(content)

      assert result =~ "First message"
      assert result =~ "Second message"
    end

    # R46: Text parts extracted (atom key variant)
    test "extracts text from atom key text parts" do
      content = [%{type: :text, text: "Atom key text"}]

      result = Helpers.format_content_for_reflection(content)

      assert result == "Atom key text"
    end

    # R47: Image parts placeholder
    test "replaces :image type with [Image] placeholder" do
      content = [
        %{type: :image, data: <<0, 1, 2>>, media_type: "image/png"}
      ]

      result = Helpers.format_content_for_reflection(content)

      assert result == "[Image]"
    end

    # R47: Image URL variant
    test "replaces :image_url type with [Image: url] placeholder" do
      content = [
        %{type: :image_url, url: "https://example.com/image.png"}
      ]

      result = Helpers.format_content_for_reflection(content)

      assert result == "[Image: https://example.com/image.png]"
    end

    # R48: String keys supported
    test "handles string key content parts from MCP" do
      content = [
        %{"type" => "text", "text" => "String key text"},
        %{"type" => "image", "data" => <<0, 1, 2>>, "media_type" => "image/png"}
      ]

      result = Helpers.format_content_for_reflection(content)

      assert result =~ "String key text"
      assert result =~ "[Image]"
    end

    # R48: String key image_url
    test "handles string key image_url parts" do
      content = [
        %{"type" => "image_url", "url" => "https://example.com/pic.jpg"}
      ]

      result = Helpers.format_content_for_reflection(content)

      assert result == "[Image: https://example.com/pic.jpg]"
    end

    # R49: Mixed content types
    test "joins mixed text and image content with newlines" do
      content = [
        %{type: :text, text: "Before the image"},
        %{type: :image, data: <<0, 1, 2>>, media_type: "image/png"},
        %{type: :text, text: "After the image"}
      ]

      result = Helpers.format_content_for_reflection(content)

      # Should join with newlines
      assert result == "Before the image\n[Image]\nAfter the image"
    end

    # R50: Empty list
    test "handles empty list content" do
      result = Helpers.format_content_for_reflection([])

      assert result == ""
    end

    # R51: Nil content in parts
    test "handles nil text in content parts" do
      content = [
        %{type: :text, text: nil}
      ]

      result = Helpers.format_content_for_reflection(content)

      # Should not crash, return empty or fallback
      assert is_binary(result)
    end

    # R51: Missing text field
    test "handles content parts with missing text field" do
      content = [
        %{type: :text}
      ]

      result = Helpers.format_content_for_reflection(content)

      assert is_binary(result)
    end

    # R52: Unknown part types
    test "handles unknown content part types gracefully" do
      content = [
        %{type: :audio, data: <<0, 1, 2>>},
        %{type: :video, url: "https://example.com/video.mp4"}
      ]

      result = Helpers.format_content_for_reflection(content)

      # Should not crash, falls through to map handler
      assert is_binary(result)
    end

    # R52: Unknown type with string keys
    test "handles unknown string key types gracefully" do
      content = [
        %{"type" => "custom", "data" => "some data"}
      ]

      result = Helpers.format_content_for_reflection(content)

      assert is_binary(result)
    end

    # R53: Binary parts passthrough
    test "passes through binary strings in list" do
      content = ["Plain string one", "Plain string two"]

      result = Helpers.format_content_for_reflection(content)

      assert result =~ "Plain string one"
      assert result =~ "Plain string two"
    end

    # R53: Mixed binary and map parts
    test "handles mixed binary and map parts" do
      content = [
        "Plain string",
        %{type: :text, text: "Structured text"}
      ]

      result = Helpers.format_content_for_reflection(content)

      assert result =~ "Plain string"
      assert result =~ "Structured text"
    end
  end

  describe "format_content_for_reflection/1 existing behavior preserved" do
    test "passes through binary content unchanged" do
      result = Helpers.format_content_for_reflection("Simple string")

      assert result == "Simple string"
    end

    test "normalizes map content to JSON" do
      result = Helpers.format_content_for_reflection(%{key: "value"})

      assert is_binary(result)
      assert result =~ "key"
      assert result =~ "value"
    end

    test "normalizes tuple content to JSON" do
      result = Helpers.format_content_for_reflection({:ok, "result"})

      assert is_binary(result)
    end

    test "converts other types via to_string" do
      result = Helpers.format_content_for_reflection(42)

      assert result == "42"
    end
  end

  describe "format_messages_for_reflection/1 with multimodal content" do
    test "handles history entries with multimodal content" do
      history = [
        %{
          type: :result,
          content: [
            %{type: :text, text: "Screenshot captured"},
            %{type: :image, data: <<0, 1, 2>>, media_type: "image/png"}
          ]
        }
      ]

      result = Helpers.format_messages_for_reflection(history)

      assert length(result) == 1
      [message] = result
      assert message.role == "user"
      assert message.content =~ "Screenshot captured"
      assert message.content =~ "[Image]"
    end

    test "handles mixed history with multimodal and text entries" do
      history = [
        %{type: :user, content: "Take a screenshot"},
        %{
          type: :result,
          content: [
            %{type: :text, text: "Here is the screenshot"},
            %{type: :image, data: <<0, 1, 2>>, media_type: "image/png"}
          ]
        },
        %{type: :assistant, content: "I see the screenshot shows..."}
      ]

      result = Helpers.format_messages_for_reflection(history)

      assert length(result) == 3

      # First message: user
      assert Enum.at(result, 0).role == "user"
      assert Enum.at(result, 0).content == "Take a screenshot"

      # Second message: result with multimodal (becomes user role)
      assert Enum.at(result, 1).role == "user"
      assert Enum.at(result, 1).content =~ "Here is the screenshot"
      assert Enum.at(result, 1).content =~ "[Image]"

      # Third message: assistant
      assert Enum.at(result, 2).role == "assistant"
      assert Enum.at(result, 2).content =~ "I see the screenshot"
    end
  end

  # ========== ACCEPTANCE TEST (A1) ==========

  describe "full consensus cycle with multimodal content (A1)" do
    @tag :acceptance
    test "consensus cycle completes with multimodal MCP content" do
      # This acceptance test verifies the full reflection/condensation cycle
      # doesn't crash when history contains multimodal content (MCP screenshots).
      #
      # USER OBSERVABLE BEHAVIOR:
      # - User sends MCP screenshot to agent during consensus
      # - Agent processes image and continues consensus cycle without crash
      #
      # The crash occurred at helpers.ex:47 when format_content_for_reflection
      # called to_string() on a list of content parts.

      model_id = "anthropic:claude-sonnet-4"

      # Build history with multimodal MCP content (screenshot result)
      history_with_multimodal = [
        %{type: :user, content: "Take a screenshot of the webpage"},
        %{
          type: :assistant,
          content: "I'll take a screenshot using the MCP browser tool."
        },
        %{
          type: :result,
          content: [
            %{type: :text, text: "Screenshot captured successfully"},
            %{type: :image, data: <<0, 1, 2, 3>>, media_type: "image/png"}
          ]
        },
        %{type: :assistant, content: "I can see the webpage shows a login form."},
        %{type: :user, content: "What elements are visible?"},
        %{type: :assistant, content: "The form has username and password fields."}
      ]

      # Build state that would trigger reflection during condensation
      state = %{
        agent_id: "multimodal-test-#{System.unique_integer([:positive])}",
        task_id: Ecto.UUID.generate(),
        restoration_mode: false,
        model_histories: %{model_id => history_with_multimodal},
        context_lessons: %{},
        model_states: %{}
      }

      # Mock the reflector to verify messages are properly formatted
      # The bug causes a crash BEFORE this function is called
      table_name = :"captured_messages_#{System.unique_integer([:positive])}"
      captured_messages = :ets.new(table_name, [:set, :public])

      reflector_fn = fn messages, _model_id, _opts ->
        :ets.insert(captured_messages, {:messages, messages})

        {:ok,
         %{
           lessons: [%{type: :factual, content: "Learned from screenshot", confidence: 1}],
           state: [%{summary: "Analyzed webpage screenshot", updated_at: DateTime.utc_now()}]
         }}
      end

      opts = [
        reflector_fn: reflector_fn,
        test_mode: true,
        embedding_fn: fn _text -> {:ok, %{embedding: [0.1, 0.2, 0.3]}} end
      ]

      # ACTION: Call the condensation function that triggers format_messages_for_reflection
      # This MUST NOT crash with ArgumentError
      result =
        PerModelQuery.condense_model_history_with_reflection(
          state,
          model_id,
          opts
        )

      # POSITIVE ASSERTION: Condensation completes without crash
      assert is_map(result), "Condensation should return updated state map"
      assert Map.has_key?(result, :model_histories), "Result should have model_histories"

      # Verify reflector received properly formatted messages (not garbled list output)
      [{:messages, formatted_messages}] = :ets.lookup(captured_messages, :messages)
      :ets.delete(captured_messages)

      assert is_list(formatted_messages), "Formatted messages should be a list"

      # Find the message that came from the multimodal result
      result_message =
        Enum.find(formatted_messages, fn msg ->
          msg.content =~ "Screenshot" or msg.content =~ "[Image]"
        end)

      assert result_message != nil,
             "Should find message with screenshot content. Got: #{inspect(Enum.map(formatted_messages, & &1.content))}"

      # NEGATIVE ASSERTION: Content should NOT be garbled Elixir list representation
      refute result_message.content =~ "%{type:",
             "Content should not contain raw Elixir map syntax"

      refute result_message.content =~ "[%{",
             "Content should not contain raw Elixir list-of-maps syntax"

      # Content should have human-readable format with both text and image placeholder
      assert result_message.content =~ "[Image]",
             "Image should be formatted as [Image] placeholder"

      assert result_message.content =~ "Screenshot",
             "Text should be extracted from screenshot content"
    end
  end
end
