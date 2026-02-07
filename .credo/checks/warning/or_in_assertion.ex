defmodule Credo.Check.Warning.OrInAssertion do
  @moduledoc """
  Flags `assert X or Y` patterns in test files.

  ## Why This Matters

  OR assertions are almost always cheating - they pass if ANY condition is true,
  which often means passing on implementation details (CSS classes, data attributes)
  rather than user-visible content:

  - **False positives** - Test passes when wrong condition is true
  - **Weak verification** - Doesn't actually test what user sees
  - **Hidden failures** - Real bugs masked by alternate condition
  - **Maintenance debt** - Which condition is "correct" becomes unclear

  ## Bad Example

      # ❌ BAD: Passes if EITHER condition is true
      test "displays cost to user" do
        {:ok, view, html} = live(conn, "/dashboard")
        # This passes on CSS class even if actual cost text is missing!
        assert html =~ "$0.08" or html =~ "cost-badge"
      end

  ## Good Example

      # ✅ GOOD: Asserts exactly what user should see
      test "displays cost to user" do
        {:ok, view, html} = live(conn, "/dashboard")
        assert html =~ "$0.08"
      end

  ## Why LLMs Write OR Assertions

  LLMs optimize for "tests pass" not "feature works". When unsure what the
  implementation will produce, they hedge with OR to guarantee a pass:

  - Unsure of exact text format → OR with multiple formats
  - Unsure if feature renders → OR with CSS class (always present)
  - Unsure of error message → OR with generic fallback

  This defeats the purpose of TDD - tests should verify ONE specific behavior.

  ## Valid Alternatives

  If you genuinely need to test multiple valid states:

      # ✅ GOOD: Separate tests for each case
      test "shows formatted cost" do
        assert html =~ "$0.08"
      end

      test "shows cost badge styling" do
        assert html =~ "cost-badge"
      end

      # ✅ GOOD: Test the actual requirement
      test "shows cost in dollars" do
        assert html =~ ~r/\$\d+\.\d{2}/
      end

  ## Configuration

  This check runs on test files only with high priority.
  Part of acceptance test quality enforcement.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      OR assertions in tests almost always indicate weak verification.
      They pass when ANY condition is true, often hiding real failures.
      Assert exactly what the user should see, not alternatives.
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

  # Match assert(X or Y) - the `or` is inside the assert call
  defp traverse(
         {:assert, meta, [{:or, _, _}]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "assert", "or") | issues]}
  end

  # Match assert X or Y without parens - `or` wraps the assert
  # AST: {:or, _, [{:assert, _, [left]}, right]}
  defp traverse(
         {:or, meta, [{:assert, _, _}, _]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "assert", "or") | issues]}
  end

  # Match assert(X || Y) - the `||` is inside the assert call
  # AST for ||: {:||, meta, [left, right]}
  defp traverse(
         {:assert, meta, [{:||, _, _}]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "assert", "||") | issues]}
  end

  # Match assert X || Y without parens - `||` wraps the assert
  defp traverse(
         {:||, meta, [{:assert, _, _}, _]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "assert", "||") | issues]}
  end

  # Match refute(X or Y)
  defp traverse(
         {:refute, meta, [{:or, _, _}]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "refute", "or") | issues]}
  end

  # Match refute X or Y without parens
  defp traverse(
         {:or, meta, [{:refute, _, _}, _]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "refute", "or") | issues]}
  end

  # Match refute(X || Y)
  defp traverse(
         {:refute, meta, [{:||, _, _}]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "refute", "||") | issues]}
  end

  # Match refute X || Y without parens
  defp traverse(
         {:||, meta, [{:refute, _, _}, _]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "refute", "||") | issues]}
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

  defp issue_for(issue_meta, line_no, assertion_type, operator) do
    format_issue(
      issue_meta,
      message:
        "#{assertion_type} with `#{operator}` - this passes when ANY condition is true, often hiding real failures. Assert exactly what the user should see.",
      trigger: operator,
      line_no: line_no
    )
  end
end
