defmodule Quoracle.Utils.BugReportLogger do
  @moduledoc """
  Isolated file logging for LLM self-reported bugs.
  All operations are failure-safe - never affects other code paths.
  """

  @default_path "/tmp/quoracle_bugs.log"

  @doc """
  Logs a bug report from an LLM model to a file.

  Always returns `:ok` - file operation failures are silently ignored
  to ensure logging never affects other code paths.

  ## Options
    * `:path` or `:log_path` - Override the default log path (for test isolation)
  """
  @spec log(String.t(), String.t(), keyword()) :: :ok
  def log(model_id, bug_report, opts \\ []) do
    path = Keyword.get(opts, :path) || Keyword.get(opts, :log_path, @default_path)

    try do
      entry = format_entry(model_id, bug_report)
      File.write!(path, entry, [:append])
    rescue
      _ -> :ok
    end

    :ok
  end

  defp format_entry(model_id, bug_report) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    "[#{timestamp}] [#{model_id}]\n#{bug_report}\n\n"
  end
end
