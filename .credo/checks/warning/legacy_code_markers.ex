defmodule Credo.Check.Warning.LegacyCodeMarkers do
  @moduledoc """
  No legacy, deprecated, or versioned function names. Make clean breaks.

  ## Why This Matters

  Function names with `_deprecated`, `_legacy`, `_old`, or `_v2` suffixes indicate
  **dual code paths** - keeping both old and new implementations side by side.

  This is a sign of:
  - **Technical debt accumulation** - Old code that should be deleted
  - **Maintenance burden** - Two implementations to maintain and test
  - **Confusion** - Which version should be used?
  - **Broken migration** - Old code never gets removed
  - **Feature creep** - Multiple ways to do the same thing

  ## Phase-Review Rule: ZERO TOLERANCE

  From phase-review.md:
  > "Dual code paths (old+new implementations side by side)"
  > "Legacy or deprecated functions kept around"
  > "Every dual path doubles maintenance burden"
  > "Clean breaks force proper migration"

  ## Bad Example

      # ❌ BAD: Dual code paths
      defmodule UserService do
        # New implementation
        def create_user(attrs) do
          # New logic with validation
        end

        # Old implementation kept "just in case"
        def create_user_legacy(attrs) do
          # Old logic without validation
        end

        # Version suffix indicates dual implementation
        def process_v2(data) do
          # New version, but v1 still exists somewhere
        end
      end

  ## Good Example

      # ✅ GOOD: Single implementation only
      defmodule UserService do
        def create_user(attrs) do
          # Current implementation - this is the only way
        end
      end

      # ✅ GOOD: Clean migration
      # 1. Deploy new code with new function name
      # 2. Update all callers in separate deploy
      # 3. Delete old function completely
      # Result: Only one implementation exists at a time

  ## How to Migrate Without Dual Paths

  **Wrong approach (dual path):**
  ```elixir
  # Step 1: Add new function, keep old
  def process(data), do: process_new(data)  # Adapter
  def process_new(data), do: ...  # New implementation
  ```

  **Right approach (clean break):**
  ```elixir
  # Step 1: Rename old function
  def process_data(data), do: ...  # Different name, no conflict

  # Step 2: Update all callers to new name
  # Step 3: Delete old function entirely
  ```

  ## Version Suffixes

  Suffixes like `_v2`, `_v3` indicate multiple versions exist:
  - `process_v2` implies `process_v1` exists (or existed)
  - Both must be maintained
  - Callers must choose which version
  - Creates cognitive overhead

  **Better:** Just name it `process`. If breaking change, make clean migration.

  ## Exceptions

  This check allows legacy markers in test files where they're used to test
  backward compatibility or migration scenarios.

  ## Configuration

  This check runs on production code (lib/) with high priority.
  Enforces phase-review ZERO TOLERANCE rule for dual code paths.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      No legacy/deprecated/versioned function names - make clean breaks.

      Function names with _deprecated, _legacy, _old, or _v2 suffixes indicate
      dual code paths. Delete the old implementation and keep only the new one.
      """
    ]

  # Legacy suffixes to detect
  @legacy_suffixes [
    "_deprecated",
    "_legacy",
    "_old"
  ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    # Only check production code
    if production_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.ast()
      |> find_legacy_functions()
      |> Enum.map(fn {name, line} -> issue_for(issue_meta, name, line) end)
    else
      []
    end
  end

  # Find all function definitions with legacy markers
  defp find_legacy_functions(ast) do
    {_ast, functions} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          # Match public functions
          {:def, meta, [{name, _, _args} | _]} when is_atom(name) ->
            if legacy_function?(name) do
              {node, [{name, meta[:line]} | acc]}
            else
              {node, acc}
            end

          # Match private functions
          {:defp, meta, [{name, _, _args} | _]} when is_atom(name) ->
            if legacy_function?(name) do
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

  # Check if function name has legacy markers
  defp legacy_function?(name) when is_atom(name) do
    name_str = Atom.to_string(name)

    # Check for explicit suffixes
    suffix_match = Enum.any?(@legacy_suffixes, fn suffix -> String.ends_with?(name_str, suffix) end)

    # Check for version suffixes (_v1, _v2, _v3, etc.)
    version_match = Regex.match?(~r/_v\d+$/, name_str)

    suffix_match or version_match
  end

  defp legacy_function?(_), do: false

  defp production_file?(%{filename: filename}) do
    # Only check lib/ files (production code)
    cond do
      String.starts_with?(filename, "lib/") -> true
      String.contains?(filename, "/lib/") -> true
      String.ends_with?(filename, "_test.exs") -> false
      String.contains?(filename, "/test/") -> false
      true -> false
    end
  end

  defp issue_for(issue_meta, function_name, line_no) do
    format_issue(
      issue_meta,
      message:
        "Function #{function_name}/_ has legacy marker suffix - indicates dual code path. Delete old implementation and make clean break instead of maintaining multiple versions",
      trigger: "#{function_name}",
      line_no: line_no
    )
  end
end
