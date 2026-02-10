defmodule Quoracle.Skills.Loader do
  @moduledoc """
  Loads and parses SKILL.md files from the skills directory.
  Extracts YAML frontmatter and markdown body content.
  """

  @type skill_metadata :: %{
          name: String.t(),
          description: String.t(),
          path: String.t(),
          metadata: map()
        }

  @type skill :: %{
          name: String.t(),
          description: String.t(),
          content: String.t(),
          path: String.t(),
          metadata: map()
        }

  @doc """
  Returns the skills directory path.
  Fallback chain: opts :skills_path > DB config > hardcoded default.
  """
  @spec skills_dir(keyword()) :: String.t()
  def skills_dir(opts \\ []) do
    case Keyword.get(opts, :skills_path) do
      nil -> db_skills_path_or_default()
      path -> path
    end
  end

  defp db_skills_path_or_default do
    case Quoracle.Models.ConfigModelSettings.get_skills_path() do
      {:ok, path} -> Path.expand(path)
      {:error, _} -> Path.expand("~/.quoracle/skills")
    end
  rescue
    # Repo may not be started during compilation or test setup
    _ -> Path.expand("~/.quoracle/skills")
  end

  @doc """
  Searches skills by terms (OR logic).
  Returns skill metadata for skills whose name or description contains any search term.
  """
  @spec search([String.t()], keyword()) :: [skill_metadata()]
  def search(terms, opts \\ []) do
    {:ok, skills} = list_skills(opts)

    Enum.filter(skills, fn skill ->
      Enum.any?(terms, fn term ->
        term_down = String.downcase(term)

        String.contains?(String.downcase(skill.name), term_down) or
          String.contains?(String.downcase(skill.description), term_down)
      end)
    end)
  end

  @doc """
  Lists all skills (metadata only, no content).
  Returns empty list if directory doesn't exist.
  """
  @spec list_skills(keyword()) :: {:ok, [skill_metadata()]}
  def list_skills(opts \\ []) do
    path = skills_dir(opts)

    if File.dir?(path) do
      skills =
        path
        |> File.ls!()
        |> Enum.filter(&skill_directory?(&1, path))
        |> Enum.map(&load_skill_metadata(&1, path))
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, skill} -> skill end)

      {:ok, skills}
    else
      {:ok, []}
    end
  end

  @doc """
  Loads a skill by name (includes full content).
  """
  @spec load_skill(String.t(), keyword()) ::
          {:ok, skill()} | {:error, :not_found | :invalid_format}
  def load_skill(name, opts \\ []) do
    path = skills_dir(opts)
    skill_path = Path.join(path, name)
    skill_file = Path.join(skill_path, "SKILL.md")

    cond do
      not File.dir?(skill_path) ->
        {:error, :not_found}

      not File.exists?(skill_file) ->
        {:error, :not_found}

      true ->
        content = File.read!(skill_file)

        case parse_skill_file(skill_path, content) do
          {:ok, skill} ->
            if skill.name == name do
              {:ok, skill}
            else
              {:error, :invalid_format}
            end

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  Loads multiple skills by name.
  Returns error if ANY skill not found.
  """
  @spec load_skills([String.t()], keyword()) ::
          {:ok, [skill()]} | {:error, {:not_found, String.t()} | :not_found | :invalid_format}
  def load_skills(names, opts \\ []) do
    results =
      Enum.map(names, fn name ->
        {name, load_skill(name, opts)}
      end)

    case Enum.find(results, fn {_name, result} -> match?({:error, _}, result) end) do
      nil ->
        skills = Enum.map(results, fn {_name, {:ok, skill}} -> skill end)
        {:ok, skills}

      {name, {:error, :not_found}} ->
        {:error, {:not_found, name}}

      {_name, {:error, reason}} ->
        {:error, reason}
    end
  end

  @doc """
  Parses SKILL.md content into structured data.
  Extracts YAML frontmatter and markdown body.
  """
  @spec parse_skill_file(String.t(), String.t()) :: {:ok, skill()} | {:error, :invalid_format}
  def parse_skill_file(path, content) do
    case extract_frontmatter(content) do
      {:ok, yaml_content, body} ->
        case parse_yaml(yaml_content) do
          {:ok, frontmatter} ->
            build_skill(path, frontmatter, body)

          {:error, _} ->
            {:error, :invalid_format}
        end

      {:error, _} ->
        {:error, :invalid_format}
    end
  end

  # Private functions

  defp skill_directory?(name, base_path) do
    dir_path = Path.join(base_path, name)
    skill_file = Path.join(dir_path, "SKILL.md")
    File.dir?(dir_path) and File.exists?(skill_file)
  end

  defp load_skill_metadata(name, base_path) do
    skill_path = Path.join(base_path, name)
    skill_file = Path.join(skill_path, "SKILL.md")
    content = File.read!(skill_file)

    case parse_skill_file(skill_path, content) do
      {:ok, skill} ->
        if skill.name == name do
          metadata = %{
            name: skill.name,
            description: skill.description,
            path: skill.path,
            metadata: skill.metadata
          }

          {:ok, metadata}
        else
          {:error, :invalid_format}
        end

      {:error, _} = error ->
        error
    end
  end

  defp extract_frontmatter(content) do
    # Match YAML frontmatter between --- delimiters
    case Regex.run(~r/\A\s*---\s*\n(.*?)\n---\s*\n?(.*)\z/s, content) do
      [_, yaml, body] ->
        {:ok, yaml, String.trim(body)}

      nil ->
        {:error, :no_frontmatter}
    end
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

  defp build_skill(path, frontmatter, body) do
    name = Map.get(frontmatter, "name")
    description = Map.get(frontmatter, "description")

    cond do
      is_nil(name) or name == "" ->
        {:error, :invalid_format}

      is_nil(description) or description == "" ->
        {:error, :invalid_format}

      true ->
        metadata = Map.get(frontmatter, "metadata", %{}) || %{}

        skill = %{
          name: name,
          description: description,
          content: body,
          path: path,
          metadata: metadata
        }

        {:ok, skill}
    end
  end
end
