defmodule Quoracle.Groves.SpawnContractResolver do
  @moduledoc """
  Resolves topology edge auto-inject values for child agent spawns.
  """

  require Logger

  alias Quoracle.Groves.PathSecurity

  @type topology_edge :: %{optional(String.t()) => term()}

  @type auto_inject_result :: %{
          skills: [String.t()],
          profile: String.t() | nil,
          constraints: String.t() | nil
        }

  @doc """
  Returns the first topology edge matching parent and child skill names.
  """
  @spec find_edge(map() | nil, [String.t()], [String.t()]) :: topology_edge() | nil
  def find_edge(_topology, _parent_skill_names, []), do: nil

  def find_edge(topology, parent_skill_names, child_skill_names)
      when is_list(parent_skill_names) and is_list(child_skill_names) do
    matches =
      topology
      |> edges_from_topology()
      |> Enum.filter(&edge_matches?(&1, parent_skill_names, child_skill_names))

    case matches do
      [first, second | _] ->
        Logger.warning(
          "Spawn contract has multiple matching edges; using first: #{inspect(first)} and ignoring #{inspect(second)}"
        )

        first

      [first] ->
        first

      [] ->
        nil
    end
  end

  def find_edge(_topology, _parent_skill_names, _child_skill_names), do: nil

  @doc """
  Resolves edge auto-inject values and merges them with existing params.
  """
  @spec resolve_auto_inject(topology_edge(), String.t(), map()) ::
          {:ok, auto_inject_result()}
          | {:error, {:path_traversal, String.t()} | {:symlink_not_allowed, String.t()} | term()}
  def resolve_auto_inject(edge, grove_path, existing_params)
      when is_map(edge) and is_binary(grove_path) and is_map(existing_params) do
    case Map.get(edge, "auto_inject") do
      auto_inject when is_map(auto_inject) ->
        with {:ok, topology_constraints} <-
               resolve_constraints(Map.get(auto_inject, "constraints"), grove_path) do
          skills = merge_skills(Map.get(auto_inject, "skills"), Map.get(existing_params, :skills))

          profile =
            existing_params
            |> Map.get(:profile)
            |> choose_profile(Map.get(auto_inject, "profile"))

          constraints =
            merge_constraints(
              topology_constraints,
              Map.get(existing_params, :downstream_constraints)
            )

          {:ok, %{skills: skills, profile: profile, constraints: constraints}}
        end

      _ ->
        {:ok, %{skills: [], profile: nil, constraints: nil}}
    end
  end

  @doc """
  Extracts a markdown section (## heading) by name, case-insensitively.
  """
  @spec extract_section(String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def extract_section(content, section_name)
      when is_binary(content) and is_binary(section_name) do
    pattern =
      ~r/(^##\s+#{Regex.escape(section_name)}\s*$\n?[\s\S]*?)(?=^##\s+|^#\s+|\z)/im

    case Regex.run(pattern, content, capture: :all_but_first) do
      [section] -> {:ok, String.trim(section)}
      _ -> :not_found
    end
  end

  def extract_section(_content, _section_name), do: :not_found

  @spec edges_from_topology(map() | nil) :: [topology_edge()]
  defp edges_from_topology(%{"edges" => edges}) when is_list(edges), do: edges
  defp edges_from_topology(_), do: []

  @spec edge_matches?(map(), [String.t()], [String.t()]) :: boolean()
  defp edge_matches?(edge, parent_skill_names, child_skill_names) when is_map(edge) do
    parent = Map.get(edge, "parent")
    child = Map.get(edge, "child")

    is_binary(parent) and is_binary(child) and
      parent in parent_skill_names and
      child in child_skill_names
  end

  defp edge_matches?(_edge, _parent_skill_names, _child_skill_names), do: false

  @spec merge_skills(term(), term()) :: [String.t()]
  defp merge_skills(auto_inject_skills, existing_skills) do
    (normalize_skills(auto_inject_skills) ++ normalize_skills(existing_skills))
    |> Enum.uniq()
  end

  @spec normalize_skills(term()) :: [String.t()]
  defp normalize_skills(skills) when is_list(skills), do: Enum.filter(skills, &is_binary/1)
  defp normalize_skills(_skills), do: []

  @spec choose_profile(String.t() | nil | term(), String.t() | nil | term()) :: String.t() | nil
  # LLM-explicit profile overrides edge defaults; edge profile is a fallback.
  defp choose_profile(existing_profile, _edge_profile)
       when is_binary(existing_profile) and existing_profile != "" do
    existing_profile
  end

  defp choose_profile(_existing_profile, edge_profile)
       when is_binary(edge_profile) and edge_profile != "" do
    edge_profile
  end

  defp choose_profile(_existing_profile, _edge_profile), do: nil

  @spec resolve_constraints(String.t() | nil | term(), String.t()) ::
          {:ok, String.t() | nil}
          | {:error, {:path_traversal, String.t()} | {:symlink_not_allowed, String.t()} | term()}
  defp resolve_constraints(nil, _grove_path), do: {:ok, nil}

  defp resolve_constraints(constraints_ref, grove_path) when is_binary(constraints_ref) do
    {file_path, section_name} = split_anchor(constraints_ref)

    case PathSecurity.safe_read_file(file_path, file_path, grove_path) do
      {:ok, content} ->
        resolve_section(content, section_name)

      {:error, {:file_not_found, _full_path}} ->
        Logger.warning("Spawn contract constraints file not found: #{file_path}")
        {:ok, nil}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_constraints(_constraints_ref, _grove_path), do: {:ok, nil}

  @spec resolve_section(String.t(), String.t() | nil) :: {:ok, String.t()}
  defp resolve_section(content, nil), do: {:ok, content}

  defp resolve_section(content, section_name) do
    case extract_section(content, section_name) do
      {:ok, section_content} ->
        {:ok, section_content}

      :not_found ->
        Logger.warning(
          "Spawn contract section not found: #{section_name}; falling back to full file"
        )

        {:ok, content}
    end
  end

  @spec split_anchor(String.t()) :: {String.t(), String.t() | nil}
  defp split_anchor(ref) do
    case String.split(ref, "#", parts: 2) do
      [path, section] -> {path, normalize_section(section)}
      [path] -> {path, nil}
    end
  end

  @spec normalize_section(String.t()) :: String.t() | nil
  defp normalize_section(section) do
    case String.trim(section) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @spec merge_constraints(String.t() | nil, String.t() | nil | term()) :: String.t() | nil
  defp merge_constraints(topology_constraints, llm_constraints)
       when is_binary(topology_constraints) and is_binary(llm_constraints) and
              llm_constraints != "" do
    topology_constraints <> "\n\n" <> llm_constraints
  end

  defp merge_constraints(topology_constraints, _llm_constraints)
       when is_binary(topology_constraints) do
    topology_constraints
  end

  defp merge_constraints(nil, llm_constraints)
       when is_binary(llm_constraints) and llm_constraints != "" do
    llm_constraints
  end

  defp merge_constraints(_topology_constraints, _llm_constraints), do: nil
end
