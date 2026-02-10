defmodule Quoracle.Tasks.TaskManager do
  @moduledoc """
  Thin wrapper for task database operations.

  Handles task creation, queries, and status updates. Delegates agent
  spawning to AGENT_DynSup - does NOT implement spawning logic itself.
  """

  import Ecto.Query
  alias Quoracle.Repo
  alias Quoracle.Tasks.Task
  alias Quoracle.Agents.Agent
  alias Quoracle.Agent.DynSup, as: AgentDynSup
  alias Quoracle.Agent.Core
  alias Quoracle.Logs.Log
  alias Quoracle.Messages.Message
  alias Quoracle.Profiles.Resolver, as: ProfileResolver

  # Task Creation (UI entry point)

  @doc """
  Creates a new task with hierarchical prompt fields and spawns its root agent.

  This version supports the hierarchical prompt field system, splitting fields into:
  - Task-level fields (global_context, global_constraints) saved to Task record
  - Agent-level fields (all 9 provided fields) passed as prompt_fields to agent

  ## Parameters
  - `task_fields`: Map with `:global_context` (TEXT) and `:global_constraints` (list)
  - `agent_fields`: Map with all 9 provided fields from prompt field system
  - `opts`: Keyword list with `:sandbox_owner`, `:dynsup`, `:registry`, `:pubsub`

  ## Returns
  - `{:ok, {task, root_pid}}` on success
  - `{:error, changeset}` if task validation fails
  - `{:error, reason}` if agent spawn fails
  """
  @spec create_task(map(), map(), keyword()) :: {:ok, {%Task{}, pid()}} | {:error, term()}
  def create_task(task_fields, agent_fields, opts) do
    sandbox_owner = Keyword.get(opts, :sandbox_owner)
    dynsup = Keyword.get(opts, :dynsup)
    registry = Keyword.get(opts, :registry)
    pubsub = Keyword.get(opts, :pubsub)

    # Grant sandbox access to TaskManager process for DB transaction
    if sandbox_owner do
      Ecto.Adapters.SQL.Sandbox.allow(Repo, sandbox_owner, self())
    end

    # Step 0: Validate profile and resolve skills (before any DB operations - fail-fast)
    profile_name = Map.get(task_fields, :profile)
    skill_names = Map.get(task_fields, :skills) || []

    with {:ok, _} <- validate_profile_present(profile_name),
         {:ok, profile_data} <- ProfileResolver.resolve(profile_name),
         {:ok, active_skills} <- resolve_skills(skill_names, opts) do
      # Step 1: Create task record in transaction (commit before spawning agent)
      task_attrs = %{
        prompt: Map.get(agent_fields, :task_description, ""),
        status: "running",
        global_context: Map.get(task_fields, :global_context),
        initial_constraints: Map.get(task_fields, :global_constraints),
        budget_limit: Map.get(task_fields, :budget_limit),
        profile_name: profile_name
      }

      changeset = Task.changeset(%Task{}, task_attrs)

      case Repo.insert(changeset) do
        {:ok, task} ->
          do_spawn_agent(
            {:ok, task},
            agent_fields,
            profile_data,
            active_skills,
            opts,
            dynsup,
            registry,
            pubsub,
            sandbox_owner
          )

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :profile_required} -> {:error, :profile_required}
      {:error, :profile_not_found} -> {:error, :profile_not_found}
      {:error, {:skill_not_found, _name}} = error -> error
    end
  end

  # Validates that profile is present and non-empty
  defp validate_profile_present(nil), do: {:error, :profile_required}
  defp validate_profile_present(""), do: {:error, :profile_required}

  defp validate_profile_present(profile_name) when is_binary(profile_name),
    do: {:ok, profile_name}

  # Resolves skill names to skill content via SkillLoader
  # Returns {:ok, [skill_metadata]} or {:error, {:skill_not_found, name}}
  defp resolve_skills([], _opts), do: {:ok, []}

  defp resolve_skills(skill_names, opts) do
    skills_path = Keyword.get(opts, :skills_path)
    load_opts = if skills_path, do: [skills_path: skills_path], else: []

    Enum.reduce_while(skill_names, {:ok, []}, fn name, {:ok, acc} ->
      case Quoracle.Skills.Loader.load_skill(name, load_opts) do
        {:ok, skill} ->
          # Convert to metadata format for agent consumption
          metadata = %{
            name: skill.name,
            description: skill.description,
            content: skill.content,
            metadata: skill.metadata
          }

          {:cont, {:ok, acc ++ [metadata]}}

        {:error, :not_found} ->
          {:halt, {:error, {:skill_not_found, name}}}
      end
    end)
  end

  # Spawns the root agent after task creation
  defp do_spawn_agent(
         result,
         agent_fields,
         profile_data,
         active_skills,
         opts,
         dynsup,
         registry,
         pubsub,
         sandbox_owner
       ) do
    # Step 2: Spawn agent AFTER task transaction commits
    # This ensures the task exists in the database before agent tries to persist
    with {:ok, task} <- result do
      dynsup_pid = dynsup || AgentDynSup.get_dynsup_pid()

      # Allow test_mode override for acceptance tests that need test_mode: false
      # with model_query_fn injection (to record costs through real pipeline)
      test_mode =
        case Keyword.fetch(opts, :test_mode) do
          {:ok, mode} -> mode
          :error -> Application.get_env(:quoracle, :env) == :test
        end

      # Build prompt_fields for root agent (injected fields come from GlobalContextInjector)
      provided_fields = agent_fields
      injected_fields = Quoracle.Fields.GlobalContextInjector.inject(task.id)

      # Initialize transformed.constraints for root agent (matches transform_for_child pattern)
      # Without this, PromptFieldManager.build_system_prompt won't find constraints
      prompt_fields = %{
        injected: injected_fields,
        provided: provided_fields,
        transformed: %{
          constraints: Map.get(injected_fields, :constraints, [])
        }
      }

      # Convert prompt_fields to system_prompt (user_prompt removed in Packet 2)
      {system_prompt, _user_prompt} =
        Quoracle.Fields.PromptFieldManager.build_prompts_from_fields(prompt_fields)

      # Base agent config
      agent_config = %{
        agent_id: "root-#{task.id}",
        task_id: task.id,
        test_mode: test_mode,
        prompt_fields: prompt_fields,
        system_prompt: system_prompt,
        budget_data: build_budget_data(task.budget_limit),
        active_skills: active_skills
      }

      # Merge profile fields using DRY helper (v9.0)
      agent_config = Map.merge(agent_config, ProfileResolver.to_config_fields(profile_data))

      # Add optional dependencies if provided
      agent_config =
        agent_config
        |> maybe_put(:sandbox_owner, sandbox_owner)
        |> maybe_put(:registry, registry)
        |> maybe_put(:pubsub, pubsub)
        |> maybe_put(:force_init_error, Keyword.get(opts, :force_init_error))
        |> maybe_put(:test_opts, Keyword.get(opts, :test_opts))

      case AgentDynSup.start_agent(dynsup_pid, agent_config) do
        {:ok, root_pid} ->
          {:ok, _state} = Core.get_state(root_pid)
          {:ok, {task, root_pid}}

        {:error, reason} ->
          # Agent spawn failed after task committed - mark task as failed to prevent orphan
          task
          |> Task.fail_changeset(inspect(reason))
          |> Repo.update!()

          {:error, reason}
      end
    end
  end

  # Helper: conditionally add key-value to map if value is not nil
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Build budget_data for root agent from task.budget_limit
  defp build_budget_data(nil) do
    %{mode: :na, allocated: nil, committed: nil}
  end

  defp build_budget_data(%Decimal{} = budget_limit) do
    %{mode: :root, allocated: budget_limit, committed: Decimal.new("0")}
  end

  # Task Queries (read-only)

  @doc "Get task by ID"
  @spec get_task(binary()) :: {:ok, %Task{}} | {:error, :not_found}
  def get_task(id) do
    case Repo.get(Task, id) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  @doc "List all tasks, optionally filtered by status"
  @spec list_tasks(keyword()) :: [%Task{}]
  def list_tasks(opts \\ []) do
    query = from(t in Task, order_by: [desc: t.inserted_at])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(t in query, where: t.status == ^status)
      end

    Repo.all(query)
  end

  # Task Updates

  @doc "Update task status"
  @spec update_task_status(binary(), String.t()) :: {:ok, %Task{}} | {:error, term()}
  def update_task_status(id, status) do
    with {:ok, task} <- get_task(id) do
      task
      |> Task.status_changeset(status)
      |> Repo.update()
    end
  end

  @doc "Mark task as completed with result"
  @spec complete_task(binary(), String.t()) :: {:ok, %Task{}} | {:error, term()}
  def complete_task(id, result) do
    with {:ok, task} <- get_task(id) do
      task
      |> Task.complete_changeset(result)
      |> Repo.update()
    end
  end

  @doc "Mark task as failed with error message"
  @spec fail_task(binary(), String.t()) :: {:ok, %Task{}} | {:error, term()}
  def fail_task(id, error_message) do
    with {:ok, task} <- get_task(id) do
      task
      |> Task.fail_changeset(error_message)
      |> Repo.update()
    end
  end

  @doc "Update task budget_limit"
  @spec update_task_budget(binary(), Decimal.t()) :: {:ok, %Task{}} | {:error, term()}
  def update_task_budget(id, budget_limit) do
    with {:ok, task} <- get_task(id) do
      task
      |> Task.budget_limit_changeset(budget_limit)
      |> Repo.update()
    end
  end

  # Agent Queries (called by AGENT_Core, not application code)

  @doc """
  Save agent to database.

  Called by AGENT_Core.persist_agent/1 during agent initialization.
  NOT called by application code.
  """
  @spec save_agent(map()) :: {:ok, %Agent{}} | {:error, term()}
  def save_agent(attrs) do
    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Get agent by agent_id string"
  @spec get_agent(String.t()) :: {:ok, %Agent{}} | {:error, :not_found}
  def get_agent(agent_id) do
    query = from(a in Agent, where: a.agent_id == ^agent_id)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Update agent state (ACE context_lessons, model_states).

  Persists the full agent state to the database state JSONB column.
  Called by ACE system for lesson/state persistence.
  Automatically sanitizes non-JSON-safe values (PIDs, refs, etc.).
  """
  @spec update_agent_state(String.t(), map()) :: {:ok, %Agent{}} | {:error, term()}
  def update_agent_state(agent_id, state) when is_struct(state) do
    update_agent_state(agent_id, Map.from_struct(state))
  end

  def update_agent_state(agent_id, state) when is_map(state) do
    sanitized = sanitize_for_json(state)

    with {:ok, agent} <- get_agent(agent_id) do
      agent
      |> Agent.update_state_changeset(sanitized)
      |> Repo.update()
    end
  end

  # Sanitize data for JSON storage (PIDs, refs, etc. can't be serialized)
  defp sanitize_for_json(pid) when is_pid(pid), do: inspect(pid)
  defp sanitize_for_json(ref) when is_reference(ref), do: inspect(ref)
  defp sanitize_for_json(port) when is_port(port), do: inspect(port)
  defp sanitize_for_json(fun) when is_function(fun), do: "#Function<...>"
  defp sanitize_for_json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp sanitize_for_json(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp sanitize_for_json(%Date{} = d), do: Date.to_iso8601(d)
  defp sanitize_for_json(%Time{} = t), do: Time.to_iso8601(t)

  defp sanitize_for_json(%{__struct__: _} = struct) do
    struct |> Map.from_struct() |> sanitize_for_json()
  end

  defp sanitize_for_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {sanitize_key(k), sanitize_for_json(v)} end)
  end

  defp sanitize_for_json(list) when is_list(list), do: Enum.map(list, &sanitize_for_json/1)

  defp sanitize_for_json(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> sanitize_for_json()

  defp sanitize_for_json(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp sanitize_for_json(value), do: value

  defp sanitize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp sanitize_key(key), do: key

  @doc "Get all agents for a task (for restoration)"
  @spec get_agents_for_task(binary()) :: [%Agent{}]
  def get_agents_for_task(task_id) do
    from(a in Agent, where: a.task_id == ^task_id, order_by: [asc: a.inserted_at])
    |> Repo.all()
  end

  # Action Logging (called by ACTION_Router)

  @doc """
  Save action execution log to database.

  Called by ACTION_Router.persist_action_result/4 after action execution.
  NOT called by application code.
  """
  @spec save_log(map()) :: {:ok, %Log{}} | {:error, term()}
  def save_log(attrs) do
    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end

  # Message Logging (called by AGENT_MessageHandler)

  @doc """
  Save inter-agent message to database.

  Called by AGENT_MessageHandler.persist_message/3 when messages are received.
  NOT called by application code.
  """
  @spec save_message(map()) :: {:ok, %Message{}} | {:error, term()}
  def save_message(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  # Task Deletion

  @doc """
  Delete task and cascade cleanup.

  Permanently deletes a task and all associated data (agents, logs, messages).
  If task is running, automatically pauses (terminates agents) before deletion.

  ## Flow
  1. Auto-pause if task is running (delegates to TaskRestorer.pause_task/2)
  2. Delete task record (DB cascades to agents/logs/messages)
  3. Return success or error

  ## Options
  - `:registry` - Registry for finding live agents (required)
  - `:dynsup` - DynSup PID for terminating agents (default: discovered via PidDiscovery)

  ## Returns
  - `{:ok, deleted_task}` on success
  - `{:error, :not_found}` if task doesn't exist
  - `{:error, reason}` if pause or deletion fails
  """
  @spec delete_task(binary(), keyword()) :: {:ok, %Task{}} | {:error, term()}
  def delete_task(task_id, opts \\ []) do
    # CRITICAL: Pause agents OUTSIDE transaction to avoid deadlock.
    # Agent terminate/2 calls persist_ace_state which does Repo.update.
    # If pause is inside transaction, the update blocks on transaction lock,
    # but transaction waits for pause to complete → 5-second timeout.
    with :ok <- maybe_pause_task(task_id, opts) do
      Repo.transaction(fn ->
        with {:ok, task} <- get_task(task_id),
             {:ok, deleted_task} <- Repo.delete(task) do
          deleted_task
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  # Private helper for auto-pause logic
  defp maybe_pause_task(task_id, opts) do
    # Always call pause_task - it handles both empty and non-empty cases
    # This follows "let it crash" philosophy - no defensive checking
    Quoracle.Tasks.TaskRestorer.pause_task(task_id, opts)
  end
end
