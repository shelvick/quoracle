defmodule Credo.Check.Warning.GlobalLoggerConfigInTests do
  @moduledoc """
  Tests should not modify global Logger configuration.

  ## Why This Is Critical

  Logger configuration is global state. When tests modify it, they affect all
  other tests running concurrently, causing non-deterministic failures that are
  difficult to debug.

  ## Bad Example

      # ❌ BAD: Modifies global Logger config
      test "logs at debug level" do
        Logger.configure(level: :debug)
        # Other tests now see debug level too!
        MyModule.do_work()
        assert_receive {:log, :debug, _}
      end

      # ❌ BAD: Modifies Logger via Application.put_env
      setup do
        Application.put_env(:logger, :level, :warning)
        :ok
      end

  ## Good Example

      # ✅ GOOD: Capture logs without changing global config
      import ExUnit.CaptureLog

      test "logs warning message" do
        log = capture_log(fn ->
          MyModule.do_work()
        end)

        assert log =~ "Something happened"
      end

      # ✅ GOOD: Use log metadata for test-specific filtering
      test "logs with request_id" do
        Logger.metadata(request_id: "test-123")
        # Metadata is process-local, not global
      end

      # ✅ GOOD: If you must change config, save and restore
      setup do
        original_level = Logger.level()
        on_exit(fn -> Logger.configure(level: original_level) end)
        :ok
      end

  ## What This Check Detects

  - `Logger.configure/1`
  - `Logger.configure_backend/2`
  - `Application.put_env(:logger, ...)`
  - `Application.put_all_env([{:logger, ...}, ...])`
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Tests should not modify global Logger configuration.

      Logger config is global state shared by all concurrent tests. Use
      `ExUnit.CaptureLog` or `Logger.metadata/1` (process-local) instead.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    if test_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    else
      []
    end
  end

  # Logger.configure(...)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Logger]}, :configure]}, _, _} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "Logger.configure/1") | issues]}
  end

  # Logger.configure_backend(...)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Logger]}, :configure_backend]}, _, _} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "Logger.configure_backend/2") | issues]}
  end

  # Application.put_env(:logger, ...)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Application]}, :put_env]}, _, [:logger | _]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "Application.put_env(:logger, ...)") | issues]}
  end

  # Application.put_all_env([{:logger, ...}, ...]) - check if :logger is in the list
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Application]}, :put_all_env]}, _, [env_list | _]} = ast,
         issues,
         issue_meta
       )
       when is_list(env_list) do
    if Enum.any?(env_list, &logger_env_tuple?/1) do
      {ast, [issue_for(issue_meta, meta[:line], "Application.put_all_env with :logger") | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp logger_env_tuple?({:logger, _}), do: true
  defp logger_env_tuple?(_), do: false

  defp test_file?(%{filename: filename}) do
    String.ends_with?(filename, "_test.exs") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/test/")
  end

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(
      issue_meta,
      message: "Avoid modifying global Logger config in tests - use ExUnit.CaptureLog instead",
      trigger: trigger,
      line_no: line_no
    )
  end
end
