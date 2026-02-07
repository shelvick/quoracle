defmodule Quoracle.Models.ModelQuery.MessageBuilderCompressionTest do
  @moduledoc """
  Tests for ImageCompressor integration in MessageBuilder.
  Verifies that oversized images are automatically compressed before
  being sent to LLM providers.

  WorkGroupID: feat-20260116-211126
  Packet: 2 (MessageBuilder Integration)

  Performance: Test images are generated once via setup_all and reused.
  This is safe because test images are immutable binaries (read-only shared data).
  """
  use ExUnit.Case, async: true

  alias Quoracle.Models.ModelQuery.MessageBuilder

  # =============================================================================
  # Test Fixtures (Generated Once, Reused Across Tests)
  # =============================================================================
  # NOTE: Using setup_all for immutable read-only test data is safe with async: true.
  # These binaries are never modified by tests - only read for compression testing.

  setup_all do
    # Generate small image (under 4.5MB limit) - fast, ~2ms
    {:ok, small} =
      Image.new!(100, 100, color: :blue)
      |> Image.write(:memory, suffix: ".png")

    # Generate oversized image (over 4.5MB limit) - expensive, ~2.8s
    # 6000x5000 gaussnoise creates ~4.78MB PNG
    {:ok, noise} = Vix.Vips.Operation.gaussnoise(6000, 5000)
    {:ok, oversized} = Vix.Vips.Image.write_to_buffer(noise, ".png")

    %{small: small, oversized: oversized}
  end

  # =============================================================================
  # R39: Compression Called for Atom Image Types
  # =============================================================================

  describe "compression for atom :image type" do
    test "compresses oversized image with atom type and media_type", %{oversized: oversized} do
      assert byte_size(oversized) > 4_500_000, "Test image should be over 4.5MB"

      messages = [
        %{
          role: "user",
          content: [
            %{type: :image, data: oversized, media_type: "image/png"}
          ]
        }
      ]

      [built_message] = MessageBuilder.build_messages(messages)
      [content_part] = built_message.content

      # The image data in the ContentPart should be compressed (smaller than original)
      assert byte_size(content_part.data) < byte_size(oversized),
             "Image should be compressed: #{byte_size(content_part.data)} < #{byte_size(oversized)}"

      assert byte_size(content_part.data) <= 4_500_000,
             "Compressed image should be under 4.5MB"
    end

    test "compresses oversized image with atom type without media_type", %{oversized: oversized} do
      assert byte_size(oversized) > 4_500_000, "Test image should be over 4.5MB"

      messages = [
        %{
          role: "user",
          content: [
            %{type: :image, data: oversized}
          ]
        }
      ]

      [built_message] = MessageBuilder.build_messages(messages)
      [content_part] = built_message.content

      # Should be compressed even without explicit media_type
      assert byte_size(content_part.data) < byte_size(oversized),
             "Image should be compressed"
    end
  end

  # =============================================================================
  # R40: Compression Called for String Image Types
  # =============================================================================

  describe "compression for string image type" do
    test "compresses oversized image with string type and media_type", %{oversized: oversized} do
      assert byte_size(oversized) > 4_500_000, "Test image should be over 4.5MB"

      messages = [
        %{
          role: "user",
          content: [
            %{type: "image", data: oversized, media_type: "image/png"}
          ]
        }
      ]

      [built_message] = MessageBuilder.build_messages(messages)
      [content_part] = built_message.content

      assert byte_size(content_part.data) < byte_size(oversized),
             "Image should be compressed"
    end

    test "compresses oversized image with string type without media_type", %{oversized: oversized} do
      messages = [
        %{
          role: "user",
          content: [
            %{type: "image", data: oversized}
          ]
        }
      ]

      [built_message] = MessageBuilder.build_messages(messages)
      [content_part] = built_message.content

      assert byte_size(content_part.data) < byte_size(oversized),
             "Image should be compressed"
    end
  end

  # =============================================================================
  # R41: Compression Called for String Key Images
  # =============================================================================

  describe "compression for string key images" do
    test "compresses oversized image with string keys and media_type", %{oversized: oversized} do
      assert byte_size(oversized) > 4_500_000, "Test image should be over 4.5MB"

      messages = [
        %{
          role: "user",
          content: [
            %{"type" => "image", "data" => oversized, "media_type" => "image/png"}
          ]
        }
      ]

      [built_message] = MessageBuilder.build_messages(messages)
      [content_part] = built_message.content

      assert byte_size(content_part.data) < byte_size(oversized),
             "Image should be compressed"
    end

    test "compresses oversized image with string keys without media_type", %{oversized: oversized} do
      messages = [
        %{
          role: "user",
          content: [
            %{"type" => "image", "data" => oversized}
          ]
        }
      ]

      [built_message] = MessageBuilder.build_messages(messages)
      [content_part] = built_message.content

      assert byte_size(content_part.data) < byte_size(oversized),
             "Image should be compressed"
    end
  end

  # =============================================================================
  # R42: Small Images Pass Through Unchanged
  # =============================================================================

  describe "small image pass-through" do
    test "small images pass through unchanged via compression pipeline", %{
      small: small,
      oversized: oversized
    } do
      assert byte_size(small) < 4_500_000, "Test image should be under 4.5MB"
      assert byte_size(oversized) > 4_500_000, "Oversized image should be over 4.5MB"

      messages = [
        %{
          role: "user",
          content: [
            %{type: :image, data: small, media_type: "image/png"},
            %{type: :image, data: oversized, media_type: "image/png"}
          ]
        }
      ]

      [built_message] = MessageBuilder.build_messages(messages)
      [small_part, oversized_part] = built_message.content

      # Small image should pass through unchanged
      assert small_part.data == small,
             "Small image should pass through unchanged"

      # Oversized image MUST be compressed (proves compression pipeline is active)
      assert byte_size(oversized_part.data) < byte_size(oversized),
             "Oversized image must be compressed to prove compression is active"
    end
  end

  # =============================================================================
  # R43: Large Images Compressed
  # =============================================================================

  describe "large image compression" do
    test "large images are compressed before reaching ContentPart", %{oversized: oversized} do
      original_size = byte_size(oversized)
      assert original_size > 4_500_000, "Test image should be over 4.5MB"

      messages = [
        %{
          role: "user",
          content: [
            %{type: :image, data: oversized, media_type: "image/png"}
          ]
        }
      ]

      [built_message] = MessageBuilder.build_messages(messages)
      [content_part] = built_message.content

      compressed_size = byte_size(content_part.data)

      # Verify compression happened
      assert compressed_size < original_size,
             "Image should be smaller after compression"

      assert compressed_size <= 4_500_000,
             "Compressed image should fit within 4.5MB limit"
    end
  end

  # =============================================================================
  # R44: Media Type Preserved
  # =============================================================================

  describe "media type preservation" do
    test "media_type preserved through compression", %{oversized: oversized} do
      assert byte_size(oversized) > 4_500_000, "Test image should be over 4.5MB"

      messages = [
        %{
          role: "user",
          content: [
            %{type: :image, data: oversized, media_type: "image/png"}
          ]
        }
      ]

      [built_message] = MessageBuilder.build_messages(messages)
      [content_part] = built_message.content

      # Verify compression happened AND media_type preserved
      assert byte_size(content_part.data) < byte_size(oversized),
             "Image must be compressed first"

      assert content_part.media_type == "image/png",
             "Media type should be preserved after compression"
    end

    test "default media_type applied through compression pipeline", %{oversized: oversized} do
      assert byte_size(oversized) > 4_500_000, "Test image should be over 4.5MB"

      messages = [
        %{
          role: "user",
          content: [
            %{type: :image, data: oversized}
          ]
        }
      ]

      [built_message] = MessageBuilder.build_messages(messages)
      [content_part] = built_message.content

      # Verify compression happened AND default media_type applied
      assert byte_size(content_part.data) < byte_size(oversized),
             "Image must be compressed"

      assert content_part.media_type == "image/png",
             "Default media type should be image/png"
    end
  end
end
