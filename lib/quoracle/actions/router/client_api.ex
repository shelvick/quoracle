defmodule Quoracle.Actions.Router.ClientAPI do
  @moduledoc """
  Client-facing API for action execution with validation, secret resolution,
  and result broadcasting.

  Handles the complete action execution flow:
  - Parameter validation and normalization
  - Secret resolution and audit logging
  - Action module lookup
  - Metrics tracking
  - Smart mode threshold determination
  - Result broadcasting (success/error/async)
  """

  require Logger
  alias Quoracle.Actions.{Schema, Validator, Router.ActionMapper, Router.Security}
  alias Quoracle.Budget.Enforcer
  alias Quoracle.Profiles.ActionGate
  alias Quoracle.PubSub.AgentEvents
  alias Quoracle.Audit.SecretUsage

  @default_smart_threshold 100

  # Actions that should always execute synchronously (no smart mode)
  # These are "instant" operations that complete in milliseconds with no async semantics
  # For wait parameter semantics, see AGENT_ConsensusHandler.md section 24
  # NOTE: :execute_shell is NOT here - Shell has its own smart mode internally
  @always_sync_actions [
    :spawn_child,
    :send_message,
    :orient,
    :wait,
    :todo,
    :generate_secret,
    :adjust_budget,
    # Skill actions - file I/O, no external APIs
    :learn_skills,
    :create_skill,
    # Fast local operations - no reason for async
    :search_secrets,
    :file_read,
    :file_write,
    # Batch execution - sequential sync actions
    :batch_sync
    # NOTE: batch_async is NOT here - wait:true must trigger consensus after completion
  ]

  @doc "Returns list of always-sync actions for use by other modules."
  @spec always_sync_actions() :: [atom()]
  def always_sync_actions, do: @always_sync_actions

  @doc """
  Execute action through router instance with full validation and secret resolution.

  ## Parameters
    * `router` - GenServer reference to the Router instance
    * `action_type` - Action name as atom (e.g., :execute_shell)
    * `params` - Action parameters as map (string or atom keys)
    * `agent_id` - Agent identifier string
    * `opts` - Keyword list options:
      - `:action_id` - Pre-generated action ID (default: generated)
      - `:pubsub` - PubSub instance for test isolation (default: from router state)
      - `:smart_threshold` - Milliseconds threshold for sync/async (default: 100)
      - `:timeout` - Timeout for synchronous actions (default: varies by action)
      - `:sandbox_owner` - Ecto sandbox owner PID for test isolation
      - `:task_id` - Task ID for audit trail

  ## Returns
    * `{:ok, result}` - Synchronous success
    * `{:error, reason}` - Validation or execution error
    * `{:async, reference}` - Async execution reference
  """
  @spec execute(GenServer.server(), atom(), map(), String.t(), keyword()) ::
          {:ok, any()} | {:error, any()} | {:async, reference()} | {:async, reference(), map()}
  def execute(router, action_type, params, agent_id, opts) do
    # Use action_id from opts if provided (by ConsensusHandler), otherwise generate one
    action_id = Keyword.get(opts, :action_id, "action_#{:erlang.unique_integer([:positive])}")

    # Get pubsub from opts (required for test isolation)
    pubsub = Keyword.get_lazy(opts, :pubsub, fn -> GenServer.call(router, :get_pubsub) end)

    # Log the execution attempt (before validation to ensure we always log)
    Logger.info("Executing action #{action_type} for agent #{agent_id}")

    # Broadcast action started
    AgentEvents.broadcast_action_started(agent_id, action_type, action_id, params, pubsub)

    # Budget enforcement: block costly actions when over budget (before validation)
    over_budget = Keyword.get(opts, :over_budget, false)

    if over_budget and Enforcer.costly_action?(action_type, params) do
      error = {:error, :budget_exceeded}
      AgentEvents.broadcast_action_error(agent_id, action_id, error, pubsub)
      error
    else
      execute_with_access_and_autonomy(
        router,
        action_type,
        params,
        agent_id,
        action_id,
        pubsub,
        opts
      )
    end
  end

  # Private helper that checks autonomy for actions
  defp execute_with_access_and_autonomy(
         router,
         action_type,
         params,
         agent_id,
         action_id,
         pubsub,
         opts
       ) do
    # First check if action exists (before autonomy, to preserve :unknown_action errors)
    case Schema.validate_action_type(action_type) do
      {:error, :unknown_action} = error ->
        AgentEvents.broadcast_action_error(agent_id, action_id, error, pubsub)
        error

      {:ok, _} ->
        # Check permission via capability_groups
        permission_check = get_permission_check(opts)

        case ActionGate.check(action_type, permission_check) do
          {:error, :action_not_allowed} = error ->
            AgentEvents.broadcast_action_error(agent_id, action_id, error, pubsub)
            error

          :ok ->
            execute_with_validation(
              router,
              action_type,
              params,
              agent_id,
              action_id,
              pubsub,
              opts
            )
        end
    end
  end

  # Returns capability_groups for permission check
  defp get_permission_check(opts) do
    Keyword.get(opts, :capability_groups, [])
  end

  # Private helper for validation and execution flow
  defp execute_with_validation(router, action_type, params, agent_id, action_id, pubsub, opts) do
    # Validate and normalize params (string keys → atom keys)
    case Validator.validate_params(action_type, params) do
      {:ok, normalized_params} ->
        # Resolve secret templates in normalized parameters
        case Security.resolve_secrets(normalized_params) do
          {:ok, resolved_params, secrets_used} ->
            # Log secret usage for audit trail
            task_id = Keyword.get(opts, :task_id)

            Enum.each(secrets_used, fn {secret_name, _value} ->
              SecretUsage.log_usage(secret_name, agent_id, to_string(action_type), task_id)
            end)

            # Check if action module exists
            case ActionMapper.get_action_module(action_type) do
              {:ok, module} ->
                execute_action_module(
                  router,
                  module,
                  action_type,
                  resolved_params,
                  agent_id,
                  action_id,
                  secrets_used,
                  pubsub,
                  opts
                )

              {:error, :not_implemented} ->
                error = {:error, :action_not_implemented}
                AgentEvents.broadcast_action_error(agent_id, action_id, error, pubsub)
                error
            end
        end

      {:error, reason} ->
        error = {:error, reason}
        AgentEvents.broadcast_action_error(agent_id, action_id, error, pubsub)
        error
    end
  end

  # Private helper to execute the action module after budget check passes
  defp execute_action_module(
         router,
         module,
         action_type,
         resolved_params,
         agent_id,
         action_id,
         secrets_used,
         pubsub,
         opts
       ) do
    smart_threshold = Keyword.get(opts, :smart_threshold, @default_smart_threshold)

    # Force synchronous execution for instant actions
    timeout =
      if action_type in @always_sync_actions do
        Keyword.get(opts, :timeout, 5000)
      else
        Keyword.get(opts, :timeout)
      end

    sandbox_owner = Keyword.get(opts, :sandbox_owner)

    # Emit telemetry start event
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:quoracle, :action, :execute, :start],
      %{system_time: System.system_time()},
      %{action_type: action_type, agent_id: agent_id, action_id: action_id}
    )

    # Delegate to GenServer for smart mode execution - use resolved_params
    result =
      GenServer.call(
        router,
        {:execute, module, resolved_params, agent_id, action_id, smart_threshold, timeout,
         sandbox_owner, secrets_used, opts},
        :infinity
      )

    # Emit telemetry stop event with duration
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:quoracle, :action, :execute, :stop],
      %{duration: duration},
      %{action_type: action_type, agent_id: agent_id, action_id: action_id, result: result}
    )

    # Broadcast result
    case result do
      {:ok, _} = success ->
        AgentEvents.broadcast_action_completed(agent_id, action_id, success, pubsub)

        # Auto-complete TODO if requested (R7: only on success)
        # Note: auto_complete_todo is at response level, passed via opts
        if Keyword.get(opts, :auto_complete_todo) == true do
          agent_pid = Keyword.get(opts, :agent_pid)

          if agent_pid && Process.alive?(agent_pid) do
            GenServer.cast(agent_pid, :mark_first_todo_done)
          end
        end

        success

      {:error, _} = error ->
        AgentEvents.broadcast_action_error(agent_id, action_id, error, pubsub)
        error

      {:async, _} = async ->
        # For async, completion will be broadcast later
        async

      {:async, _ref, _ack} = async_with_ack ->
        # Shell async with acknowledgement - pass through to ActionExecutor
        async_with_ack
    end
  end
end
