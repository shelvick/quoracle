defmodule Quoracle.Agent.Core.Initialization do
  @moduledoc """
  Handles Core agent initialization and setup.

  Extracted from Core to maintain <500 line module size requirement.
  """

  require Logger
  alias Quoracle.PubSub.AgentEvents
  alias Quoracle.Agent.{ConfigManager, Core.Persistence, Core.State}

  @doc """
  Initialize agent state from config and options.

  Handles both map and tuple config formats, sets up dependency injection,
  and defers DB setup to handle_continue to prevent race conditions.

  Returns a Core.State struct for compile-time validation.
  """
  @spec init({map() | {pid(), String.t()} | {pid(), String.t(), keyword()}, keyword()}) ::
          {:ok, State.t(), {:continue, :complete_db_setup}}
          | {:stop, :forced_init_error | {:already_started, String.t()}}
  def init({config, opts}) do
    # Handle new format with dependency injection options
    normalized = ConfigManager.normalize_config(config)

    # Test infrastructure: force_init_error allows tests to simulate agent init failures
    # without requiring invalid config. Used by task_restorer_test (R11/R13), dyn_sup_test.
    if normalized[:force_init_error] do
      {:stop, :forced_init_error}
    else
      # Sandbox setup moved to handle_continue to prevent race conditions

      # Trap exits so terminate/2 runs for proper Router cleanup.
      # Without this, Core dies instantly on EXIT signals, bypassing terminate/2,
      # causing Postgrex "owner exited" errors if Router was mid-DB-operation.
      Process.flag(:trap_exit, true)

      try do
        # The normalized config has pubsub extracted from the original test opts
        # We need to make sure it gets passed to setup_agent via opts
        merged_opts =
          if normalized[:pubsub] do
            Keyword.put(opts, :pubsub, normalized[:pubsub])
          else
            opts
          end

        # Pass options to setup_agent for dependency injection
        state = ConfigManager.setup_agent(normalized, merged_opts)

        {:ok, state, {:continue, :complete_db_setup}}
      catch
        {:duplicate_agent_id, agent_id} ->
          # Another agent already has this ID - stop this one
          {:stop, {:already_started, agent_id}}
      end
    end
  end

  @doc """
  Complete database setup after init.

  Establishes sandbox connection for tests, auto-detects restarts by checking
  DB for existing agent record, and restores conversation history if found.
  """
  @spec handle_continue_db_setup(State.t()) ::
          {:noreply, State.t(), {:continue, :load_context_limit}}
  def handle_continue_db_setup(state) do
    # Establish sandbox connection FIRST when sandbox_owner is present
    # Core receives sandbox_owner via config map, must call Sandbox.allow to grant DB access
    # CRITICAL: Must happen BEFORE any DB queries (including get_agent check)
    # NOTE: Sandbox access is granted whenever sandbox_owner is present, regardless of test_mode
    # This allows acceptance tests to use test_mode: false (for model_query_fn) while still having DB access
    # Use Map.get for optional fields (works with both structs and maps)
    if Map.get(state, :sandbox_owner) do
      Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, Map.get(state, :sandbox_owner), self())
    end

    # Auto-detect restarts: Check if agent already exists in DB
    # This handles both supervisor restarts (crashes) AND manual restore_agent calls
    # Skip DB check entirely if already in restoration_mode (restore_agent set it explicitly)
    state =
      if Map.get(state, :restoration_mode, false) do
        # Already flagged as restoration - skip DB check
        state
      else
        # Defensive DB check - handle ownership errors gracefully
        try do
          case Quoracle.Tasks.TaskManager.get_agent(state.agent_id) do
            {:ok, db_agent} ->
              # DB record exists - this is a restart or restore
              Logger.info("Agent #{state.agent_id} restarting, restoring state from DB")

              # Restore ACE state (context_lessons, model_states, model_histories) from DB
              ace_state = Persistence.restore_ace_state(db_agent)

              %State{
                state
                | model_histories: ace_state.model_histories,
                  context_lessons: ace_state.context_lessons,
                  model_states: ace_state.model_states,
                  restoration_mode: true
              }

            {:error, :not_found} ->
              # Fresh spawn - persist to DB
              Persistence.persist_agent(state)
              state
          end
        rescue
          e in [DBConnection.OwnershipError, DBConnection.ConnectionError] ->
            # DB not accessible - either no sandbox_owner OR owner exited during query
            # Skip persistence entirely - agent will try again on next operation
            Logger.debug(
              "Skipping DB check for agent #{state.agent_id}: #{inspect(e.__struct__)}"
            )

            state
        end
      end

    {:noreply, state, {:continue, :load_context_limit}}
  end

  @doc """
  Complete context limit loading after DB setup.

  Marks agent as ready immediately without loading context limits (lazy loading).
  Broadcasts ready event via PubSub.
  """
  @spec handle_continue_load_context_limit(State.t()) :: {:noreply, State.t()}
  def handle_continue_load_context_limit(%State{} = state) do
    # Don't load context limits here - do it lazily on first message
    # Just mark agent as ready immediately
    state = %State{state | state: :ready, context_limits_loaded: false}

    # Broadcast that agent is ready (defensive - PubSub might not exist in tests)
    pubsub = state.pubsub

    try do
      AgentEvents.broadcast_log(
        state.agent_id,
        :info,
        "Agent ready",
        %{state: :ready, task_id: state.task_id},
        pubsub
      )

      # Subscribe to cost events for budget tracking (v22.0)
      if pubsub && state.agent_id do
        Phoenix.PubSub.subscribe(pubsub, "agents:#{state.agent_id}:costs")
      end
    rescue
      ArgumentError ->
        # PubSub not running (test cleanup) - skip broadcast
        :ok
    end

    {:noreply, state}
  end
end
