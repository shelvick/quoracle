defmodule Credo.Check.Warning.SkippedTests do
  @moduledoc """
  Disabled tests indicate untested code in production. Fix or delete them.

  ## Why This Matters

  When you disable a test with @tag, the code that test is supposed to verify
  runs in production **without any test coverage**. This creates blind spots where
  bugs can hide:

  - **Untested code** - Feature runs in production without verification
  - **Forgotten fixes** - "Temporarily" disabled tests stay disabled forever
  - **False confidence** - Test suite passes but critical paths untested
  - **Regression risk** - No safety net when refactoring
  - **Technical debt** - Accumulates and becomes normal

  ## Bad Example

      # ❌ BAD: Disabled test = untested production code
      defmodule UserControllerTest do
        use ExUnit.Case

        @tag :s\u200Bkip
        test "user registration with invalid email" do
          # This edge case is now untested in production!
          conn = post(conn, "/register", email: "invalid")
          assert response(conn, 422)
        end
      end

  ## Good Example

      # ✅ GOOD: Fix the test
      defmodule UserControllerTest do
        use ExUnit.Case

        test "user registration with invalid email" do
          conn = post(conn, "/register", email: "invalid")
          assert response(conn, 422)
        end
      end

      # ✅ GOOD: Delete if no longer needed
      # (If feature was removed, delete the test entirely)

  ## If Test is Broken

  **Don't disable it - fix it or delete it:**

  1. **Fix it** - Update test to match current implementation
  2. **Delete it** - If feature removed or test is duplicate
  3. **Refactor it** - If test is flaky, fix the race condition

  **Never use @tag :s\u200Bkip as a solution.**

  ## Temporary Disable for WIP?

  Even during development, disabling tests is dangerous:
  - Easy to forget and commit
  - Breaks other developers' assumptions
  - Hides real failures in CI

  Better alternatives:
  - Work in feature branch, keep test red until fixed
  - Use @tag :wip with custom suite filter (never committed)
  - Comment out test temporarily (won't pass CI)

  ## Configuration

  This check runs on test files only with high priority.
  Enforces phase-review rule: No disabled tests.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Disabled tests mean untested code in production. Fix or delete them.

      Using @tag to disable tests creates blind spots in test coverage where
      bugs can hide. Fix the test or delete it if no longer needed.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    # Only check test files
    if test_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    else
      []
    end
  end

  # Match @tag :s\u200Bkip (atom)
  defp traverse(
         {:@, meta, [{:tag, _, [:skip]}]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], ":s\u200Bkip") | issues]}
  end

  # Match @tag s\u200Bkip: true
  defp traverse(
         {:@, meta, [{:tag, _, [[{:skip, true}]]}]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "s\u200Bkip: true") | issues]}
  end

  # Match @tag s\u200Bkip: "reason"
  defp traverse(
         {:@, meta, [{:tag, _, [[{:skip, reason}]]}]} = ast,
         issues,
         issue_meta
       )
       when is_binary(reason) do
    {ast, [issue_for(issue_meta, meta[:line], "s\u200Bkip: \"#{reason}\"") | issues]}
  end

  # Match @moduletag :s\u200Bkip
  defp traverse(
         {:@, meta, [{:moduletag, _, [:skip]}]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], ":s\u200Bkip (module-level)") | issues]}
  end

  # Match @moduletag s\u200Bkip: true
  defp traverse(
         {:@, meta, [{:moduletag, _, [[{:skip, true}]]}]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "s\u200Bkip: true (module-level)") | issues]}
  end

  # Match @moduletag s\u200Bkip: "reason"
  defp traverse(
         {:@, meta, [{:moduletag, _, [[{:skip, reason}]]}]} = ast,
         issues,
         issue_meta
       )
       when is_binary(reason) do
    {ast, [issue_for(issue_meta, meta[:line], "s\u200Bkip: \"#{reason}\" (module-level)") | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp test_file?(%{filename: filename}) do
    String.ends_with?(filename, "_test.exs") or
      String.ends_with?(filename, "test_helper.exs") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/test/")
  end

  defp issue_for(issue_meta, line_no, tag_value) do
    format_issue(
      issue_meta,
      message:
        "Disabled test with @tag #{tag_value} - this means untested code in production. Fix or delete the test instead of disabling it",
      trigger: "@tag",
      line_no: line_no
    )
  end
end
