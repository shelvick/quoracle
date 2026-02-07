defmodule Credo.Check.Warning.SandboxAllowInInit do
  @moduledoc """
  Never call `Sandbox.allow/3` in `init/1` - use `handle_continue/2` instead.

  ## Why This Matters

  Calling `Sandbox.allow/3` in `init/1` creates a race condition that causes
  "cannot find ownership process" errors:

  - **Race condition** - Parent process may exit before `init/1` completes
  - **Ownership errors** - GenServer tries to use DB before allowance registered
  - **Test flakiness** - Fails randomly depending on process scheduling
  - **Hard to debug** - Error messages don't clearly indicate root cause

  When a test spawns a GenServer that needs DB access:
  1. Test calls `GenServer.start_link(Worker, opts)`
  2. GenServer process starts, calls `init/1`
  3. If `init/1` calls `Sandbox.allow(Repo, owner, self())`, race condition!
  4. Parent might exit before allowance is registered
  5. GenServer tries DB query → "cannot find ownership process"

  ## Bad Example

      # ❌ BAD: Sandbox.allow in init/1
      defmodule Worker do
        def init(opts) do
          if owner = opts[:sandbox_owner] do
            # Race condition! Parent may exit before this completes
            allow_owner = owner
            Sandbox.allow(Repo, allow_owner, self())
          end
          {:ok, %{}}
        end
      end

  ## Good Example

      # ✅ GOOD: Use handle_continue/2
      defmodule Worker do
        def init(opts) do
          {:ok, opts, {:continue, :setup}}
        end

        def handle_continue(:setup, state) do
          if owner = state[:sandbox_owner] do
            Sandbox.allow(Repo, owner, self())
          end
          {:noreply, state}
        end
      end

  ## Why handle_continue is Safe

  - `init/1` returns immediately with `{:continue, :setup}`
  - Parent receives confirmation that GenServer started
  - `handle_continue/2` runs *after* init completes
  - No race condition - parent knows GenServer is alive
  - DB allowance registered before any DB operations

  ## Configuration

  This check runs on all files with high priority.
  Prevents race conditions in Ecto.Sandbox ownership.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Never call Sandbox.allow/3 in init/1 - use handle_continue/2 instead.

      Calling Sandbox.allow in init/1 creates a race condition where the parent
      process may exit before allowance is registered, causing ownership errors.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # Match def init(...) and check its body for Sandbox.allow
  defp traverse({:def, _, [{:init, _, _args}, [do: body]]} = ast, issues, issue_meta) do
    new_issues = find_sandbox_allows_in_body(body, issue_meta)
    {ast, new_issues ++ issues}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  # Recursively search for Sandbox.allow in the function body
  defp find_sandbox_allows_in_body(body, issue_meta) do
    {_ast, issues} =
      Macro.prewalk(body, [], fn node, acc ->
        case check_sandbox_allow(node, issue_meta) do
          nil -> {node, acc}
          issue -> {node, [issue | acc]}
        end
      end)

    issues
  end

  # Match Sandbox.allow/3
  defp check_sandbox_allow(
         {{:., meta, [{:__aliases__, _, [:Sandbox]}, :allow]}, _, [_repo, _owner, _pid]},
         issue_meta
       ) do
    issue_for(issue_meta, meta[:line], "Sandbox.allow")
  end

  # Match Ecto.Adapters.SQL.Sandbox.allow/3
  defp check_sandbox_allow(
         {{:., meta,
           [{:__aliases__, _, [:Ecto, :Adapters, :SQL, :Sandbox]}, :allow]}, _,
          [_repo, _owner, _pid]},
         issue_meta
       ) do
    issue_for(issue_meta, meta[:line], "Ecto.Adapters.SQL.Sandbox.allow")
  end

  defp check_sandbox_allow(_node, _issue_meta), do: nil

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(
      issue_meta,
      message:
        "Never call #{trigger} in init/1 - creates race condition. Use handle_continue/2 instead to avoid ownership errors",
      trigger: trigger,
      line_no: line_no
    )
  end
end
