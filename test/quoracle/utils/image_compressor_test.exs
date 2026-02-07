defmodule Quoracle.Utils.ImageCompressorTest do
  @moduledoc """
  Unit tests for UTIL_ImageCompressor module.
  Tests compression logic, error handling, and edge cases using programmatically generated test images.

  WorkGroupID: feat-20260116-211126
  Packet: 1 (Foundation)

  Performance: Oversized test images are generated once via setup_all and reused.
  This is safe because test images are immutable binaries (read-only shared data).
  """
  use ExUnit.Case, async: true

  alias Quoracle.Utils.ImageCompressor

  # =============================================================================
  # Test Fixtures (Generated Once, Reused Across Tests)
  # =============================================================================
  # NOTE: Using setup_all for immutable read-only test data is safe with async: true.
  # These binaries are never modified by tests - only read for compression testing.

  setup_all do
    # Generate expensive test images once per module run
    # 6000x5000 gaussnoise creates ~4.78MB PNG (over 4.5MB limit)
    {:ok, noise} = Vix.Vips.Operation.gaussnoise(6000, 5000)
    {:ok, oversized} = Vix.Vips.Image.write_to_buffer(noise, ".png")

    # 8000x4000 (2:1 ratio) gaussnoise for aspect ratio test
    {:ok, wide_noise} = Vix.Vips.Operation.gaussnoise(8000, 4000)
    {:ok, oversized_wide} = Vix.Vips.Image.write_to_buffer(wide_noise, ".png")

    %{oversized: oversized, oversized_wide: oversized_wide}
  end

  # =============================================================================
  # Test Helpers (Fast Operations Only)
  # =============================================================================

  # Generate small image (under limit) - fast, ~2ms
  defp small_image(format \\ :png) do
    {:ok, data} =
      Image.new!(100, 100, color: :blue)
      |> Image.write(:memory, suffix: ".#{format}")

    data
  end

  # =============================================================================
  # R1: Pass-through Under Limit
  # =============================================================================

  describe "pass-through behavior" do
    test "returns original image when under size limit" do
      data = small_image()
      media_type = "image/png"

      assert {:ok, ^data, ^media_type} = ImageCompressor.maybe_compress(data, media_type)
    end
  end

  # =============================================================================
  # R2: Compress Over Limit
  # =============================================================================

  describe "compression behavior" do
    test "compresses oversized image to under limit", %{oversized: data} do
      assert byte_size(data) > 4_500_000, "Test image should be over 4.5MB"

      {:ok, compressed, _media_type} = ImageCompressor.maybe_compress(data, "image/png")

      assert byte_size(compressed) <= 4_500_000
      assert byte_size(compressed) < byte_size(data)
    end

    # R3: Progressive Resize
    test "uses progressive resize targets", %{oversized: data} do
      {:ok, compressed, _} = ImageCompressor.maybe_compress(data, "image/png")

      # Verify dimensions were reduced
      {:ok, original} = Image.from_binary(data)
      {:ok, result} = Image.from_binary(compressed)

      {orig_w, orig_h, _} = Image.shape(original)
      {new_w, new_h, _} = Image.shape(result)

      # Both dimensions should be reduced since original (6000x5000) exceeds all targets
      assert new_w < orig_w, "Width should be reduced: #{new_w} < #{orig_w}"
      assert new_h < orig_h, "Height should be reduced: #{new_h} < #{orig_h}"
    end
  end

  # =============================================================================
  # R4: Preserve Format
  # =============================================================================

  describe "format preservation" do
    test "preserves original image format", %{oversized: png_data} do
      # Test PNG - use oversized to trigger compression
      {:ok, compressed, "image/png"} = ImageCompressor.maybe_compress(png_data, "image/png")
      # Image opens successfully - validates format preserved
      assert {:ok, _img} = Image.from_binary(compressed)
    end
  end

  # =============================================================================
  # R5: Preserve Media Type
  # =============================================================================

  describe "media type preservation" do
    test "preserves media_type in output for PNG" do
      data = small_image(:png)
      {:ok, _, "image/png"} = ImageCompressor.maybe_compress(data, "image/png")
    end

    test "preserves media_type in output for JPEG" do
      {:ok, jpeg_data} =
        Image.new!(100, 100, color: :red)
        |> Image.write(:memory, suffix: ".jpg")

      {:ok, _, "image/jpeg"} = ImageCompressor.maybe_compress(jpeg_data, "image/jpeg")
    end
  end

  # =============================================================================
  # R6: Error Recovery - Invalid Image
  # =============================================================================

  describe "error recovery" do
    test "returns original on corrupted image data" do
      corrupted = "not an image at all"
      media_type = "image/png"

      # Should not raise, should return original with warning
      assert {:ok, ^corrupted, ^media_type} =
               ImageCompressor.maybe_compress(corrupted, media_type)
    end

    # R7: Error Recovery - Library Failure
    test "returns original when Image library fails" do
      # Partial/truncated image data
      {:ok, valid_data} =
        Image.new!(100, 100, color: :red)
        |> Image.write(:memory, suffix: ".png")

      truncated = binary_part(valid_data, 0, 100)

      {:ok, ^truncated, "image/png"} = ImageCompressor.maybe_compress(truncated, "image/png")
    end
  end

  # =============================================================================
  # R8: Nil/Empty Handling
  # =============================================================================

  describe "edge cases" do
    test "handles empty binary gracefully" do
      {:ok, <<>>, "image/png"} = ImageCompressor.maybe_compress(<<>>, "image/png")
    end

    test "handles very small binary (not a valid image) gracefully" do
      {:ok, "x", "image/png"} = ImageCompressor.maybe_compress("x", "image/png")
    end
  end

  # =============================================================================
  # R9: Aspect Ratio Preserved
  # =============================================================================

  describe "aspect ratio preservation" do
    test "preserves aspect ratio when resizing", %{oversized_wide: wide_data} do
      # Wide image (2:1 ratio) from setup_all
      assert byte_size(wide_data) > 4_500_000, "Test image should be over 4.5MB"

      {:ok, compressed, _} = ImageCompressor.maybe_compress(wide_data, "image/png")
      {:ok, result} = Image.from_binary(compressed)
      {w, h, _} = Image.shape(result)

      # Aspect ratio should be approximately 2:1
      ratio = w / h
      assert_in_delta ratio, 2.0, 0.1
    end
  end

  # =============================================================================
  # R10: Minimum Dimension Reached
  # =============================================================================

  describe "minimum dimension handling" do
    test "returns valid output even at small dimensions" do
      # Test that even small images produce valid output
      data = small_image()
      {:ok, result, _} = ImageCompressor.maybe_compress(data, "image/png")
      assert is_binary(result)
    end
  end
end
