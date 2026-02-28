defmodule Quoracle.Agent.Consensus.MessageUtils do
  @moduledoc false

  require Logger
  alias Quoracle.Actions.Validator

  @doc "Extract the last user message as prompt for refinement context."
  @spec extract_prompt_for_context(list(map())) :: String.t()
  def extract_prompt_for_context(messages) do
    messages
    |> Enum.filter(fn msg -> msg.role == "user" end)
    |> List.last()
    |> case do
      %{content: content} -> content
      nil -> "Agent decision"
    end
  end

  @doc false
  @spec filter_invalid_responses([map()]) :: {[map()], non_neg_integer()}
  def filter_invalid_responses(responses) do
    # Use reduce to both filter AND apply validated/coerced params
    # Bug fix: Previously discarded coerced params (e.g., %{} -> [] for lists)
    {valid_reversed, invalid_count} =
      Enum.reduce(responses, {[], 0}, fn response, {valid_acc, inv_count} ->
        action = response.action
        params = response.params

        case Validator.validate_params(action, params) do
          {:ok, validated_params} ->
            # Use validated params with coercions applied (e.g., %{} -> [] for list types)
            updated_response = %{response | params: validated_params}
            {[updated_response | valid_acc], inv_count}

          {:error, reason} ->
            Logger.warning(
              "Filtered invalid consensus response: action=#{action}, reason=#{inspect(reason)}"
            )

            {valid_acc, inv_count + 1}
        end
      end)

    {Enum.reverse(valid_reversed), invalid_count}
  end

  # Extract the last user message content from model histories.
  # Histories are newest-first; pick any model since user messages are identical across models.
  # Handles both history entry format (%{type: :user}) and raw message format (%{role: "user"}).
  def extract_last_user_content(model_histories) do
    model_histories
    |> Map.values()
    |> List.first([])
    |> Enum.find(&user_entry?/1)
    |> case do
      %{content: content} when is_binary(content) -> content
      %{content: %{content: content}} when is_binary(content) -> content
      _ -> "Agent decision"
    end
  end

  defp user_entry?(%{type: :user}), do: true
  defp user_entry?(%{role: "user"}), do: true
  defp user_entry?(_), do: false
end
