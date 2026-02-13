defmodule Quoracle.Agent.HistoryTransfer do
  @moduledoc """
  Handles history and ACE state transfer during runtime model pool switching.

  ## Design Decisions

  1. **History Selection**: Select the history from old pool whose token count
     fits within the SMALLEST new model's context window. This ensures all
     new models can use the transferred history.

  2. **Condensation**: If no history fits, condense the smallest history
     SYNCHRONOUSLY until it fits. GenServer.call(:infinity) already expects
     blocking behavior.

  3. **ACE State Alignment**: Transfer context_lessons and model_states from
     the SAME source model whose history was selected. This maintains semantic
     alignment between history and accumulated knowledge.

  4. **Atomicity**: All state changes happen within a single GenServer.call,
     leveraging OTP's built-in synchronization.

  WorkGroupID: wip-20251230-075616
  """

  alias Quoracle.Agent.TokenManager

  @type transfer_result :: {:ok, map()} | {:error, :condensation_failed}

  @doc """
  Transfers history and ACE state from old model pool to new model pool.

  Returns updated state with:
  - model_histories re-keyed under new model IDs (all sharing same history)
  - context_lessons re-keyed under new model IDs (from source model)
  - model_states re-keyed under new model IDs (from source model)
  """
  @spec transfer_state_to_new_pool(map(), [String.t()], keyword()) :: transfer_result()
  def transfer_state_to_new_pool(state, new_model_pool, opts \\ [])

  def transfer_state_to_new_pool(state, new_model_pool, opts) do
    # Handle empty old histories
    if all_histories_empty?(state.model_histories) do
      # Pick first model as source for ACE state even with empty history
      source_model_id = state.model_histories |> Map.keys() |> List.first()
      rekey_state(state, source_model_id, [], new_model_pool)
    else
      # Allow target_limit override for testing
      target_limit =
        Keyword.get(opts, :target_limit) || find_smallest_context_limit(new_model_pool)

      case select_source_model(state.model_histories, target_limit) do
        {:ok, {source_model_id, history, _tokens}} ->
          rekey_state(state, source_model_id, history, new_model_pool)

        {:error, :no_fitting_history} ->
          {smallest_model, _smallest_history} = find_smallest_history(state.model_histories)

          case condense_until_fits(state, smallest_model, target_limit, opts) do
            {:ok, condensed_state} ->
              condensed_history = Map.get(condensed_state.model_histories, smallest_model)
              rekey_state(condensed_state, smallest_model, condensed_history, new_model_pool)

            {:error, _} = error ->
              error
          end
      end
    end
  end

  @doc """
  Selects the best source model from old pool for history transfer.

  Returns `{:ok, {model_id, history, token_count}}` or `{:error, :no_fitting_history}`.

  Selection criteria:
  1. History must fit within target_limit
  2. Prefer history with most tokens (preserves most context)
  """
  @spec select_source_model(map(), non_neg_integer()) ::
          {:ok, {String.t(), list(), non_neg_integer()}} | {:error, :no_fitting_history}
  def select_source_model(model_histories, target_limit) do
    histories_with_tokens =
      Enum.map(model_histories, fn {model_id, history} ->
        tokens = TokenManager.estimate_history_tokens(history)
        {model_id, history, tokens}
      end)

    fitting =
      histories_with_tokens
      |> Enum.filter(fn {_id, _history, tokens} -> tokens <= target_limit end)
      |> Enum.sort_by(fn {_id, _history, tokens} -> tokens end, :desc)

    case fitting do
      [{model_id, history, tokens} | _] -> {:ok, {model_id, history, tokens}}
      [] -> {:error, :no_fitting_history}
    end
  end

  @doc """
  Finds the smallest context limit among a list of model specs.
  """
  @spec find_smallest_context_limit([String.t()]) :: non_neg_integer()
  def find_smallest_context_limit(model_pool) do
    model_pool
    |> Enum.map(&TokenManager.get_model_context_limit/1)
    |> Enum.min()
  end

  @doc """
  Condenses a history until it fits within target_limit.
  Uses injectable condense_fn for testing or PerModelQuery for production.
  """
  @spec condense_until_fits(map(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, :condensation_failed}
  def condense_until_fits(state, model_id, target_limit, opts) do
    history = Map.get(state.model_histories, model_id, [])
    current_tokens = TokenManager.estimate_history_tokens(history)

    if current_tokens <= target_limit do
      {:ok, state}
    else
      condensed_state = do_condense(state, model_id, opts)
      new_history = Map.get(condensed_state.model_histories, model_id, [])
      new_tokens = TokenManager.estimate_history_tokens(new_history)

      cond do
        new_tokens <= target_limit ->
          {:ok, condensed_state}

        new_tokens >= current_tokens ->
          {:error, :condensation_failed}

        true ->
          condense_until_fits(condensed_state, model_id, target_limit, opts)
      end
    end
  end

  # Private helpers

  defp do_condense(state, model_id, opts) do
    if opts[:test_mode] do
      # Use injectable condense_fn in test mode
      case Keyword.get(opts, :condense_fn) do
        nil ->
          # Default test condensation: remove half the history
          history = Map.get(state.model_histories, model_id, [])
          half_len = max(1, div(length(history), 2))
          condensed = Enum.take(history, half_len)

          # Apply reflector if provided
          state =
            case Keyword.get(opts, :reflector_fn) do
              nil ->
                state

              reflector_fn ->
                case reflector_fn.(history, model_id, opts) do
                  {:ok, %{lessons: lessons, state: model_state}} ->
                    existing_lessons = get_in(state, [:context_lessons, model_id]) || []

                    state
                    |> put_in([:context_lessons, model_id], existing_lessons ++ lessons)
                    |> put_in([:model_states, model_id], model_state)

                  _ ->
                    state
                end
            end

          put_in(state, [:model_histories, model_id], condensed)

        condense_fn ->
          condense_fn.(state, model_id, opts)
      end
    else
      # Production: use PerModelQuery
      alias Quoracle.Agent.Consensus.PerModelQuery
      PerModelQuery.condense_model_history_with_reflection(state, model_id, opts)
    end
  end

  defp all_histories_empty?(model_histories) do
    Enum.all?(model_histories, fn {_id, history} -> history == [] end)
  end

  defp find_smallest_history(model_histories) do
    model_histories
    |> Enum.map(fn {model_id, history} ->
      tokens = TokenManager.estimate_history_tokens(history)
      {model_id, history, tokens}
    end)
    |> Enum.min_by(fn {_id, _history, tokens} -> tokens end)
    |> then(fn {model_id, history, _tokens} -> {model_id, history} end)
  end

  defp rekey_state(state, source_model_id, history, new_model_pool) do
    new_histories = Map.new(new_model_pool, fn model_id -> {model_id, history} end)

    source_lessons =
      if source_model_id do
        get_in(state, [:context_lessons, source_model_id]) || []
      else
        []
      end

    new_lessons = Map.new(new_model_pool, fn model_id -> {model_id, source_lessons} end)

    source_state =
      if source_model_id do
        get_in(state, [:model_states, source_model_id])
      else
        nil
      end

    new_model_states = Map.new(new_model_pool, fn model_id -> {model_id, source_state} end)

    {:ok,
     %{
       state
       | model_histories: new_histories,
         context_lessons: new_lessons,
         model_states: new_model_states
     }}
  end

  # ============================================================================
  # Model Pool Switching (extracted from Core v24.0)
  # ============================================================================

  @doc """
  Switches agent state to a new model pool, validating and transferring history.

  Returns {:ok, updated_state} or {:error, reason}.
  """
  @spec switch_model_pool(map(), [String.t()]) ::
          {:ok, map()} | {:error, :empty_model_pool | :invalid_models | :condensation_failed}
  def switch_model_pool(_state, []), do: {:error, :empty_model_pool}

  def switch_model_pool(state, new_pool) do
    alias Quoracle.Models.ConfigModelSettings

    case ConfigModelSettings.validate_model_pool(new_pool) do
      :ok ->
        transfer_opts = build_transfer_opts(state)

        transfer_state = %{
          model_histories: state.model_histories,
          context_lessons: state.context_lessons,
          model_states: state.model_states,
          task_id: state.task_id
        }

        case transfer_state_to_new_pool(transfer_state, new_pool, transfer_opts) do
          {:ok, transferred} ->
            new_state = %{
              state
              | model_pool: new_pool,
                model_histories: transferred.model_histories,
                context_lessons: transferred.context_lessons,
                model_states: transferred.model_states
            }

            {:ok, new_state}

          {:error, _} = error ->
            error
        end

      {:error, :invalid_models} = error ->
        error
    end
  end

  defp build_transfer_opts(state) do
    if state.test_mode do
      base_opts = [test_mode: true]

      case Keyword.get(state.test_opts || [], :target_limit) do
        nil -> base_opts
        limit -> Keyword.put(base_opts, :target_limit, limit)
      end
    else
      [agent_id: state.agent_id, task_id: state.task_id, pubsub: state.pubsub]
    end
  end
end
