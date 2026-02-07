defmodule Quoracle.Actions.Spawn.ConfigBuilder do
  @moduledoc """
  Builds configuration maps for spawned child agents.

  Handles:
  - Parent config extraction and inheritance
  - Field-based parameter processing
  - Model merging (child overrides parent)
  - Test isolation settings (sandbox_owner, test_mode, pubsub)
  """

  alias Quoracle.Fields.PromptFieldManager
  alias Quoracle.Profiles.Resolver, as: ProfileResolver

  @doc """
  Extracts the DynamicSupervisor reference from dependencies.

  ## Parameters
    * `deps` - Dependencies map containing `:dynsup` (pid/atom) or `:dynsup_fn` (function)

  ## Returns
    * `{:ok, pid() | atom() | function()}` - DynamicSupervisor reference
    * `{:error, :dynsup_not_found}` - No supervisor found in deps
  """
  @spec get_dynsup(map()) :: {:ok, pid() | atom() | function()} | {:error, :dynsup_not_found}
  def get_dynsup(deps) do
    case deps do
      %{dynsup_fn: dynsup_fn} when is_function(dynsup_fn) ->
        {:ok, dynsup_fn}

      %{dynsup: dynsup} when is_pid(dynsup) or is_atom(dynsup) ->
        {:ok, dynsup}

      _ ->
        {:error, :dynsup_not_found}
    end
  end

  @doc """
  Builds complete configuration map for spawned child agent.

  ## Parameters
    * `task_result` - Tuple `{:field_based, task_description}`
    * `params` - Raw spawn parameters (may be wrapped in "params" key)
    * `parent_id` - Parent agent ID string
    * `parent_pid` - Parent agent PID
    * `deps` - Dependencies map (dynsup, registry, pubsub, sandbox_owner, etc.)
    * `child_id` - (optional) Pre-generated child agent ID for async spawn pattern

  ## Returns
    * `{:ok, config}` - Complete child agent configuration map
  """
  @spec build_config(tuple(), map(), String.t(), pid(), map()) :: {:ok, map()}
  def build_config(task_result, params, parent_id, parent_pid, deps) do
    # Generate child ID if not provided (legacy sync path)
    child_id = Quoracle.Actions.Spawn.generate_child_id()
    build_config(task_result, params, parent_id, parent_pid, deps, child_id)
  end

  @spec build_config(tuple(), map(), String.t(), pid(), map(), String.t()) :: {:ok, map()}
  def build_config(task_result, params, parent_id, parent_pid, deps, child_id) do
    # Handle both wrapped (%{"params" => ...}) and unwrapped params
    child_params =
      case Map.get(params, "params") do
        nil -> params
        wrapped -> wrapped
      end

    # Get parent config from deps - REQUIRED, no fallback to Core.get_state
    # Calling Core.get_state(parent_pid) causes GenServer deadlock when parent
    # is in handle_cast processing consensus (5-second timeout, then failure).
    parent_config =
      case Map.get(deps, :parent_config) do
        config when is_map(config) ->
          # Could be State struct or map - normalize to map
          if is_struct(config), do: Map.from_struct(config), else: config

        nil ->
          # CRITICAL: Never call Core.get_state here - causes GenServer deadlock
          # If we hit this, there's a bug in the call chain that needs fixing.
          raise ArgumentError, """
          [ConfigBuilder] parent_config is required but missing from deps.

          This prevents GenServer deadlock when parent is processing consensus.
          The caller must pass parent_config in opts/deps.

          deps keys present: #{inspect(Map.keys(deps))}
          parent_pid: #{inspect(parent_pid)}
          parent_id: #{inspect(parent_id)}

          Check that ConsensusHandler.execute_consensus_action_impl
          is passing parent_config: state in execute_opts.
          """

        _ ->
          %{}
      end

    # Extract task_id from parent config or deps
    task_id = parent_config[:task_id] || Map.get(deps, :task_id)

    # Extract task string and handle field-based parameters
    # task_result is always {:field_based, task_desc} now (no legacy support)
    {:field_based, task_desc} = task_result

    # Normalize keys and extract/transform fields
    normalized_params = Quoracle.Actions.Spawn.normalize_field_keys(child_params)
    parent_fields = parent_config[:prompt_fields] || %{}

    # Use task_id for global context injection, or generate a temporary one if nil
    effective_task_id = task_id || "task-#{System.unique_integer([:positive])}"

    # Extract profile data if present (added during resolve_profile)
    profile_data = Map.get(normalized_params, :_profile_data)
    # v15.0: Extract skills metadata if present (added during resolve_skills)
    skills_metadata = Map.get(normalized_params, :_skills_metadata, [])
    # Remove internal fields before passing to PromptFieldManager
    params_without_internal =
      normalized_params
      |> Map.delete(:_profile_data)
      |> Map.delete(:_skills_metadata)

    # Pass sandbox_owner for test DB access in LLM summarization Tasks
    # v16.0: Include cost context so FieldTransformer.maybe_add_cost_context/2 can record costs
    transform_opts = [
      sandbox_owner: Map.get(deps, :sandbox_owner),
      agent_id: Map.get(deps, :agent_id),
      task_id: Map.get(deps, :task_id),
      pubsub: Map.get(deps, :pubsub)
    ]

    child_fields =
      PromptFieldManager.transform_for_child(
        parent_fields,
        params_without_internal,
        effective_task_id,
        transform_opts
      )

    task_string = task_desc
    prompt_fields = child_fields

    # Extract optional parameters (handle both string and atom keys)
    models = Map.get(child_params, "models") || Map.get(child_params, :models, [])

    parent_models = parent_config[:models] || []

    # Merge models - use child if specified, otherwise parent
    final_models = if models == [], do: parent_models, else: models

    # WHITELIST: Only these specific fields should cascade from parent to child
    # Everything else is either set explicitly below or the child starts fresh
    # (Blacklist approach was dangerous - inherited huge model_histories, causing timeouts)
    inheritable_keys = [
      # LLM config that should cascade to children
      :temperature,
      :max_tokens,
      :timeout,
      :max_depth,
      :model_id,
      # Test isolation - required for spawned children in tests
      :model_pool,
      :simulate_failure,
      :test_pid,
      :force_init_error
    ]

    inherited_from_parent = Map.take(parent_config, inheritable_keys)

    # Build config with essential fields
    # Start with inherited config to preserve whitelisted fields (temperature, etc.)
    # Then add/override with essential spawn fields
    config =
      inherited_from_parent
      |> Map.put(:agent_id, child_id)
      |> Map.put(:id, child_id)
      |> Map.put(:parent_id, parent_id)
      |> Map.put(:parent_pid, parent_pid)
      |> Map.put(:task, task_string)
      |> Map.put(:models, final_models)
      |> Map.put(:task_id, parent_config[:task_id])

    # Add prompt_fields and generate prompts from fields
    # Both field-based and legacy spawns have prompt_fields now
    # user_prompt removed in Packet 2 - initial message flows through model_histories
    {system_prompt, _user_prompt} =
      PromptFieldManager.build_prompts_from_fields(prompt_fields)

    # v5.0: Field-based system_prompt flows through unchanged.
    # Contains XML tags (role, cognitive_style, constraints) from merged
    # default_fields + spawn params.

    config =
      config
      |> Map.put(:prompt_fields, prompt_fields)
      |> Map.put(:system_prompt, system_prompt)

    # v16.0: Merge profile fields using DRY helper (profile_data always present per R32-R37)
    config =
      if profile_data do
        Map.merge(config, ProfileResolver.to_config_fields(profile_data))
      else
        config
      end

    # v15.0: Add skills metadata as active_skills
    config =
      if skills_metadata != [] do
        Map.put(config, :active_skills, skills_metadata)
      else
        config
      end

    # Inherit test-related fields from parent for DB sandbox access and PubSub isolation
    # Fallback to deps if not in parent_config (fixes race condition where parent hasn't fully initialized)
    config =
      cond do
        Map.has_key?(parent_config, :sandbox_owner) ->
          Map.put(config, :sandbox_owner, parent_config[:sandbox_owner])

        Map.has_key?(deps, :sandbox_owner) ->
          Map.put(config, :sandbox_owner, deps[:sandbox_owner])

        true ->
          config
      end

    config =
      cond do
        Map.has_key?(parent_config, :test_mode) ->
          Map.put(config, :test_mode, parent_config[:test_mode])

        Map.has_key?(deps, :test_mode) ->
          Map.put(config, :test_mode, deps[:test_mode])

        true ->
          config
      end

    # CRITICAL: Always inherit pubsub (not conditional on sandbox_owner)
    # Tests may use isolated PubSub without sandbox_owner
    # Fallback to deps[:pubsub] if not in parent_config (fixes non-deterministic test failures)
    config =
      cond do
        Map.has_key?(parent_config, :pubsub) ->
          Map.put(config, :pubsub, parent_config[:pubsub])

        Map.has_key?(deps, :pubsub) ->
          Map.put(config, :pubsub, deps[:pubsub])

        true ->
          config
      end

    # Inherit skip_auto_consensus for consistent test behavior across agent hierarchy
    config =
      if Map.has_key?(parent_config, :skip_auto_consensus) do
        Map.put(config, :skip_auto_consensus, parent_config[:skip_auto_consensus])
      else
        config
      end

    # Add registry and dynsup from deps so child can spawn its own children
    config =
      config
      |> Map.put(:registry, Map.get(deps, :registry))
      |> Map.put(:dynsup, Map.get(deps, :dynsup) || Map.get(deps, :dynsup_fn))

    {:ok, config}
  end
end
