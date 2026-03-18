defmodule Quoracle.Actions.FileWrite do
  @moduledoc """
  File write action with two modes: create new files or edit existing.
  Uses Claude Code edit semantics for targeted replacements.
  """

  alias Quoracle.Groves.{HardRuleEnforcer, SchemaValidator}

  @doc """
  Creates a new file or edits an existing file using Claude Code semantics.
  """
  @spec execute(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom() | {atom(), map()}}
  def execute(params, _agent_id, opts) do
    with {:ok, path} <- validate_path(params),
         {:ok, mode} <- validate_mode(params),
         :ok <- validate_confinement(path, mode, opts),
         {:ok, _} <- validate_mode_params(params, mode) do
      execute_mode(mode, path, params, opts)
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

  defp validate_confinement(path, mode, opts) when mode in [:write, :edit] do
    parent_config = Keyword.get(opts, :parent_config, %{})
    confinement = parent_config_value(parent_config, :grove_confinement)
    confinement_mode = parent_config_value(parent_config, :grove_confinement_mode)
    skill_name = parent_config_value(parent_config, :skill_name)

    HardRuleEnforcer.check_file_access(path, :write, confinement, skill_name, confinement_mode)
  end

  defp validate_confinement(_path, _mode, _opts), do: :ok

  # Execute write mode
  defp execute_mode(:write, path, %{content: content}, opts) do
    case File.stat(path) do
      {:ok, _} ->
        {:error,
         {:file_exists,
          %{
            path: path,
            hint: "Use :edit mode to modify, or delete file first via shell"
          }}}

      {:error, :enoent} ->
        with :ok <- validate_schema(path, content, opts) do
          write_new_file(path, content)
        end

      {:error, :eacces} ->
        {:error, {:permission_denied, %{path: path}}}

      {:error, reason} ->
        {:error, {:file_error, %{path: path, reason: reason}}}
    end
  end

  # Execute edit mode
  defp execute_mode(:edit, path, params, opts) do
    case File.read(path) do
      {:ok, content} ->
        with {:ok, new_content, replacement_count} <- build_edited_content(path, content, params),
             :ok <- validate_schema(path, new_content, opts) do
          do_write(path, new_content, replacement_count)
        end

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

  defp build_edited_content(path, content, params) do
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
        {:ok, String.replace(content, old_string, new_string, global: false), 1}

      count when replace_all ->
        {:ok, String.replace(content, old_string, new_string), count}

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

  defp validate_schema(path, final_content, opts) do
    parent_config = Keyword.get(opts, :parent_config, %{})
    schemas = parent_config_value(parent_config, :grove_schemas)
    workspace = parent_config_value(parent_config, :grove_workspace)
    grove_path = parent_config_value(parent_config, :grove_path)

    SchemaValidator.validate_file_write(path, final_content, schemas, workspace, grove_path)
  end

  defp parent_config_value(parent_config, key) when is_map(parent_config) and is_atom(key) do
    Map.get(parent_config, key, Map.get(parent_config, Atom.to_string(key)))
  end

  defp parent_config_value(_parent_config, _key), do: nil

  defp truncate_for_error(string) when byte_size(string) > 50 do
    String.slice(string, 0, 50) <> "..."
  end

  defp truncate_for_error(string), do: string
end
