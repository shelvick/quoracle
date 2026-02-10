defmodule Quoracle.Utils.ResponseTruncator do
  @moduledoc """
  Truncates large response data to prevent OOM kills.

  Applies a hard size limit to string content in action results,
  preventing any single action from consuming gigabytes of memory.
  """

  # 10MB
  @default_max_bytes 10 * 1024 * 1024

  @doc """
  Truncates a binary if it exceeds the maximum size.

  Returns the original binary if under the limit, or a truncated
  version with a marker indicating truncation occurred.

  ## Examples

      iex> truncate_if_large("small", max_bytes: 100)
      "small"

      iex> truncate_if_large(String.duplicate("x", 200), max_bytes: 100)
      String.duplicate("x", 100) <> "\\n\\n[TRUNCATED - exceeded 0.0MB limit]"

  """
  @spec truncate_if_large(binary() | nil, keyword()) :: binary() | nil
  def truncate_if_large(data, opts \\ [])
  def truncate_if_large(nil, _opts), do: nil

  def truncate_if_large(data, opts) when is_binary(data) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    if byte_size(data) > max_bytes do
      truncated = binary_part(data, 0, max_bytes)
      limit_mb = Float.round(max_bytes / (1024 * 1024), 1)
      truncated <> "\n\n[TRUNCATED - exceeded #{limit_mb}MB limit]"
    else
      data
    end
  end

  @doc """
  Truncates string fields in a map result.

  Recursively checks :stdout, :stderr, :body, :content, :output, :result
  fields and truncates any that exceed the limit.

  ## Examples

      iex> truncate_result({:ok, %{stdout: "small"}})
      {:ok, %{stdout: "small"}}

  """
  @spec truncate_result({:ok, map()} | {:error, term()}, keyword()) ::
          {:ok, map()} | {:error, term()}
  def truncate_result({:ok, data}, opts) when is_map(data) do
    {:ok, truncate_map_fields(data, opts)}
  end

  def truncate_result({:error, _reason} = error, _opts), do: error
  def truncate_result(other, _opts), do: other

  @doc """
  Truncates known large fields in a map.
  """
  @spec truncate_map_fields(map(), keyword()) :: map()
  def truncate_map_fields(data, opts \\ []) when is_map(data) do
    large_fields = [:stdout, :stderr, :body, :content, :output, :result, :text, :data]

    Enum.reduce(large_fields, data, fn field, acc ->
      case Map.get(acc, field) do
        value when is_binary(value) ->
          Map.put(acc, field, truncate_if_large(value, opts))

        _ ->
          acc
      end
    end)
  end

  @doc """
  Returns the default maximum bytes limit.
  """
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes
end
