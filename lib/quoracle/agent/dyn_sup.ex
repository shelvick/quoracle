defmodule Quoracle.Agent.DynSup do
  @moduledoc """
  Thin wrapper around DynamicSupervisor for agent lifecycle management.
  """

  use DynamicSupervisor
  alias Quoracle.Supervisor.PidDiscovery
  require Logger

  # Compile-time environment check for orphan prevention
  # Dialyzer: @mix_env is constant at compile time, producing env-dependent warnings
  # (test: :pattern_match, dev: :exact_eq + :unused_fun). Suppress in-module to avoid
  # cross-environment unnecessary skips in .dialyzer_ignore.exs.
  @dialyzer [:no_match, :no_unused]
  @mix_env Mix.env()

  @doc """
  Custom child_spec with shutdown: :infinity to prevent kill escalation.

  CRITICAL: DynamicSupervisor default shutdown is 5000ms. When ExUnit terminates
  DynSup after this timeout, it escalates to :kill which bypasses terminate/2
  callbacks in children (Core → Router), causing orphaned Routers with active
  DB connections and "owner exited while client was still running" errors.

  With shutdown: :infinity, ExUnit waits for DynSup to properly terminate all
  children via GenServer.stop with :infinity timeout.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(init_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [init_arg]},
      type: :supervisor,
      shutdown: :infinity
    }
  end

  @doc """
  Starts the DynamicSupervisor.
  Supports optional :name parameter for test isolation.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, {:already_started, pid()}}
  def start_link(init_arg) do
    name = Keyword.get(init_arg, :name)

    if name do
      DynamicSupervisor.start_link(__MODULE__, init_arg, name: name)
    else
      DynamicSupervisor.start_link(__MODULE__, init_arg)
    end
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 60
    )
  end

  @doc """
  Gets the PID of the DynSup from the application supervisor.
  Returns nil if not found.
  """
  @spec get_dynsup_pid() :: pid() | nil
  def get_dynsup_pid() do
    PidDiscovery.find_child_pid(__MODULE__)
  end

  @doc """
  Starts an agent process under supervision using explicit DynSup PID.
  """
  @spec start_agent(pid(), map()) :: {:ok, pid()} | {:error, term()}
  @spec start_agent(pid(), map(), keyword()) :: {:ok, pid()} | {:error, term()}

  # Production interface - no options
  def start_agent(dynsup_pid, config) do
    start_agent(dynsup_pid, config, [])
  end

  # Dependency injection interface - accepts registry and pubsub options
  def start_agent(dynsup_pid, config, opts) do
    # ORPHAN PREVENTION: In test environment, enforce use of test helpers
    # This prevents orphaned processes that cause DB connection leaks
    if @mix_env == :test do
      enforce_test_helper_usage()
    end

    # Extract registry and pubsub from config first, then opts (required - no defaults)
    registry = config[:registry] || Keyword.get(opts, :registry) || raise "registry is required"
    pubsub = config[:pubsub] || Keyword.get(opts, :pubsub) || raise "pubsub is required"
    dynsup_from_config = config[:dynsup]

    # Build options list with all dependencies
    child_opts = [
      registry: registry,
      pubsub: pubsub
    ]

    child_opts =
      if dynsup_from_config, do: [{:dynsup, dynsup_from_config} | child_opts], else: child_opts

    with :ok <- validate_config(config) do
      case DynamicSupervisor.start_child(dynsup_pid, build_child_spec(config, child_opts)) do
        {:ok, pid} ->
          # Agent registers itself in init/1 with injected registry
          {:ok, pid}

        {:error, reason} = error ->
          Logger.error("Failed to start agent: #{inspect(reason)}")
          error
      end
    end
  end

  @doc """
  Terminates an agent gracefully.

  CRITICAL: Uses GenServer.stop instead of DynamicSupervisor.terminate_child to ensure
  Core.terminate/2 callback is triggered, which properly stops the Router GenServer.
  Without this, Routers are orphaned with active DB connections, causing Postgrex errors.

  ## Parameters
    - agent_pid: The PID of the agent to terminate

  ## Returns
    - :ok if the agent was successfully terminated
    - {:error, :not_found} if the agent was not alive
  """
  @spec terminate_agent(pid()) :: :ok | {:error, :not_found}
  def terminate_agent(agent_pid) do
    # Use GenServer.stop to trigger Core.terminate/2 which stops the Router
    # DynamicSupervisor.terminate_child does NOT trigger terminate/2 callback
    if Process.alive?(agent_pid) do
      try do
        GenServer.stop(agent_pid, :normal, :infinity)
        :ok
      catch
        :exit, _ ->
          # Not a GenServer or already terminated
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Lists all supervised agent PIDs.
  """
  @spec list_agents() :: [pid()]
  def list_agents do
    case get_dynsup_pid() do
      nil ->
        []

      dynsup_pid ->
        DynamicSupervisor.which_children(dynsup_pid)
        |> Enum.map(fn {_, pid, _, _} -> pid end)
    end
  end

  @doc """
  Returns the count of supervised agents.
  """
  @spec get_agent_count() :: non_neg_integer()
  def get_agent_count do
    case get_dynsup_pid() do
      nil ->
        0

      dynsup_pid ->
        DynamicSupervisor.count_children(dynsup_pid).active
    end
  end

  @doc """
  Restore agent from persisted database state.

  Similar to start_agent/3 but sets restoration_mode flag to prevent
  duplicate persistence writes during initialization.

  ## Parameters
  - `dynsup_pid` - DynamicSupervisor PID
  - `db_agent` - Agent record from database (Quoracle.Agents.Agent struct)
  - `opts` - Options keyword list:
    - `:registry` - Registry instance (default: Quoracle.AgentRegistry)
    - `:pubsub` - PubSub instance (default: Quoracle.PubSub)
    - `:parent_pid_override` - Override parent PID if parent restored separately

  ## Returns
  - `{:ok, pid}` - Agent restored successfully
  - `{:error, reason}` - Restoration failed
  """
  @spec restore_agent(pid(), %Quoracle.Agents.Agent{}, keyword()) ::
          {:ok, pid()} | {:error, term()}
  def restore_agent(dynsup_pid, db_agent, opts \\ []) do
    # Extract base config from database and atomize known keys
    # (JSONB stores all keys as strings, but code expects atom keys)
    base_config = atomize_config_keys(db_agent.config)

    # Re-resolve profile to get capability_groups (not persisted in config)
    # This also ensures updated profile capabilities apply to restored agents
    profile_data = resolve_profile_for_restore(db_agent.profile_name)

    # Validate base config has required fields
    with :ok <- validate_restore_config(base_config) do
      # Restore ACE state (context_lessons, model_states, model_histories) from database
      ace_state = Quoracle.Agent.Core.Persistence.restore_ace_state(db_agent)

      # Build restoration config
      restoration_config = %{
        # Core identity (from DB)
        agent_id: db_agent.agent_id,
        task_id: db_agent.task_id,
        parent_id: db_agent.parent_id,
        profile_name: db_agent.profile_name,
        # Restore model histories from ACE state
        model_histories: ace_state.model_histories,
        # Restore ACE state (context_lessons, model_states)
        context_lessons: ace_state.context_lessons,
        model_states: ace_state.model_states,
        # Restore prompt_fields and re-derive system_prompt from them
        prompt_fields: db_agent.prompt_fields,
        system_prompt: rederive_system_prompt(db_agent.prompt_fields),
        # Restore capability_groups from re-resolved profile (not persisted in config)
        capability_groups: profile_data[:capability_groups] || [],
        # Restore max_refinement_rounds from re-resolved profile (not persisted in config)
        max_refinement_rounds: profile_data[:max_refinement_rounds] || 4,
        # Set restoration_mode flag
        restoration_mode: true
      }

      # Merge with base config (restoration_config takes precedence)
      config = Map.merge(base_config, restoration_config)

      # Handle parent_pid override
      config =
        case Keyword.get(opts, :parent_pid_override) do
          nil ->
            # No override - use nil (orphan agent)
            Map.put(config, :parent_pid, nil)

          parent_pid ->
            # Override provided - use it
            Map.put(config, :parent_pid, parent_pid)
        end

      # Extract sandbox_owner from opts for test isolation
      # (sandbox_owner is needed in config so build_child_spec can pass it to Core)
      # Also set test_mode: true when sandbox_owner present to avoid DB queries for model_pool
      config =
        case Keyword.get(opts, :sandbox_owner) do
          nil ->
            config

          sandbox_owner ->
            config
            |> Map.put(:sandbox_owner, sandbox_owner)
            |> Map.put(:test_mode, true)
        end

      # Pass through registry and pubsub from opts
      start_agent(dynsup_pid, config, opts)
    end
  end

  defp validate_config(%{agent_id: _}), do: :ok
  defp validate_config(_), do: {:error, :invalid_config}

  # Validate config from database is a map (empty maps are valid)
  # Agent configs persist [:test_mode, :initial_prompt, :model_pool] fields
  defp validate_restore_config(config) when is_map(config), do: :ok
  defp validate_restore_config(_), do: {:error, :invalid_restore_config}

  # Enforces use of test helpers to prevent orphaned processes
  # Scans stack to find if called from an unapproved test module without production code in between
  defp enforce_test_helper_usage do
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

    # Skip the first two frames: enforce_test_helper_usage and start_agent
    # Then scan stack to find the first non-anonymous module
    violating_test_module =
      stack
      |> Enum.drop(2)
      |> Enum.reduce_while(nil, fn
        {module, _function, _arity, _location}, _acc when is_atom(module) ->
          module_str = to_string(module)

          # Skip anonymous functions
          if String.starts_with?(module_str, "Elixir.") do
            # Check if it's a test module (must check this first!)
            is_test_module = String.ends_with?(module_str, "Test")

            # Check if it's production code (actions, tasks, etc.) - BUT NOT test modules
            is_production =
              not is_test_module and
                (String.starts_with?(module_str, "Elixir.Quoracle.Actions.") or
                   String.starts_with?(module_str, "Elixir.Quoracle.Tasks.") or
                   String.contains?(module_str, "Live"))

            # Approved test helpers (check both atom and string forms)
            is_approved =
              module == Test.AgentTestHelpers or
                module == Test.IsolationHelpers or
                String.ends_with?(module_str, ".AgentTestHelpers") or
                String.ends_with?(module_str, ".IsolationHelpers") or
                String.ends_with?(module_str, "DynSupTest") or
                String.ends_with?(module_str, "DynSupPubSubTest") or
                String.ends_with?(module_str, "DynSupRefactorTest") or
                String.ends_with?(module_str, "DynSupRestoreTest")

            cond do
              # If we hit production code or approved caller first, stop - it's legitimate
              is_production or is_approved -> {:halt, nil}
              # If we hit an unapproved test module, flag it and stop
              is_test_module -> {:halt, module}
              # Otherwise keep looking
              true -> {:cont, nil}
            end
          else
            {:cont, nil}
          end

        _, acc ->
          {:cont, acc}
      end)

    if violating_test_module do
      raise """
      DynSup.start_agent called directly from test module: #{inspect(violating_test_module)}

      This causes orphaned processes and DB connection leaks (Postgrex "owner exited" errors).

      REQUIRED: Use spawn_agent_with_cleanup/3 instead:

        # In setup or test:
        import Test.AgentTestHelpers

        {:ok, pid} = spawn_agent_with_cleanup(dynsup, config, registry: registry)

      This helper ensures proper cleanup with tree termination (Core + Router + children).

      Why this matters:
      - Agents without cleanup hold DB connections after test completes
      - Causes Postgrex "owner exited while client was still running" errors
      - Creates race conditions between parallel tests
      - Leads to non-deterministic test failures

      See test/support/agent_test_helpers.ex for usage examples.
      """
    end
  end

  # Re-resolve profile to get capability_groups (not persisted in config JSONB)
  # Returns empty map if profile_name is nil or profile not found
  defp resolve_profile_for_restore(nil), do: %{}

  defp resolve_profile_for_restore(profile_name) do
    case Quoracle.Profiles.Resolver.resolve(profile_name) do
      {:ok, profile_data} -> profile_data
      {:error, :profile_not_found} -> %{}
    end
  end

  @spec rederive_system_prompt(map() | nil) :: String.t() | nil
  defp rederive_system_prompt(nil), do: nil
  defp rederive_system_prompt(prompt_fields) when prompt_fields == %{}, do: nil

  defp rederive_system_prompt(prompt_fields) do
    # prompt_fields from JSONB has string keys, but build_prompts_from_fields expects atoms
    atomized = atomize_prompt_fields(prompt_fields)

    {system_prompt, _user_prompt} =
      Quoracle.Fields.PromptFieldManager.build_prompts_from_fields(atomized)

    system_prompt
  end

  defp atomize_prompt_fields(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      {key, atomize_prompt_fields(v)}
    end)
  end

  defp atomize_prompt_fields(list) when is_list(list),
    do: Enum.map(list, &atomize_prompt_fields/1)

  defp atomize_prompt_fields(value), do: value

  # Known config keys that are persisted with atom keys but come back as strings from JSONB.
  # Keys that should be atomized when restoring from DB (all are internal, controlled values).
  #
  # NOTE: force_init_error is test infrastructure — used by tests to simulate agent init
  # failures (e.g., R11/R13 in task_restorer_test, dyn_sup_test). It flows through
  # ConfigManager → Initialization → config_builder and must be atomized here because
  # tests insert DB records with string-keyed JSONB configs containing this flag.
  # Removal would require a test-only config overlay pattern across 6+ modules.
  @config_keys ~w(test_mode initial_prompt model_pool profile_description capability_groups force_init_error)

  defp atomize_config_keys(nil), do: %{}

  defp atomize_config_keys(config) when is_map(config) do
    Enum.reduce(config, %{}, fn {key, value}, acc ->
      atom_key =
        cond do
          is_atom(key) -> key
          is_binary(key) and key in @config_keys -> String.to_atom(key)
          true -> key
        end

      Map.put(acc, atom_key, value)
    end)
  end

  defp build_child_spec(config, opts) do
    # Extract all injected dependencies to pass to Core.start_link (required - no defaults)
    registry = Keyword.fetch!(opts, :registry)
    dynsup = Keyword.get(opts, :dynsup)
    pubsub = Keyword.fetch!(opts, :pubsub)
    # Extract sandbox_owner from config (not opts) - it comes via agent config map
    sandbox_owner = Map.get(config, :sandbox_owner)

    # Build options list for Core, only including non-nil values
    core_opts = []
    core_opts = if registry, do: [{:registry, registry} | core_opts], else: core_opts
    core_opts = if dynsup, do: [{:dynsup, dynsup} | core_opts], else: core_opts
    core_opts = if pubsub, do: [{:pubsub, pubsub} | core_opts], else: core_opts

    core_opts =
      if sandbox_owner, do: [{:sandbox_owner, sandbox_owner} | core_opts], else: core_opts

    %{
      id: {:agent, config.agent_id, Map.get(config, :parent_pid, :no_parent)},
      start: {Quoracle.Agent.Core, :start_link, [config, core_opts]},
      restart: Map.get(config, :restart, :transient),
      shutdown: :infinity,
      type: :worker
    }
  end
end
