defmodule Credo.Check.Quality.MissingSpec do
  @moduledoc """
  All public functions must have a `@spec` type specification.

  ## Why This Matters

  Type specifications (`@spec`) are critical for:
  - **Documentation** - Communicate function contracts clearly
  - **Dialyzer** - Enable static type checking to catch bugs
  - **Maintenance** - Help future developers understand expected types
  - **Refactoring** - Catch breaking changes early

  Without `@spec`, Dialyzer can't provide meaningful type checking, and
  developers must read the implementation to understand the function contract.

  ## Bad Example

      # ❌ BAD: Public function without @spec
      def process_user(user, options) do
        # What types are user and options?
        # What does this return?
      end

  ## Good Example

      # ✅ GOOD: Clear type contract
      @spec process_user(User.t(), keyword()) :: {:ok, User.t()} | {:error, term()}
      def process_user(user, options) do
        # Implementation
      end

  ## Exceptions

  This check allows omitting `@spec` for:
  - Private functions (`defp`) - optional
  - Functions with `@doc false` (internal APIs)
  - Callbacks with `@impl` (specified by behaviour)
  - Macros (`defmacro`)
  - Test files

  ## Configuration

  This check runs on all non-test files with medium priority.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      All public functions should have a `@spec` type specification.

      Type specs enable Dialyzer type checking, document function contracts,
      and help maintain code quality over time.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    # Skip test files
    if test_file?(source_file) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.ast()
      |> find_public_functions_without_spec()
      |> Enum.map(fn {name, line} -> issue_for(issue_meta, name, line) end)
    end
  end

  # Extract all function definitions and check for @spec
  defp find_public_functions_without_spec(ast) do
    {_ast, state} =
      Macro.prewalk(ast, %{functions: [], last_attributes: []}, fn node, acc ->
        analyze_node(node, acc)
      end)

    # Filter to public functions without @spec
    state.functions
    |> Enum.reject(fn {_name, _line, metadata} ->
      metadata[:has_spec] or metadata[:has_impl] or metadata[:has_doc_false]
    end)
    |> Enum.map(fn {name, line, _metadata} -> {name, line} end)
  end

  # Track module attributes (@spec, @impl, @doc false)
  defp analyze_node({:@, _, [{attr_name, _, _}]} = node, acc) when attr_name in [:spec, :impl] do
    {node, %{acc | last_attributes: [attr_name | acc.last_attributes]}}
  end

  defp analyze_node({:@, _, [{:doc, _, [false]}]} = node, acc) do
    {node, %{acc | last_attributes: [:doc_false | acc.last_attributes]}}
  end

  # Track public function definitions
  defp analyze_node({:def, meta, [{name, _, _args} | _]} = node, acc) when is_atom(name) do
    has_spec = :spec in acc.last_attributes
    has_impl = :impl in acc.last_attributes
    has_doc_false = :doc_false in acc.last_attributes

    function_info = {
      name,
      meta[:line],
      %{has_spec: has_spec, has_impl: has_impl, has_doc_false: has_doc_false}
    }

    # Reset attributes after consuming them for this function
    {node, %{acc | functions: [function_info | acc.functions], last_attributes: []}}
  end

  # Ignore defp (private), defmacro, and other nodes
  defp analyze_node({def_type, _, _} = node, acc)
       when def_type in [:defp, :defmacro, :defmacrop] do
    # Reset attributes as they apply to this private/macro definition
    {node, %{acc | last_attributes: []}}
  end

  defp analyze_node(node, acc) do
    {node, acc}
  end

  defp test_file?(%{filename: filename}) do
    String.ends_with?(filename, "_test.exs") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/test/")
  end

  defp issue_for(issue_meta, function_name, line_no) do
    format_issue(
      issue_meta,
      message: "Public function #{function_name}/_ is missing @spec type specification",
      trigger: "#{function_name}",
      line_no: line_no
    )
  end
end
