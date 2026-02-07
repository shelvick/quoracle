defmodule Quoracle.Utils.ContentStringifier do
  @moduledoc """
  Converts multimodal content to human-readable strings.

  Used by:
  - Reflector (reflection prompts)
  - PerModelQuery.Helpers (condensation messages)
  - LogEntry.Helpers (UI display)

  Handles MCP multimodal content: `[%{type: :text, text: "..."}, %{type: :image, ...}]`
  """

  @doc """
  Stringifies content, handling multimodal lists from MCP.

  ## Options

  - `:map_fallback` - Function to call for unknown map types.
    Defaults to `&inspect/1`. Use `&JSONNormalizer.normalize/1` for structured output.

  ## Examples

      iex> stringify("hello")
      "hello"

      iex> stringify([%{type: :text, text: "Hello"}, %{type: :image, data: <<>>}])
      "Hello\\n[Image]"

  """
  @spec stringify(term(), keyword()) :: String.t()
  def stringify(content, opts \\ [])
  def stringify(content, _opts) when is_binary(content), do: content

  def stringify(content, opts) when is_list(content) do
    Enum.map_join(content, "\n", &stringify_part(&1, opts))
  end

  def stringify(content, opts) when is_map(content), do: stringify_part(content, opts)
  def stringify(nil, _opts), do: ""
  def stringify(_, _opts), do: ""

  @doc """
  Stringifies a single content part.

  Handles both atom keys (`:type`, `:text`) and string keys (`"type"`, `"text"`).
  """
  @spec stringify_part(term(), keyword()) :: String.t()
  def stringify_part(part, opts \\ [])

  # Atom key variants
  def stringify_part(%{type: :text, text: text}, _opts) when is_binary(text), do: text
  def stringify_part(%{type: :image}, _opts), do: "[Image]"
  def stringify_part(%{type: :image_url, url: url}, _opts), do: "[Image: #{url}]"

  # String key variants (from MCP JSON)
  def stringify_part(%{"type" => "text", "text" => text}, _opts) when is_binary(text), do: text
  def stringify_part(%{"type" => "image"}, _opts), do: "[Image]"
  def stringify_part(%{"type" => "image_url", "url" => url}, _opts), do: "[Image: #{url}]"

  # Fallback for unknown map types
  def stringify_part(part, opts) when is_map(part) do
    fallback = Keyword.get(opts, :map_fallback, &inspect/1)
    fallback.(part)
  end

  def stringify_part(part, _opts) when is_binary(part), do: part
  def stringify_part(_, _opts), do: ""
end
