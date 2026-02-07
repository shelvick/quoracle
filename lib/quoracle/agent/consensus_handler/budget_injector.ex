defmodule Quoracle.Agent.ConsensusHandler.BudgetInjector do
  @moduledoc """
  Handles budget injection into consensus messages.
  Extracted from system prompt to user message for KV cache preservation.
  """

  alias Quoracle.Agent.ConsensusHandler.Helpers
  alias Quoracle.Budget.Tracker

  @doc "Injects budget context into last message. Returns messages unchanged if no budget."
  @spec inject_budget_context(map(), list(map())) :: list(map())
  def inject_budget_context(state, messages) do
    budget_data = Map.get(state, :budget_data)

    cond do
      messages == [] ->
        messages

      budget_data == nil ->
        messages

      Map.get(budget_data, :allocated) == nil ->
        messages

      true ->
        inject_into_last_message(messages, state)
    end
  end

  @doc "Formats budget as Markdown within <budget> wrapper."
  @spec format_budget(map()) :: String.t()
  def format_budget(%{budget_data: nil}), do: ""
  def format_budget(%{budget_data: %{allocated: nil}}), do: ""

  # Production path: fetch spent from DB via agent_id
  # Wrapped in try/rescue for test isolation (UI logging path may lack sandbox access)
  def format_budget(%{agent_id: agent_id, budget_data: budget_data, over_budget: over_budget})
      when is_binary(agent_id) do
    try do
      spent = Tracker.get_spent(agent_id)
      format_budget_with_spent(budget_data, spent, over_budget)
    rescue
      _e in [DBConnection.OwnershipError, DBConnection.ConnectionError] ->
        ""
    end
  end

  # Test path: spent provided directly in map
  def format_budget(%{budget_data: budget_data, spent: spent, over_budget: over_budget}) do
    format_budget_with_spent(budget_data, spent, over_budget)
  end

  def format_budget(_), do: ""

  @spec format_budget_with_spent(map(), Decimal.t(), boolean()) :: String.t()
  defp format_budget_with_spent(budget_data, spent, over_budget) do
    allocated = budget_data.allocated
    committed = budget_data.committed
    available = Decimal.sub(Decimal.sub(allocated, spent), committed)

    status = if over_budget, do: "OVER BUDGET", else: "Within budget"

    over_budget_warning =
      if over_budget do
        """

        **IMPORTANT:** You are over budget. Only free actions are allowed:
        - orient (planning/reasoning)
        - wait (pausing)
        - send_message (communication)
        - todo (task management)
        - dismiss_child (cleanup - also recovers unspent child budget)

        Costly actions (spawn_child, answer_engine, execute_shell, etc.) will be blocked.
        To continue work: request budget increase from parent, or dismiss children to recover their unspent funds.
        """
      else
        ""
      end

    content = """
    ## Budget Status

    | Metric | Amount |
    |--------|--------|
    | Allocated | $#{format_decimal(allocated)} |
    | Spent | $#{format_decimal(spent)} |
    | Committed to Children | $#{format_decimal(committed)} |
    | Available | $#{format_decimal(available)} |

    **Status:** #{status}
    #{over_budget_warning}
    """

    "<budget>\n#{String.trim(content)}\n</budget>\n"
  end

  @spec format_decimal(Decimal.t()) :: String.t()
  defp format_decimal(decimal) do
    Decimal.round(decimal, 2) |> Decimal.to_string()
  end

  @spec inject_into_last_message(list(map()), map()) :: list(map())
  defp inject_into_last_message(messages, state) when is_list(messages) and messages != [] do
    budget_str = format_budget(state)

    if budget_str == "" do
      messages
    else
      List.update_at(messages, -1, fn last_msg ->
        original_content = Map.get(last_msg, :content, "")
        %{last_msg | content: Helpers.prepend_to_content(budget_str, original_content)}
      end)
    end
  end
end
