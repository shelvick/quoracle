defmodule Quoracle.Agent.ConsensusHandler.TodoInjector do
  @moduledoc """
  Handles TODO injection into consensus messages.
  Extracted from ConsensusHandler to maintain <500 line modules.
  """

  alias Quoracle.Agent.ConsensusHandler.Helpers

  @doc "Injects TODO context (up to 20) into last message. Returns messages unchanged if empty."
  @spec inject_todo_context(map(), list(map())) :: list(map())
  def inject_todo_context(state, messages) do
    todos = Map.get(state, :todos, [])

    if todos == [] or messages == [] do
      messages
    else
      inject_into_last_message(messages, Enum.take(todos, 20))
    end
  end

  @doc "Formats todos as JSON objects within <todos> wrapper, matching the todo action schema."
  @spec format_todos(list(map())) :: String.t()
  def format_todos([]), do: "<todos>\n</todos>"

  def format_todos(todos) do
    json_lines =
      Enum.map(todos, fn todo ->
        %{
          "content" => Map.get(todo, :content, ""),
          "state" => to_string(Map.get(todo, :state, :todo))
        }
        |> Jason.encode!()
      end)

    "<todos>\n" <> Enum.join(json_lines, ",\n") <> "\n</todos>\n"
  end

  @doc "Injects TODOs at beginning of last message content."
  @spec inject_into_last_message(list(map()) | nil, list(map())) :: list(map()) | nil
  def inject_into_last_message(nil, _todos), do: nil

  def inject_into_last_message(messages, todos) when is_list(messages) and messages != [] do
    todos_str = format_todos(todos)

    List.update_at(messages, -1, fn last_msg ->
      original_content = Map.get(last_msg, :content, "")
      %{last_msg | content: Helpers.prepend_to_content(todos_str, original_content)}
    end)
  end
end
