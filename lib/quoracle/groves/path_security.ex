defmodule Quoracle.Groves.PathSecurity do
  @moduledoc """
  Shared path security utilities for grove file resolution.
  """

  @type security_error ::
          {:error,
           {:path_traversal, String.t()}
           | {:symlink_not_allowed, String.t()}
           | {:file_not_found, String.t()}}

  @doc """
  Returns true when the given path is absolute or contains `..` segments.
  """
  @spec path_traversal?(String.t()) :: boolean()
  def path_traversal?(filename) when is_binary(filename) do
    String.starts_with?(filename, "/") or
      filename
      |> Path.split()
      |> Enum.any?(&(&1 == ".."))
  end

  @doc """
  Returns true when the target path or one of its intermediate directories is
  a symlink that escapes the grove root.
  """
  @spec symlink_outside_grove?(String.t(), String.t()) :: boolean()
  def symlink_outside_grove?(full_path, grove_path) do
    canonical_grove = Path.expand(grove_path) <> "/"

    final_is_symlink =
      case File.lstat(full_path) do
        {:ok, %{type: :symlink}} ->
          case File.read_link(full_path) do
            {:ok, target} ->
              resolved =
                if Path.type(target) == :absolute do
                  Path.expand(target)
                else
                  full_path |> Path.dirname() |> Path.join(target) |> Path.expand()
                end

              not String.starts_with?(resolved, canonical_grove)

            {:error, _} ->
              true
          end

        _ ->
          false
      end

    final_is_symlink or intermediate_symlink_outside_grove?(full_path, canonical_grove)
  end

  @doc """
  Validates and reads a file relative to the grove path.
  """
  @spec safe_read_file(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | security_error()
  def safe_read_file(source_path, source_for_validation, grove_path)
      when is_binary(source_path) and is_binary(source_for_validation) do
    if path_traversal?(source_for_validation) do
      {:error, {:path_traversal, source_for_validation}}
    else
      full_path = Path.join(grove_path, source_path)

      if symlink_outside_grove?(full_path, grove_path) do
        {:error, {:symlink_not_allowed, source_path}}
      else
        case File.read(full_path) do
          {:ok, content} -> {:ok, String.trim(content)}
          {:error, _} -> {:error, {:file_not_found, full_path}}
        end
      end
    end
  end

  def safe_read_file(_source_path, _source_for_validation, _grove_path) do
    {:error, {:path_traversal, ""}}
  end

  @spec intermediate_symlink_outside_grove?(String.t(), String.t()) :: boolean()
  defp intermediate_symlink_outside_grove?(full_path, canonical_grove) do
    grove_root = String.trim_trailing(canonical_grove, "/")
    relative = Path.relative_to(full_path, grove_root)

    if relative == full_path do
      true
    else
      segments = Path.split(relative)
      intermediate_dirs = Enum.drop(segments, -1)

      Enum.reduce_while(intermediate_dirs, grove_root, fn segment, current_dir ->
        component_path = Path.join(current_dir, segment)

        case File.lstat(component_path) do
          {:ok, %{type: :symlink}} ->
            case File.read_link(component_path) do
              {:ok, target} ->
                resolved =
                  if Path.type(target) == :absolute do
                    Path.expand(target)
                  else
                    component_path |> Path.dirname() |> Path.join(target) |> Path.expand()
                  end

                if String.starts_with?(resolved, canonical_grove) do
                  {:cont, component_path}
                else
                  {:halt, :outside}
                end

              {:error, _} ->
                {:halt, :outside}
            end

          _ ->
            {:cont, component_path}
        end
      end)
      |> case do
        :outside -> true
        _ -> false
      end
    end
  end
end
