defmodule Quoracle.Agent.ConfigManager do
  @moduledoc """
  Configuration normalization and agent setup for AGENT_Core.
  Handles various config formats and initializes agent state.
  """

  alias Quoracle.Agent.ConfigManager.{ModelPoolInit, TestGuards}
  alias Quoracle.PubSub.AgentEvents
  require Logger

  @doc """
  Normalizes configuration from various formats into a consistent map.

  Supports multiple input formats:
  - Keyword lists (converted to maps)
  - Maps (production format with defaults applied)
  - 2-tuples `{parent_pid, initial_prompt}` (test format)
  - 3-tuples `{parent_pid, initial_prompt, opts}` (test format with options)

  All formats are normalized to a consistent map structure with required fields
  populated with appropriate defaults.
  """
  @spec normalize_config(keyword() | map() | tuple()) :: map()

  def normalize_config(config) when is_list(config) do
    # Convert keyword list to map and normalize
    config |> Map.new() |> normalize_config()
  end

  def normalize_config(%{} = config) do
    # Map config - ensure agent_id exists
    agent_id = Map.get(config, :agent_id, generate_agent_id())
    config = Map.put(config, :agent_id, agent_id)

    # Map config from DynSup
    test_opts = Map.get(config, :test_opts, [])

    # Add skip_initial_consultation to test_opts if it's at the top level
    test_opts =
      if Map.has_key?(config, :skip_initial_consultation) do
        Keyword.put(test_opts, :skip_initial_consultation, config.skip_initial_consultation)
      else
        test_opts
      end

    # Extract sandbox_owner from config or test_opts
    sandbox_owner =
      Map.get(config, :sandbox_owner) ||
        if is_list(test_opts) do
          Keyword.get(test_opts, :sandbox_owner)
        else
          nil
        end

    # Get task if present (nil for reactive agents)
    task = Map.get(config, :task)

    # Get model pool and initialize per-model histories (Packet 2)
    # Preserve model_histories from config if present (restoration case - v5.0)
    # FIX: Empty map %{} is truthy, so we must check map_size > 0
    # Otherwise restored agents with NULL state get empty model_histories
    # and StateUtils creates "default" key instead of proper model IDs
    test_mode = Map.get(config, :test_mode, false)
    model_pool = ModelPoolInit.get_model_pool_for_init(config, test_mode)

    model_histories =
      case Map.get(config, :model_histories) do
        mh when is_map(mh) and map_size(mh) > 0 -> mh
        _ -> ModelPoolInit.initialize_model_histories(model_pool)
      end

    # Build base config as a map with timestamp
    base_config = %{
      agent_id: agent_id,
      parent_pid: Map.get(config, :parent_pid),
      # Preserve parent_id from Spawn action
      parent_id: Map.get(config, :parent_id),
      task_id: Map.get(config, :task_id),
      task: task,
      model_id: Map.get(config, :model_id),
      models: Map.get(config, :models, []),
      pubsub: Map.get(config, :pubsub),
      registry: Map.get(config, :registry),
      dynsup: Map.get(config, :dynsup),
      # Model pool for consensus (v3.0 DI - avoids DB access from spawned processes)
      # NOTE: Do NOT default to [] here - breaks test_mode fallback to Manager.test_model_pool()
      model_pool: Map.get(config, :model_pool),
      force_init_error: Map.get(config, :force_init_error, false),
      test_mode: test_mode,
      simulate_failure: Map.get(config, :simulate_failure, false),
      force_condense: Map.get(config, :force_condense, false),
      skip_consensus: Map.get(config, :skip_consensus, false),
      test_opts: test_opts,
      sandbox_owner: sandbox_owner,
      test_pid: Map.get(config, :test_pid),
      skip_auto_consensus: Map.get(config, :skip_auto_consensus, false),
      started_at: System.monotonic_time(),
      prompt_fields: Map.get(config, :prompt_fields),
      system_prompt: Map.get(config, :system_prompt),
      temperature: Map.get(config, :temperature),
      max_tokens: Map.get(config, :max_tokens),
      timeout: Map.get(config, :timeout),
      max_depth: Map.get(config, :max_depth),
      config: Map.get(config, :config),
      todos: Map.get(config, :todos, []),
      model_histories: model_histories,
      context_lessons: Map.get(config, :context_lessons),
      model_states: Map.get(config, :model_states),
      restoration_mode: Map.get(config, :restoration_mode, false),
      budget_data: Map.get(config, :budget_data),
      # Profile fields (v6.0)
      profile_name: Map.get(config, :profile_name),
      profile_description: Map.get(config, :profile_description),
      max_refinement_rounds: Map.get(config, :max_refinement_rounds, 4),
      # v8.0: Capability groups for profile-based action filtering
      capability_groups: Map.get(config, :capability_groups, []),
      # v9.0: Skills system - skill names requested for spawn, active skill metadata
      skills: Map.get(config, :skills, []),
      active_skills: Map.get(config, :active_skills, [])
    }

    # Only add initial_prompt if task was provided
    if task do
      Map.put(base_config, :initial_prompt, task)
    else
      base_config
    end
  end

  def normalize_config({parent_pid, initial_prompt}) do
    # Tuple config from tests - no test_mode, no model_pool
    # Production mode will query DB (and raise if not configured)
    model_pool = ModelPoolInit.get_model_pool_for_init(%{}, false)
    model_histories = ModelPoolInit.initialize_model_histories(model_pool)

    %{
      agent_id: generate_agent_id(),
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      task_id: nil,
      force_init_error: false,
      test_mode: false,
      test_opts: [],
      sandbox_owner: nil,
      model_pool: nil,
      started_at: System.monotonic_time(),
      model_histories: model_histories
    }
  end

  def normalize_config({parent_pid, initial_prompt, opts}) do
    # Tuple config with options from tests
    # Extract test_mode and simulate_failure but keep ALL options in test_opts for consensus
    test_mode = Keyword.get(opts, :test_mode, false)
    simulate_failure = Keyword.get(opts, :simulate_failure, false)
    explicit_pool = Keyword.get(opts, :model_pool)

    # Build temp config map for get_model_pool_for_init
    temp_config = %{model_pool: explicit_pool}
    model_pool = ModelPoolInit.get_model_pool_for_init(temp_config, test_mode)
    model_histories = ModelPoolInit.initialize_model_histories(model_pool)

    %{
      agent_id: generate_agent_id(),
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      task_id: nil,
      force_init_error: false,
      test_mode: test_mode,
      simulate_failure: simulate_failure,
      # Keep ALL options including test_mode
      test_opts: opts,
      sandbox_owner: Keyword.get(opts, :sandbox_owner),
      # Preserve injected dependencies
      registry: Keyword.get(opts, :registry),
      dynsup: Keyword.get(opts, :dynsup),
      pubsub: Keyword.get(opts, :pubsub),
      model_pool: explicit_pool,
      started_at: System.monotonic_time(),
      model_histories: model_histories,
      # v8.0: Capability groups for profile-based action filtering
      capability_groups: Keyword.get(opts, :capability_groups, [])
    }
  end

  @doc """
  Registers an agent with the Registry using atomic composite value.
  This prevents race conditions between agent_id and parent_pid registration.

  Registry is required - no defaults.

  ## Examples

      # With registry atom directly
      register_agent(config, MyRegistry)

      # With keyword list
      register_agent(config, registry: my_registry)

  """
  @spec register_agent(map(), atom() | keyword()) :: :ok

  def register_agent(config, registry) when is_atom(registry) do
    do_register_agent(config, registry)
  end

  def register_agent(config, opts) when is_list(opts) do
    registry = Keyword.fetch!(opts, :registry)
    do_register_agent(config, registry)
  end

  defp do_register_agent(config, registry) do
    agent_id = Map.get(config, :agent_id)
    parent_pid = Map.get(config, :parent_pid)

    # Single atomic registration with composite value
    composite_value = %{
      pid: self(),
      agent_id: agent_id,
      task_id: Map.get(config, :task_id),
      parent_pid: parent_pid,
      # Parent's agent_id for SendMessage resolution
      parent_id: Map.get(config, :parent_id),
      registered_at: System.monotonic_time()
    }

    case Registry.register(registry, {:agent, agent_id}, composite_value) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, _pid}} ->
        # Crash - let supervisor handle duplicate agent ID
        raise "Duplicate agent ID: #{agent_id}"
    end
  end

  @doc """
  Sets up initial agent state with all required components.
  Spawns router, registers with registry, and broadcasts events.

  Returns a Core.State struct with compile-time validated fields.

  ## Options

    * `:registry` - The Registry PID to use (defaults to Quoracle.AgentRegistry)
    * `:dynsup` - The DynamicSupervisor PID to use (defaults to discovered via DynSup)

  ## Examples

      # Production usage
      state = setup_agent(%{agent_id: "agent-1", parent_pid: self()})

      # Test usage with dependency injection
      state = setup_agent(config, registry: test_registry, dynsup: test_dynsup)

  """
  @spec setup_agent(keyword() | map()) :: Quoracle.Agent.Core.State.t()
  @spec setup_agent(keyword() | map(), keyword()) :: Quoracle.Agent.Core.State.t()

  # Production interface
  def setup_agent(config) do
    setup_agent(config, [])
  end

  # Dependency injection interface
  def setup_agent(config, opts) do
    # Extract pubsub from opts first, then config (required - no default)
    pubsub = Keyword.get(opts, :pubsub) || config[:pubsub] || raise "pubsub is required"

    # Validate PubSub isolation in test environment
    validate_pubsub_isolation(config, pubsub)

    # Per-action Router (v28.0): Router is spawned per-action in Router.execute/3,
    # not at agent init time. Each action gets its own Router that terminates after completion.

    # Monitor parent if provided
    if config[:parent_pid] do
      Process.monitor(config[:parent_pid])
    end

    # Extract injected dependencies - check config first, then opts (required - no defaults)
    registry = config[:registry] || Keyword.get(opts, :registry) || raise "registry is required"
    dynsup = config[:dynsup] || Keyword.get(opts, :dynsup) || discover_dynsup()

    # Use atomic registration to prevent race conditions
    # Convert keyword list to map if needed for register_agent
    config_map = if is_list(config), do: Map.new(config), else: config

    # This will raise on duplicate agent_id (let it crash philosophy)
    # Pass registry as keyword list for proper function dispatch
    :ok = register_agent(config_map, registry: registry)

    # In test mode, check test_opts for context_limit
    default_limit =
      if config[:test_mode] && config[:test_opts] do
        Keyword.get(config[:test_opts], :context_limit, 4000)
      else
        4000
      end

    # Build state configuration map first
    state_config = %{
      agent_id: config[:agent_id],
      parent_pid: config[:parent_pid],
      parent_id: config[:parent_id],
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      children: [],
      # Use model_histories from normalize_config (initialized from model pool)
      model_histories: config[:model_histories] || %{},
      pending_actions: %{},
      wait_timer: nil,
      timer_generation: 0,
      action_counter: 0,
      # Don't store initial_prompt - agents are reactive now
      task_id: config[:task_id],
      # Task string for backward compatibility
      task: config[:task],
      # Start ready immediately
      state: :ready,
      test_mode: config[:test_mode],
      simulate_failure: config[:simulate_failure],
      force_condense: config[:force_condense],
      skip_consensus: config[:skip_consensus],
      test_opts: config[:test_opts] || [],
      sandbox_owner: config[:sandbox_owner],
      test_pid: config[:test_pid],
      context_summary: nil,
      # Track lazy loading
      context_limits_loaded: false,
      model_id: config[:model_id],
      # Models list for inheritance by child agents
      models: config[:models] || [],
      # Model pool for consensus (DI for test isolation)
      model_pool: config[:model_pool],
      # Messages mailbox for inter-agent communication
      messages: [],
      # Default, will be loaded lazily on first message
      context_limit: default_limit,
      # For integration tests that need manual control of consensus
      skip_auto_consensus: config[:skip_auto_consensus] || false,
      # TODO list for Packet 2
      todos: config[:todos] || [],
      # Field-based prompt system (v3.0)
      prompt_fields: config[:prompt_fields],
      system_prompt: config[:system_prompt],
      # Preserve arbitrary config fields (temperature, max_tokens, etc.)
      temperature: config[:temperature],
      max_tokens: config[:max_tokens],
      timeout: config[:timeout],
      max_depth: config[:max_depth],
      # Preserve nested config structure for complex configurations
      config: config[:config],
      # ACE state restoration (context_lessons, model_states)
      context_lessons: config[:context_lessons],
      model_states: config[:model_states],
      # Restoration mode flag (prevents re-persistence loops)
      restoration_mode: config[:restoration_mode] || false,
      # Budget system (v4.0)
      budget_data: config[:budget_data],
      # Profile fields (v6.0, v9.0 added capability_groups)
      profile_name: config[:profile_name],
      profile_description: config[:profile_description],
      max_refinement_rounds:
        case config[:max_refinement_rounds] do
          nil -> 4
          value -> value
        end,
      capability_groups: config[:capability_groups] || [],
      # Skills system (v9.0)
      active_skills: config[:active_skills] || []
    }

    # Create State struct from configuration
    state = Quoracle.Agent.Core.State.new(state_config)

    # Broadcast agent spawned event using previously extracted pubsub
    # Skip broadcast if this is a spawned child (parent_id present) - Spawn action will broadcast with full context
    # Broadcast for: root agents (no parent_id) OR restored agents (restoration_mode true)
    if !config[:parent_id] or config[:restoration_mode] do
      # For restored agents, use string parent_id (Dashboard expects string for agents map lookup)
      # For root agents, parent_pid is nil anyway
      parent_identifier = config[:parent_id] || config[:parent_pid]

      # Include budget_data in payload to avoid blocking GenServer.call in LiveView
      AgentEvents.broadcast_agent_spawned(
        config[:agent_id],
        config[:task_id],
        parent_identifier,
        pubsub,
        config[:budget_data]
      )
    end

    state
  end

  @doc """
  Build agent configuration with dependency injection.
  Requires pubsub and registry in deps - no defaults.
  """
  @spec build_agent_config(map(), map()) :: map()
  def build_agent_config(base_config, deps) do
    unless deps[:pubsub], do: raise("pubsub is required in deps")
    unless deps[:registry], do: raise("registry is required in deps")

    # Use Map.put_new to avoid overwriting existing values
    base_config
    |> Map.put_new(:pubsub, deps[:pubsub])
    |> Map.put_new(:registry, deps[:registry])
    |> Map.put_new(:dynsup, deps[:dynsup])
  end

  @doc """
  Inject dependencies into configuration.
  """
  @spec inject_dependencies(map(), map()) :: map()
  def inject_dependencies(config, deps) do
    # Use Map.put_new to avoid overwriting
    Enum.reduce(deps, config, fn {key, value}, acc ->
      Map.put_new(acc, key, value)
    end)
  end

  @doc """
  Propagate parent configuration to child.
  """
  @spec propagate_to_children(map(), map()) :: map()
  def propagate_to_children(parent_config, child_base) do
    # Child can override inherited values
    parent_config
    |> Map.take([:pubsub, :registry, :dynsup])
    |> Map.merge(child_base)
  end

  @doc """
  Validate configuration including pubsub.
  """
  @spec validate_config(map()) :: :ok | {:error, atom()}
  def validate_config(config) do
    cond do
      not Map.has_key?(config, :agent_id) ->
        {:error, :missing_agent_id}

      config[:pubsub] && not is_atom(config[:pubsub]) ->
        {:error, :invalid_pubsub}

      true ->
        :ok
    end
  end

  @doc """
  Generates a unique agent ID.
  """
  @spec generate_agent_id() :: String.t()
  def generate_agent_id do
    "agent-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp discover_dynsup, do: Quoracle.Agent.DynSup.get_dynsup_pid()

  # Delegate to extracted module (keeps ConfigManager under 500 lines)
  defp validate_pubsub_isolation(config, pubsub) do
    TestGuards.validate_pubsub_isolation(config, pubsub)
  end
end
