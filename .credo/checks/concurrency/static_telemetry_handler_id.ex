defmodule Credo.Check.Concurrency.StaticTelemetryHandlerId do
  @moduledoc """
  Telemetry handlers in async tests should use unique IDs, not static strings.

  ## Why This Is Critical

  Global `:telemetry` handlers capture events from ALL parallel tests. When tests
  use static handler IDs (strings), events from concurrent tests pollute each
  other's handlers, causing count/order assertions to fail randomly.

  ## Bad Example

      # ❌ BAD: Static handler ID in async test
      defmodule MyTest do
        use ExUnit.Case, async: true

        test "tracks events" do
          :telemetry.attach("my_handler", [:app, :event], handler_fn, nil)
          # Test A and Test B both see each other's events!
        end
      end

  ## Good Example

      # ✅ GOOD: Unique handler ID per test + cleanup
      defmodule MyTest do
        use ExUnit.Case, async: true

        setup do
          handler_id = {:test_handler, System.unique_integer([:positive])}
          :telemetry.attach(handler_id, [:app, :event], handler_fn, nil)
          on_exit(fn -> :telemetry.detach(handler_id) end)
          %{handler_id: handler_id}
        end
      end

  ## Configuration

  This check only runs on test files with `async: true`.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Telemetry handlers in async tests should use unique IDs.

      Static string IDs cause cross-test pollution in parallel execution.
      Use tuples with unique integers instead, and always detach in on_exit.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    # Only check async test files
    if test_file?(source_file) and has_async_true?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.ast()
      |> find_static_telemetry_handlers()
      |> Enum.map(fn line -> issue_for(issue_meta, line) end)
    else
      []
    end
  end

  defp find_static_telemetry_handlers(ast) do
    {_ast, violations} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          # Match: :telemetry.attach("static_string", ...)
          {{:., meta, [{:__aliases__, _, [:telemetry]}, :attach]}, _,
           [handler_id | _rest]} ->
            if static_string?(handler_id) do
              {node, [meta[:line] | acc]}
            else
              {node, acc}
            end

          # Match: :telemetry.attach_many("static_string", ...)
          {{:., meta, [{:__aliases__, _, [:telemetry]}, :attach_many]}, _,
           [handler_id | _rest]} ->
            if static_string?(handler_id) do
              {node, [meta[:line] | acc]}
            else
              {node, acc}
            end

          # Match atom form: :telemetry.attach("static_string", ...)
          {{:., meta, [:telemetry, :attach]}, _, [handler_id | _rest]} ->
            if static_string?(handler_id) do
              {node, [meta[:line] | acc]}
            else
              {node, acc}
            end

          {{:., meta, [:telemetry, :attach_many]}, _, [handler_id | _rest]} ->
            if static_string?(handler_id) do
              {node, [meta[:line] | acc]}
            else
              {node, acc}
            end

          _ ->
            {node, acc}
        end
      end)

    violations
  end

  # Check if handler_id is a static string literal
  defp static_string?(handler_id) do
    case handler_id do
      # Binary string literal
      str when is_binary(str) -> true
      # Interpolated string
      {:<<>>, _, _} -> true
      # Anything else (variables, tuples, function calls) is OK
      _ -> false
    end
  end

  defp has_async_true?(source_file) do
    source_file
    |> Credo.Code.ast()
    |> check_for_async_true()
  end

  defp check_for_async_true(ast) do
    {_ast, has_async} =
      Macro.prewalk(ast, false, fn node, acc ->
        case node do
          {:use, _, [{:__aliases__, _, [:ExUnit, :Case]}, opts]} ->
            if Keyword.get(opts, :async) == true do
              {node, true}
            else
              {node, acc}
            end

          _ ->
            {node, acc}
        end
      end)

    has_async
  end

  defp test_file?(%{filename: filename}) do
    String.ends_with?(filename, "_test.exs") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/test/")
  end

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Static telemetry handler ID in async test - use unique ID like {:handler, System.unique_integer()}",
      trigger: ":telemetry.attach",
      line_no: line_no
    )
  end
end
