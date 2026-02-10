defmodule Quoracle.Actions.BatchSync do
  @moduledoc """
  Executes multiple fast actions in a single batch.

  Sequential execution with early termination on error.
  Results returned individually, identical to independent execution.
  """

  alias Quoracle.Actions.Validator
  alias Quoracle.Actions.Schema.ActionList

  # Delegate to ActionList - single source of truth for batchable actions
  defdelegate batchable_actions(), to: ActionList

  @doc """
  Execute a batch of actions sequentially.

  ## Returns
  - {:ok, %{results: [result]}} - All actions succeeded
  - {:error, :empty_batch} - Empty actions list
  - {:error, :batch_too_small} - Single action (use batch for 2+)
  - {:error, {:unbatchable_action, action}} - Non-batchable action in batch
  - {:error, :nested_batch} - batch_sync cannot contain batch_sync
  - {:error, {:validation_error, reason}} - Action param validation failed
  - {:error, {partial_results, error}} - First error with preceding successes
  """
  @spec execute(map(), String.t(), keyword()) ::
          {:ok, %{results: [map()]}} | {:error, term()}
  def execute(%{actions: []}, _agent_id, _opts), do: {:error, :empty_batch}

  def execute(%{actions: [_single]}, _agent_id, _opts), do: {:error, :batch_too_small}

  def execute(%{actions: actions}, agent_id, opts) when is_list(actions) do
    with :ok <- validate_all_batchable(actions),
         :ok <- validate_all_params(actions) do
      execute_batch(actions, agent_id, opts, [])
    end
  end

  # Validate all actions are batchable (not wait, batch_sync, or slow async)
  defp validate_all_batchable(actions) do
    batchable = ActionList.batchable_actions()

    Enum.reduce_while(actions, :ok, fn %{action: action_type}, _acc ->
      cond do
        action_type == :batch_sync ->
          {:halt, {:error, :nested_batch}}

        action_type not in batchable ->
          {:halt, {:error, {:unbatchable_action, action_type}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  # Validate params for each action before execution
  defp validate_all_params(actions) do
    Enum.reduce_while(actions, :ok, fn %{action: action_type, params: params}, _acc ->
      case Validator.validate_params(action_type, params) do
        {:ok, _validated} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:validation_error, reason}}}
      end
    end)
  end

  # Execute actions sequentially, stopping on first error
  defp execute_batch([], _agent_id, _opts, results), do: {:ok, %{results: Enum.reverse(results)}}

  defp execute_batch([action_spec | rest], agent_id, opts, results) do
    case execute_single(action_spec, agent_id, opts) do
      {:ok, result} ->
        execute_batch(rest, agent_id, opts, [result | results])

      {:error, reason} ->
        {:error, {Enum.reverse(results), reason}}
    end
  end

  # Spawn per-action Router directly for each sub-action (v2.0)
  # This ensures: secret resolution, permission validation, metrics, history recording
  # Note: Cannot call back into Core's GenServer (would deadlock since we're already in a call)
  defp execute_single(%{action: action_type, params: params}, agent_id, opts) do
    # Generate unique action_id for the sub-action
    action_id = "batch_sub_#{agent_id}_#{:erlang.unique_integer([:positive])}"
    agent_pid = Keyword.get(opts, :agent_pid)

    # Spawn per-action Router with agent_pid: nil to prevent premature consensus triggers
    # (consistent with batch_async - sub-action Routers don't notify Core directly)
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

    # Execute through Router (synchronous with timeout)
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

    # Notify Core of result for history recording (async cast to avoid deadlock)
    # Uses :batch_action_result which includes action_type directly (no pending_actions lookup)
    if agent_pid do
      GenServer.cast(agent_pid, {:batch_action_result, action_id, action_type, result})
    end

    # Wrap result with action type for batch result format
    case result do
      {:ok, inner_result} ->
        {:ok, %{action: to_string(action_type), result: inner_result}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
