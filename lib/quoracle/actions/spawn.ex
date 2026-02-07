defmodule Quoracle.Actions.Spawn do
  @moduledoc """
  Spawns child agents to handle delegated tasks.

  Enables recursive agent orchestration through parent-child relationships.

  ## Async Spawn Pattern (v5.0)

  Spawn returns immediately with child_id, deferring actual child creation
  to a background task. This eliminates timeout issues caused by LLM
  summarization in the critical path.

  Flow:
  1. Generate child_id upfront
  2. Validate params synchronously (fast)
  3. Spawn background task for actual child creation
  4. Return immediately with child_id
  5. Background task: build config → spawn → send message → broadcast
  6. On failure: notify parent via send_message
  """

  alias Quoracle.Agent.Core
  alias Quoracle.Agent.DynSup
  alias Quoracle.Fields.PromptFieldManager
  alias Quoracle.Profiles.Resolver, as: ProfileResolver
  alias Quoracle.Actions.Spawn.{ConfigBuilder, BudgetValidation, Helpers}
  alias Quoracle.Skills.Loader, as: SkillLoader
  require Logger

  @doc """
  Spawns a child agent with the given task (standard 3-arity signature).

  Parameters:
  - params: Map containing task and optional models (no wrapper)
  - agent_id: Parent agent ID string
  - opts: Keyword list with :agent_pid (parent PID), :registry, :dynsup, :pubsub, etc.

  Returns:
  - {:ok, %{action: String.t(), agent_id: String.t(), pid: pid(), spawned_at: DateTime.t()}}
  - {:error, :invalid_params} for missing/invalid task
  - {:error, :dynsup_not_found} for missing dynsup
  - {:error, :spawn_failed} for spawn failures
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(params, agent_id, opts) when is_binary(agent_id) and is_list(opts) do
    parent_pid = Keyword.get(opts, :agent_pid)
    deps = Enum.into(opts, %{})
    execute(params, agent_id, parent_pid, deps)
  end

  @doc """
  Spawns a child agent with the given task (4-arity signature for backward compatibility).

  ## Async Spawn Pattern (v5.0)

  Returns immediately with child_id, deferring actual child creation to background.
  This eliminates timeout issues caused by LLM summarization in the critical path.

  Parameters:
  - params: Map with task and optional models (may be wrapped in "params" key)
  - agent_id: Parent agent ID string
  - parent_pid: Parent agent PID
  - deps: Map with injected dependencies (:registry, :dynsup, :pubsub, etc.)

  Returns:
  - {:ok, %{action: String.t(), agent_id: String.t(), message: String.t(), spawned_at: DateTime.t()}}
  - {:error, :invalid_params} for missing/invalid task
  - {:error, :dynsup_not_found} for missing dynsup

  Note: Actual spawn failures are reported asynchronously via send_message to parent.
  """
  @spec execute(map(), String.t(), pid(), map()) :: {:ok, map()} | {:error, term()}
  def execute(params, agent_id, parent_pid, deps) when is_binary(agent_id) and is_map(deps) do
    # Check if parent is dismissing children (race prevention with dismiss_child)
    # Use dismissing state from deps if available (passed by Core during action dispatch)
    # This avoids deadlock when called via Core.process_action
    if parent_dismissing?(parent_pid, deps) do
      {:error, :parent_dismissing}
    else
      do_execute(params, agent_id, parent_pid, deps)
    end
  end

  # Check if parent is dismissing - uses deps first to avoid GenServer callback deadlock
  defp parent_dismissing?(parent_pid, deps) do
    # Check deps first (set by Core when dispatching actions)
    case Map.get(deps, :dismissing) do
      true ->
        true

      false ->
        false

      nil ->
        # Fall back to GenServer call for direct execute calls (tests)
        parent_pid && Process.alive?(parent_pid) && safe_dismissing_check(parent_pid)
    end
  end

  # Safely check dismissing state (handles non-Core pids gracefully)
  defp safe_dismissing_check(parent_pid) do
    try do
      Core.dismissing?(parent_pid)
    catch
      :exit, _ -> false
    end
  end

  # Actual spawn implementation after dismissing check passes
  defp do_execute(params, agent_id, parent_pid, deps) do
    # v5.0: Generate child_id UPFRONT (before any async work)
    child_id = generate_child_id()

    # Normalize params (unwrap if wrapped, convert string keys to atoms)
    normalized_params = normalize_params(params)

    # Validate params synchronously (fast, no LLM calls)
    with {:ok, profile_data} <- resolve_profile(normalized_params),
         {:ok, skills_metadata} <- resolve_skills(normalized_params, deps),
         {:ok, task_result} <- extract_task(normalized_params),
         {:ok, dynsup} <- ConfigBuilder.get_dynsup(deps),
         {:ok, budget_result} <-
           BudgetValidation.validate_and_check_budget(normalized_params, deps) do
      # Add profile data and skills to params for ConfigBuilder
      merged_params = Map.put(normalized_params, :_profile_data, profile_data)
      merged_params = Map.put(merged_params, :_skills_metadata, skills_metadata)
      {:field_based, _task_string} = task_result

      # Spawn background task for actual child creation
      spawn_child_async(
        child_id,
        task_result,
        merged_params,
        agent_id,
        parent_pid,
        deps,
        dynsup,
        budget_result
      )

      # Return IMMEDIATELY with child_id (no pid yet - spawning in background)
      {:ok,
       %{
         action: "spawn",
         agent_id: child_id,
         spawned_at: DateTime.utc_now()
       }}
    end
  end

  # Truncate string for display
  defp truncate(str, max_len) when byte_size(str) <= max_len, do: str
  defp truncate(str, max_len), do: String.slice(str, 0, max_len - 3) <> "..."

  # v5.0: Spawn background task for actual child creation
  defp spawn_child_async(
         child_id,
         task_result,
         merged_params,
         parent_id,
         parent_pid,
         deps,
         dynsup,
         budget_result
       ) do
    # Get task supervisor - use injected one for tests or global for production
    task_sup = Map.get(deps, :task_supervisor, Quoracle.SpawnTaskSupervisor)

    # Pass sandbox_owner for test DB access
    sandbox_owner = Map.get(deps, :sandbox_owner)

    Task.Supervisor.start_child(task_sup, fn ->
      # Allow sandbox access in background task (for tests)
      if sandbox_owner do
        Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, sandbox_owner, self())
      end

      # Extract task_string for error reporting (task_result already validated)
      {:field_based, task_string} = task_result

      try do
        do_spawn_child(
          child_id,
          task_result,
          merged_params,
          parent_id,
          parent_pid,
          deps,
          dynsup,
          budget_result
        )
      catch
        kind, payload ->
          # Catch exceptions AND :exit signals (e.g., GenServer.call timeout in
          # Core.get_state). try/rescue only catches exceptions, missing :exit
          # which silently killed the background Task before the UI broadcast.
          message =
            case kind do
              :error when is_exception(payload) -> Exception.message(payload)
              :error -> inspect(payload)
              :exit -> inspect(payload)
              :throw -> inspect(payload)
            end

          reason = {:spawn_crashed, message}
          notify_parent_spawn_failed(parent_pid, child_id, reason, task_string, deps)

          # Also notify test process if waiting
          if notify_pid = Map.get(deps, :spawn_complete_notify) do
            send(notify_pid, {:spawn_complete, child_id, {:error, reason}})
          end

          {:error, reason}
      end
    end)
  end

  # Background task: build config → spawn → send message → broadcast
  defp do_spawn_child(
         child_id,
         task_result,
         merged_params,
         parent_id,
         parent_pid,
         deps,
         dynsup,
         budget_result
       ) do
    {:field_based, task_string} = task_result

    # Build config with pre-generated child_id (always succeeds per @spec)
    {:ok, config} =
      ConfigBuilder.build_config(
        task_result,
        merged_params,
        parent_id,
        parent_pid,
        deps,
        child_id
      )

    # Add budget_data to child config
    config = Map.put(config, :budget_data, budget_result.child_budget_data)

    result =
      case spawn_with_retry(config, deps, dynsup) do
        {:ok, child_pid} ->
          # Broadcast FIRST so UI updates immediately, before any blocking calls.
          # Core.get_state has a 5s timeout that can cause :exit signals if the
          # child's handle_continue is slow, which previously killed this Task
          # before the broadcast was reached.
          if deps[:pubsub] do
            Quoracle.PubSub.AgentEvents.broadcast_agent_spawned(
              child_id,
              Map.get(config, :task_id, child_id),
              parent_id,
              task_string,
              deps[:pubsub],
              Map.get(config, :budget_data)
            )
          end

          # Wait for agent setup to complete (handle_continue:setup does DB work)
          # GenServer.call blocks until all pending handle_continue callbacks finish
          # Skip for mock dynsup functions (tests that don't create real agents)
          unless is_function(dynsup) do
            {:ok, _state} = Core.get_state(child_pid)

            # Trigger initial consensus (matches root agent pattern in event_handlers.ex:54)
            # send_user_message skips adding to history when content matches task_description
            Core.send_user_message(child_pid, task_string)
          end

          # Notify parent to track child (idempotent - ChildrenTracker deduplicates)
          # ActionExecutor also adds child immediately; this handles direct Spawn.execute calls
          if is_pid(parent_pid) and Process.alive?(parent_pid) do
            GenServer.cast(
              parent_pid,
              {:child_spawned,
               %{
                 agent_id: child_id,
                 spawned_at: DateTime.utc_now()
               }}
            )

            # Update parent's committed budget (escrow) if child has allocated budget
            if budget_result.escrow_amount do
              Core.update_budget_committed(parent_pid, budget_result.escrow_amount)
            end
          end

          {:ok, child_pid}

        {:error, reason} ->
          notify_parent_spawn_failed(parent_pid, child_id, reason, task_string, deps)
          {:error, reason}
      end

    # Notify test process of completion (for test synchronization)
    if notify_pid = Map.get(deps, :spawn_complete_notify) do
      send(notify_pid, {:spawn_complete, child_id, result})
    end

    result
  end

  # Notify parent of spawn failure via send_message
  defp notify_parent_spawn_failed(parent_pid, child_id, reason, task_string, _deps) do
    failure_message =
      "Spawn failed for child #{child_id}: #{inspect(reason)}. Task was: #{truncate(task_string, 100)}"

    # Send message to parent if alive (use is_pid guard for nil safety)
    if is_pid(parent_pid) and Process.alive?(parent_pid) do
      # Use direct message for immediate notification
      send(parent_pid, {:spawn_failed, %{child_id: child_id, reason: reason, task: task_string}})
    end

    Logger.warning("Background spawn failed: #{failure_message}")
    {:error, reason}
  end

  # Private functions

  # v14.0: Resolve profile from params (required parameter)
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

  # v15.0: Resolve skills via Loader - converts skill names to metadata
  defp resolve_skills(params, deps) do
    skill_names = Map.get(params, :skills) || Map.get(params, "skills") || []

    if skill_names == [] do
      {:ok, []}
    else
      opts = if deps[:skills_path], do: [skills_path: deps[:skills_path]], else: []

      # Load each skill and convert to active_skills metadata format
      results =
        Enum.map(skill_names, fn name ->
          case SkillLoader.load_skill(name, opts) do
            {:ok, skill} ->
              # Convert to active_skills metadata (no content in state)
              {:ok,
               %{
                 name: skill.name,
                 permanent: true,
                 loaded_at: DateTime.utc_now(),
                 description: skill.description,
                 path: skill.path,
                 metadata: skill.metadata
               }}

            {:error, :not_found} ->
              {:error, {:skill_not_found, name}}

            {:error, reason} ->
              {:error, reason}
          end
        end)

      # Check for first error
      case Enum.find(results, &match?({:error, _}, &1)) do
        nil ->
          {:ok, Enum.map(results, fn {:ok, meta} -> meta end)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Normalize params: unwrap if wrapped, convert string keys to atoms
  defp normalize_params(params) do
    # Unwrap params if wrapped
    actual_params =
      case Map.get(params, "params") do
        nil -> params
        wrapped -> wrapped
      end

    # Normalize params: Convert all string keys to atom keys
    normalize_field_keys(actual_params)
  end

  defp extract_task(params) do
    # Params are already normalized at this point
    # Just validate and extract fields
    case PromptFieldManager.extract_fields_from_params(params) do
      {:ok, _fields} ->
        task_desc = Map.get(params, :task_description)
        {:ok, {:field_based, task_desc}}

      error ->
        error
    end
  end

  # Delegate to extracted module (keeps Spawn under 500 lines)
  @doc false
  defdelegate normalize_field_keys(params), to: Helpers

  @doc false
  defdelegate generate_child_id(), to: Helpers

  defp spawn_with_retry(config, deps, dynsup), do: spawn_with_retry(config, deps, dynsup, 0, nil)

  defp spawn_with_retry(config, deps, dynsup, attempt, _last_error) when attempt < 3 do
    case spawn_child(config, deps, dynsup) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} when reason in [:persistent_error, :spawn_failed] ->
        {:error, reason}

      {:error, reason} when attempt < 2 ->
        receive after: ((attempt + 1) * 100 -> :ok)
        spawn_with_retry(config, deps, dynsup, attempt + 1, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp spawn_with_retry(_config, _deps, _dynsup, _attempt, last_error) do
    {:error, last_error || :spawn_failed}
  end

  defp spawn_child(config, _deps, dynsup) when is_function(dynsup) do
    # Test mock function - pass through the exact result for tests
    case dynsup.(self(), config, []) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:error, {:already_started, _pid}} -> {:error, :spawn_failed}
      {:error, reason} -> {:error, reason}
      error -> error
    end
  end

  defp spawn_child(config, deps, dynsup) do
    registry = Map.get(deps, :registry, Quoracle.Registry)

    # DynSup.start_agent expects (dynsup_pid, config, opts)
    case DynSup.start_agent(dynsup, config, registry: registry) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("Child agent already exists: #{config.agent_id}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to spawn child agent: #{inspect(reason)}")
        {:error, :spawn_failed}
    end
  end
end
