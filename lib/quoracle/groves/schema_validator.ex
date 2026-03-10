defmodule Quoracle.Groves.SchemaValidator do
  @moduledoc """
  Validates file-write content against grove-declared JSON schemas.
  """

  require Logger

  alias Quoracle.Groves.PathSecurity

  @type schema_entry :: %{String.t() => any()}

  @type validation_error :: %{
          path: String.t(),
          errors: [String.t()]
        }

  @doc """
  Validates file content for a write operation when a matching grove schema exists.
  """
  @spec validate_file_write(
          String.t(),
          String.t(),
          [schema_entry()] | nil,
          String.t() | nil,
          String.t() | nil
        ) :: :ok | {:error, term()}
  def validate_file_write(_file_path, _final_content, schemas, _workspace, _grove_path)
      when schemas in [nil, []] do
    :ok
  end

  def validate_file_write(_file_path, _final_content, schemas, nil, _grove_path)
      when is_list(schemas) do
    message = "Grove schemas configured but workspace is missing; skipping schema validation"
    Logger.warning(message)
    :ok
  end

  def validate_file_write(file_path, final_content, schemas, workspace, grove_path)
      when is_binary(file_path) and is_binary(final_content) and is_list(schemas) and
             is_binary(workspace) do
    case find_matching_schema(file_path, schemas, workspace) do
      nil ->
        :ok

      %{"validate_on" => trigger} when trigger != "file_write" ->
        :ok

      schema ->
        validate_with_schema(file_path, final_content, schema, grove_path)
    end
  end

  def validate_file_write(_file_path, _final_content, _schemas, _workspace, _grove_path), do: :ok

  @doc """
  Finds the most-specific schema whose path pattern matches the file path.
  """
  @spec find_matching_schema(String.t(), [schema_entry()], String.t()) :: schema_entry() | nil
  def find_matching_schema(file_path, schemas, workspace)
      when is_binary(file_path) and is_list(schemas) and is_binary(workspace) do
    case relative_path(file_path, workspace) do
      {:ok, relative_path} ->
        schemas
        |> Enum.filter(&schema_matches?(&1, relative_path))
        |> Enum.min_by(&specificity_score(Map.get(&1, "path_pattern", "")), fn -> nil end)

      :outside ->
        nil
    end
  end

  def find_matching_schema(_file_path, _schemas, _workspace), do: nil

  @doc """
  Returns true when a relative path matches a schema path pattern.
  """
  @spec path_matches_pattern?(String.t(), String.t()) :: boolean()
  def path_matches_pattern?(relative_path, pattern)
      when is_binary(relative_path) and is_binary(pattern) do
    path_segments = path_segments(relative_path)
    pattern_segments = path_segments(pattern)

    match_segments?(path_segments, pattern_segments)
  end

  def path_matches_pattern?(_relative_path, _pattern), do: false

  @spec validate_with_schema(String.t(), String.t(), schema_entry(), String.t() | nil) ::
          :ok | {:error, term()}
  defp validate_with_schema(file_path, final_content, schema, grove_path) do
    definition = Map.get(schema, "definition")
    schema_name = Map.get(schema, "name", "unknown")

    with {:ok, schema_map} <- load_schema(definition, grove_path),
         {:ok, root} <- build_schema_root(schema_map, definition),
         {:ok, parsed_content} <- parse_content_json(file_path, final_content) do
      run_schema_validation(parsed_content, root, file_path, schema_name)
    end
  end

  @spec load_schema(any(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  defp load_schema(definition, _grove_path) when not is_binary(definition) do
    {:error, {:schema_load_failed, %{definition: definition, reason: :invalid_definition}}}
  end

  defp load_schema(definition, grove_path) when not is_binary(grove_path) do
    {:error, {:schema_load_failed, %{definition: definition, reason: :missing_grove_path}}}
  end

  defp load_schema(definition, grove_path) do
    case PathSecurity.safe_read_file(definition, definition, grove_path) do
      {:ok, content} ->
        decode_schema_json(content, definition)

      # Security errors pass through unchanged
      {:error, {:path_traversal, _}} = error ->
        error

      {:error, {:symlink_not_allowed, _}} = error ->
        error

      {:error, {:file_not_found, reason}} ->
        {:error, {:schema_load_failed, %{definition: definition, reason: reason}}}
    end
  end

  @spec decode_schema_json(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp decode_schema_json(content, definition) do
    case Jason.decode(content) do
      {:ok, schema_map} when is_map(schema_map) ->
        {:ok, schema_map}

      {:ok, _other} ->
        {:error, {:schema_load_failed, %{definition: definition, reason: :schema_not_an_object}}}

      {:error, reason} ->
        {:error,
         {:schema_load_failed, %{definition: definition, reason: Exception.message(reason)}}}
    end
  end

  @spec build_schema_root(map(), any()) :: {:ok, JSV.Root.t()} | {:error, term()}
  defp build_schema_root(schema_map, definition) do
    case JSV.build(schema_map) do
      {:ok, root} ->
        {:ok, root}

      {:error, reason} ->
        {:error, {:schema_load_failed, %{definition: definition, reason: reason}}}
    end
  end

  @spec parse_content_json(String.t(), String.t()) :: {:ok, any()} | {:error, term()}
  defp parse_content_json(file_path, final_content) do
    case Jason.decode(final_content) do
      {:ok, parsed_content} ->
        {:ok, parsed_content}

      {:error, reason} ->
        {:error, {:invalid_json, %{path: file_path, reason: Exception.message(reason)}}}
    end
  end

  @spec run_schema_validation(any(), JSV.Root.t(), String.t(), String.t()) ::
          :ok | {:error, {:schema_validation_failed, validation_error()}}
  defp run_schema_validation(parsed_content, root, file_path, schema_name) do
    case JSV.validate(parsed_content, root) do
      {:ok, _cast_content} ->
        :ok

      {:error, validation_error} ->
        {:error,
         {:schema_validation_failed,
          %{
            path: file_path,
            schema: schema_name,
            errors: format_validation_errors(validation_error)
          }}}
    end
  end

  @spec format_validation_errors(Exception.t()) :: [String.t()]
  defp format_validation_errors(validation_error) do
    messages =
      validation_error
      |> JSV.normalize_error(keys: :atoms)
      |> Map.get(:details, [])
      |> Enum.flat_map(&extract_error_messages/1)
      |> Enum.uniq()

    case messages do
      [] -> [Exception.message(validation_error)]
      _ -> messages
    end
  rescue
    _ -> [Exception.message(validation_error)]
  end

  # Recursively extracts human-readable error messages from JSV normalized error units.
  # Each unit may have direct :errors (with :message fields) and nested :details.
  @spec extract_error_messages(map()) :: [String.t()]
  defp extract_error_messages(%{} = unit) do
    direct =
      unit
      |> Map.get(:errors, [])
      |> Enum.flat_map(fn
        %{message: msg} = error when is_binary(msg) ->
          [msg | extract_nested_messages(error)]

        _ ->
          []
      end)

    nested = extract_nested_messages(unit)
    direct ++ nested
  end

  defp extract_error_messages(_unit), do: []

  @spec extract_nested_messages(map()) :: [String.t()]
  defp extract_nested_messages(node) do
    node
    |> Map.get(:details, [])
    |> Enum.flat_map(&extract_error_messages/1)
  end

  @spec schema_matches?(schema_entry(), String.t()) :: boolean()
  defp schema_matches?(schema, relative_path) do
    case Map.get(schema, "path_pattern") do
      pattern when is_binary(pattern) -> path_matches_pattern?(relative_path, pattern)
      _ -> false
    end
  end

  @spec specificity_score(String.t()) :: {non_neg_integer(), integer()}
  defp specificity_score(pattern) when is_binary(pattern) do
    wildcard_count =
      pattern
      |> path_segments()
      |> Enum.count(fn segment -> segment in ["*", "**"] or String.contains?(segment, "*") end)

    {wildcard_count, -String.length(pattern)}
  end

  @spec relative_path(String.t(), String.t()) :: {:ok, String.t()} | :outside
  defp relative_path(file_path, workspace) do
    expanded_file = Path.expand(file_path)
    expanded_workspace = String.trim_trailing(Path.expand(workspace), "/") <> "/"

    if String.starts_with?(expanded_file, expanded_workspace) do
      {:ok, String.trim_leading(expanded_file, expanded_workspace)}
    else
      :outside
    end
  end

  @spec path_segments(String.t()) :: [String.t()]
  defp path_segments(path) do
    String.split(path, "/", trim: true)
  end

  @spec match_segments?([String.t()], [String.t()]) :: boolean()
  defp match_segments?([], []), do: true

  defp match_segments?([], ["**" | remaining_pattern]) do
    match_segments?([], remaining_pattern)
  end

  defp match_segments?([], _pattern), do: false
  defp match_segments?(_path, []), do: false

  defp match_segments?(path_segments, ["**" | remaining_pattern]) do
    match_segments?(path_segments, remaining_pattern) or
      match_segments?(tl(path_segments), ["**" | remaining_pattern])
  end

  defp match_segments?([path_segment | remaining_path], [pattern_segment | remaining_pattern]) do
    segment_matches_pattern?(path_segment, pattern_segment) and
      match_segments?(remaining_path, remaining_pattern)
  end

  @spec segment_matches_pattern?(String.t(), String.t()) :: boolean()
  defp segment_matches_pattern?(_segment, "*"), do: true

  defp segment_matches_pattern?(segment, pattern) do
    if String.contains?(pattern, "*") do
      glob_match?(segment, pattern)
    else
      segment == pattern
    end
  end

  # Matches a filename segment against a glob pattern containing * wildcards.
  # Splits the pattern on * to get literal parts, then checks that the segment
  # contains all parts in order with the correct prefix/suffix anchoring.
  @spec glob_match?(String.t(), String.t()) :: boolean()
  defp glob_match?(segment, pattern) do
    parts = String.split(pattern, "*")

    case parts do
      [prefix, suffix] ->
        String.starts_with?(segment, prefix) and String.ends_with?(segment, suffix) and
          String.length(segment) >= String.length(prefix) + String.length(suffix)

      _ ->
        # Multiple wildcards: fall back to regex for correctness
        regex =
          pattern
          |> Regex.escape()
          |> String.replace("\\*", "[^/]*")
          |> then(&"\\A#{&1}\\z")
          |> Regex.compile!()

        Regex.match?(regex, segment)
    end
  end
end
