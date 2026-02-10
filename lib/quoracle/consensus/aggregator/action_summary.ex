defmodule Quoracle.Consensus.Aggregator.ActionSummary do
  @moduledoc """
  Formats action responses into truncated summary strings.
  Extracted from Aggregator to maintain <500 line modules.
  """

  @max_summary_length 100

  @doc """
  Formats an action response into a truncated summary string.
  Shows action name with key parameter(s), truncated to max length.
  """
  @spec format_action_summary(map()) :: String.t()
  def format_action_summary(%{action: action, params: params}) do
    summary =
      case action do
        :execute_shell -> format_shell_summary(params)
        :spawn_child -> format_spawn_summary(params)
        :answer_engine -> format_answer_summary(params)
        :fetch_web -> format_web_summary(params)
        :send_message -> format_message_summary(params)
        :call_api -> format_api_summary(params)
        :call_mcp -> format_mcp_summary(params)
        :wait -> format_wait_summary(params)
        :orient -> format_orient_summary(params)
        :todo -> format_todo_summary(params)
        :generate_secret -> format_secret_summary(params)
        :batch_sync -> format_batch_sync_summary(params)
        :batch_async -> format_batch_async_summary(params)
        other -> "[#{other}]"
      end

    truncate_summary(summary, @max_summary_length)
  end

  # Key param extractors per action type
  defp format_shell_summary(%{command: cmd}) when is_binary(cmd),
    do: "[execute_shell: #{inspect(cmd)}]"

  defp format_shell_summary(%{"command" => cmd}) when is_binary(cmd),
    do: "[execute_shell: #{inspect(cmd)}]"

  defp format_shell_summary(%{check_id: id}), do: "[execute_shell: check(#{id})]"
  defp format_shell_summary(%{"check_id" => id}), do: "[execute_shell: check(#{id})]"
  defp format_shell_summary(_), do: "[execute_shell]"

  defp format_spawn_summary(%{task_description: task}) when is_binary(task),
    do: "[spawn_child: #{inspect(task)}]"

  defp format_spawn_summary(%{"task_description" => task}) when is_binary(task),
    do: "[spawn_child: #{inspect(task)}]"

  defp format_spawn_summary(_), do: "[spawn_child]"

  defp format_answer_summary(%{prompt: p}) when is_binary(p), do: "[answer_engine: #{inspect(p)}]"

  defp format_answer_summary(%{"prompt" => p}) when is_binary(p),
    do: "[answer_engine: #{inspect(p)}]"

  defp format_answer_summary(_), do: "[answer_engine]"

  defp format_web_summary(%{url: url}) when is_binary(url), do: "[fetch_web: #{inspect(url)}]"
  defp format_web_summary(%{"url" => url}) when is_binary(url), do: "[fetch_web: #{inspect(url)}]"
  defp format_web_summary(_), do: "[fetch_web]"

  defp format_message_summary(%{to: to, content: c}) when is_binary(c),
    do: "[send_message(#{to}): #{inspect(c)}]"

  defp format_message_summary(%{"to" => to, "content" => c}) when is_binary(c),
    do: "[send_message(#{to}): #{inspect(c)}]"

  defp format_message_summary(%{to: to}), do: "[send_message(#{to})]"
  defp format_message_summary(%{"to" => to}), do: "[send_message(#{to})]"
  defp format_message_summary(_), do: "[send_message]"

  defp format_api_summary(%{api_type: t, method: m, url: u}), do: "[call_api: #{t} #{m} #{u}]"

  defp format_api_summary(%{"api_type" => t, "method" => m, "url" => u}),
    do: "[call_api: #{t} #{m} #{u}]"

  defp format_api_summary(%{api_type: t, url: u}), do: "[call_api: #{t} #{u}]"
  defp format_api_summary(%{"api_type" => t, "url" => u}), do: "[call_api: #{t} #{u}]"
  defp format_api_summary(_), do: "[call_api]"

  defp format_mcp_summary(%{tool: tool}) when is_binary(tool), do: "[call_mcp: #{tool}]"
  defp format_mcp_summary(%{"tool" => tool}) when is_binary(tool), do: "[call_mcp: #{tool}]"

  defp format_mcp_summary(%{transport: t, command: c}),
    do: "[call_mcp: connect #{t} #{inspect(c)}]"

  defp format_mcp_summary(%{"transport" => t, "command" => c}),
    do: "[call_mcp: connect #{t} #{inspect(c)}]"

  defp format_mcp_summary(_), do: "[call_mcp]"

  defp format_wait_summary(%{wait: w}), do: "[wait: #{inspect(w)}]"
  defp format_wait_summary(%{"wait" => w}), do: "[wait: #{inspect(w)}]"
  defp format_wait_summary(_), do: "[wait]"

  defp format_orient_summary(%{current_situation: s}) when is_binary(s),
    do: "[orient: #{inspect(s)}]"

  defp format_orient_summary(%{"current_situation" => s}) when is_binary(s),
    do: "[orient: #{inspect(s)}]"

  defp format_orient_summary(_), do: "[orient]"

  defp format_todo_summary(%{items: items}) when is_list(items),
    do: "[todo: [#{length(items)} items]]"

  defp format_todo_summary(%{"items" => items}) when is_list(items),
    do: "[todo: [#{length(items)} items]]"

  defp format_todo_summary(_), do: "[todo]"

  defp format_secret_summary(%{name: n}), do: "[generate_secret: #{inspect(n)}]"
  defp format_secret_summary(%{"name" => n}), do: "[generate_secret: #{inspect(n)}]"
  defp format_secret_summary(_), do: "[generate_secret]"

  defp format_batch_sync_summary(%{actions: actions}) when is_list(actions) do
    action_names =
      Enum.map(actions, fn
        %{action: a} -> a
        %{"action" => a} -> a
      end)

    "[batch_sync: [#{Enum.join(action_names, ", ")}]]"
  end

  defp format_batch_sync_summary(%{"actions" => actions}) when is_list(actions) do
    action_names =
      Enum.map(actions, fn
        %{action: a} -> a
        %{"action" => a} -> a
      end)

    "[batch_sync: [#{Enum.join(action_names, ", ")}]]"
  end

  defp format_batch_sync_summary(_), do: "[batch_sync]"

  # batch_async: show SORTED action list (order-independent)
  defp format_batch_async_summary(%{actions: actions}) when is_list(actions) do
    action_names =
      actions
      |> Enum.map(fn
        %{action: a} -> a
        %{"action" => a} -> a
      end)
      |> Enum.sort()

    "[batch_async: [#{Enum.join(action_names, ", ")}]]"
  end

  defp format_batch_async_summary(%{"actions" => actions}) when is_list(actions) do
    action_names =
      actions
      |> Enum.map(fn
        %{action: a} -> a
        %{"action" => a} -> a
      end)
      |> Enum.sort()

    "[batch_async: [#{Enum.join(action_names, ", ")}]]"
  end

  defp format_batch_async_summary(_), do: "[batch_async]"

  @doc """
  Truncates a string to max_length, adding "..." if truncated.
  """
  @spec truncate_summary(String.t(), pos_integer()) :: String.t()
  def truncate_summary(str, max_length) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length - 3) <> "..."
    else
      str
    end
  end

  @doc """
  Formats reasoning history from previous rounds with action context.
  """
  @spec format_reasoning_history(list()) :: String.t()
  def format_reasoning_history(history) do
    history
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {round_responses, round_idx} ->
      entries =
        round_responses
        # Show up to 3 per round
        |> Enum.take(3)
        |> Enum.map_join("\n", fn response ->
          action_summary = format_action_summary(response)

          reasoning =
            case response[:reasoning] do
              nil -> "(no reasoning provided)"
              "" -> "(no reasoning provided)"
              r -> r
            end

          "  - #{action_summary} #{reasoning}"
        end)

      "Round #{round_idx}:\n#{entries}"
    end)
  end
end
