defmodule Quoracle.Agent.ConsensusHandler.CorrectionInjector do
  @moduledoc """
  Injects per-model correction feedback into consensus messages.

  When a model's previous consensus attempt failed, correction feedback
  is prepended to the last user message as forward-looking instructions
  guiding the model to respond correctly.

  Injection happens at step 7.5 in the MessageBuilder pipeline — after
  budget injection (step 7) and before context token count (step 8).
  Since prepending happens after budget, the correction appears ABOVE
  budget text in the final user message.
  """

  alias Quoracle.Agent.ConsensusHandler.Helpers

  @doc """
  Injects correction feedback for a specific model into messages.

  Looks up `state.correction_feedback[model_id]`. If a correction exists,
  prepends it to the last user message content. Returns messages unchanged
  when no correction is pending for the given model.

  Handles backward compatibility with pre-v43.0 state that lacks the
  `correction_feedback` key entirely.
  """
  @spec inject_correction_feedback(map(), list(map()), String.t()) :: list(map())
  def inject_correction_feedback(_state, [] = messages, _model_id), do: messages

  def inject_correction_feedback(state, messages, model_id) do
    correction = get_correction(state, model_id)

    if correction do
      inject_into_last_message(messages, correction)
    else
      messages
    end
  end

  @spec get_correction(map(), String.t()) :: String.t() | nil
  defp get_correction(state, model_id) do
    case Map.get(state, :correction_feedback) do
      nil -> nil
      feedback when is_map(feedback) -> Map.get(feedback, model_id)
      _ -> nil
    end
  end

  @spec inject_into_last_message(list(map()), String.t()) :: list(map())
  defp inject_into_last_message(messages, correction) do
    List.update_at(messages, -1, fn last_msg ->
      original_content = Map.get(last_msg, :content, "")
      %{last_msg | content: Helpers.prepend_to_content(correction <> "\n", original_content)}
    end)
  end
end
