defmodule Quoracle.Utils.ImageCompressor do
  @moduledoc """
  Resizes images that exceed LLM provider size limits.

  Uses dimension-based progressive resizing (not quality reduction) to preserve
  image fidelity for LLM vision analysis. Bedrock has a 5MB limit; this module
  automatically resizes oversized images to fit within a safe 4.5MB buffer.

  Design principle: Optimistic pass-through. Never block the LLM query - if
  compression fails for any reason, return the original and let the provider
  reject if needed.
  """

  require Logger

  @max_size 4_500_000
  @target_dimensions [1920, 1280, 1024, 768, 512, 384, 256]

  @doc """
  Compresses image if it exceeds size limit.

  Returns `{:ok, data, media_type}` always. On error, logs warning and returns
  original image for optimistic pass-through.

  ## Examples

      iex> maybe_compress(small_image_binary, "image/png")
      {:ok, small_image_binary, "image/png"}

      iex> maybe_compress(oversized_image_binary, "image/png")
      {:ok, resized_image_binary, "image/png"}
  """
  @spec maybe_compress(binary(), String.t()) :: {:ok, binary(), String.t()}
  def maybe_compress(data, media_type) when is_binary(data) and is_binary(media_type) do
    cond do
      # Empty or very small data - pass through
      byte_size(data) == 0 ->
        {:ok, data, media_type}

      # Under limit - pass through unchanged
      byte_size(data) <= @max_size ->
        {:ok, data, media_type}

      # Over limit - try to compress
      true ->
        compress_image(data, media_type)
    end
  end

  # Attempts progressive resize until image fits under limit
  defp compress_image(data, media_type) do
    try do
      image = Image.from_binary!(data)
      suffix = media_type_to_suffix(media_type)

      result = try_progressive_resize(image, suffix, @target_dimensions)

      case result do
        {:ok, compressed_data} ->
          {:ok, compressed_data, media_type}

        :too_large ->
          Logger.warning("Image still too large after reaching minimum dimension (256px)")
          {:ok, data, media_type}
      end
    rescue
      e ->
        Logger.warning("Image compression failed: #{inspect(e)}, returning original")
        {:ok, data, media_type}
    end
  end

  # Try each target dimension until image fits
  defp try_progressive_resize(_image, _suffix, []) do
    :too_large
  end

  defp try_progressive_resize(image, suffix, [target | rest]) do
    resized = resize_to_fit(image, target)

    case Image.write(resized, :memory, suffix: suffix) do
      {:ok, data} when byte_size(data) <= @max_size ->
        {:ok, data}

      {:ok, _data} ->
        # Still too large, try next smaller target
        try_progressive_resize(resized, suffix, rest)

      {:error, _reason} ->
        # Try next target on write error
        try_progressive_resize(image, suffix, rest)
    end
  end

  # Resize image to fit within max_dimension while preserving aspect ratio
  defp resize_to_fit(image, max_dimension) do
    {width, height} = extract_dimensions(Image.shape(image))
    longest_edge = max(width, height)

    if longest_edge > max_dimension do
      scale = max_dimension / longest_edge
      Image.resize!(image, scale)
    else
      image
    end
  end

  # Extract width and height from Image.shape tuple
  defp extract_dimensions({width, height, _bands}), do: {width, height}

  # Convert media_type to file suffix for Image.write
  defp media_type_to_suffix("image/png"), do: ".png"
  defp media_type_to_suffix("image/jpeg"), do: ".jpg"
  defp media_type_to_suffix("image/jpg"), do: ".jpg"
  defp media_type_to_suffix("image/webp"), do: ".webp"
  defp media_type_to_suffix("image/gif"), do: ".gif"
  defp media_type_to_suffix(_), do: ".png"
end
