defmodule Quoracle.Actions.LearnSkills do
  @moduledoc """
  Action module for loading skills into agent context.
  Temporary skills return content; permanent skills update state.
  """

  alias Quoracle.Skills.Loader

  @doc """
  Loads skills into agent context.
  Standard 3-arity action signature.
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(params, _agent_id, opts) do
    with {:ok, skill_names} <- validate_skills_param(params),
         {:ok, skills} <- Loader.load_skills(skill_names, opts) do
      permanent = get_permanent_flag(params)

      # Format content for LLM
      content = format_skills_content(skills)

      # If permanent, update agent state
      if permanent do
        agent_pid = Keyword.get(opts, :agent_pid)

        if agent_pid do
          skills_metadata = Enum.map(skills, &skill_to_metadata/1)
          GenServer.cast(agent_pid, {:learn_skills, skills_metadata})
        end
      end

      # Omit content when permanent (will be in system prompt, saves tokens)
      paths = Map.new(skills, fn s -> {s.name, s.path} end)

      result = %{
        action: "learn_skills",
        skills: skill_names,
        permanent: permanent,
        paths: paths
      }

      {:ok, if(permanent, do: result, else: Map.put(result, :content, content))}
    end
  end

  defp validate_skills_param(params) when is_map(params) do
    skills = Map.get(params, :skills) || Map.get(params, "skills")

    cond do
      is_nil(skills) -> {:error, "skills is required"}
      not is_list(skills) -> {:error, "skills must be a list"}
      true -> {:ok, skills}
    end
  end

  defp get_permanent_flag(params) do
    case Map.get(params, :permanent) || Map.get(params, "permanent") do
      true -> true
      _ -> false
    end
  end

  defp skill_to_metadata(skill) do
    %{
      name: skill.name,
      permanent: true,
      loaded_at: DateTime.utc_now(),
      description: skill.description,
      path: skill.path,
      metadata: skill.metadata,
      content: skill.content
    }
  end

  defp format_skills_content(skills) do
    Enum.map_join(skills, "\n\n---\n\n", fn skill ->
      "<skill name=\"#{skill.name}\">\n#{skill.content}\n</skill>"
    end)
  end
end
