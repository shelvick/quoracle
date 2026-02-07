defmodule Quoracle.Agent.ConsensusHandler.ChildrenInjector do
  @moduledoc """
  Handles children injection into consensus messages.
  Extracted from ConsensusHandler to maintain <500 line modules.
  """

  alias Quoracle.Agent.ConsensusHandler.Helpers

  @doc "Injects children context (up to 20) into last message. Returns messages unchanged if empty."
  @spec inject_children_context(map(), list(map())) :: list(map())
  def inject_children_context(state, messages) do
    children = Map.get(state, :children, [])
    registry = Map.get(state, :registry)

    if children == [] or messages == [] do
      messages
    else
      live_children = filter_live_children(children, registry)

      if live_children == [] do
        messages
      else
        inject_into_last_message(messages, Enum.take(live_children, 20))
      end
    end
  end

  @doc "Formats children as JSON objects within <children> wrapper."
  @spec format_children(list(map())) :: String.t()
  def format_children([]), do: "<children>\n</children>"

  def format_children(children) do
    json_lines =
      Enum.map(children, fn child ->
        %{
          "agent_id" => child.agent_id,
          "spawned_at" => format_timestamp(child.spawned_at),
          "status" => "active"
        }
        |> Jason.encode!()
      end)

    "<children>\n" <> Enum.join(json_lines, ",\n") <> "\n</children>\n"
  end

  @spec filter_live_children(list(map()), atom() | pid() | nil) :: list(map())
  defp filter_live_children(children, registry) do
    Enum.filter(children, fn child ->
      case safe_registry_lookup(registry, child.agent_id) do
        {:ok, _pid} -> true
        :not_found -> false
      end
    end)
  end

  defp safe_registry_lookup(nil, _agent_id), do: :not_found

  defp safe_registry_lookup(registry, agent_id) do
    try do
      case Registry.lookup(registry, {:agent, agent_id}) do
        [{pid, _}] -> {:ok, pid}
        [] -> :not_found
      end
    rescue
      _ -> :not_found
    catch
      _, _ -> :not_found
    end
  end

  # Handle both DateTime and NaiveDateTime for spawned_at
  # Uses RFC 2822 format for consistency with MessageTimestamp (LLM-facing)
  @spec format_timestamp(DateTime.t() | NaiveDateTime.t()) :: String.t()
  defp format_timestamp(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S +0000")

  defp format_timestamp(%NaiveDateTime{} = ndt),
    do: Calendar.strftime(ndt, "%a, %d %b %Y %H:%M:%S UTC")

  @spec inject_into_last_message(list(map()), list(map())) :: list(map())
  defp inject_into_last_message(messages, children) when is_list(messages) and messages != [] do
    children_str = format_children(children)

    List.update_at(messages, -1, fn last_msg ->
      original_content = Map.get(last_msg, :content, "")
      %{last_msg | content: Helpers.prepend_to_content(children_str, original_content)}
    end)
  end
end
