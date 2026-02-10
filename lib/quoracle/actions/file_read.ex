defmodule Quoracle.Actions.FileRead do
  @moduledoc """
  Action module for reading file contents with line numbers.

  Supports offset/limit for reading portions of large files.
  Returns content with line numbers in "N\\tcontent" format.
  """

  @default_limit 2000
  @max_line_length 2000

  @doc """
  Reads file contents from the filesystem.

  ## Parameters
  - `params`: Map with:
    - `:path` (required, string) - Absolute path to file
    - `:offset` (optional, integer) - Line to start from (1-indexed, default: 1)
    - `:limit` (optional, integer) - Max lines to read (default/max: 2000)
  - `agent_id`: ID of requesting agent
  - `opts`: Keyword list of options

  ## Returns
  - `{:ok, result_map}` - Success with content, lines_read, total_lines, truncated
  - `{:error, reason}` - Validation or file access errors
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(%{path: path} = params, _agent_id, _opts) when is_binary(path) do
    offset = Map.get(params, :offset, 1)
    limit = Map.get(params, :limit, @default_limit) |> min(@default_limit)

    with :ok <- validate_offset(offset),
         :ok <- validate_absolute_path(path),
         :ok <- validate_not_directory(path),
         {:ok, raw_content} <- read_file(path),
         :ok <- validate_not_binary(raw_content, path) do
      format_result(raw_content, path, offset, limit)
    end
  end

  def execute(_params, _agent_id, _opts) do
    {:error, :missing_required_param}
  end

  defp validate_offset(offset) when is_integer(offset) and offset >= 1, do: :ok
  defp validate_offset(_), do: {:error, :invalid_offset}

  defp validate_absolute_path(path) do
    if String.starts_with?(path, "/") do
      :ok
    else
      {:error, {:relative_path, %{path: path, hint: "Use absolute path starting with /"}}}
    end
  end

  defp validate_not_directory(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:error, {:is_directory, %{path: path}}}

      {:ok, _} ->
        :ok

      {:error, :enoent} ->
        # Let read_file handle this for consistent error
        :ok

      {:error, :eacces} ->
        {:error, {:permission_denied, %{path: path}}}

      {:error, _} ->
        :ok
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error, {:file_not_found, %{path: path}}}

      {:error, :eacces} ->
        {:error, {:permission_denied, %{path: path}}}

      {:error, reason} ->
        {:error, {:read_error, %{path: path, reason: reason}}}
    end
  end

  defp validate_not_binary(content, path) do
    if String.valid?(content) and not contains_null_bytes?(content) do
      :ok
    else
      {:error, {:binary_file, %{path: path, hint: "File contains binary content"}}}
    end
  end

  defp contains_null_bytes?(content) do
    String.contains?(content, <<0>>)
  end

  defp format_result(raw_content, path, offset, limit) do
    all_lines = String.split(raw_content, "\n")
    total_lines = length(all_lines)

    # Handle empty files (single empty string from split)
    {all_lines, total_lines} =
      if total_lines == 1 and hd(all_lines) == "" do
        {[], 0}
      else
        {all_lines, total_lines}
      end

    # Apply offset (1-indexed) and limit
    selected_lines =
      all_lines
      |> Enum.drop(offset - 1)
      |> Enum.take(limit)

    lines_read = length(selected_lines)

    # Format with line numbers and truncate long lines
    formatted_content =
      selected_lines
      |> Enum.with_index(offset)
      |> Enum.map_join("\n", fn {line, line_num} ->
        truncated_line = truncate_line(line)
        "#{line_num}\t#{truncated_line}"
      end)

    truncated = total_lines > offset - 1 + lines_read

    {:ok,
     %{
       action: "file_read",
       path: path,
       content: formatted_content,
       truncated: truncated
     }}
  end

  defp truncate_line(line) when byte_size(line) > @max_line_length do
    truncated = String.slice(line, 0, @max_line_length - 15)
    "#{truncated}... [truncated]"
  end

  defp truncate_line(line), do: line
end
