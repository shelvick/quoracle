defmodule Quoracle.Skills.Creator do
  @moduledoc """
  Creates new skill files in the skills directory.
  Validates name format and handles directory creation.
  """

  alias Quoracle.Skills.Loader

  @type attachment :: %{
          type: String.t(),
          filename: String.t(),
          content: String.t()
        }

  @name_pattern ~r/^[a-z][a-z0-9]*(-[a-z0-9]+)*$/
  @max_name_length 64

  @attachment_dirs %{
    "script" => "scripts",
    "reference" => "references",
    "asset" => "assets"
  }

  @doc """
  Creates a new skill.
  Creates directory, writes SKILL.md with frontmatter + body.
  Auto-creates skills directory if needed.
  """
  @spec create(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create(params, opts \\ []) do
    name = Map.get(params, :name)

    with :ok <- validate_name(name),
         skills_dir <- Loader.skills_dir(opts),
         skill_path <- Path.join(skills_dir, name),
         :ok <- check_not_exists(skill_path),
         :ok <- create_skill_directory(skill_path),
         :ok <- write_skill_file(skill_path, params),
         :ok <- write_attachments(skill_path, Map.get(params, :attachments, [])) do
      {:ok, skill_path}
    end
  end

  @doc """
  Validates skill name format.
  Lowercase alphanumeric with hyphens, no consecutive hyphens.
  Must start with letter, max 64 chars.
  """
  @spec validate_name(String.t()) :: :ok | {:error, String.t()}
  def validate_name(name) when is_binary(name) do
    cond do
      name == "" ->
        {:error, "Name cannot be empty"}

      String.length(name) > @max_name_length ->
        {:error, "Name must be #{@max_name_length} characters or less"}

      not Regex.match?(@name_pattern, name) ->
        {:error,
         "Name must be lowercase alphanumeric with hyphens, start with letter, no consecutive hyphens"}

      true ->
        :ok
    end
  end

  def validate_name(_), do: {:error, "Name must be a string"}

  # Private functions

  defp check_not_exists(skill_path) do
    if File.dir?(skill_path) do
      {:error, :already_exists}
    else
      :ok
    end
  end

  defp create_skill_directory(skill_path) do
    File.mkdir_p!(skill_path)
    :ok
  end

  defp write_skill_file(skill_path, params) do
    content = build_skill_content(params)
    skill_file = Path.join(skill_path, "SKILL.md")
    File.write!(skill_file, content)
    :ok
  end

  defp build_skill_content(params) do
    name = Map.get(params, :name)
    description = Map.get(params, :description, "")
    body = Map.get(params, :content, "")
    metadata = Map.get(params, :metadata, %{})

    metadata_yaml = build_metadata_yaml(metadata)

    """
    ---
    name: #{name}
    description: #{description}
    #{metadata_yaml}---

    #{body}
    """
  end

  defp build_metadata_yaml(metadata) when map_size(metadata) == 0, do: ""

  defp build_metadata_yaml(metadata) do
    lines =
      Enum.map_join(metadata, "\n", fn {key, value} ->
        "  #{key}: #{format_yaml_value(value)}"
      end)

    "metadata:\n#{lines}\n"
  end

  defp format_yaml_value(value) when is_binary(value), do: "\"#{value}\""
  defp format_yaml_value(value), do: inspect(value)

  defp write_attachments(_skill_path, []), do: :ok

  defp write_attachments(skill_path, attachments) do
    Enum.each(attachments, fn attachment ->
      write_attachment(skill_path, attachment)
    end)

    :ok
  end

  defp write_attachment(skill_path, %{type: type, filename: filename, content: content}) do
    dir_name = Map.get(@attachment_dirs, type, type)
    attachment_dir = Path.join(skill_path, dir_name)
    File.mkdir_p!(attachment_dir)
    File.write!(Path.join(attachment_dir, filename), content)
  end

  defp write_attachment(skill_path, %{
         "type" => type,
         "filename" => filename,
         "content" => content
       }) do
    write_attachment(skill_path, %{type: type, filename: filename, content: content})
  end
end
