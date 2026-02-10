defmodule Quoracle.Agent.ConsensusHandler do
  @moduledoc """
  Handles consensus operations for AGENT_Core.
  Manages consensus acquisition and action execution.
  """

  require Logger
  alias Quoracle.Agent.ImageDetector
  alias Quoracle.Agent.StateUtils

  alias Quoracle.Agent.Consensus.MessageBuilder

  alias Quoracle.Agent.ConsensusHandler.{
    AceInjector,
    ActionExecutor,
    BudgetInjector,
    ChildrenInjector,
    LogHelper,
    TodoInjector
  }

  # Delegate TODO injection to extracted TodoInjector module
  defdelegate inject_todo_context(state, messages), to: TodoInjector
  defdelegate format_todos(todos), to: TodoInjector
  defdelegate inject_into_last_message(messages, todos), to: TodoInjector

  # Delegate children injection to extracted ChildrenInjector module
  defdelegate inject_children_context(state, messages), to: ChildrenInjector
  defdelegate format_children(children), to: ChildrenInjector

  # Delegate budget injection to extracted BudgetInjector module
  defdelegate inject_budget_context(state, messages), to: BudgetInjector
  defdelegate format_budget(state), to: BudgetInjector

  # Delegate ACE injection to extracted AceInjector module
  defdelegate inject_ace_context(state, messages, model_id), to: AceInjector
  defdelegate format_ace_context(lessons, model_state), to: AceInjector

  # Delegate action execution to extracted ActionExecutor module
  defdelegate execute_consensus_action(state, action_response, agent_pid \\ self()),
    to: ActionExecutor

  @doc """
  Processes an action result, detecting images and storing appropriately.
  Returns updated state with result stored as :image or :result type.
  """
  @spec process_action_result(map(), {atom(), String.t(), term()}) :: map()
  def process_action_result(state, {action_type, action_id, result}) do
    case ImageDetector.detect(result, action_type) do
      {:image, multimodal_content} ->
        StateUtils.add_history_entry(state, :image, multimodal_content)

      {:text, _original_result} ->
        StateUtils.add_history_entry_with_action(state, :result, {action_id, result}, action_type)
    end
  end

  alias Quoracle.Costs.Accumulator

  @doc "Gets action consensus from multiple models using per-model histories from state."
  @spec get_action_consensus(map()) ::
          {:ok, map(), map(), Accumulator.t()} | {:error, term(), Accumulator.t()}
  def get_action_consensus(state) do
    # v23.0: Extract or create cost accumulator for embedding cost batching
    accumulator = Map.get(state, :cost_accumulator) || Accumulator.new()
    # v8.0: Single-arity signature - state contains model_histories
    # TODO injection happens in PerModelQuery after build_conversation_messages

    models_list =
      cond do
        # 1. Explicit model_pool in state (DI for test isolation)
        is_list(Map.get(state, :model_pool)) ->
          Map.get(state, :model_pool)

        # 2. Test mode uses mock atoms
        Map.get(state, :test_mode, false) ->
          [:mock_model_1, :mock_model_2, :mock_model_3]

        # 3. Production fallback - raises if model_pool not in profile
        true ->
          Quoracle.Consensus.Manager.get_model_pool()
      end

    base_opts =
      Keyword.merge(
        Map.get(state, :test_opts, []),
        models: models_list,
        # Pass model_pool for consensus.ex to use (avoids redundant resolution)
        model_pool: models_list,
        test_mode: Map.get(state, :test_mode, false),
        # Pass simulate_failure for test error scenarios
        simulate_failure: Map.get(state, :simulate_failure, false),
        # Pass force_condense for test isolation (bypasses token threshold check)
        force_condense: Map.get(state, :force_condense, false)
      )

    consensus_opts =
      if Map.get(state, :sandbox_owner) do
        Keyword.put(base_opts, :sandbox_owner, Map.get(state, :sandbox_owner))
      else
        base_opts
      end

    pubsub = Map.get(state, :pubsub)
    sandbox_owner = Map.get(state, :sandbox_owner)

    # v20.0: Single source of truth for prompt-related opts (fix-20260113-skill-injection)
    # Used by BOTH UI logging AND LLM query paths to ensure consistency
    prompt_opts = [
      profile_name: Map.get(state, :profile_name),
      profile_description: Map.get(state, :profile_description),
      capability_groups: Map.get(state, :capability_groups, []),
      active_skills: Map.get(state, :active_skills, []),
      skills_path: Map.get(state, :skills_path)
    ]

    # Calculate per-model message counts by actually building messages
    # This accounts for merging consecutive same-role messages
    per_model_counts =
      Enum.map(models_list, fn model_id ->
        # Build messages as PerModelQuery will (includes merging)
        messages = Quoracle.Agent.ContextManager.build_conversation_messages(state, model_id)

        # Add system prompt (+1) - user_prompt no longer injected (flows through history)
        length(messages) + 1
      end)

    counts_str = Enum.join(per_model_counts, "/")

    if is_atom(pubsub) and pubsub != :test_pubsub do
      # Build sent_messages for UI using shared MessageBuilder
      sent_messages = MessageBuilder.build_messages_for_models(state, models_list, prompt_opts)

      LogHelper.safe_broadcast_log(
        state.agent_id,
        :debug,
        "Sending to consensus: #{counts_str} messages across #{length(models_list)} models",
        %{
          model_count: length(models_list),
          per_model_counts: per_model_counts,
          sent_messages: sent_messages
        },
        pubsub
      )
    end

    # Build full consensus opts by merging prompt_opts with consensus-specific opts
    consensus_opts_with_context =
      consensus_opts
      |> Keyword.merge(prompt_opts)
      |> Keyword.put(:agent_id, state.agent_id)
      |> Keyword.put(:task_id, Map.get(state, :task_id))
      |> Keyword.put(:pubsub, pubsub)
      |> Keyword.put(:sandbox_owner, sandbox_owner)

    result =
      Quoracle.Agent.Consensus.get_consensus_with_state(state, consensus_opts_with_context)

    case result do
      {:ok, {:consensus, consensus_result, _opts}, updated_state} ->
        if is_atom(pubsub) and pubsub != :test_pubsub do
          LogHelper.safe_broadcast_log(
            state.agent_id,
            :info,
            "Consensus achieved",
            %{
              type: :consensus,
              action: consensus_result.action,
              params: consensus_result.params,
              reasoning: consensus_result[:reasoning],
              full_result: consensus_result
            },
            pubsub
          )
        end

        {:ok, consensus_result, updated_state, accumulator}

      {:ok, {:forced_decision, consensus_result, _opts}, updated_state} ->
        if is_atom(pubsub) and pubsub != :test_pubsub do
          LogHelper.safe_broadcast_log(
            state.agent_id,
            :warning,
            "Forced decision (no consensus)",
            %{
              type: :forced_decision,
              action: consensus_result.action,
              params: consensus_result.params,
              reasoning: consensus_result[:reasoning],
              full_result: consensus_result
            },
            pubsub
          )
        end

        {:ok, consensus_result, updated_state, accumulator}

      {:error, reason} ->
        if is_atom(pubsub) and pubsub != :test_pubsub do
          LogHelper.safe_broadcast_log(
            state.agent_id,
            :error,
            "Consensus failed",
            %{error: {:error, reason}},
            pubsub
          )
        end

        {:error, reason, accumulator}
    end
  end

  @doc "Handles wait param: false/0=immediate, true=wait, int=timed wait, invalid=default to true."
  @spec handle_wait_parameter(map(), atom(), boolean() | integer() | String.t()) :: map()
  def handle_wait_parameter(state, _action, wait_value) do
    # v21.0: Use StateUtils.cancel_wait_timer for DRY timer cancellation
    # Handles nil, 2-tuple, and 3-tuple formats; clears wait_timer to nil
    state = StateUtils.cancel_wait_timer(state)

    # Coerce string "true"/"false" to boolean (LLMs return strings from JSON)
    wait_value =
      case wait_value do
        "true" -> true
        "false" -> false
        other -> other
      end

    case wait_value do
      v when v in [false, 0] ->
        StateUtils.schedule_consensus_continuation(state)

      true ->
        state

      seconds when is_integer(seconds) and seconds > 0 ->
        timer_ref = Process.send_after(self(), :trigger_consensus, seconds * 1000)
        %{state | wait_timer: {timer_ref, :timed_wait}}

      _ ->
        Logger.warning("Invalid wait value: #{inspect(wait_value)}, defaulting to true")
        state
    end
  end
end
