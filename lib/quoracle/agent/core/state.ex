defmodule Quoracle.Agent.Core.State do
  @moduledoc """
  Struct definition for Agent.Core GenServer state.

  Implements the Access behaviour to support get_in/put_in/update_in
  for nested field access (e.g., `get_in(state, [:context_lessons, model_id])`).

  Provides compile-time validation and type safety for the 40+ fields
  that comprise agent runtime state. Required fields are enforced with
  @enforce_keys to catch initialization errors at compile time.

  ## Required Fields

  The following fields must be provided when creating a new state:
  - `:agent_id` - Unique agent identifier
  - `:registry` - Registry module/PID for agent lookup
  - `:dynsup` - DynamicSupervisor PID for spawning children
  - `:pubsub` - PubSub module for event broadcasting

  ## Optional Fields

  All other fields have sensible defaults and can be omitted during
  initialization. The struct will populate them with nil or empty
  collections as appropriate.

  ## Field Categories

  - **Identity**: agent_id, parent_pid, parent_id, task_id
  - **OTP Integration**: registry, dynsup, pubsub
  - **Agent Tree**: children, parent_pid, parent_id
  - **Conversation**: model_histories, messages, pending_actions
  - **Timing**: wait_timer, timer_generation, action_counter
  - **Context Management**: context_summary, context_limit, context_limits_loaded
  - **ACE Context**: context_lessons, model_states
  - **Prompts**: prompt_fields, system_prompt
  - **Configuration**: model_id, models, temperature, max_tokens, timeout, max_depth, config
  - **State Management**: state, waiting_for_ready, restoration_mode
  - **Testing**: test_mode, test_opts, sandbox_owner, test_pid, skip_auto_consensus
  - **Tasks**: task_id, task, todos
  """

  @enforce_keys [
    :agent_id,
    :registry,
    :dynsup,
    :pubsub
  ]

  # Derive Jason.Encoder but exclude non-serializable fields (PIDs, refs, functions)
  # and environment-specific dependencies (registry, dynsup, pubsub)
  @derive {Jason.Encoder,
           except: [
             :parent_pid,
             :dynsup,
             :registry,
             :pubsub,
             :wait_timer,
             :sandbox_owner,
             :test_pid,
             :waiting_for_ready,
             :children,
             :pending_actions,
             :messages,
             :mcp_client,
             :spawn_complete_notify
           ]}

  defstruct [
    # Required fields
    :agent_id,
    :registry,
    :dynsup,
    :pubsub,
    # Identity and hierarchy
    :parent_pid,
    :parent_id,
    :task_id,
    :task,
    # Agent tree
    children: [],
    # Conversation and actions (per-model histories for consensus)
    model_histories: %{},
    messages: [],
    pending_actions: %{},
    # Timing and synchronization
    wait_timer: nil,
    timer_generation: 0,
    action_counter: 0,
    # State management
    state: :initializing,
    waiting_for_ready: [],
    restoration_mode: false,
    # Context management
    context_summary: nil,
    context_limit: 4000,
    context_limits_loaded: false,
    additional_context: [],
    # ACE Context Management (v15.0)
    context_lessons: %{},
    model_states: %{},
    # Prompt system
    prompt_fields: nil,
    system_prompt: nil,
    governance_rules: nil,
    governance_config: nil,
    grove_hard_rules: nil,
    grove_confinement: nil,
    grove_confinement_mode: nil,
    grove_topology: nil,
    grove_path: nil,
    grove_skills_path: nil,
    grove_schemas: nil,
    grove_workspace: nil,
    # MCP integration
    mcp_client: nil,
    # Model configuration
    model_id: nil,
    models: [],
    # NOTE: nil default allows test_mode fallback to mock models in ConsensusHandler
    model_pool: nil,
    temperature: nil,
    max_tokens: nil,
    timeout: nil,
    max_depth: nil,
    config: nil,
    # Task management
    todos: [],
    # Testing support
    test_mode: false,
    simulate_failure: false,
    force_condense: false,
    skip_consensus: false,
    test_opts: [],
    sandbox_owner: nil,
    test_pid: nil,
    skip_auto_consensus: false,
    # Test synchronization for async spawn completion (fires after budget escrow)
    spawn_complete_notify: nil,
    # Dismiss child race prevention (v19.0)
    dismissing: false,
    # Budget system (v4.0)
    budget_data: nil,
    # Budget system v22.0: Over budget tracking
    over_budget: false,
    # Message queueing during action execution (v12.0)
    queued_messages: [],
    # v28.0: Deferred consensus flag for event batching
    consensus_scheduled: false,
    # v32.0: Consecutive consensus failure counter for retry logic
    consensus_retry_count: 0,
    # Profile fields (v24.0)
    profile_name: nil,
    profile_description: nil,
    max_refinement_rounds: 4,
    # v39.0: Force reflection for single-model profiles
    force_reflection: false,
    # v26.0: Capability groups for profile-based action filtering
    capability_groups: [],
    # v27.0: Skills system - active skill metadata (no content)
    active_skills: [],
    # v30.0: Per-action Router lifecycle tracking
    # active_routers: monitor_ref => router_pid (all spawned Routers)
    active_routers: %{},
    # shell_routers: command_id => router_pid (shell command Routers for status routing)
    shell_routers: %{},
    # v38.0: Cached system prompt for consensus (lazy build, invalidated by learn_skills)
    cached_system_prompt: nil,
    # v43.0: Per-model correction feedback for consensus retry injection
    correction_feedback: %{}
  ]

  @type t :: %__MODULE__{
          # Required fields
          agent_id: String.t(),
          registry: atom() | pid(),
          dynsup: pid(),
          pubsub: atom(),
          # Identity and hierarchy
          parent_pid: pid() | nil,
          parent_id: String.t() | nil,
          task_id: integer() | nil,
          task: String.t() | nil,
          # Agent tree
          children: [%{agent_id: String.t(), spawned_at: DateTime.t()}],
          # Conversation and actions (per-model histories for consensus)
          model_histories: %{String.t() => [history_entry()]},
          messages: [any()],
          pending_actions: %{String.t() => action()},
          # Timing and synchronization
          wait_timer: wait_timer() | nil,
          timer_generation: non_neg_integer(),
          action_counter: non_neg_integer(),
          # State management
          state: :initializing | :ready | atom(),
          waiting_for_ready: [GenServer.from()],
          restoration_mode: boolean(),
          # Context management
          context_summary: String.t() | nil,
          context_limit: pos_integer(),
          context_limits_loaded: boolean(),
          additional_context: [any()],
          # ACE Context Management (v15.0)
          context_lessons: %{String.t() => [lesson()]},
          model_states: %{String.t() => state_entry() | nil},
          # Prompt system
          prompt_fields: map() | nil,
          system_prompt: String.t() | nil,
          governance_rules: String.t() | nil,
          governance_config: [map()] | nil,
          grove_hard_rules: [map()] | nil,
          grove_confinement: map() | nil,
          grove_confinement_mode: String.t() | nil,
          grove_topology: map() | nil,
          grove_path: String.t() | nil,
          grove_skills_path: String.t() | nil,
          grove_schemas: [map()] | nil,
          grove_workspace: String.t() | nil,
          # MCP integration
          mcp_client: pid() | nil,
          # Model configuration
          model_id: String.t() | nil,
          models: [String.t()],
          model_pool: [String.t()] | nil,
          temperature: float() | nil,
          max_tokens: integer() | nil,
          timeout: integer() | nil,
          max_depth: integer() | nil,
          config: map() | nil,
          # Task management
          todos: [map()],
          # Testing support
          test_mode: boolean(),
          simulate_failure: boolean(),
          test_opts: keyword(),
          sandbox_owner: pid() | nil,
          test_pid: pid() | nil,
          skip_auto_consensus: boolean(),
          # Test synchronization for async spawn completion
          spawn_complete_notify: pid() | nil,
          # Dismiss child race prevention (v19.0)
          dismissing: boolean(),
          # Budget system (v4.0)
          budget_data: budget_data() | nil,
          # Budget system v22.0: Over budget tracking
          over_budget: boolean(),
          # Message queueing during action execution (v12.0)
          queued_messages: [queued_message()],
          # v28.0: Deferred consensus flag for event batching
          consensus_scheduled: boolean(),
          consensus_retry_count: non_neg_integer(),
          # Profile fields (v24.0)
          profile_name: String.t() | nil,
          profile_description: String.t() | nil,
          max_refinement_rounds: integer(),
          # v39.0: Force reflection for single-model profiles
          force_reflection: boolean(),
          # v26.0: Capability groups for profile-based action filtering
          capability_groups: [atom()],
          # v27.0: Skills system
          active_skills: [skill_metadata()],
          # v30.0: Per-action Router lifecycle
          active_routers: %{reference() => pid()},
          shell_routers: %{String.t() => pid()},
          # v38.0: Cached system prompt
          cached_system_prompt: String.t() | nil,
          # v43.0: Per-model correction feedback
          correction_feedback: %{String.t() => String.t()}
        }

  @type queued_message :: %{
          sender_id: atom() | String.t(),
          content: String.t(),
          queued_at: DateTime.t()
        }

  @type history_entry :: %{
          type: atom(),
          content: any(),
          timestamp: DateTime.t(),
          action_type: atom() | nil
        }
  @type action :: %{type: atom(), params: map(), timestamp: DateTime.t()}
  @type wait_timer :: {reference(), String.t(), non_neg_integer()}

  # Budget system types (v4.0)
  @type budget_data :: %{
          mode: :root | :allocated | :na,
          allocated: Decimal.t() | nil,
          committed: Decimal.t() | nil
        }

  # ACE Context Management types (v15.0)
  @type lesson :: %{
          type: :factual | :behavioral,
          content: String.t(),
          confidence: pos_integer()
        }
  @type state_entry :: %{
          summary: String.t(),
          updated_at: DateTime.t()
        }

  # Skills system types (v27.0)
  @type skill_metadata :: %{
          name: String.t(),
          permanent: boolean(),
          loaded_at: DateTime.t(),
          description: String.t(),
          path: String.t(),
          metadata: map()
        }

  # ============================================================================
  # Access behaviour implementation
  # ============================================================================
  # Enables get_in/put_in/update_in for nested access like:
  #   get_in(state, [:context_lessons, model_id])
  #   put_in(state, [:model_histories, model_id], history)

  @behaviour Access

  @impl Access
  def fetch(%__MODULE__{} = state, key) do
    Map.fetch(Map.from_struct(state), key)
  end

  @impl Access
  def get_and_update(%__MODULE__{} = state, key, fun) do
    map = Map.from_struct(state)

    case Map.fetch(map, key) do
      {:ok, current_value} ->
        case fun.(current_value) do
          {get_value, update_value} ->
            {get_value, struct!(__MODULE__, Map.put(map, key, update_value))}

          :pop ->
            {current_value, struct!(__MODULE__, Map.put(map, key, nil))}
        end

      :error ->
        case fun.(nil) do
          {get_value, update_value} ->
            {get_value, struct!(__MODULE__, Map.put(map, key, update_value))}

          :pop ->
            {nil, state}
        end
    end
  end

  @impl Access
  def pop(%__MODULE__{} = state, key) do
    map = Map.from_struct(state)
    {Map.get(map, key), struct!(__MODULE__, Map.put(map, key, nil))}
  end

  @doc """
  Creates a new Core state struct from a configuration map.

  Extracts required fields and validates they are present, then
  populates all optional fields with defaults or values from config.

  ## Examples

      iex> State.new(%{
      ...>   agent_id: "agent-1",
      ...>   registry: MyRegistry,
      ...>   dynsup: self(),
      ...>   pubsub: MyPubSub
      ...> })
      %State{agent_id: "agent-1", ...}

  """
  @spec new(map()) :: t()
  def new(config) when is_map(config) do
    %__MODULE__{
      # Required fields
      agent_id: Map.fetch!(config, :agent_id),
      registry: Map.fetch!(config, :registry),
      dynsup: Map.fetch!(config, :dynsup),
      pubsub: Map.fetch!(config, :pubsub),
      # Optional fields with defaults or config values
      parent_pid: Map.get(config, :parent_pid),
      parent_id: Map.get(config, :parent_id),
      task_id: Map.get(config, :task_id),
      task: Map.get(config, :task),
      children: Map.get(config, :children, []),
      model_histories: init_per_model_map(config, :model_histories, []),
      messages: Map.get(config, :messages, []),
      pending_actions: Map.get(config, :pending_actions, %{}),
      wait_timer: Map.get(config, :wait_timer),
      timer_generation: Map.get(config, :timer_generation, 0),
      action_counter: Map.get(config, :action_counter, 0),
      state: Map.get(config, :state, :initializing),
      waiting_for_ready: Map.get(config, :waiting_for_ready, []),
      restoration_mode: Map.get(config, :restoration_mode, false),
      context_summary: Map.get(config, :context_summary),
      context_limit: Map.get(config, :context_limit, 4000),
      context_limits_loaded: Map.get(config, :context_limits_loaded, false),
      additional_context: Map.get(config, :additional_context, []),
      # ACE Context Management (v15.0)
      # Initialize per-model if models provided, otherwise use config or empty
      context_lessons: init_per_model_map(config, :context_lessons, []),
      model_states: init_per_model_map(config, :model_states, nil),
      prompt_fields: Map.get(config, :prompt_fields),
      system_prompt: Map.get(config, :system_prompt),
      governance_rules: Map.get(config, :governance_rules),
      governance_config: Map.get(config, :governance_config),
      grove_hard_rules: Map.get(config, :grove_hard_rules),
      grove_confinement: Map.get(config, :grove_confinement),
      grove_confinement_mode: Map.get(config, :grove_confinement_mode),
      grove_topology: Map.get(config, :grove_topology),
      grove_path: Map.get(config, :grove_path),
      grove_skills_path: Map.get(config, :grove_skills_path),
      grove_schemas: Map.get(config, :grove_schemas),
      grove_workspace: Map.get(config, :grove_workspace),
      mcp_client: Map.get(config, :mcp_client),
      model_id: Map.get(config, :model_id),
      models: Map.get(config, :models, []),
      temperature: Map.get(config, :temperature),
      max_tokens: Map.get(config, :max_tokens),
      timeout: Map.get(config, :timeout),
      max_depth: Map.get(config, :max_depth),
      config: Map.get(config, :config),
      todos: Map.get(config, :todos, []),
      test_mode: Map.get(config, :test_mode, false),
      simulate_failure: Map.get(config, :simulate_failure, false),
      force_condense: Map.get(config, :force_condense, false),
      skip_consensus: Map.get(config, :skip_consensus, false),
      test_opts: Map.get(config, :test_opts, []),
      sandbox_owner: Map.get(config, :sandbox_owner),
      test_pid: Map.get(config, :test_pid),
      skip_auto_consensus: Map.get(config, :skip_auto_consensus, false),
      # Test synchronization for async spawn completion
      spawn_complete_notify: Map.get(config, :spawn_complete_notify),
      # Dismiss child race prevention (v19.0)
      dismissing: Map.get(config, :dismissing, false),
      # Budget system (v4.0)
      budget_data: init_budget_data(config),
      # Budget system v22.0: Over budget tracking
      over_budget: Map.get(config, :over_budget, false),
      # Message queueing during action execution (v12.0)
      queued_messages: Map.get(config, :queued_messages, []),
      # v28.0: Deferred consensus flag for event batching
      consensus_scheduled: Map.get(config, :consensus_scheduled, false),
      # Profile fields (v24.0)
      profile_name: Map.get(config, :profile_name),
      profile_description: Map.get(config, :profile_description),
      max_refinement_rounds: Map.get(config, :max_refinement_rounds, 4),
      # v39.0: Force reflection for single-model profiles
      force_reflection: Map.get(config, :force_reflection, false),
      # model_pool from profile - nil allows test_mode fallback in ConsensusHandler
      model_pool: Map.get(config, :model_pool),
      # v26.0: Capability groups for profile-based action filtering
      capability_groups: Map.get(config, :capability_groups, []),
      # v27.0: Skills system
      active_skills: Map.get(config, :active_skills, []),
      # v30.0: Per-action Router lifecycle
      active_routers: Map.get(config, :active_routers, %{}),
      shell_routers: Map.get(config, :shell_routers, %{}),
      # v38.0: Cached system prompt
      cached_system_prompt: Map.get(config, :cached_system_prompt),
      # v43.0: Per-model correction feedback
      correction_feedback: Map.get(config, :correction_feedback, %{})
    }
  end

  # Initialize budget_data from config or default to N/A (v22.0)
  defp init_budget_data(config) do
    case Map.get(config, :budget_data) do
      nil ->
        # Default to N/A budget mode
        %{mode: :na, allocated: nil, committed: Decimal.new(0)}

      budget_data ->
        budget_data
    end
  end

  # Initialize a per-model map from config, falling back to model pool with a default value.
  # Used for context_lessons (default []), model_states (default nil), model_histories (default []).
  defp init_per_model_map(config, key, default) do
    case Map.get(config, key) do
      nil -> Map.new(Map.get(config, :models, []), fn model_id -> {model_id, default} end)
      value -> value
    end
  end
end
