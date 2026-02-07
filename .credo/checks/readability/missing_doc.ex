defmodule Credo.Check.Readability.MissingDoc do
  @moduledoc """
  All public functions should have a `@doc` documentation string.

  ## Why This Matters

  Documentation is critical for:
  - **Maintainability** - Help future developers understand what the function does
  - **API clarity** - Communicate purpose and usage to consumers
  - **Team knowledge** - Share context without reading implementation
  - **Generated docs** - Enable ExDoc to produce quality documentation

  Without `@doc`, developers must read the implementation to understand
  what a function does, slowing down development and increasing mistakes.

  ## Bad Example

      # ❌ BAD: Public function without @doc
      def process_user(user, options) do
        # What does this do? What are valid options?
        # Future developers must read all this code
      end

  ## Good Example

      # ✅ GOOD: Clear documentation
      @doc \"""
      Processes a user with the given options.

      ## Options
        * `:send_email` - Whether to send confirmation email (default: true)
        * `:update_timestamp` - Whether to update last_seen (default: true)

      ## Examples

          iex> process_user(user, send_email: false)
          {:ok, %User{}}
      \"""
      @spec process_user(User.t(), keyword()) :: {:ok, User.t()} | {:error, term()}
      def process_user(user, options \\\\ []) do
        # Implementation
      end

  ## Exceptions

  This check allows omitting `@doc` for:
  - Private functions (`defp`) - internal implementation
  - Functions with `@doc false` (explicitly marked as internal)
  - Callbacks with `@impl` (documented by behaviour)
  - Macros (`defmacro`)
  - Test files

  ## Configuration

  This check runs on all non-test files with normal priority.
  Companion to MissingSpec check.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      All public functions should have a `@doc` documentation string.

      Documentation helps maintainability and enables ExDoc to generate
      quality API documentation for your modules.
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
      |> find_public_functions_without_doc()
      |> Enum.map(fn {name, line} -> issue_for(issue_meta, name, line) end)
    end
  end

  # Extract all function definitions and check for @doc
  defp find_public_functions_without_doc(ast) do
    {_ast, state} =
      Macro.prewalk(ast, %{functions: [], last_attributes: []}, fn node, acc ->
        analyze_node(node, acc)
      end)

    # Filter to public functions without @doc
    state.functions
    |> Enum.reject(fn {_name, _line, metadata} ->
      metadata[:has_doc] or metadata[:has_impl] or metadata[:has_doc_false]
    end)
    |> Enum.map(fn {name, line, _metadata} -> {name, line} end)
  end

  # Track module attributes (@doc, @impl, @doc false)
  defp analyze_node({:@, _, [{:doc, _, [doc_value]}]} = node, acc) do
    if doc_value == false do
      {node, %{acc | last_attributes: [:doc_false | acc.last_attributes]}}
    else
      {node, %{acc | last_attributes: [:doc | acc.last_attributes]}}
    end
  end

  defp analyze_node({:@, _, [{:impl, _, _}]} = node, acc) do
    {node, %{acc | last_attributes: [:impl | acc.last_attributes]}}
  end

  # Track public function definitions
  defp analyze_node({:def, meta, [{name, _, _args} | _]} = node, acc) when is_atom(name) do
    has_doc = :doc in acc.last_attributes
    has_impl = :impl in acc.last_attributes
    has_doc_false = :doc_false in acc.last_attributes

    function_info = {
      name,
      meta[:line],
      %{has_doc: has_doc, has_impl: has_impl, has_doc_false: has_doc_false}
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
      message: "Public function #{function_name}/_ is missing @doc documentation",
      trigger: "#{function_name}",
      line_no: line_no
    )
  end
end
