defmodule Quoracle.Actions.Spawn.TopologyResolver do
  @moduledoc """
  Grove topology resolution for spawn actions.
  Extracted from Spawn to keep module under 500 lines.

  Handles consulting grove topology edges to auto-inject skills, profile,
  and constraints into child agent spawn parameters.
  """

  alias Quoracle.Groves.SpawnContractResolver
  alias Quoracle.Profiles.Resolver, as: ProfileResolver
  require Logger

  @doc """
  Applies spawn contract from grove topology, merging auto-injected values.
  """
  @spec apply_spawn_contract(map(), map()) :: {:ok, map()} | {:error, term()}
  def apply_spawn_contract(params, deps) do
    parent_config = Map.get(deps, :parent_config, %{})
    topology = Map.get(deps, :grove_topology) || Map.get(parent_config, :grove_topology)
    grove_path = Map.get(deps, :grove_path) || Map.get(parent_config, :grove_path)
    grove_vars = Map.get(params, :grove_vars) || Map.get(params, "grove_vars")

    child_skill_names = normalize_skill_names(Map.get(params, :skills))

    parent_skill_names =
      parent_config
      |> Map.get(:active_skills, [])
      |> Enum.map(&Map.get(&1, :name))
      |> Enum.filter(&is_binary/1)

    case SpawnContractResolver.find_edge(topology, parent_skill_names, child_skill_names) do
      edge when is_map(edge) ->
        apply_matched_spawn_contract(edge, grove_path, params, grove_vars)

      _ ->
        if is_map(topology) and child_skill_names != [] do
          Logger.info(
            "Spawn: no topology edge for parent skills #{inspect(parent_skill_names)} -> child skills #{inspect(child_skill_names)}"
          )
        end

        {:ok, strip_grove_vars(params)}
    end
  end

  @doc """
  Resolves profile data, allowing edge-injected profiles to pass through.
  """
  @spec resolve_profile_data(map(), map()) :: {:ok, map() | nil} | {:error, term()}
  def resolve_profile_data(original_params, resolved_params) do
    requested_profile = Map.get(original_params, :profile) || Map.get(original_params, "profile")
    resolved_profile = Map.get(resolved_params, :profile)

    case resolve_profile(resolved_params) do
      {:ok, profile_data} ->
        {:ok, profile_data}

      {:error, :profile_not_found} ->
        # Allow edge-injected profiles that don't exist in DB to pass through.
        # Edge injection is detected when resolved_profile differs from requested_profile.
        if (is_nil(requested_profile) or requested_profile != resolved_profile) and
             is_binary(resolved_profile) do
          {:ok, nil}
        else
          {:error, :profile_not_found}
        end

      error ->
        error
    end
  end

  @doc """
  Resolves the grove skills path from deps, with fallback to grove_path/skills.
  """
  @spec resolve_grove_skills_path(map()) :: String.t() | nil
  def resolve_grove_skills_path(deps) do
    parent_config = Map.get(deps, :parent_config, %{})

    case Map.get(deps, :grove_skills_path) || Map.get(parent_config, :grove_skills_path) do
      path when is_binary(path) ->
        path

      _ ->
        case Map.get(deps, :grove_path) || Map.get(parent_config, :grove_path) do
          path when is_binary(path) -> Path.join(path, "skills")
          _ -> nil
        end
    end
  end

  @spec resolve_profile(map()) :: {:ok, map()} | {:error, :profile_required | :profile_not_found}
  defp resolve_profile(params) do
    case Map.get(params, :profile) || Map.get(params, "profile") do
      nil ->
        {:error, :profile_required}

      profile_name ->
        case ProfileResolver.resolve(profile_name) do
          {:ok, profile_data} -> {:ok, profile_data}
          {:error, :profile_not_found} -> {:error, :profile_not_found}
        end
    end
  end

  @doc """
  Normalizes skill names, filtering out non-binary values.
  """
  @spec normalize_skill_names(term()) :: [String.t()]
  def normalize_skill_names(skills) when is_list(skills), do: Enum.filter(skills, &is_binary/1)
  def normalize_skill_names(_skills), do: []

  @doc """
  Puts a parameter only if the value is non-nil.
  """
  @spec maybe_put_param(map(), atom(), term() | nil) :: map()
  def maybe_put_param(map, _key, nil), do: map
  def maybe_put_param(map, key, value), do: Map.put(map, key, value)

  @spec apply_matched_spawn_contract(map(), String.t() | nil, map(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  defp apply_matched_spawn_contract(edge, grove_path, params, grove_vars) do
    :ok = SpawnContractResolver.validate_required_context(edge, grove_vars)

    if is_binary(grove_path) do
      case SpawnContractResolver.resolve_auto_inject(edge, grove_path, params) do
        {:ok, injected} ->
          merged =
            params
            |> maybe_put_param(:skills, non_empty_skills(injected.skills))
            |> maybe_put_param(:profile, injected.profile)
            |> maybe_put_param(:downstream_constraints, injected.constraints)

          {:ok, merged}

        {:error, reason} ->
          Logger.warning("Spawn contract auto-inject failed: #{inspect(reason)}")
          {:ok, params}
      end
    else
      {:ok, params}
    end
  end

  @spec non_empty_skills([String.t()]) :: [String.t()] | nil
  defp non_empty_skills([]), do: nil
  defp non_empty_skills(skills) when is_list(skills), do: skills

  @spec strip_grove_vars(map()) :: map()
  defp strip_grove_vars(params) when is_map(params) do
    params
    |> Map.delete(:grove_vars)
    |> Map.delete("grove_vars")
  end
end
