defmodule QuoracleWeb.UI.LogEntry.Helpers do
  @moduledoc """
  Helper functions for LogEntry component - formatting, styling, and data extraction.
  """

  import Phoenix.HTML, only: [raw: 1]

  @type log_level :: :debug | :info | :warn | :error | atom()

  # Timestamp formatting
  @spec format_timestamp(DateTime.t() | binary() | nil, log_level()) :: String.t()
  def format_timestamp(nil, _level), do: ""

  def format_timestamp(%DateTime{} = dt, level) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, dt)

    cond do
      # Handle future timestamps
      diff_seconds < 0 ->
        format_time_with_level(dt, level)

      diff_seconds < 60 ->
        "#{diff_seconds} seconds ago"

      diff_seconds < 3600 ->
        "#{div(diff_seconds, 60)} minutes ago"

      Date.compare(DateTime.to_date(dt), Date.utc_today()) == :eq ->
        format_time_with_level(dt, level)

      true ->
        Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
    end
  end

  def format_timestamp(timestamp, _level) when is_binary(timestamp), do: timestamp
  def format_timestamp(_, _), do: ""

  # Helper for time formatting with debug-level milliseconds
  @spec format_time_with_level(DateTime.t(), log_level()) :: String.t()
  defp format_time_with_level(dt, :debug) do
    {microseconds, _precision} = dt.microsecond
    milliseconds = div(microseconds, 1000)

    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [dt.hour, dt.minute, dt.second, milliseconds])
    |> IO.iodata_to_binary()
  end

  defp format_time_with_level(dt, _level), do: Calendar.strftime(dt, "%H:%M:%S")

  # Level styling
  @spec level_color_class(log_level()) :: String.t()
  def level_color_class(:error), do: "text-red-600 bg-red-100"
  def level_color_class(:warn), do: "text-yellow-600 bg-yellow-100"
  def level_color_class(:info), do: "text-blue-600 bg-blue-100"
  def level_color_class(:debug), do: "text-gray-600 bg-gray-100"
  def level_color_class(_), do: "text-gray-600"

  @spec level_time_class(log_level()) :: String.t()
  def level_time_class(:debug), do: "text-gray-400"
  def level_time_class(_), do: "text-gray-500"

  # Metadata formatting
  @spec format_metadata(map() | term()) :: String.t()
  def format_metadata(metadata) when is_map(metadata) do
    Enum.map_join(metadata, "\n", fn {k, v} -> "#{k}: #{format_metadata_value(v)}" end)
  end

  def format_metadata(_), do: ""

  @doc """
  Formats a metadata value for display.
  Decimals are converted to plain number strings (not inspected).
  Other types are converted appropriately.
  """
  @spec format_metadata_value(term()) :: String.t()
  def format_metadata_value(%Decimal{} = decimal) do
    Decimal.to_string(decimal)
  end

  def format_metadata_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def format_metadata_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  def format_metadata_value(%Date{} = d), do: Date.to_iso8601(d)
  def format_metadata_value(%Time{} = t), do: Time.to_iso8601(t)

  def format_metadata_value(value) when is_binary(value), do: value
  def format_metadata_value(value) when is_integer(value), do: Integer.to_string(value)
  def format_metadata_value(value) when is_float(value), do: Float.to_string(value)
  def format_metadata_value(value) when is_atom(value), do: Atom.to_string(value)

  def format_metadata_value(value) when is_map(value) do
    # Recursively format map values to handle nested Decimals properly
    formatted =
      Enum.map_join(value, ", ", fn {k, v} -> "#{k}: #{format_metadata_value(v)}" end)

    "{#{formatted}}"
  end

  def format_metadata_value(value) when is_list(value) do
    formatted =
      Enum.map(value, fn item ->
        format_metadata_value(item)
      end)

    "[#{Enum.join(formatted, ", ")}]"
  end

  def format_metadata_value(value), do: inspect(value)

  # LLM Response helpers
  @spec has_llm_responses?(map() | term()) :: boolean()
  def has_llm_responses?(metadata) when is_map(metadata) do
    responses = metadata[:raw_responses] || metadata["raw_responses"]
    is_list(responses) && responses != []
  end

  def has_llm_responses?(_), do: false

  # Sent messages helpers
  @spec has_sent_messages?(map() | term()) :: boolean()
  def has_sent_messages?(metadata) when is_map(metadata) do
    messages = metadata[:sent_messages] || metadata["sent_messages"]
    is_list(messages) && messages != []
  end

  def has_sent_messages?(_), do: false

  @spec format_model_id_for_sent(map() | term()) :: String.t()
  def format_model_id_for_sent(model_entry) when is_map(model_entry) do
    model_id = Map.get(model_entry, :model_id) || Map.get(model_entry, "model_id")

    cond do
      is_binary(model_id) -> model_id
      is_atom(model_id) -> Atom.to_string(model_id)
      true -> inspect(model_id)
    end
  end

  def format_model_id_for_sent(_), do: "Unknown Model"

  @spec get_sent_message_count(map() | term()) :: non_neg_integer()
  def get_sent_message_count(model_entry) when is_map(model_entry) do
    messages = Map.get(model_entry, :messages) || Map.get(model_entry, "messages") || []
    length(messages)
  end

  def get_sent_message_count(_), do: 0

  @spec format_sent_messages(map() | term()) :: String.t()
  def format_sent_messages(model_entry) when is_map(model_entry) do
    messages = Map.get(model_entry, :messages) || Map.get(model_entry, "messages") || []

    messages
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {msg, idx} ->
      role = Map.get(msg, :role) || Map.get(msg, "role") || "unknown"
      content = Map.get(msg, :content) || Map.get(msg, "content") || ""
      "--- Message #{idx} (#{role}) ---\n#{content}"
    end)
  end

  def format_sent_messages(_), do: ""

  # Helpers for nested message accordions
  @spec get_messages_from_entry(map() | term()) :: list()
  def get_messages_from_entry(model_entry) when is_map(model_entry) do
    Map.get(model_entry, :messages) || Map.get(model_entry, "messages") || []
  end

  def get_messages_from_entry(_), do: []

  @spec get_message_role(map() | term()) :: String.t()
  def get_message_role(msg) when is_map(msg) do
    Map.get(msg, :role) || Map.get(msg, "role") || "unknown"
  end

  def get_message_role(_), do: "unknown"

  @spec get_message_content(map() | term()) :: String.t()
  def get_message_content(msg) when is_map(msg) do
    content = Map.get(msg, :content) || Map.get(msg, "content") || ""
    stringify_content(content)
  end

  def get_message_content(_), do: ""

  # Convert content to string, handling multimodal content (list of maps)
  defp stringify_content(content) when is_binary(content), do: content

  defp stringify_content(content) when is_list(content) do
    # Multimodal content: [%{type: :text, text: "..."}, %{type: :image, ...}]
    Enum.map_join(content, "\n", &stringify_content_part/1)
  end

  defp stringify_content(content) when is_map(content), do: stringify_content_part(content)
  defp stringify_content(_), do: ""

  defp stringify_content_part(%{type: :text, text: text}) when is_binary(text), do: text
  defp stringify_content_part(%{type: :image}), do: "[Image]"
  defp stringify_content_part(%{type: :image_url, url: url}), do: "[Image: #{url}]"
  defp stringify_content_part(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp stringify_content_part(%{"type" => "image"}), do: "[Image]"
  defp stringify_content_part(%{"type" => "image_url", "url" => url}), do: "[Image: #{url}]"
  defp stringify_content_part(other) when is_map(other), do: inspect(other)
  defp stringify_content_part(other) when is_binary(other), do: other
  defp stringify_content_part(_), do: ""

  @spec truncate_content(String.t() | list() | term(), non_neg_integer()) :: String.t()
  def truncate_content(content, max_length) when is_binary(content) do
    if String.length(content) > max_length do
      String.slice(content, 0, max_length) <> "..."
    else
      content
    end
  end

  def truncate_content(content, max_length) when is_list(content) do
    truncate_content(stringify_content(content), max_length)
  end

  def truncate_content(_, _), do: ""

  # Role-based styling for message accordions
  @spec role_border_class(String.t()) :: String.t()
  def role_border_class("system"), do: "border-purple-200"
  def role_border_class("user"), do: "border-green-200"
  def role_border_class("assistant"), do: "border-blue-200"
  def role_border_class(_), do: "border-gray-200"

  @spec role_hover_class(String.t()) :: String.t()
  def role_hover_class("system"), do: "hover:bg-purple-50"
  def role_hover_class("user"), do: "hover:bg-green-50"
  def role_hover_class("assistant"), do: "hover:bg-blue-50"
  def role_hover_class(_), do: "hover:bg-gray-50"

  @spec role_text_class(String.t()) :: String.t()
  def role_text_class("system"), do: "text-purple-400"
  def role_text_class("user"), do: "text-green-400"
  def role_text_class("assistant"), do: "text-blue-400"
  def role_text_class(_), do: "text-gray-400"

  @spec role_badge_class(String.t()) :: String.t()
  def role_badge_class("system"), do: "bg-purple-100 text-purple-700"
  def role_badge_class("user"), do: "bg-green-100 text-green-700"
  def role_badge_class("assistant"), do: "bg-blue-100 text-blue-700"
  def role_badge_class(_), do: "bg-gray-100 text-gray-700"

  @spec role_content_bg(String.t()) :: String.t()
  def role_content_bg("system"), do: "bg-purple-50 border-purple-200"
  def role_content_bg("user"), do: "bg-green-50 border-green-200"
  def role_content_bg("assistant"), do: "bg-blue-50 border-blue-200"
  def role_content_bg(_), do: "bg-gray-50 border-gray-200"

  @spec format_model_name(map() | term()) :: String.t()
  def format_model_name(%{__struct__: _} = response) do
    Map.get(response, :model) || Map.get(response, :model_spec) || "Unknown Model"
  end

  def format_model_name(response) when is_map(response) do
    response[:model] || response["model"] ||
      response[:model_spec] || response["model_spec"] ||
      "Unknown Model"
  end

  def format_model_name(_), do: "Unknown Model"

  @spec format_response_stats(map() | term()) :: String.t()
  def format_response_stats(response) when is_map(response) do
    parts = []

    usage = Map.get(response, :usage) || Map.get(response, "usage")

    parts =
      if usage do
        total =
          Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") ||
            (Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0) +
              (Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0)

        if total > 0, do: ["#{total} tokens" | parts], else: parts
      else
        parts
      end

    latency = Map.get(response, :latency_ms) || Map.get(response, "latency_ms")

    parts =
      if latency do
        ["#{Float.round(latency / 1000, 1)}s" | parts]
      else
        parts
      end

    case parts do
      [] -> ""
      _ -> "(#{Enum.join(Enum.reverse(parts), ", ")})"
    end
  end

  def format_response_stats(_), do: ""

  @spec format_response_content(map() | term()) :: String.t()
  def format_response_content(%{__struct__: struct_name} = response) do
    if function_exported?(struct_name, :text, 1) do
      apply(struct_name, :text, [response]) || inspect(response, pretty: true)
    else
      Map.get(response, :content) || Map.get(response, :text) ||
        inspect(response, pretty: true, limit: :infinity)
    end
  end

  def format_response_content(response) when is_map(response) do
    content =
      Map.get(response, :content) || Map.get(response, "content") ||
        Map.get(response, :text) || Map.get(response, "text")

    case content do
      nil -> inspect(response, pretty: true, limit: :infinity)
      text when is_binary(text) -> text
      other -> inspect(other, pretty: true, limit: :infinity)
    end
  end

  def format_response_content(other), do: inspect(other, pretty: true, limit: :infinity)

  @spec highlight_message(binary() | term()) :: Phoenix.HTML.safe() | term()
  def highlight_message(message) when is_binary(message) do
    message
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(
      ~r/\bERROR\b/,
      "<span class=\"highlight font-bold text-red-600\">ERROR</span>"
    )
    |> String.replace(
      ~r/\bWARN\b/,
      "<span class=\"highlight font-bold text-yellow-600\">WARN</span>"
    )
    |> raw()
  end

  def highlight_message(message), do: message

  # Cost data helpers for per-request cost display
  @spec has_cost_data?(map() | term()) :: boolean()
  def has_cost_data?(metadata) when is_map(metadata) do
    get_cost_from_metadata(metadata) != nil
  end

  def has_cost_data?(_), do: false

  @spec get_cost_from_metadata(map() | term()) :: Decimal.t() | nil
  def get_cost_from_metadata(metadata) when is_map(metadata) do
    # Check direct cost_usd first
    direct_cost = metadata[:cost_usd] || metadata["cost_usd"]

    if direct_cost do
      direct_cost
    else
      # Check aggregate_usage.total_cost (from consensus logs)
      aggregate = metadata[:aggregate_usage] || metadata["aggregate_usage"]

      if is_map(aggregate) do
        aggregate[:total_cost] || aggregate["total_cost"]
      else
        nil
      end
    end
  end

  def get_cost_from_metadata(_), do: nil
end
