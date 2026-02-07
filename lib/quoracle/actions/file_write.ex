defmodule Quoracle.Actions.FileWrite do
  @moduledoc """
  File write action with two modes: create new files or edit existing.
  Uses Claude Code edit semantics for targeted replacements.
  """

  @spec execute(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom() | {atom(), map()}}
  def execute(params, _agent_id, _opts) do
    with {:ok, path} <- validate_path(params),
         {:ok, mode} <- validate_mode(params),
         {:ok, _} <- validate_mode_params(params, mode) do
      execute_mode(mode, path, params)
    end
  end

  # Path validation (same as FileRead)
  defp validate_path(%{path: path}) when is_binary(path) do
    if String.starts_with?(path, "/") do
      {:ok, path}
    else
      {:error, {:relative_path, %{path: path}}}
    end
  end

  defp validate_path(_), do: {:error, :missing_path}

  # Mode validation
  defp validate_mode(%{mode: :write}), do: {:ok, :write}
  defp validate_mode(%{mode: :edit}), do: {:ok, :edit}

  defp validate_mode(%{mode: mode}) do
    {:error, {:invalid_mode, %{mode: mode, hint: "Valid modes are :write or :edit"}}}
  end

  defp validate_mode(_), do: {:error, :missing_mode}

  # Mode-specific param validation
  defp validate_mode_params(%{content: content}, :write) when is_binary(content) do
    {:ok, :valid}
  end

  defp validate_mode_params(_, :write) do
    {:error, {:missing_content, %{hint: "content required for :write mode"}}}
  end

  defp validate_mode_params(%{old_string: old, new_string: new}, :edit)
       when is_binary(old) and is_binary(new) do
    {:ok, :valid}
  end

  defp validate_mode_params(%{old_string: _}, :edit) do
    {:error, {:missing_new_string, %{hint: "new_string required for :edit mode"}}}
  end

  defp validate_mode_params(_, :edit) do
    {:error, {:missing_old_string, %{hint: "old_string required for :edit mode"}}}
  end

  # Execute write mode
  defp execute_mode(:write, path, %{content: content}) do
    case File.stat(path) do
      {:ok, _} ->
        {:error,
         {:file_exists,
          %{
            path: path,
            hint: "Use :edit mode to modify, or delete file first via shell"
          }}}

      {:error, :enoent} ->
        write_new_file(path, content)

      {:error, :eacces} ->
        {:error, {:permission_denied, %{path: path}}}

      {:error, reason} ->
        {:error, {:file_error, %{path: path, reason: reason}}}
    end
  end

  # Execute edit mode
  defp execute_mode(:edit, path, params) do
    case File.read(path) do
      {:ok, content} ->
        apply_edit(path, content, params)

      {:error, :enoent} ->
        {:error,
         {:file_not_found,
          %{
            path: path,
            hint: "Use :write mode to create new file"
          }}}

      {:error, :eacces} ->
        {:error, {:permission_denied, %{path: path}}}

      {:error, reason} ->
        {:error, {:file_error, %{path: path, reason: reason}}}
    end
  end

  defp write_new_file(path, content) do
    # Ensure parent directory exists
    path |> Path.dirname() |> File.mkdir_p()

    case File.write(path, content) do
      :ok ->
        {:ok,
         %{
           action: "file_write",
           path: path,
           mode: :write,
           created: true
         }}

      {:error, :eacces} ->
        {:error, {:permission_denied, %{path: path}}}

      {:error, reason} ->
        {:error, {:write_failed, %{path: path, reason: reason}}}
    end
  end

  defp apply_edit(path, content, params) do
    old_string = Map.fetch!(params, :old_string)
    new_string = Map.fetch!(params, :new_string)
    replace_all = Map.get(params, :replace_all, false)

    case count_occurrences(content, old_string) do
      0 ->
        {:error,
         {:string_not_found,
          %{
            path: path,
            old_string: truncate_for_error(old_string),
            hint: "Verify old_string matches file content exactly"
          }}}

      1 ->
        do_replace(path, content, old_string, new_string, 1)

      count when replace_all ->
        new_content = String.replace(content, old_string, new_string)
        do_write(path, new_content, count)

      count ->
        {:error,
         {:ambiguous_match,
          %{
            path: path,
            old_string: truncate_for_error(old_string),
            count: count,
            hint:
              "Found #{count} occurrences. Provide more context in old_string or use replace_all: true"
          }}}
    end
  end

  defp count_occurrences(content, substring) do
    content
    |> String.split(substring)
    |> length()
    |> Kernel.-(1)
  end

  defp do_replace(path, content, old_string, new_string, count) do
    new_content = String.replace(content, old_string, new_string, global: false)
    do_write(path, new_content, count)
  end

  defp do_write(path, content, replacement_count) do
    case File.write(path, content) do
      :ok ->
        {:ok,
         %{
           action: "file_write",
           path: path,
           mode: :edit,
           replacements: replacement_count
         }}

      {:error, reason} ->
        {:error, {:write_failed, %{path: path, reason: reason}}}
    end
  end

  defp truncate_for_error(string) when byte_size(string) > 50 do
    String.slice(string, 0, 50) <> "..."
  end

  defp truncate_for_error(string), do: string
end
