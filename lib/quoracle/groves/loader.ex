defmodule Quoracle.Groves.Loader do
  @moduledoc """
  Loads and parses GROVE.md frontmatter from grove directories.
  Provides APIs for listing available groves and extracting bootstrap configuration.
  """

  require Logger

  alias Quoracle.Groves.Loader.Sanitizer
  alias Quoracle.Models.ConfigModelSettings

  @type grove_metadata :: %{
          name: String.t(),
          description: String.t(),
          version: String.t(),
          path: String.t()
        }

  @type grove_bootstrap :: %{
          global_context_file: String.t() | nil,
          task_description_file: String.t() | nil,
          success_criteria_file: String.t() | nil,
          immediate_context_file: String.t() | nil,
          approach_guidance_file: String.t() | nil,
          global_constraints: String.t() | nil,
          output_style: String.t() | nil,
          role: String.t() | nil,
          cognitive_style: String.t() | nil,
          delegation_strategy: String.t() | nil,
          skills: [String.t()] | nil,
          profile: String.t() | nil,
          budget_limit: number() | nil
        }

  @type grove :: %{
          name: String.t(),
          description: String.t(),
          version: String.t(),
          path: String.t(),
          bootstrap: grove_bootstrap(),
          topology: map(),
          governance: map() | nil,
          confinement: map() | nil,
          confinement_mode: String.t() | nil,
          schemas: [map()] | nil,
          workspace: String.t() | nil,
          skills_path: String.t() | nil
        }

  @doc """
  Lists all valid groves in the groves directory.
  Returns metadata only (name, description, version, path).
  Skips groves with malformed or missing GROVE.md frontmatter.
  Returns {:ok, []} if groves directory doesn't exist.
  Results sorted alphabetically by name.
  """
  @spec list_groves(keyword()) :: {:ok, [grove_metadata()]}
  def list_groves(opts \\ []) do
    path = groves_dir(opts)

    if File.dir?(path) do
      case File.ls(path) do
        {:ok, entries} ->
          groves =
            entries
            |> Enum.filter(&grove_directory?(&1, path))
            |> Enum.map(&load_grove_metadata(&1, path))
            |> Enum.filter(&match?({:ok, _}, &1))
            |> Enum.map(fn {:ok, meta} -> meta end)
            |> Enum.sort_by(& &1.name)

          {:ok, groves}

        {:error, reason} ->
          Logger.warning("Cannot list groves directory #{path}: #{inspect(reason)}")
          {:ok, []}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Loads a specific grove's full manifest by name.
  Returns the complete grove struct including bootstrap, topology, governance, and skills_path.
  """
  @spec load_grove(String.t(), keyword()) :: {:ok, grove()} | {:error, :not_found | :parse_error}
  def load_grove(grove_name, opts \\ []) do
    path = groves_dir(opts)
    grove_dir = Path.join(path, grove_name)
    grove_md = Path.join(grove_dir, "GROVE.md")

    cond do
      not File.dir?(grove_dir) ->
        {:error, :not_found}

      not File.exists?(grove_md) ->
        {:error, :not_found}

      true ->
        case File.read(grove_md) do
          {:ok, content} ->
            case parse_grove_file(grove_dir, content) do
              {:ok, grove} -> {:ok, grove}
              {:error, _} -> {:error, :parse_error}
            end

          {:error, _} ->
            {:error, :not_found}
        end
    end
  end

  @doc """
  Convenience function that loads a grove and extracts just the bootstrap section.
  """
  @spec get_bootstrap(String.t(), keyword()) ::
          {:ok, grove_bootstrap()} | {:error, :not_found | :parse_error}
  def get_bootstrap(grove_name, opts \\ []) do
    case load_grove(grove_name, opts) do
      {:ok, grove} -> {:ok, grove.bootstrap}
      {:error, _} = error -> error
    end
  end

  # ---- Private Functions ----

  @spec groves_dir(keyword()) :: String.t()
  defp groves_dir(opts) do
    case Keyword.get(opts, :groves_path) do
      path when is_binary(path) -> Path.expand(path)
      nil -> get_configured_groves_path()
    end
  end

  defp get_configured_groves_path do
    case ConfigModelSettings.get_groves_path() do
      {:ok, path} -> Path.expand(path)
      {:error, _} -> Path.expand("~/.quoracle/groves")
    end
  rescue
    _ -> Path.expand("~/.quoracle/groves")
  end

  defp grove_directory?(name, base_path) do
    dir_path = Path.join(base_path, name)
    grove_file = Path.join(dir_path, "GROVE.md")
    File.dir?(dir_path) and File.exists?(grove_file)
  end

  defp load_grove_metadata(name, base_path) do
    grove_dir = Path.join(base_path, name)
    grove_md = Path.join(grove_dir, "GROVE.md")

    case File.read(grove_md) do
      {:error, reason} ->
        Logger.warning("Skipping grove #{name}: cannot read GROVE.md: #{inspect(reason)}")
        {:error, :read_error}

      {:ok, content} ->
        load_grove_metadata_from_content(name, grove_dir, content)
    end
  end

  defp load_grove_metadata_from_content(name, grove_dir, content) do
    case extract_frontmatter(content) do
      {:ok, yaml_content} ->
        case parse_yaml(yaml_content) do
          {:ok, frontmatter} ->
            {:ok,
             %{
               name: Map.get(frontmatter, "name", name),
               description: Map.get(frontmatter, "description", ""),
               version: to_string(Map.get(frontmatter, "version", "")),
               path: grove_dir
             }}

          {:error, _} ->
            Logger.warning("Skipping grove #{name}: malformed YAML frontmatter")
            {:error, :parse_error}
        end

      {:error, _} ->
        Logger.warning("Skipping grove #{name}: no frontmatter found")
        {:error, :no_frontmatter}
    end
  end

  defp parse_grove_file(grove_dir, content) do
    case extract_frontmatter(content) do
      {:ok, yaml_content} ->
        case parse_yaml(yaml_content) do
          {:ok, frontmatter} ->
            build_grove(grove_dir, frontmatter)

          {:error, _} ->
            {:error, :parse_error}
        end

      {:error, _} ->
        {:error, :no_frontmatter}
    end
  end

  defp extract_frontmatter(content) do
    case Regex.run(~r/\A\s*---\s*\n(.*?)\n\s*---/s, content) do
      [_, yaml] ->
        {:ok, dedent(yaml)}

      nil ->
        {:error, :no_frontmatter}
    end
  end

  defp dedent(text) do
    lines = String.split(text, "\n")

    min_indent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(fn line ->
        case Regex.run(~r/^(\s*)/, line) do
          [_, spaces] -> String.length(spaces)
          _ -> 0
        end
      end)
      |> Enum.min(fn -> 0 end)

    Enum.map_join(lines, "\n", fn line ->
      if String.trim(line) == "" do
        ""
      else
        String.slice(line, min_indent, String.length(line))
      end
    end)
  end

  defp parse_yaml(yaml_content) do
    case YamlElixir.read_from_string(yaml_content) do
      {:ok, parsed} when is_map(parsed) ->
        {:ok, parsed}

      {:ok, _} ->
        {:error, :invalid_yaml}

      {:error, _} ->
        {:error, :invalid_yaml}
    end
  end

  defp build_grove(grove_dir, frontmatter) do
    bootstrap_raw = Map.get(frontmatter, "bootstrap", %{}) || %{}
    topology_raw = Map.get(frontmatter, "topology", %{}) || %{}
    governance_raw = Map.get(frontmatter, "governance")
    confinement_raw = Map.get(frontmatter, "confinement")
    schemas_raw = Map.get(frontmatter, "schemas")
    workspace_raw = Map.get(frontmatter, "workspace")

    skills_dir = Path.join(grove_dir, "skills")

    skills_path =
      if File.dir?(skills_dir) do
        skills_dir
      else
        nil
      end

    bootstrap = build_bootstrap(bootstrap_raw)
    governance = Sanitizer.sanitize_governance(governance_raw)
    confinement = Sanitizer.sanitize_confinement(confinement_raw)

    grove = %{
      name: Map.get(frontmatter, "name", ""),
      description: Map.get(frontmatter, "description", ""),
      version: to_string(Map.get(frontmatter, "version", "")),
      path: grove_dir,
      bootstrap: bootstrap,
      topology: topology_raw,
      governance: governance,
      confinement: confinement,
      confinement_mode: get_confinement_mode(frontmatter),
      schemas: Sanitizer.sanitize_schema_definitions(schemas_raw, &get_safe_file_ref/2),
      workspace: Sanitizer.parse_workspace(workspace_raw),
      skills_path: skills_path
    }

    {:ok, grove}
  end

  defp build_bootstrap(raw) when is_map(raw) do
    %{
      global_context_file: get_safe_file_ref(raw, "global_context_file"),
      task_description_file: get_safe_file_ref(raw, "task_description_file"),
      success_criteria_file: get_safe_file_ref(raw, "success_criteria_file"),
      immediate_context_file: get_safe_file_ref(raw, "immediate_context_file"),
      approach_guidance_file: get_safe_file_ref(raw, "approach_guidance_file"),
      global_constraints: get_string(raw, "global_constraints"),
      output_style: get_string(raw, "output_style"),
      role: get_string(raw, "role"),
      cognitive_style: get_string(raw, "cognitive_style"),
      delegation_strategy: get_string(raw, "delegation_strategy"),
      skills: get_list(raw, "skills"),
      profile: get_string(raw, "profile"),
      budget_limit: get_number(raw, "budget_limit")
    }
  end

  defp build_bootstrap(_), do: build_bootstrap(%{})

  defp get_string(map, key) do
    case Map.get(map, key) do
      nil -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  # Sanitize file reference paths: strip `..` components and leading `/`
  # to prevent path traversal attacks from grove manifests.
  defp get_safe_file_ref(map, key) do
    case get_string(map, key) do
      nil ->
        nil

      path ->
        sanitized =
          path
          |> Path.split()
          |> Enum.reject(&(&1 == ".."))
          |> then(fn
            ["/" | rest] -> rest
            parts -> parts
          end)
          |> Path.join()

        if sanitized == "", do: nil, else: sanitized
    end
  end

  defp get_list(map, key) do
    case Map.get(map, key) do
      nil -> nil
      list when is_list(list) -> list
      _ -> nil
    end
  end

  defp get_confinement_mode(frontmatter) do
    case Map.get(frontmatter, "confinement_mode") do
      "strict" -> "strict"
      value when is_atom(value) and value == :strict -> "strict"
      _ -> nil
    end
  end

  defp get_number(map, key) do
    case Map.get(map, key) do
      nil -> nil
      num when is_number(num) -> num
      _ -> nil
    end
  end
end
