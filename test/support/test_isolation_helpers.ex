defmodule Test.IsolationHelpers do
  @moduledoc """
  Gold standard test isolation utilities for Registry and DynSup dependencies.
  Enables true parallel test execution without conflicts.
  """

  @doc """
  Creates isolated Registry, DynSup, and PubSub instances for test use.
  Returns a map with registry name (atom), dynsup PID, and pubsub name (atom)
  that can be injected into production code.
  """
  @spec create_isolated_deps() :: %{registry: atom(), dynsup: pid(), pubsub: atom()}
  def create_isolated_deps do
    reg_name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _registry_pid} = start_supervised({Registry, keys: :unique, name: reg_name})

    # Use a proper child spec with unique ID for DynamicSupervisor
    # CRITICAL: shutdown: :infinity prevents ExUnit from killing DynSup
    # before children can terminate gracefully
    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
      shutdown: :infinity
    }

    {:ok, dynsup} = start_supervised(dynsup_spec)

    # Create isolated PubSub instance
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    pubsub_spec = {Phoenix.PubSub, name: pubsub_name}
    {:ok, _pubsub_pid} = start_supervised(pubsub_spec)

    %{
      registry: reg_name,
      dynsup: dynsup,
      pubsub: pubsub_name
    }
  end

  @doc """
  Creates a test agent with injected dependencies.
  Ensures proper isolation from other tests.
  """
  @spec create_test_agent(map()) :: {:ok, pid()} | {:error, term()}
  def create_test_agent(config) do
    unless Map.has_key?(config, :agent_id) do
      raise ArgumentError, "agent_id is required in config"
    end

    deps = create_isolated_deps()

    # Merge dependencies into config
    config = Map.merge(config, deps)

    # Start agent with injected dependencies
    case start_supervised({Quoracle.Agent.Core, config}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Injects dependencies into an existing configuration map.
  """
  @spec inject_deps(map(), map()) :: map()
  def inject_deps(config, %{registry: registry, dynsup: dynsup, pubsub: pubsub} = _deps) do
    unless is_atom(registry) and is_pid(dynsup) and is_atom(pubsub) do
      raise ArgumentError,
            "registry must be an atom, dynsup must be a valid PID, and pubsub must be an atom"
    end

    config
    |> Map.put(:registry, registry)
    |> Map.put(:dynsup, dynsup)
    |> Map.put(:pubsub, pubsub)
  end

  @doc """
  Polls a condition function until it returns true or timeout expires.
  Returns :ok on success, raises on timeout.

  ## Examples

      # Wait for Registry cleanup
      poll_until(fn -> Registry.lookup(registry, key) == [] end, 5000)

      # Wait for process to start
      poll_until(fn -> Process.whereis(:my_server) != nil end)
  """
  @spec poll_until((-> boolean()), non_neg_integer() | :infinity, non_neg_integer()) ::
          :ok | {:error, :timeout}
  def poll_until(condition_fn, timeout \\ :infinity, interval \\ 10) do
    deadline =
      case timeout do
        :infinity -> :infinity
        ms -> System.monotonic_time(:millisecond) + ms
      end

    do_poll_until(condition_fn, deadline, interval)
  end

  defp do_poll_until(condition_fn, deadline, interval) do
    if condition_fn.() do
      :ok
    else
      continue? =
        case deadline do
          :infinity -> true
          ms -> System.monotonic_time(:millisecond) < ms
        end

      if continue? do
        # Yield to scheduler before next poll (idiomatic receive/after pattern)
        receive do
        after
          interval -> :ok
        end

        do_poll_until(condition_fn, deadline, interval)
      else
        {:error, :timeout}
      end
    end
  end

  @doc """
  Stops an agent and waits for Registry cleanup to complete.
  This prevents race conditions when immediately spawning a new agent with the same ID.
  """
  @spec stop_and_wait_for_unregister(pid(), atom(), String.t(), non_neg_integer()) :: :ok
  def stop_and_wait_for_unregister(pid, registry, agent_id, timeout \\ 5000) do
    if Process.alive?(pid) do
      # Monitor the process so we can wait for :DOWN message
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal, :infinity)

      # Wait for process to actually terminate
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          # Process is dead, now wait for Registry cleanup
          # Registry cleanup is async - poll until clean
          poll_registry_cleanup(registry, agent_id, timeout)
      after
        timeout ->
          Process.demonitor(ref, [:flush])
          raise "Timeout waiting for agent #{agent_id} to terminate"
      end
    else
      :ok
    end
  end

  defp poll_registry_cleanup(registry, agent_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_until_clean(registry, agent_id, deadline)
  end

  defp poll_until_clean(registry, agent_id, deadline) do
    case Registry.lookup(registry, {:agent, agent_id}) do
      [] ->
        # Registry is clean
        :ok

      _ ->
        # Still registered, check if we have time left
        if System.monotonic_time(:millisecond) < deadline do
          # Yield multiple times to let Registry process :DOWN message
          # Registry cleanup is async and may take several scheduler cycles
          Enum.each(1..10, fn _ -> :erlang.yield() end)
          # Try again
          poll_until_clean(registry, agent_id, deadline)
        else
          raise "Agent #{agent_id} still in Registry after timeout - Registry cleanup didn't complete"
        end
    end
  end

  # Private helper - wraps ExUnit's start_supervised
  defp start_supervised(spec) do
    ExUnit.Callbacks.start_supervised(spec)
  end
end
