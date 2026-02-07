defmodule Credo.Check.Warning.OutdatedSandboxPattern do
  @moduledoc """
  The outdated `Sandbox.checkout/1` pattern should be replaced with `Sandbox.start_owner!/2`.

  ## Why This Is Critical

  The old `Sandbox.checkout/1` pattern has a critical flaw: the **test process owns
  the database connection**. When the test spawns processes (GenServers, Tasks, etc.),
  those processes crash when the test exits because the connection is killed.

  The modern `start_owner!` pattern creates a separate owner process that outlives
  the test, preventing spawned processes from crashing.

  ## Bad Example (Outdated Pattern)

      # ❌ OUTDATED - Test owns connection, spawned processes crash
      setup tags do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
        unless tags[:async], do: Sandbox.mode(Repo, {:shared, self()})
        :ok
      end

      test "spawns worker" do
        {:ok, pid} = GenServer.start_link(Worker, [])
        # Test exits → connection dies → Worker crashes with Postgrex error
      end

  ## Good Example (Modern Pattern)

      # ✅ MODERN - Separate owner survives test exit
      setup tags do
        pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: not tags[:async])
        on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
        {:ok, sandbox_owner: pid}
      end

      test "spawns worker", %{sandbox_owner: owner} do
        {:ok, pid} = GenServer.start_link(Worker, [sandbox_owner: owner])
        # Worker can call Sandbox.allow(Repo, owner, self()) in handle_continue
        # Worker survives test exit
      end

  ## Migration Guide

  1. Replace `Sandbox.checkout(Repo)` with `Sandbox.start_owner!(Repo, shared: not tags[:async])`
  2. Store the owner PID: `pid = Sandbox.start_owner!(...)`
  3. Add cleanup: `on_exit(fn -> Sandbox.stop_owner(pid) end)`
  4. Return owner in context: `{:ok, sandbox_owner: pid}`
  5. Pass owner to spawned processes and call `Sandbox.allow(Repo, owner, self())` in `handle_continue`

  ## Configuration

  This check only runs on test files with high priority.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Use modern `Sandbox.start_owner!/2` instead of outdated `Sandbox.checkout/1`.

      The old pattern causes spawned processes to crash when the test exits.
      The modern pattern creates a separate owner process that outlives the test.
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

  # Match full path: Ecto.Adapters.SQL.Sandbox.checkout
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Ecto, :Adapters, :SQL, :Sandbox]}, :checkout]}, _,
          _args} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line]) | issues]}
  end

  # Match aliased: Sandbox.checkout (after alias Ecto.Adapters.SQL.Sandbox)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Sandbox]}, :checkout]}, _, _args} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line]) | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
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
        "Use Sandbox.start_owner! instead of outdated Sandbox.checkout - old pattern crashes spawned processes",
      trigger: "Sandbox.checkout",
      line_no: line_no
    )
  end
end
