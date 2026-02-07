defmodule Quoracle.Actions.BatchAsync do
  @moduledoc """
  Executes multiple actions in parallel with per-action Router spawning.

  Key differences from batch_sync:
  - Parallel execution (not sequential)
  - No early termination on errors (all actions complete)
  - Returns immediately with acknowledgement (like shell async mode)
  - Results flow to history as individual entries via :batch_action_result casts
  - Completion notified via :batch_completed cast
  """

  alias Quoracle.Actions.Schema.ActionList
  alias Quoracle.Actions.Shared.BatchValidation

  # Delegate to ActionList - single source of truth
  defdelegate excluded_actions(), to: ActionList, as: :async_excluded_actions
  defdelegate async_batchable?(action_type), to: ActionList

  @doc """
  Execute a batch of actions in parallel.

  Returns immediately with an acknowledgement (async: true pattern like shell).
  Actions execute in background, results recorded via :batch_action_result casts.
  Completion notified via :batch_completed cast to agent_pid.

  ## Parameters
  - params: %{actions: [%{action: atom, params: map}, ...]}
  - agent_id: String agent identifier
  - opts: Keyword list with agent_pid, pubsub, sandbox_owner, etc.

  ## Returns
  - {:ok, %{batch_id, async: true, status: :running, started: count}} - Batch started
  - {:error, reason} - Validation failure
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(%{actions: actions}, agent_id, opts) do
    agent_pid = Keyword.get(opts, :agent_pid)
    batch_id = generate_batch_id()

    # Validate using shared module (DRY with batch_sync)
    with :ok <- BatchValidation.validate_batch_size(actions),
         :ok <- BatchValidation.validate_actions_eligible(actions, &async_batchable?/1),
         :ok <- BatchValidation.validate_action_params(actions) do
      # Spawn background task to execute all actions in parallel
      # This returns immediately with acknowledgement (like shell's async mode)
      # preventing alternation errors when top-level wait: false
      spawn_batch_executor(batch_id, actions, agent_id, agent_pid, opts)

      # Return immediately with acknowledgement
      # The async: true pattern matches shell's async acknowledgement format
      {:ok,
       %{
         action: "batch_async",
         batch_id: batch_id,
         async: true,
         status: :running,
         started: length(actions)
       }}
    end
  end

  # Spawns a process that executes all actions and notifies Core when complete
  defp spawn_batch_executor(batch_id, actions, agent_id, agent_pid, opts) do
    Task.start(fn ->
      # Execute all actions in parallel via Task.async
      tasks =
        Enum.map(actions, fn action_spec ->
          Task.async(fn ->
            execute_single_via_router(action_spec, agent_id, agent_pid, opts)
          end)
        end)

      results = Task.await_many(tasks, :infinity)

      # Notify Core that batch completed (cast like batch_sync)
      if agent_pid do
        GenServer.cast(agent_pid, {:batch_completed, batch_id, results})
      end
    end)
  end

  # Spawn per-action Router for each sub-action (same pattern as BatchSync)
  defp execute_single_via_router(
         %{action: action_type, params: params},
         agent_id,
         agent_pid,
         opts
       ) do
    action_id = "batch_async_#{agent_id}_#{:erlang.unique_integer([:positive])}"

    # Spawn per-action Router with agent_pid: nil to prevent premature consensus triggers
    # Sub-action Routers must NOT call Core.handle_action_result on async completion -
    # only the parent batch_async should trigger consensus after all sub-actions complete.
    # Results are recorded via :batch_action_result cast (line 97) which doesn't trigger consensus.
    {:ok, router_pid} =
      Quoracle.Actions.Router.start_link(
        action_type: action_type,
        action_id: action_id,
        agent_id: agent_id,
        agent_pid: nil,
        pubsub: Keyword.get(opts, :pubsub),
        sandbox_owner: Keyword.get(opts, :sandbox_owner)
      )

    # Convert atom keys to string keys for Router compatibility
    string_params =
      for {k, v} <- params, into: %{} do
        {to_string(k), v}
      end

    # Execute through Router (synchronous)
    # Disable shell smart mode - batch waits for actual completion, not async stubs
    batch_opts = Keyword.put(opts, :smart_threshold, :infinity)

    result =
      try do
        Quoracle.Actions.Router.execute(
          router_pid,
          action_type,
          string_params,
          agent_id,
          batch_opts
        )
      catch
        :exit, reason -> {:error, {:router_exit, reason}}
      end

    # Notify Core of result for history recording (cast like batch_sync)
    if agent_pid do
      GenServer.cast(agent_pid, {:batch_action_result, action_id, action_type, result})
    end

    result
  end

  defp generate_batch_id do
    "batch_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
