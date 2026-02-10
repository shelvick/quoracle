defmodule Quoracle.Consensus.PromptBuilder.SkillLoader do
  @moduledoc """
  Loads skill content from files for injection into system prompts.
  Part of CONSENSUS_PromptBuilder v15.0 - Skills System integration.
  """

  @doc """
  Loads and combines content from active skills.

  Returns the combined skill content as a string, or empty string if no skills.
  Multiple skills are separated by --- dividers.
  Gracefully handles missing files with placeholder text.
  """
  @spec load_skill_content(list() | nil, keyword()) :: String.t()
  def load_skill_content(nil, _opts), do: ""
  def load_skill_content([], _opts), do: ""

  def load_skill_content(active_skills, _opts) when is_list(active_skills) do
    contents =
      active_skills
      |> Enum.map(&load_single_skill/1)
      |> Enum.filter(&(&1 != ""))

    case contents do
      [] -> ""
      [single] -> single
      multiple -> Enum.join(multiple, "\n\n---\n\n")
    end
  end

  # Use stored content if available (preferred - avoids disk I/O)
  defp load_single_skill(%{content: content, name: name})
       when is_binary(content) and content != "" do
    wrap_with_skill_tag(name, content)
  end

  # Fallback: re-read from file (for legacy metadata without content)
  defp load_single_skill(%{path: path, name: name}) do
    # Handle both file paths (test/legacy) and directory paths (real skills)
    skill_file = if File.dir?(path), do: Path.join(path, "SKILL.md"), else: path

    case File.read(skill_file) do
      {:ok, content} ->
        wrap_with_skill_tag(name, extract_body_content(content))

      {:error, _} ->
        # Graceful degradation - show placeholder for missing files
        wrap_with_skill_tag(name, "[Skill '#{name}' content unavailable]")
    end
  end

  defp load_single_skill(_invalid), do: ""

  # Wrap skill content with XML tags so LLMs can identify skill boundaries
  defp wrap_with_skill_tag(name, content) do
    "<skill name=\"#{name}\">\n#{content}\n</skill>"
  end

  # Extract body content from SKILL.md (after YAML frontmatter)
  defp extract_body_content(content) do
    case Regex.run(~r/\A\s*---\s*\n.*?\n---\s*\n?(.*)\z/s, content) do
      [_, body] -> String.trim(body)
      nil -> String.trim(content)
    end
  end
end
