defmodule Quoracle.Boot.AgentRevival do
  @moduledoc """
  Boot-time restoration of running tasks.

  Called after Application supervisor starts to restore all tasks
  with status "running" from the database. Each task is restored
  independently - failures are logged but don't affect other tasks.

  Also finalizes any tasks stuck in "pausing" status from a previous
  shutdown — since their agents are no longer alive after a restart,
  they are transitioned to "paused".
  """

  require Logger
  alias Quoracle.Tasks.{TaskManager, TaskRestorer}

  @doc """
  Restore all tasks with status "running" from database.

  Uses production Registry and PubSub. Sequential restoration
  with per-task failure isolation.

  ## Returns
    * `:ok` - Always returns :ok (failures are logged, not raised)
  """
  @spec restore_running_tasks() :: :ok
  def restore_running_tasks do
    restore_running_tasks(
      registry: Quoracle.AgentRegistry,
      pubsub: Quoracle.PubSub
    )
  end

  @doc """
  Restore with explicit dependencies (for testing).

  ## Options
    * `:registry` - Registry instance (required)
    * `:pubsub` - PubSub instance (required)
    * `:sandbox_owner` - DB sandbox owner PID (optional, for tests)

  ## Returns
    * `:ok` - Always returns :ok (failures are logged, not raised)
  """
  @spec restore_running_tasks(keyword()) :: :ok
  def restore_running_tasks(opts) do
    registry = Keyword.fetch!(opts, :registry)
    pubsub = Keyword.fetch!(opts, :pubsub)
    sandbox_owner = Keyword.get(opts, :sandbox_owner)

    finalize_stale_pausing_tasks()

    running_tasks = TaskManager.list_tasks(status: "running")

    case running_tasks do
      [] ->
        Logger.info("Boot: No running tasks to restore")
        :ok

      tasks ->
        Logger.info("Boot: Restoring #{length(tasks)} running task(s)")

        # Sequential restoration with per-task failure isolation
        results =
          Enum.map(tasks, fn task ->
            restore_task_safely(task, registry, pubsub, sandbox_owner)
          end)

        # Count successes and failures
        {successes, failures} = Enum.split_with(results, &match?({:ok, _}, &1))

        # Summary log
        if Enum.empty?(failures) do
          Logger.info("Boot: All #{length(successes)} task(s) restored successfully")
        else
          Logger.warning(
            "Boot: Restored #{length(successes)}/#{length(tasks)} task(s), " <>
              "#{length(failures)} failed"
          )
        end

        :ok
    end
  end

  @spec restore_task_safely(struct(), atom(), atom(), pid() | nil) ::
          {:ok, pid()} | {:error, term()}
  defp restore_task_safely(task, registry, pubsub, sandbox_owner) do
    restore_opts = [sandbox_owner: sandbox_owner]

    try do
      case TaskRestorer.restore_task(task.id, registry, pubsub, restore_opts) do
        {:ok, root_pid} ->
          # v6.0: Partial success also returns {:ok, root_pid} with logged errors
          Logger.info("Boot: Restored task #{task.id} (root: #{inspect(root_pid)})")
          {:ok, root_pid}

        {:error, reason} ->
          Logger.error("Boot: Failed to restore task #{task.id}: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Boot: Task #{task.id} restoration crashed: #{Exception.message(e)}")
        {:error, {:exception, e}}
    catch
      kind, reason ->
        Logger.error("Boot: Task #{task.id} restoration failed: #{inspect({kind, reason})}")
        {:error, {kind, reason}}
    end
  end

  @doc """
  Transition any tasks stuck in "pausing" to "paused".

  After a server restart, agents from a previous session are no longer alive.
  Tasks left in "pausing" status will never complete the transition on their
  own, so we finalize them here.

  ## Returns
    * `:ok` - Always returns :ok
  """
  @spec finalize_stale_pausing_tasks() :: :ok
  def finalize_stale_pausing_tasks do
    pausing_tasks = TaskManager.list_tasks(status: "pausing")

    case pausing_tasks do
      [] ->
        :ok

      tasks ->
        Logger.info("Boot: Finalizing #{length(tasks)} stale pausing task(s)")

        Enum.each(tasks, fn task ->
          TaskManager.update_task_status(task.id, "paused")
          Logger.info("Boot: Task #{task.id} transitioned from pausing to paused")
        end)

        :ok
    end
  end
end
