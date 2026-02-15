defmodule Quoracle.Tasks.TaskRestorer.ConflictResolver do
  @moduledoc """
  Handles Registry conflict resolution during agent restoration.

  When restoring agents, an orphan from a previous session may still be registered
  in the Registry with the same agent_id. This module detects such conflicts,
  terminates the orphan, waits for Registry cleanup, and retries the restoration.
  """

  require Logger
  alias Quoracle.Agent.DynSup

  @doc """
  Attempt to restore an agent, retrying once if a Registry conflict is detected.

  On conflict (duplicate agent ID), terminates the orphan process, waits for
  Registry to process the monitor DOWN, and retries restoration once.
  """
  @spec restore_agent_with_retry(pid(), struct(), keyword(), atom()) ::
          {:ok, pid()} | {:error, term()}
  def restore_agent_with_retry(dynsup_pid, db_agent, agent_opts, registry) do
    case DynSup.restore_agent(dynsup_pid, db_agent, agent_opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        # Check if this is a Registry conflict (duplicate agent ID)
        if registry_conflict?(reason) do
          Logger.warning(
            "Agent #{db_agent.agent_id} already registered (orphan), terminating and retrying"
          )

          # Find and terminate the orphan via Registry lookup
          case Registry.lookup(registry, {:agent, db_agent.agent_id}) do
            [{orphan_pid, _}] ->
              terminate_orphan(orphan_pid)
              # Wait for Registry to process the monitor DOWN and unregister
              wait_for_registry_cleanup(registry, db_agent.agent_id)
              # Retry once after terminating orphan
              DynSup.restore_agent(dynsup_pid, db_agent, agent_opts)

            _ ->
              # No orphan found in Registry, can't retry
              {:error, reason}
          end
        else
          {:error, reason}
        end
    end
  end

  # Check if an error reason indicates a Registry conflict (duplicate agent ID)
  @spec registry_conflict?(term()) :: boolean()
  defp registry_conflict?({%RuntimeError{message: msg}, _stacktrace})
       when is_binary(msg) do
    String.contains?(msg, "Duplicate agent ID")
  end

  defp registry_conflict?({:already_started, _pid}), do: true
  defp registry_conflict?({:already_registered, _}), do: true
  defp registry_conflict?(_), do: false

  # Terminate an orphan process gracefully
  @spec terminate_orphan(pid()) :: :ok
  defp terminate_orphan(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, :infinity)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # Wait for Registry to unregister a terminated process.
  # Registry cleanup is asynchronous (via monitors), so we poll with yields.
  @spec wait_for_registry_cleanup(atom(), String.t()) :: :ok
  def wait_for_registry_cleanup(registry, agent_id) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_wait_for_registry_cleanup(registry, agent_id, deadline)
  end

  defp do_wait_for_registry_cleanup(registry, agent_id, deadline) do
    case Registry.lookup(registry, {:agent, agent_id}) do
      [] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          # Yield to let Registry process :DOWN monitor message
          Enum.each(1..10, fn _ -> :erlang.yield() end)
          do_wait_for_registry_cleanup(registry, agent_id, deadline)
        else
          Logger.warning("Registry cleanup timeout for agent #{agent_id}, proceeding with retry")

          :ok
        end
    end
  end
end
