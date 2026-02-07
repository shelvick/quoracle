defmodule Credo.Check.Warning.GlobalAppConfigInTests do
  @moduledoc """
  Tests should not modify global Application configuration.

  ## Why This Is Critical

  `Application.put_env/3`, `Application.delete_env/2`, and `Application.put_all_env/1`
  modify global state visible to ALL processes. When tests modify Application config:

  1. **Breaks `async: true`** - Other concurrent tests see the modified values
  2. **Race conditions** - Even with cleanup, there's a window where other tests see wrong values
  3. **Non-deterministic failures** - Test order affects outcomes

  The "save and restore in on_exit" pattern is a band-aid, not a solution. There's still
  a race window between modification and cleanup where other tests can observe the change.

  ## Bad Example

      # ❌ BAD: Modifies global config (breaks async: true)
      test "uses custom timeout" do
        Application.put_env(:my_app, :timeout, 5000)
        assert MyModule.get_timeout() == 5000
      end

      # ❌ BAD: Even with cleanup, race window exists
      setup do
        original = Application.get_env(:my_app, :timeout)
        Application.put_env(:my_app, :timeout, 5000)
        on_exit(fn -> Application.put_env(:my_app, :timeout, original) end)
        :ok
      end

  ## Good Example

      # ✅ GOOD: Dependency injection - pass config as parameter
      test "uses custom timeout" do
        assert MyModule.get_timeout(timeout: 5000) == 5000
      end

      # ✅ GOOD: Design for testability
      defmodule MyModule do
        def get_timeout(opts \\ []) do
          Keyword.get_lazy(opts, :timeout, fn ->
            Application.get_env(:my_app, :timeout, 30_000)
          end)
        end
      end

      # ✅ GOOD: Use compile-time config for module attributes
      # (read once at compile time, not runtime)
      @timeout Application.compile_env(:my_app, :timeout, 30_000)

  ## Design Principle

  If your test needs to change Application config, your production code needs
  refactoring to accept that config as a parameter. This enables:

  - `async: true` for all tests
  - Deterministic test behavior
  - Clear dependency boundaries

  ## What This Check Detects

  - `Application.put_env/3` and `Application.put_env/4`
  - `Application.delete_env/2` and `Application.delete_env/3`
  - `Application.put_all_env/1` and `Application.put_all_env/2`
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Tests should not modify global Application configuration.

      Application config is global state. Modifying it breaks `async: true` and
      causes non-deterministic test failures. Use dependency injection instead -
      pass config as function parameters rather than mutating globals.
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

  # Application.put_env(app, key, value) or Application.put_env(app, key, value, opts)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Application]}, :put_env]}, _, _} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "Application.put_env") | issues]}
  end

  # Application.delete_env(app, key) or Application.delete_env(app, key, opts)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Application]}, :delete_env]}, _, _} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "Application.delete_env") | issues]}
  end

  # Application.put_all_env(config) or Application.put_all_env(config, opts)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Application]}, :put_all_env]}, _, _} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "Application.put_all_env") | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp test_file?(%{filename: filename}) do
    String.ends_with?(filename, "_test.exs") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/test/")
  end

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(
      issue_meta,
      message:
        "Avoid modifying global Application config in tests - use dependency injection instead",
      trigger: trigger,
      line_no: line_no
    )
  end
end
