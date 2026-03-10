defmodule Quoracle.Agent.ConsensusHandler.ChildrenInjector do
  @moduledoc """
  Handles children injection into consensus messages.
  Extracted from ConsensusHandler to maintain <500 line modules.

  v2.0: Message enrichment — cross-references state.messages to show
  latest_message_preview and latest_message_at per child in consensus context.
  """

  alias Quoracle.Agent.ConsensusHandler.Helpers

  @max_message_length 100

  @doc "Injects children context (up to 20) into last message. Returns messages unchanged only if messages empty."
  @spec inject_children_context(map(), list(map())) :: list(map())
  def inject_children_context(state, messages) do
    if messages == [], do: messages, else: inject_children_block(state, messages)
  end

  defp inject_children_block(state, messages) do
    children = Map.get(state, :children, [])
    registry = Map.get(state, :registry)
    live_children = if children == [], do: [], else: filter_live_children(children, registry)

    if live_children == [] do
      inject_empty_children(messages)
    else
      inbox = Map.get(state, :messages, [])
      enriched = enrich_with_messages(Enum.take(live_children, 20), inbox)
      inject_into_last_message(messages, enriched)
    end
  end

  defp inject_empty_children(messages) do
    List.update_at(messages, -1, fn last_msg ->
      original_content = Map.get(last_msg, :content, "")
      empty_block = "<children>No child agents running.</children>\n"
      %{last_msg | content: Helpers.prepend_to_content(empty_block, original_content)}
    end)
  end

  @doc "Formats children as JSON objects within <children> wrapper."
  @spec format_children(list(map())) :: String.t()
  def format_children([]), do: "<children>\n</children>"

  def format_children(children) do
    json_lines = Enum.map(children, &(child_to_json_map(&1) |> Jason.encode!()))
    "<children>\n" <> Enum.join(json_lines, ",\n") <> "\n</children>\n"
  end

  # Builds a JSON-ready map from a child entry. Handles both enriched children
  # (with latest_message_preview fields from enrich_with_messages) and unenriched children
  # (direct format_children calls without message enrichment).
  @spec child_to_json_map(map()) :: map()
  defp child_to_json_map(child) do
    base = %{
      "agent_id" => child.agent_id,
      "spawned_at" => format_timestamp(child.spawned_at)
    }

    if Map.has_key?(child, :latest_message_preview) do
      Map.merge(base, %{
        "latest_message_preview" => child.latest_message_preview,
        "latest_message_at" => format_nullable_timestamp(child.latest_message_at)
      })
    else
      base
    end
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

  # Enrich children with latest message data from the agent's inbox.
  # Cross-references each child's agent_id against inbox messages to find
  # the most recent message (by timestamp) from that child.
  @spec enrich_with_messages(list(map()), list(map())) :: list(map())
  defp enrich_with_messages(children, inbox) do
    # Group inbox messages by sender, keeping only messages from children
    child_ids = MapSet.new(children, & &1.agent_id)

    latest_by_sender =
      inbox
      |> Enum.filter(&MapSet.member?(child_ids, &1.from))
      |> Enum.group_by(& &1.from)
      |> Map.new(fn {sender, msgs} ->
        {sender, Enum.max_by(msgs, & &1.timestamp, DateTime)}
      end)

    Enum.map(children, fn child ->
      case Map.get(latest_by_sender, child.agent_id) do
        nil ->
          Map.merge(child, %{latest_message_preview: nil, latest_message_at: nil})

        msg ->
          Map.merge(child, %{
            latest_message_preview: truncate_message(msg.content),
            latest_message_at: msg.timestamp
          })
      end
    end)
  end

  @spec truncate_message(String.t()) :: String.t()
  defp truncate_message(content) do
    if String.length(content) > @max_message_length do
      String.slice(content, 0, @max_message_length) <> "..."
    else
      content
    end
  end

  # Handle both DateTime and NaiveDateTime for spawned_at
  # Uses RFC 2822 format for consistency with MessageTimestamp (LLM-facing)
  @spec format_timestamp(DateTime.t() | NaiveDateTime.t()) :: String.t()
  defp format_timestamp(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S +0000")

  defp format_timestamp(%NaiveDateTime{} = ndt),
    do: Calendar.strftime(ndt, "%a, %d %b %Y %H:%M:%S UTC")

  @spec format_nullable_timestamp(DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  defp format_nullable_timestamp(nil), do: nil
  defp format_nullable_timestamp(dt), do: format_timestamp(dt)

  @spec inject_into_last_message(list(map()), list(map())) :: list(map())
  defp inject_into_last_message(messages, children) when is_list(messages) and messages != [] do
    children_str = format_children(children)

    List.update_at(messages, -1, fn last_msg ->
      original_content = Map.get(last_msg, :content, "")
      %{last_msg | content: Helpers.prepend_to_content(children_str, original_content)}
    end)
  end
end
