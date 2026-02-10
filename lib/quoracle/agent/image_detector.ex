defmodule Quoracle.Agent.ImageDetector do
  @moduledoc """
  Detects and extracts image content from action results.
  Converts detected images to multimodal content format.
  """

  alias Quoracle.Utils.JSONNormalizer

  @type image_content :: %{
          type: :image | :image_url,
          data: String.t() | nil,
          media_type: String.t() | nil,
          url: String.t() | nil
        }

  @type multimodal_content :: [%{type: :text | :image | :image_url}]

  @doc """
  Detects if action result contains image data.
  Returns {:image, multimodal_content} or {:text, original_result}.

  CRITICAL: ConsensusHandler.process_action_result passes UNWRAPPED results.
  Production flow: Router.execute returns {:ok, result} → ConsensusHandler
  unwraps it → calls process_action_result with just `result`.
  """
  @spec detect(term(), atom()) :: {:image, multimodal_content()} | {:text, term()}

  # Handle wrapped {:ok, result} for backward compatibility - delegate to main clause
  def detect({:ok, result}, action_type) when is_map(result) do
    case detect(result, action_type) do
      {:image, content} -> {:image, content}
      {:text, _} -> {:text, {:ok, result}}
    end
  end

  # Main clause - handles unwrapped result (what production actually passes)
  def detect(result, _action_type) when is_map(result) do
    case find_images(result) do
      [] ->
        {:text, result}

      images ->
        case build_multimodal_content(result, images) do
          {:ok, content} -> {:image, content}
          :error -> {:text, result}
        end
    end
  end

  # Catch-all for non-map values
  def detect(result, _action_type), do: {:text, result}

  @doc """
  Checks if a value looks like image content.
  Supports base64 data and URLs.
  """
  @spec image_content?(term()) :: boolean()
  def image_content?(value) when is_map(value) do
    type = get_field(value, :type)
    type in ["image", :image, "image_url", :image_url]
  end

  def image_content?(_), do: false

  # Find all image maps in the result structure
  defp find_images(map) when is_map(map) do
    # Check if this map itself is an image
    direct_images =
      if image_content?(map) do
        [map]
      else
        []
      end

    # Check nested fields: :result, :content, :data (different actions use different keys)
    nested_images =
      [:result, :content, :data]
      |> Enum.flat_map(fn field -> find_images_in_field(map, field) end)

    # Recursively search all map values for deeply nested images
    deep_images =
      map
      |> Map.values()
      |> Enum.flat_map(&find_images_deep/1)

    (direct_images ++ nested_images ++ deep_images) |> Enum.uniq()
  end

  # Search a specific field for images
  defp find_images_in_field(map, field) do
    case get_field(map, field) do
      nested when is_map(nested) -> find_images(nested)
      list when is_list(list) -> Enum.flat_map(list, &find_images_in_value/1)
      _ -> []
    end
  end

  # Deep search for images in nested structures
  defp find_images_deep(value) when is_map(value) do
    if image_content?(value), do: [value], else: find_images(value)
  end

  defp find_images_deep(list) when is_list(list) do
    Enum.flat_map(list, &find_images_deep/1)
  end

  defp find_images_deep(_), do: []

  defp find_images_in_value(value) when is_map(value) do
    case {image_content?(value), text_content_block?(value)} do
      {true, _} -> [value]
      {_, true} -> find_json_image_in_text(value)
      _ -> []
    end
  end

  defp find_images_in_value(_), do: []

  # Check if this is a text content block (MCP protocol)
  # Called only from find_images_in_value/1 which already guards for is_map
  defp text_content_block?(map) do
    get_field(map, :type) in ["text", :text] and get_field(map, :text) != nil
  end

  # Try to parse JSON from text field and check if it's an image
  defp find_json_image_in_text(map) do
    text = get_field(map, :text)

    case parse_json_image(text) do
      {:ok, image_map} -> [image_map]
      :error -> []
    end
  end

  # Parse JSON string and check if it contains image data
  defp parse_json_image(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} when is_map(decoded) ->
        if image_content?(decoded), do: {:ok, decoded}, else: :error

      _ ->
        :error
    end
  end

  defp parse_json_image(_), do: :error

  # Convert struct to plain map for enumeration
  # Called only from replace_images_with_placeholder which guards for is_map
  defp to_plain_map(struct) when is_struct(struct), do: Map.from_struct(struct)
  defp to_plain_map(map), do: map

  # Build multimodal content from result and extracted images
  defp build_multimodal_content(result, images) do
    # Validate and convert images
    converted_images =
      images
      |> Enum.map(&convert_image/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(converted_images) do
      :error
    else
      # Create placeholder JSON
      placeholder_result = replace_images_with_placeholder(result)
      json_text = placeholder_result |> JSONNormalizer.normalize() |> Jason.encode!()

      text_part = %{type: :text, text: json_text}
      {:ok, [text_part | converted_images]}
    end
  end

  # Convert image map to standard format
  defp convert_image(image_map) do
    type = get_field(image_map, :type)

    cond do
      type in ["image", :image] ->
        data = get_field(image_map, :data)

        # Data comes in as base64 string, but ReqLLM expects raw bytes
        # (it will base64-encode when building the request)
        case decode_base64(data) do
          {:ok, raw_bytes} ->
            media_type =
              get_field(image_map, :mimeType) ||
                get_field(image_map, :media_type) ||
                "image/png"

            %{type: :image, data: raw_bytes, media_type: media_type}

          :error ->
            nil
        end

      type in ["image_url", :image_url] ->
        url = get_field(image_map, :url)

        if is_binary(url) do
          %{type: :image_url, url: url}
        else
          nil
        end

      true ->
        nil
    end
  end

  # Replace image data with placeholder
  # Note: Must handle structs (like Anubis.MCP.Response) which don't implement Enumerable
  defp replace_images_with_placeholder(result) when is_map(result) do
    if image_content?(result) do
      "[Image Attachment]"
    else
      result
      |> to_plain_map()
      |> Enum.map(fn {k, v} ->
        {k, replace_images_with_placeholder(v)}
      end)
      |> Map.new()
    end
  end

  defp replace_images_with_placeholder(list) when is_list(list) do
    Enum.map(list, &replace_images_with_placeholder/1)
  end

  defp replace_images_with_placeholder(value), do: value

  # Get field by atom or string key
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  # Decode base64 string to raw bytes, handling nil/invalid input
  defp decode_base64(nil), do: :error
  defp decode_base64(data) when not is_binary(data), do: :error
  defp decode_base64(data), do: Base.decode64(data)
end
