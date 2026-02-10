defmodule Credo.Check.Warning.NoStringToAtom do
  @moduledoc """
  `String.to_atom/1` should not be used on user input as it causes memory exhaustion.

  ## Why This Is Critical

  Atoms are **never garbage collected** in the BEAM. Using `String.to_atom/1` on
  user-controlled input creates a memory leak that can crash your application.

  Attackers can send many unique strings, each creating a new atom, until the atom
  table limit (1,048,576 atoms by default) is reached, causing the VM to crash.

  ## Bad Example

      # ❌ BAD: User input → atom (memory leak!)
      def handle_request(%{"action" => action}) do
        # Attacker can send 1M unique actions
        action_atom = String.to_atom(action)
        process_action(action_atom)
      end

      # ❌ BAD: Dynamic keys from external API
      def parse_response(json) do
        for {key, value} <- json, into: %{} do
          {String.to_atom(key), value}  # Memory leak!
        end
      end

  ## Good Example

      # ✅ GOOD: Pattern match on known atoms
      def handle_request(%{"action" => action}) do
        case action do
          "create" -> process_action(:create)
          "update" -> process_action(:update)
          "delete" -> process_action(:delete)
          _ -> {:error, :invalid_action}
        end
      end

      # ✅ GOOD: Use String.to_existing_atom (fails if atom doesn't exist)
      def safe_convert(str) do
        try do
          {:ok, String.to_existing_atom(str)}
        rescue
          ArgumentError -> {:error, :unknown_atom}
        end
      end

      # ✅ GOOD: Keep as strings
      def parse_response(json) do
        json  # Just use string keys
      end

  ## Exceptions

  This check allows `String.to_atom/1` in:
  - Test files (testing purposes)
  - With literal string arguments (compile-time safe, e.g., `String.to_atom("production")`)

  ## Configuration

  This check has high priority and runs on all non-test files.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Avoid using `String.to_atom/1` on user input.

      Atoms are never garbage collected. Converting user input to atoms creates
      a memory leak that attackers can exploit to crash your application.

      Use pattern matching on known atoms or `String.to_existing_atom/1` instead.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    # Allow in test files
    if test_file?(source_file) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  # Match String.to_atom(arg) calls
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:String]}, :to_atom]}, _, [arg]} = ast,
         issues,
         issue_meta
       ) do
    # Allow literal strings (compile-time safe)
    if literal_string?(arg) do
      {ast, issues}
    else
      {ast, [issue_for(issue_meta, meta[:line]) | issues]}
    end
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  # Check if argument is a literal string (compile-time constant)
  defp literal_string?({:<<>>, _, _}), do: true
  defp literal_string?(str) when is_binary(str), do: true
  defp literal_string?(_), do: false

  defp test_file?(%{filename: filename}) do
    String.ends_with?(filename, "_test.exs") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/test/")
  end

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Avoid String.to_atom on user input - atoms are never GC'd (use String.to_existing_atom or pattern match)",
      trigger: "String.to_atom",
      line_no: line_no
    )
  end
end
