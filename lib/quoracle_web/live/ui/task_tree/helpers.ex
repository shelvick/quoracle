defmodule QuoracleWeb.UI.TaskTree.Helpers do
  @moduledoc """
  Helper functions for TaskTree component.
  Extracted to keep TaskTree module under 500 lines.
  """

  @doc """
  Truncates a prompt string to the specified maximum length.
  """
  @spec truncate_prompt(String.t(), non_neg_integer()) :: String.t()
  def truncate_prompt(prompt, max_length) do
    if String.length(prompt) > max_length do
      String.slice(prompt, 0, max_length) <> "..."
    else
      prompt
    end
  end

  @doc """
  Formats a DateTime/NaiveDateTime to a human-readable string.
  """
  @spec format_timestamp(DateTime.t() | NaiveDateTime.t()) :: String.t()
  def format_timestamp(timestamp) do
    Calendar.strftime(timestamp, "%Y-%m-%d %H:%M:%S")
  end

  @doc """
  Returns the CSS class for a task status badge.
  """
  @spec status_badge_class(String.t()) :: String.t()
  def status_badge_class("running"), do: "px-2 py-1 text-xs bg-green-100 text-green-800 rounded"
  def status_badge_class("paused"), do: "px-2 py-1 text-xs bg-yellow-100 text-yellow-800 rounded"

  def status_badge_class("completed"),
    do: "px-2 py-1 text-xs bg-blue-100 text-blue-800 rounded"

  def status_badge_class("failed"), do: "px-2 py-1 text-xs bg-red-100 text-red-800 rounded"
  def status_badge_class(_), do: "px-2 py-1 text-xs bg-gray-100 text-gray-800 rounded"

  @doc """
  Returns the icon/emoji for a TODO state.
  """
  @spec state_icon(atom()) :: String.t()
  def state_icon(:todo), do: "⏳"
  def state_icon(:pending), do: "⏸️"
  def state_icon(:done), do: "✅"
  def state_icon(_), do: "⏳"

  @doc """
  Returns the CSS class for a TODO state.
  """
  @spec todo_state_class(atom()) :: String.t()
  def todo_state_class(:todo), do: "text-gray-700"
  def todo_state_class(:pending), do: "text-yellow-600"
  def todo_state_class(:done), do: "text-green-600 line-through opacity-60"
  def todo_state_class(_), do: "text-gray-700"
end
