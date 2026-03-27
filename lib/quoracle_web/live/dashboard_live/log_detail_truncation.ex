defmodule QuoracleWeb.DashboardLive.LogDetailTruncation do
  @moduledoc """
  Truncation and lazy-load storage logic for log entry metadata.

  Handles truncating raw_responses[].text and sent_messages[].messages[].content
  to a character limit, marking truncated entries with `truncated?: true`, and
  managing the bounded `log_details` map for full-detail lazy loading.
  """

  @detail_text_limit 200
  @max_log_details 500

  @doc "Truncate buffered logs from EventHistory at mount time, returning {truncated_logs_map, log_details_map}."
  @spec truncate_buffered_logs(map()) :: {map(), map()}
  def truncate_buffered_logs(logs_map) when is_map(logs_map) do
    Enum.reduce(logs_map, {%{}, %{}}, fn {agent_id, logs}, {truncated_acc, details_acc} ->
      {truncated_logs, new_details} =
        Enum.reduce(logs, {[], details_acc}, fn log, {log_acc, det_acc} ->
          log_id = log[:id]
          metadata = log[:metadata]

          det_acc =
            if log_id && is_map(metadata) && has_lazy_load_metadata?(metadata) do
              Map.put(det_acc, log_id, metadata)
            else
              det_acc
            end

          {[truncate_log_metadata(log) | log_acc], det_acc}
        end)

      {Map.put(truncated_acc, agent_id, Enum.reverse(truncated_logs)), new_details}
    end)
    |> then(fn {truncated, details} -> {truncated, trim_log_details(details)} end)
  end

  def truncate_buffered_logs(_), do: {%{}, %{}}

  @doc "Truncate a single log entry's metadata in-place."
  @spec truncate_log_metadata(map()) :: map()
  def truncate_log_metadata(log) do
    metadata = log[:metadata]

    if is_map(metadata) do
      truncated_metadata =
        metadata
        |> maybe_truncate_raw_responses()
        |> maybe_truncate_sent_messages()

      %{log | metadata: truncated_metadata}
    else
      log
    end
  end

  @doc "Check if metadata contains fields that benefit from lazy-load truncation."
  @spec has_lazy_load_metadata?(map() | term()) :: boolean()
  def has_lazy_load_metadata?(metadata) when is_map(metadata) do
    list_present?(Map.get(metadata, :raw_responses) || Map.get(metadata, "raw_responses")) or
      list_present?(Map.get(metadata, :sent_messages) || Map.get(metadata, "sent_messages"))
  end

  def has_lazy_load_metadata?(_), do: false

  @doc "Store a log detail entry, evicting oldest if over the cap."
  @spec store_and_trim(map(), term(), map()) :: map()
  def store_and_trim(details, log_id, metadata) do
    details
    |> Map.put(log_id, metadata)
    |> trim_log_details()
  end

  @doc "Evict oldest entries if the details map exceeds the cap."
  @spec trim_log_details(map()) :: map()
  def trim_log_details(details) when map_size(details) > @max_log_details do
    details
    |> Enum.sort_by(fn {id, _detail} -> id end)
    |> Enum.drop(map_size(details) - @max_log_details)
    |> Map.new()
  end

  def trim_log_details(details), do: details

  # Private helpers

  @spec list_present?(term()) :: boolean()
  defp list_present?(value), do: is_list(value) and value != []

  @spec maybe_truncate_raw_responses(map()) :: map()
  defp maybe_truncate_raw_responses(metadata) do
    case Map.get(metadata, :raw_responses) || Map.get(metadata, "raw_responses") do
      responses when is_list(responses) ->
        put_preserving_key(
          metadata,
          :raw_responses,
          Enum.map(responses, &truncate_response_text/1)
        )

      _ ->
        metadata
    end
  end

  @spec maybe_truncate_sent_messages(map()) :: map()
  defp maybe_truncate_sent_messages(metadata) do
    case Map.get(metadata, :sent_messages) || Map.get(metadata, "sent_messages") do
      sent_messages when is_list(sent_messages) ->
        truncated =
          Enum.map(sent_messages, fn model_entry ->
            case Map.get(model_entry, :messages) || Map.get(model_entry, "messages") do
              messages when is_list(messages) ->
                put_preserving_key(
                  model_entry,
                  :messages,
                  Enum.map(messages, &truncate_message_content/1)
                )

              _ ->
                model_entry
            end
          end)

        put_preserving_key(metadata, :sent_messages, truncated)

      _ ->
        metadata
    end
  end

  @spec truncate_response_text(map() | term()) :: map() | term()
  defp truncate_response_text(response) when is_map(response) do
    case Map.get(response, :text) || Map.get(response, "text") do
      text when is_binary(text) ->
        if String.length(text) > @detail_text_limit do
          response
          |> put_preserving_key(:text, String.slice(text, 0, @detail_text_limit) <> "...")
          |> put_preserving_key(:truncated?, true)
        else
          response
        end

      _ ->
        response
    end
  end

  defp truncate_response_text(response), do: response

  @spec truncate_message_content(map() | term()) :: map() | term()
  defp truncate_message_content(message) when is_map(message) do
    case Map.get(message, :content) || Map.get(message, "content") do
      content when is_binary(content) ->
        if String.length(content) > @detail_text_limit do
          message
          |> put_preserving_key(:content, String.slice(content, 0, @detail_text_limit) <> "...")
          |> put_preserving_key(:truncated?, true)
        else
          message
        end

      _ ->
        message
    end
  end

  defp truncate_message_content(message), do: message

  @spec put_preserving_key(map(), atom(), term()) :: map()
  defp put_preserving_key(map, key, value) do
    string_key = Atom.to_string(key)

    case {Map.has_key?(map, key), Map.has_key?(map, string_key)} do
      {true, _} -> Map.put(map, key, value)
      {false, true} -> Map.put(map, string_key, value)
      {false, false} -> Map.put(map, key, value)
    end
  end
end
