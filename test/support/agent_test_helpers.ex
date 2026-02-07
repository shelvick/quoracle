defmodule Test.AgentTestHelpers do
  @moduledoc """
  Test helpers for agent lifecycle management.

  Provides utilities for spawning agents with automatic cleanup,
  hierarchical agent tree management, and common assertion patterns.

  All cleanup uses `:infinity` timeout to prevent race conditions
  where agents are mid-DB-operation during shutdown.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Quoracle.Agent.{Core, DynSup}
  alias Quoracle.Profiles.{CapabilityGroups, TableProfiles}
  alias Quoracle.Repo
  alias Quoracle.Tasks.TaskManager

  require Logger

  @doc """
  Creates a test profile in the database.

  This is required for all spawn_child operations since profile is now required.

  ## Options (all optional)
    * `:name` - Profile name (default: unique random name)
    * `:model_pool` - List of model IDs (default: ["test-model"])
    * `:capability_groups` - List of capability group strings (default: all groups)
    * `:description` - Profile description (default: nil)

  ## Examples

      profile = create_test_profile()
      profile = create_test_profile(name: "my-profile", capability_groups: [])
  """
  @spec create_test_profile(keyword()) :: TableProfiles.t()
  def create_test_profile(opts \\ []) do
    all_groups = CapabilityGroups.groups() |> Enum.map(&to_string/1)
    name = Keyword.get(opts, :name, "test-profile-#{System.unique_integer([:positive])}")
    model_pool = Keyword.get(opts, :model_pool, ["test-model"])
    description = Keyword.get(opts, :description)
    capability_groups = Keyword.get(opts, :capability_groups, all_groups)

    %TableProfiles{}
    |> TableProfiles.changeset(%{
      name: name,
      model_pool: model_pool,
      capability_groups: capability_groups,
      description: description
    })
    |> Repo.insert!()
  end

  @doc """
  Spawns an agent and automatically registers cleanup with :infinity timeout.
  Waits for initialization before returning.

  ## Options
    * `:registry` - Registry instance for the agent
    * `:pubsub` - PubSub instance for the agent
    * `:sandbox_owner` - DB sandbox owner PID

  ## Returns
    * `{:ok, agent_pid}` - Agent spawned successfully
    * `{:error, reason}` - Agent failed to spawn

  ## Examples

      {:ok, agent_pid} = spawn_agent_with_cleanup(dynsup, %{
        agent_id: "test-agent",
        parent_id: nil,
        prompt: "Test prompt"
      }, registry: registry, sandbox_owner: sandbox_owner)
  """
  @spec spawn_agent_with_cleanup(pid(), map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn_agent_with_cleanup(dynsup, config, opts \\ []) do
    # REQUIRE registry parameter - fail fast if missing
    # This prevents orphaned Routers and ensures proper tree cleanup
    registry = Keyword.fetch!(opts, :registry)

    # Ensure test_mode: true to avoid DB queries for model_pool (Packet 2)
    config = Map.put_new(config, :test_mode, true)

    case DynSup.start_agent(dynsup, config, opts) do
      {:ok, agent_pid} ->
        # Wait for initialization
        assert {:ok, _state} = Core.get_state(agent_pid)

        # Register cleanup - ALWAYS use tree cleanup
        # This ensures children (including Router) are cleaned up
        on_exit(fn ->
          # CRITICAL: Stop agent FIRST to prevent new actions during cleanup
          # With continuation fix, agents loop infinitely with mock consensus
          # Stopping agent prevents it from processing action_result messages
          # that would spawn new tasks during shutdown
          if Process.alive?(agent_pid) do
            try do
              GenServer.stop(agent_pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end

          # Then cleanup tree (this is now mostly a no-op since agent is stopped)
          stop_agent_tree(agent_pid, registry)

          # VERIFY cleanup succeeded
          refute Process.alive?(agent_pid),
                 "Agent #{inspect(agent_pid)} still alive after cleanup!"
        end)

        {:ok, agent_pid}

      error ->
        error
    end
  end

  @doc """
  Registers cleanup for an already-spawned agent.

  CRITICAL: With continuation fix, agents loop infinitely with mock consensus.
  This stops agent BEFORE ExUnit supervisor cleanup to prevent new tasks spawning.

  Use this when you've spawned an agent directly (not via spawn_agent_with_cleanup)
  and need to ensure it's cleaned up before the test exits.

  ## Options
    * `:cleanup_tree` - If true, recursively cleanup all children (default: false)
    * `:registry` - Required if cleanup_tree is true
    * `:dynsup` - Optional, for compatibility

  ## Examples

      {:ok, agent_pid} = DynSup.start_agent(dynsup, config)
      register_agent_cleanup(agent_pid)

      # After start_supervised! (prevents infinite loops)
      agent = start_supervised!({Core, config}, shutdown: :infinity)
      register_agent_cleanup(agent)

      # With tree cleanup:
      register_agent_cleanup(parent_pid, cleanup_tree: true, registry: registry)
  """
  @spec register_agent_cleanup(pid(), keyword()) :: :ok
  def register_agent_cleanup(agent_pid, opts \\ []) do
    cleanup_tree = Keyword.get(opts, :cleanup_tree, false)
    registry = Keyword.get(opts, :registry)

    on_exit(fn ->
      # CRITICAL: If cleanup_tree requested, stop children FIRST (bottom-up)
      # This must happen BEFORE stopping the agent, because stop_agent_tree
      # checks Process.alive? and skips if agent is already dead
      if cleanup_tree && registry do
        stop_agent_tree(agent_pid, registry)
      else
        # No tree cleanup - just stop the agent
        stop_agent_gracefully(agent_pid)
      end
    end)

    :ok
  end

  @doc """
  Stops an agent gracefully with :infinity timeout.
  Handles already-dead processes gracefully.

  Uses :infinity timeout to allow agents to complete any pending
  DB operations before shutdown.

  ## Examples

      stop_agent_gracefully(agent_pid)
  """
  @spec stop_agent_gracefully(pid()) :: :ok
  def stop_agent_gracefully(agent_pid) do
    if Process.alive?(agent_pid) do
      try do
        GenServer.stop(agent_pid, :normal, :infinity)
      catch
        _kind, _reason -> :ok
      end
    end

    :ok
  end

  @doc """
  Stops an agent and all its children recursively.
  Stops children first (bottom-up), then the parent.

  ## Examples

      stop_agent_tree(parent_pid, registry)
  """
  @spec stop_agent_tree(pid(), atom() | pid()) :: :ok
  def stop_agent_tree(agent_pid, registry) do
    if Process.alive?(agent_pid) do
      # Recursively stop all children first
      # Registry may be stopped before on_exit runs (ExUnit supervisor cleanup
      # happens BEFORE on_exit callbacks), so handle gracefully
      children =
        if registry_alive?(registry) do
          try do
            Core.find_children_by_parent(agent_pid, registry)
          rescue
            ArgumentError -> []
          end
        else
          []
        end

      Enum.each(children, fn {child_pid, _meta} ->
        stop_agent_tree(child_pid, registry)
      end)

      # Then stop parent
      stop_agent_gracefully(agent_pid)
    end

    :ok
  end

  # Check if registry process is alive (handles both named and PID registries)
  defp registry_alive?(registry) when is_atom(registry) do
    case Process.whereis(registry) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp registry_alive?(registry) when is_pid(registry) do
    Process.alive?(registry)
  end

  @doc """
  Spawns multiple agents concurrently and registers cleanup for all.

  All agents are spawned in parallel using Task.async. Each agent
  waits for initialization and has cleanup registered automatically.

  ## Examples

      configs = [
        %{agent_id: "agent-1", prompt: "Task 1"},
        %{agent_id: "agent-2", prompt: "Task 2"}
      ]
      results = spawn_agents_concurrently(dynsup, configs,
        registry: registry, sandbox_owner: sandbox_owner)
  """
  @spec spawn_agents_concurrently(pid(), [map()], keyword()) :: [
          {:ok, pid()} | {:error, term()}
        ]
  def spawn_agents_concurrently(dynsup, configs, opts \\ []) do
    results =
      Enum.map(configs, fn config ->
        # Ensure test_mode: true to avoid DB queries for model_pool (Packet 2)
        config = Map.put_new(config, :test_mode, true)

        Task.async(fn ->
          DynSup.start_agent(dynsup, config, opts)
        end)
      end)
      |> Enum.map(&Task.await/1)

    # Wait for all to initialize and register cleanup
    Enum.each(results, fn
      {:ok, agent_pid} ->
        assert {:ok, _state} = Core.get_state(agent_pid)

        on_exit(fn ->
          stop_agent_gracefully(agent_pid)
        end)

      {:error, _} ->
        :ok
    end)

    results
  end

  @doc """
  Creates a task and automatically registers agent cleanup.

  The task agent is spawned, waited for initialization, and cleanup
  is registered. If a registry is provided, the entire agent tree
  will be cleaned up recursively.

  ## Examples

      {:ok, {task, agent_pid}} = create_task_with_cleanup(
        "Test task",
        sandbox_owner: sandbox_owner,
        dynsup: dynsup,
        registry: registry,
        pubsub: pubsub
      )
  """
  @spec create_task_with_cleanup(String.t(), keyword()) ::
          {:ok, {Ecto.Schema.t(), pid()}} | {:error, term()}
  def create_task_with_cleanup(prompt, opts) do
    # Ensure test profile exists and include it - use unique name to avoid ON CONFLICT contention
    profile = create_test_profile()
    task_fields = %{profile: profile.name}
    agent_fields = %{task_description: prompt}

    case TaskManager.create_task(task_fields, agent_fields, opts) do
      {:ok, {task, task_agent_pid}} ->
        # Wait for initialization
        assert {:ok, _state} = Core.get_state(task_agent_pid)

        # Register cleanup - use tree cleanup if registry provided
        on_exit(fn ->
          registry = opts[:registry]

          if registry do
            stop_agent_tree(task_agent_pid, registry)
          else
            stop_agent_gracefully(task_agent_pid)
          end
        end)

        {:ok, {task, task_agent_pid}}

      error ->
        error
    end
  end

  @doc """
  Restores an agent from database and automatically registers cleanup.
  Waits for initialization before returning.

  This is the test helper wrapper for DynSup.restore_agent/3.

  ## Options
    * `:registry` - Registry instance for the agent (required)
    * `:pubsub` - PubSub instance for the agent (required)
    * `:sandbox_owner` - DB sandbox owner PID
    * `:parent_pid_override` - Override parent PID during restoration

  ## Returns
    * `{:ok, agent_pid}` - Agent restored successfully
    * `{:error, reason}` - Agent failed to restore

  ## Examples

      {:ok, restored_pid} = restore_agent_with_cleanup(dynsup, db_agent,
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner
      )
  """
  @spec restore_agent_with_cleanup(pid(), map() | struct(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def restore_agent_with_cleanup(dynsup, db_agent, opts \\ []) do
    # REQUIRE registry parameter - fail fast if missing
    registry = Keyword.fetch!(opts, :registry)

    case DynSup.restore_agent(dynsup, db_agent, opts) do
      {:ok, agent_pid} ->
        # Wait for initialization
        assert {:ok, _state} = Core.get_state(agent_pid)

        # Register cleanup - ALWAYS use tree cleanup
        on_exit(fn ->
          if Process.alive?(agent_pid) do
            try do
              GenServer.stop(agent_pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end

          stop_agent_tree(agent_pid, registry)

          refute Process.alive?(agent_pid),
                 "Agent #{inspect(agent_pid)} still alive after cleanup!"
        end)

        {:ok, agent_pid}

      error ->
        error
    end
  end

  @doc """
  Asserts an agent exists in the registry and is alive.

  Returns the agent PID if found and alive, otherwise fails the test.

  ## Examples

      agent_pid = assert_agent_in_registry("test-agent", registry)
      assert Process.alive?(agent_pid)
  """
  @spec assert_agent_in_registry(String.t(), atom() | pid()) :: pid()
  def assert_agent_in_registry(agent_id, registry) do
    case Registry.lookup(registry, {:agent, agent_id}) do
      [{pid, _meta}] ->
        assert Process.alive?(pid), "Agent #{agent_id} found but not alive"
        pid

      _ ->
        flunk("Agent #{agent_id} not found in registry")
    end
  end

  @doc """
  Asserts an agent does NOT exist in the registry.

  ## Examples

      refute_agent_in_registry("test-agent", registry)
  """
  @spec refute_agent_in_registry(String.t(), atom() | pid()) :: :ok
  def refute_agent_in_registry(agent_id, registry) do
    case Registry.lookup(registry, {:agent, agent_id}) do
      [] ->
        :ok

      [{_pid, _meta}] ->
        flunk("Agent #{agent_id} should not be in registry but was found")
    end
  end

  @doc """
  Waits for an agent to appear in the registry.

  Polls the registry until the agent appears or timeout is reached.

  ## Options
    * `:timeout` - Maximum time to wait in milliseconds (default: 5000)
    * `:interval` - Polling interval in milliseconds (default: 10)

  ## Examples

      wait_for_agent_in_registry("test-agent", registry, timeout: 5000)
  """
  @spec wait_for_agent_in_registry(String.t(), atom() | pid(), keyword()) ::
          {:ok, pid()} | {:error, :timeout}
  def wait_for_agent_in_registry(agent_id, registry, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    interval = Keyword.get(opts, :interval, 10)
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_for_agent_loop(agent_id, registry, deadline, interval)
  end

  defp wait_for_agent_loop(agent_id, registry, deadline, interval) do
    case Registry.lookup(registry, {:agent, agent_id}) do
      [{pid, _meta}] ->
        {:ok, pid}

      [] ->
        if System.monotonic_time(:millisecond) < deadline do
          # Use receive-after for idiomatic yielding (no event to receive, just delay)
          receive do
          after
            interval -> :ok
          end

          wait_for_agent_loop(agent_id, registry, deadline, interval)
        else
          {:error, :timeout}
        end
    end
  end

  @doc """
  Gets or creates a test profile for use in tests.
  Uses "test-default" profile with all capability groups.

  Uses atomic upsert pattern to prevent race conditions when
  multiple async tests call this simultaneously.
  """
  @spec get_or_create_test_profile() :: Quoracle.Profiles.TableProfiles.t()
  def get_or_create_test_profile do
    alias Quoracle.Profiles.TableProfiles
    alias Quoracle.Repo

    all_groups = CapabilityGroups.groups() |> Enum.map(&to_string/1)

    attrs = %{
      name: "test-default",
      model_pool: ["gpt-4o"],
      capability_groups: all_groups
    }

    # Fast path: check if already exists (most common after first test)
    case Repo.get_by(TableProfiles, name: "test-default") do
      nil ->
        # Use upsert with ON CONFLICT DO NOTHING to handle race conditions
        %TableProfiles{}
        |> TableProfiles.changeset(attrs)
        |> Repo.insert(on_conflict: :nothing, conflict_target: :name)
        |> case do
          {:ok, %{id: nil}} ->
            # Insert was no-op due to race (another test inserted first)
            Repo.get_by!(TableProfiles, name: "test-default")

          {:ok, profile} ->
            profile

          {:error, _changeset} ->
            # Constraint violation caught, fetch existing
            Repo.get_by!(TableProfiles, name: "test-default")
        end

      profile ->
        profile
    end
  end
end
