defmodule Credo.Check.Concurrency.NoHardcodedPubSub do
  @moduledoc """
  Phoenix.PubSub should not be used with hardcoded module names as it creates
  global state that breaks test isolation when tests run in parallel.

  ## Why This Is Critical

  Using hardcoded PubSub module names (like `MyApp.PubSub`) creates global state
  that causes cross-test contamination in parallel tests. Instead, create isolated
  PubSub instances per test and pass them explicitly as parameters.

  ## Bad Example

      # ❌ BAD: Hardcoded global PubSub
      def broadcast_event(event) do
        Phoenix.PubSub.broadcast(MyApp.PubSub, "events", event)
      end

      # ❌ BAD: Hardcoded in production code
      Phoenix.PubSub.subscribe(MyApp.PubSub, "topic")

  ## Good Example

      # ✅ GOOD: PubSub passed as parameter
      def broadcast_event(pubsub, event) do
        Phoenix.PubSub.broadcast(pubsub, "events", event)
      end

      # ✅ GOOD: PubSub from state
      def subscribe_to_topic(state) do
        Phoenix.PubSub.subscribe(state.pubsub, "topic")
      end

      # ✅ GOOD: Create isolated instance in tests
      setup do
        pubsub = :"test_pubsub_\#{System.unique_integer()}"
        start_supervised!({Phoenix.PubSub, name: pubsub})
        %{pubsub: pubsub}
      end

  ## Why Explicit Parameter Passing Required

  The Process dictionary does NOT propagate to spawned processes (Task.async,
  GenServer, etc.), so even "test-only" PubSub stored in Process dictionary
  will fail when your code spawns processes. Always pass dependencies explicitly.

  ## Configuration

  This check is enabled by default with high priority.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Phoenix.PubSub should receive instances as parameters, not hardcoded module names.

      Hardcoded PubSub module names create global state that causes test isolation
      issues when running tests in parallel (`async: true`). Create isolated PubSub
      instances per test and pass them explicitly through function parameters.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # Match Phoenix.PubSub.broadcast/3, subscribe/2, unsubscribe/2, local_broadcast/3
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Phoenix, :PubSub]}, function]}, _,
          [pubsub_arg | _rest]} = ast,
         issues,
         issue_meta
       )
       when function in [:broadcast, :subscribe, :unsubscribe, :local_broadcast] do
    if hardcoded_module?(pubsub_arg) do
      {ast, [issue_for(issue_meta, meta[:line], function) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  # Check if argument is a hardcoded module alias (e.g., MyApp.PubSub)
  defp hardcoded_module?({:__aliases__, _meta, _module_parts}), do: true
  # Variables, map/struct access, function calls are all OK
  defp hardcoded_module?(_), do: false

  defp issue_for(issue_meta, line_no, function) do
    format_issue(
      issue_meta,
      message:
        "Avoid hardcoded PubSub module names - pass PubSub instance as parameter for test isolation",
      trigger: "Phoenix.PubSub.#{function}",
      line_no: line_no
    )
  end
end
