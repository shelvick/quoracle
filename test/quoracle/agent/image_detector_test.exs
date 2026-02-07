defmodule Quoracle.Agent.ImageDetectorTest do
  @moduledoc """
  Unit tests for ImageDetector module (R1-R12).
  Tests detection of image content in action results and conversion to multimodal format.

  CRITICAL: All tests use UNWRAPPED results (just the map, not {:ok, map}) because
  that's what ConsensusHandler.process_action_result passes to ImageDetector.detect.
  Production flow: Router.execute returns {:ok, result} → ConsensusHandler unwraps it →
  calls process_action_result with just `result` → calls ImageDetector.detect(result, type)
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.ImageDetector

  # Valid 1x1 PNG base64 for testing
  @valid_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

  describe "detect/2 - MCP results (R1-R4)" do
    test "R1: detects MCP screenshot result" do
      # UNWRAPPED - matches production flow
      result = %{
        connection_id: "conn-123",
        result: %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"}
      }

      assert {:image, content} = ImageDetector.detect(result, :call_mcp)
      assert is_list(content)
      assert Enum.any?(content, &match?(%{type: :image}, &1))
      assert Enum.any?(content, &match?(%{type: :text}, &1))
    end

    test "R2: detects image URL result" do
      # UNWRAPPED - matches production flow
      result = %{
        result: %{"type" => "image_url", "url" => "https://example.com/screenshot.png"}
      }

      assert {:image, content} = ImageDetector.detect(result, :call_mcp)
      assert is_list(content)

      assert Enum.any?(content, fn part ->
               match?(%{type: :image_url, url: "https://example.com/screenshot.png"}, part)
             end)
    end

    test "R3: detects image nested in result field" do
      # UNWRAPPED - matches production flow
      result = %{
        status: "ok",
        result: %{type: "image", data: @valid_base64, mimeType: "image/png"}
      }

      assert {:image, content} = ImageDetector.detect(result, :call_api)
      assert is_list(content)
      assert Enum.any?(content, &match?(%{type: :image}, &1))
    end

    test "R4: detects array of multiple images" do
      # UNWRAPPED - matches production flow
      result = %{
        result: [
          %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"},
          %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/jpeg"}
        ]
      }

      assert {:image, content} = ImageDetector.detect(result, :call_mcp)
      assert is_list(content)
      # Should have 2 image parts plus text placeholder
      image_parts = Enum.filter(content, &match?(%{type: :image}, &1))
      assert length(image_parts) == 2
    end
  end

  describe "detect/2 - format handling (R5-R10)" do
    test "R5: passes through non-image results unchanged" do
      # UNWRAPPED - matches production flow
      result = %{
        action: "fetch_web",
        markdown: "# Hello World",
        status_code: 200
      }

      assert {:text, ^result} = ImageDetector.detect(result, :fetch_web)
    end

    test "R6: handles string keys from JSON" do
      # UNWRAPPED - matches production flow
      result = %{
        "result" => %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"}
      }

      assert {:image, content} = ImageDetector.detect(result, :call_mcp)
      assert is_list(content)
      assert Enum.any?(content, &match?(%{type: :image}, &1))
    end

    test "R7: handles atom keys from Elixir" do
      # UNWRAPPED - matches production flow
      result = %{
        result: %{type: :image, data: @valid_base64, media_type: "image/png"}
      }

      assert {:image, content} = ImageDetector.detect(result, :call_mcp)
      assert is_list(content)
      assert Enum.any?(content, &match?(%{type: :image}, &1))
    end

    test "R8: creates JSON with Image Attachment placeholder" do
      # UNWRAPPED - matches production flow
      result = %{
        connection_id: "conn-123",
        result: %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"}
      }

      assert {:image, content} = ImageDetector.detect(result, :call_mcp)
      text_part = Enum.find(content, &match?(%{type: :text}, &1))
      assert text_part != nil
      assert text_part.text =~ "[Image Attachment]"
      assert text_part.text =~ "connection_id"
    end

    test "R9: extracts and normalizes media type" do
      # UNWRAPPED - matches production flow
      # Test mimeType key
      result1 = %{
        result: %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"}
      }

      assert {:image, content1} = ImageDetector.detect(result1, :call_mcp)
      image_part1 = Enum.find(content1, &match?(%{type: :image}, &1))
      assert image_part1.media_type == "image/png"

      # Test media_type key
      result2 = %{result: %{type: "image", data: @valid_base64, media_type: "image/jpeg"}}

      assert {:image, content2} = ImageDetector.detect(result2, :call_mcp)
      image_part2 = Enum.find(content2, &match?(%{type: :image}, &1))
      assert image_part2.media_type == "image/jpeg"
    end

    test "R10: defaults to image/png when media type missing" do
      # UNWRAPPED - matches production flow
      result = %{result: %{"type" => "image", "data" => @valid_base64}}

      assert {:image, content} = ImageDetector.detect(result, :call_mcp)
      image_part = Enum.find(content, &match?(%{type: :image}, &1))
      assert image_part.media_type == "image/png"
    end
  end

  describe "detect/2 - error handling (R11-R12)" do
    test "R11: handles malformed image data gracefully" do
      # UNWRAPPED - matches production flow
      # Invalid base64 data
      result = %{
        result: %{
          "type" => "image",
          "data" => "not-valid-base64!!!",
          "mimeType" => "image/png"
        }
      }

      # Should fall back to text type
      assert {:text, ^result} = ImageDetector.detect(result, :call_mcp)
    end

    test "R12: handles missing data field" do
      # UNWRAPPED - matches production flow
      result = %{result: %{"type" => "image", "mimeType" => "image/png"}}

      # Should fall back to text type when data is missing
      assert {:text, ^result} = ImageDetector.detect(result, :call_mcp)
    end
  end

  describe "detect/2 - MCP content field with JSON-wrapped images (R21-R24)" do
    test "R21: detects image in MCP :content array" do
      # UNWRAPPED - matches production flow
      # MCP responses use :content field, not nested :result
      result = %{
        connection_id: "conn-123",
        result: %{
          "content" => [
            %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"}
          ],
          "isError" => false
        }
      }

      assert {:image, content} = ImageDetector.detect(result, :call_mcp)
      assert is_list(content)
      assert Enum.any?(content, &match?(%{type: :image}, &1))
    end

    test "R22: detects JSON-wrapped image in text content block" do
      # UNWRAPPED - matches production flow
      # The actual MCP bug: image is JSON-encoded inside a type: "text" block
      json_image =
        Jason.encode!(%{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"})

      result = %{
        connection_id: "conn-123",
        result: %{
          "content" => [
            %{"type" => "text", "text" => json_image}
          ],
          "isError" => false
        }
      }

      assert {:image, content} = ImageDetector.detect(result, :call_mcp)
      assert is_list(content)
      assert Enum.any?(content, &match?(%{type: :image}, &1))
    end

    test "R23: handles mixed content with JSON-wrapped image" do
      # UNWRAPPED - matches production flow
      json_image =
        Jason.encode!(%{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"})

      result = %{
        connection_id: "conn-123",
        result: %{
          "content" => [
            %{"type" => "text", "text" => "Some regular text"},
            %{"type" => "text", "text" => json_image}
          ],
          "isError" => false
        }
      }

      assert {:image, content} = ImageDetector.detect(result, :call_mcp)
      assert is_list(content)
      assert Enum.any?(content, &match?(%{type: :image}, &1))
    end

    test "R24: ignores non-image JSON in text blocks" do
      # UNWRAPPED - matches production flow
      json_data = Jason.encode!(%{"type" => "data", "value" => 123})

      result = %{
        connection_id: "conn-123",
        result: %{
          "content" => [
            %{"type" => "text", "text" => json_data}
          ],
          "isError" => false
        }
      }

      # Should NOT detect as image
      assert {:text, ^result} = ImageDetector.detect(result, :call_mcp)
    end
  end

  describe "detect/2 - API :data field (R25-R26)" do
    test "R25: detects image in API :data field" do
      # UNWRAPPED - matches production flow
      # API responses use :data field for body content
      result = %{
        action: "call_api",
        status_code: 200,
        data: %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"},
        errors: [],
        headers: %{},
        response_size: 1000,
        execution_time_ms: 50
      }

      assert {:image, content} = ImageDetector.detect(result, :call_api)
      assert is_list(content)
      assert Enum.any?(content, &match?(%{type: :image}, &1))
    end

    test "R26: detects nested image in API :data field" do
      # UNWRAPPED - matches production flow
      result = %{
        action: "call_api",
        status_code: 200,
        data: %{
          "response" => %{
            "image" => %{
              "type" => "image",
              "data" => @valid_base64,
              "mimeType" => "image/jpeg"
            }
          }
        },
        errors: [],
        headers: %{}
      }

      assert {:image, content} = ImageDetector.detect(result, :call_api)
      assert is_list(content)
      assert Enum.any?(content, &match?(%{type: :image}, &1))
    end
  end

  describe "detect/2 - REAL MCP response structure (R27-R28)" do
    @tag :integration
    test "R27: detects image in REAL MCP response with triple-nested result" do
      # UNWRAPPED - matches production flow
      # This is the EXACT structure from production MCP call_tool response
      # result.result.result.content (THREE levels of nesting!)
      json_image =
        Jason.encode!(%{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"})

      result = %{
        connection_id: "134211a2f1701f42b76117e14cb01d63",
        execution_time_ms: 70,
        result: %{
          "id" => "req_GINxAipjCarHY4cwLv4=",
          "is_error" => false,
          "method" => "tools/call",
          "result" => %{
            "content" => [
              %{"type" => "text", "text" => json_image}
            ],
            "isError" => false
          }
        }
      }

      assert {:image, content} = ImageDetector.detect(result, :call_mcp)
      assert is_list(content)
      assert Enum.any?(content, &match?(%{type: :image}, &1))
    end

    test "R28: detects direct image in REAL MCP response structure" do
      # UNWRAPPED - matches production flow
      # Same triple-nested structure but with direct image (not JSON-wrapped)
      result = %{
        connection_id: "134211a2f1701f42b76117e14cb01d63",
        execution_time_ms: 70,
        result: %{
          "id" => "req_abc123",
          "is_error" => false,
          "method" => "tools/call",
          "result" => %{
            "content" => [
              %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"}
            ],
            "isError" => false
          }
        }
      }

      assert {:image, content} = ImageDetector.detect(result, :call_mcp)
      assert is_list(content)
      assert Enum.any?(content, &match?(%{type: :image}, &1))
    end
  end

  describe "detect/2 - Anubis struct handling (R30)" do
    test "R30: handles Anubis.MCP.Response struct without crashing" do
      # UNWRAPPED - matches production flow
      # This tests the ACTUAL production structure with Anubis struct
      json_image =
        Jason.encode!(%{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"})

      # Simulate the Anubis.MCP.Response struct
      anubis_response = %Anubis.MCP.Response{
        result: %{
          "content" => [
            %{"type" => "text", "text" => json_image}
          ],
          "isError" => false
        },
        id: "req_test123",
        method: "tools/call",
        is_error: false
      }

      # UNWRAPPED - just the map, not {:ok, map}
      result = %{
        connection_id: "test-conn-id",
        execution_time_ms: 70,
        result: anubis_response
      }

      # Should NOT crash with Protocol.UndefinedError
      assert {:image, content} = ImageDetector.detect(result, :call_mcp)
      assert is_list(content)
      assert Enum.any?(content, &match?(%{type: :image}, &1))
    end
  end

  describe "detect/2 - ConsensusHandler integration (R29)" do
    test "R29: ConsensusHandler.process_action_result stores MCP image as :image type" do
      # This tests the ACTUAL integration path
      # ConsensusHandler.process_action_result receives UNWRAPPED result
      alias Quoracle.Agent.ConsensusHandler

      json_image =
        Jason.encode!(%{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"})

      # UNWRAPPED - This is what ConsensusHandler.process_action_result actually receives
      # after ConsensusHandler.execute_consensus_action_impl unwraps {:ok, result}
      result = %{
        connection_id: "134211a2f1701f42b76117e14cb01d63",
        execution_time_ms: 70,
        result: %{
          "id" => "req_GINxAipjCarHY4cwLv4=",
          "is_error" => false,
          "method" => "tools/call",
          "result" => %{
            "content" => [
              %{"type" => "text", "text" => json_image}
            ],
            "isError" => false
          }
        }
      }

      # Create minimal state with model_histories
      state = %{
        model_histories: %{
          "model_1" => [],
          "model_2" => []
        }
      }

      # Process through ConsensusHandler.process_action_result
      # This is EXACTLY how production calls it - with UNWRAPPED result
      new_state = ConsensusHandler.process_action_result(state, {:call_mcp, "action_123", result})

      # Verify result was stored as :image type, not :result type
      model_1_history = new_state.model_histories["model_1"]
      assert length(model_1_history) == 1

      entry = hd(model_1_history)
      assert entry.type == :image, "Expected :image type but got #{inspect(entry.type)}"

      # Verify multimodal content structure
      assert is_list(entry.content)
      assert Enum.any?(entry.content, &match?(%{type: :image}, &1))
    end

    test "R31: ConsensusHandler.process_action_result stores API image as :image type" do
      # Same test but for call_api action
      alias Quoracle.Agent.ConsensusHandler

      # UNWRAPPED API result with image in data field
      result = %{
        action: "call_api",
        status_code: 200,
        data: %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"},
        errors: [],
        headers: %{},
        response_size: 1000,
        execution_time_ms: 50
      }

      state = %{
        model_histories: %{
          "model_1" => [],
          "model_2" => []
        }
      }

      new_state = ConsensusHandler.process_action_result(state, {:call_api, "action_456", result})

      model_1_history = new_state.model_histories["model_1"]
      assert length(model_1_history) == 1

      entry = hd(model_1_history)
      assert entry.type == :image, "Expected :image type but got #{inspect(entry.type)}"

      assert is_list(entry.content)
      assert Enum.any?(entry.content, &match?(%{type: :image}, &1))
    end
  end

  describe "image_content?/1" do
    test "returns true for base64 image map" do
      value = %{"type" => "image", "data" => @valid_base64, "mimeType" => "image/png"}
      assert ImageDetector.image_content?(value) == true
    end

    test "returns true for image_url map" do
      value = %{"type" => "image_url", "url" => "https://example.com/image.png"}
      assert ImageDetector.image_content?(value) == true
    end

    test "returns false for text content" do
      value = %{"type" => "text", "content" => "Hello world"}
      assert ImageDetector.image_content?(value) == false
    end

    test "returns false for non-map values" do
      assert ImageDetector.image_content?("string") == false
      assert ImageDetector.image_content?(123) == false
      assert ImageDetector.image_content?(nil) == false
    end
  end
end
