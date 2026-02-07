defmodule Quoracle.Agent.ConsensusHandler.AceInjector do
  @moduledoc """
  Handles ACE (Adaptive Context Engine) injection into consensus messages.
  Injects accumulated lessons and model state into the FIRST user message.

  Key difference from other injectors:
  - TodoInjector/ChildrenInjector/BudgetInjector: Inject into LAST message (current state)
  - AceInjector: Injects into FIRST user message (historical knowledge)
  """

  @doc "Injects ACE context (lessons + state) into first user message. Returns messages unchanged if empty."
  @spec inject_ace_context(map(), list(map()), String.t()) :: list(map())
  def inject_ace_context(state, messages, model_id) do
    context_lessons = Map.get(state, :context_lessons) || %{}
    lessons = Map.get(context_lessons, model_id, [])

    model_states = Map.get(state, :model_states) || %{}
    model_state = Map.get(model_states, model_id)

    if lessons == [] and model_state == nil do
      messages
    else
      inject_into_first_user_message(messages, lessons, model_state)
    end
  end

  @doc "Formats lessons and state with XML tags."
  @spec format_ace_context(list(), map() | nil) :: String.t()
  def format_ace_context([], nil), do: ""

  def format_ace_context(lessons, model_state) do
    # Build list of parts, filtering out nils for cleaner functional approach
    [
      if(lessons != [], do: "<lessons>\n#{format_lessons(lessons)}\n</lessons>"),
      if(model_state, do: "<state>\n#{model_state.summary}\n</state>")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @spec inject_into_first_user_message(list(map()), list(), map() | nil) :: list(map())
  defp inject_into_first_user_message([], lessons, model_state) do
    # When messages is empty (e.g., after condensation), create user message with ACE content
    ace_str = format_ace_context(lessons, model_state)
    [%{role: "user", content: ace_str}]
  end

  defp inject_into_first_user_message(messages, lessons, model_state) do
    ace_str = format_ace_context(lessons, model_state)

    case Enum.find_index(messages, &(&1.role == "user")) do
      nil ->
        [%{role: "user", content: ace_str} | messages]

      idx ->
        List.update_at(messages, idx, fn msg ->
          original_content = Map.get(msg, :content, "")

          new_content =
            case original_content do
              list when is_list(list) ->
                [%{type: :text, text: ace_str <> "\n\n"} | list]

              binary when is_binary(binary) ->
                ace_str <> "\n\n" <> binary
            end

          %{msg | content: new_content}
        end)
    end
  end

  @spec format_lessons(list()) :: String.t()
  defp format_lessons(lessons) do
    lessons
    |> Enum.sort_by(& &1.confidence, :desc)
    |> Enum.map_join("\n", fn lesson ->
      type_label = if lesson.type == :factual, do: "Fact", else: "Pattern"
      "- [#{type_label}] #{lesson.content}"
    end)
  end
end
