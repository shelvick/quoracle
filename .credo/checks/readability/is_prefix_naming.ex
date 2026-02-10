defmodule Credo.Check.Readability.IsPrefixNaming do
  @moduledoc """
  Function names should not use the `is_` prefix. Use the `?` suffix instead.

  ## Why This Matters

  Elixir convention for predicate functions (functions that return boolean values)
  is to use the `?` suffix, not the `is_` prefix. This makes the code more idiomatic
  and easier to read.

  The `is_` prefix is reserved for Kernel guard functions like `is_binary/1`,
  `is_atom/1`, etc.

  ## Bad Example

      # ❌ BAD: is_ prefix
      def is_valid(data) do
        not is_nil(data)
      end

      def is_empty(list) do
        list == []
      end

      def is_active(user) do
        user.status == :active
      end

  ## Good Example

      # ✅ GOOD: ? suffix
      def valid?(data) do
        not is_nil(data)
      end

      def empty?(list) do
        list == []
      end

      def active?(user) do
        user.status == :active
      end

  ## Kernel Functions

  Kernel guard functions like `is_nil/1`, `is_binary/1`, `is_atom/1` are fine
  to use - this check only flags function **definitions**, not function calls.

  ## Configuration

  This check runs on all files with normal priority.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      Function names should use `?` suffix for predicates, not `is_` prefix.

      Elixir convention is `valid?/1` not `is_valid/1`. The `is_` prefix is
      reserved for Kernel guard functions.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Credo.Code.ast()
    |> find_is_prefix_functions()
    |> Enum.map(fn {name, line} -> issue_for(issue_meta, name, line) end)
  end

  # Find all function definitions with is_ prefix
  defp find_is_prefix_functions(ast) do
    {_ast, functions} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          # Match def with is_ prefix
          {:def, meta, [{name, _, _args} | _]} when is_atom(name) ->
            if has_is_prefix?(name) do
              {node, [{name, meta[:line]} | acc]}
            else
              {node, acc}
            end

          # Match defp with is_ prefix
          {:defp, meta, [{name, _, _args} | _]} when is_atom(name) ->
            if has_is_prefix?(name) do
              {node, [{name, meta[:line]} | acc]}
            else
              {node, acc}
            end

          _ ->
            {node, acc}
        end
      end)

    functions
  end

  defp has_is_prefix?(name) when is_atom(name) do
    name_str = Atom.to_string(name)
    String.starts_with?(name_str, "is_")
  end

  defp has_is_prefix?(_), do: false

  defp issue_for(issue_meta, function_name, line_no) do
    # Convert is_valid to valid?
    suggested_name = suggest_correct_name(function_name)

    format_issue(
      issue_meta,
      message: "Function #{function_name}/_ uses is_ prefix - use #{suggested_name}/_ instead",
      trigger: "#{function_name}",
      line_no: line_no
    )
  end

  defp suggest_correct_name(name) do
    name
    |> Atom.to_string()
    |> String.replace_prefix("is_", "")
    |> Kernel.<>("?")
  end
end
