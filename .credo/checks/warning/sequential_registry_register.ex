defmodule Credo.Check.Warning.SequentialRegistryRegister do
  @moduledoc """
  Avoid multiple sequential `Registry.register/3` calls in the same function.
  Use a single atomic registration with a composite value instead.

  ## Why This Matters

  Sequential Registry.register calls create a **race window** where other processes
  can query the Registry and see incomplete state:

  ```elixir
  # ❌ RACE WINDOW between these two calls:
  Registry.register(reg, {:worker, id}, self())      # Point A
  # OTHER PROCESSES can query here and see worker WITHOUT parent relationship!
  Registry.register(reg, {:child_of, parent_id}, self())  # Point B
  ```

  During the gap between Point A and Point B:
  - Queries see the worker registered but without parent metadata
  - Supervision trees may make decisions on incomplete data
  - Race conditions in concurrent systems
  - Non-deterministic behavior in tests

  ## Bad Example

      # ❌ BAD: Sequential registrations create race window
      def register_worker(reg, worker_id, parent_id) do
        Registry.register(reg, {:worker, worker_id}, self())
        Registry.register(reg, {:child_of, parent_id}, self())
        # Queries between these two lines see incomplete state!
      end

      # ❌ BAD: Even with conditionals
      def register_worker(reg, worker_id, parent_id, is_child) do
        Registry.register(reg, {:worker, worker_id}, self())
        if is_child do
          Registry.register(reg, {:child_of, parent_id}, self())
        end
      end

  ## Good Example

      # ✅ GOOD: Single atomic registration with composite value
      def register_worker(reg, worker_id, parent_id) do
        Registry.register(reg, {:worker, worker_id}, %{
          pid: self(),
          parent_id: parent_id,
          registered_at: System.monotonic_time()
        })
      end

      # ✅ GOOD: Query the composite value
      def get_worker_parent(reg, worker_id) do
        case Registry.lookup(reg, {:worker, worker_id}) do
          [{_pid, %{parent_id: parent_id}}] -> {:ok, parent_id}
          [] -> {:error, :not_found}
        end
      end

  ## Why Single Registration is Atomic

  A single `Registry.register/3` call is atomic - other processes either:
  - See the complete registration with all metadata, OR
  - Don't see the registration at all (before it completes)

  There's no intermediate state visible to other processes.

  ## Configuration

  This check runs on all files with high priority.
  Part of concurrency safety checks.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Avoid multiple Registry.register calls in same function - creates race window.

      Sequential Registry.register calls allow other processes to query and see
      incomplete state between the calls. Use single atomic registration with
      composite value instead.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Credo.Code.ast()
    |> find_functions_with_multiple_registers()
    |> Enum.map(fn {function_name, line} ->
      issue_for(issue_meta, function_name, line)
    end)
  end

  # Find all functions that contain 2+ Registry.register calls
  defp find_functions_with_multiple_registers(ast) do
    {_ast, functions} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          # Match function definitions (def and defp)
          {def_type, meta, [{name, _, _args} = _signature, [do: body]]}
          when def_type in [:def, :defp] and is_atom(name) ->
            register_count = count_registry_registers(body)

            if register_count >= 2 do
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

  # Count Registry.register calls in an AST node
  defp count_registry_registers(ast) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, acc ->
        case node do
          # Match Registry.register/3 calls
          {{:., _, [{:__aliases__, _, [:Registry]}, :register]}, _, [_reg, _key, _value]} ->
            {node, acc + 1}

          _ ->
            {node, acc}
        end
      end)

    count
  end

  defp issue_for(issue_meta, function_name, line_no) do
    format_issue(
      issue_meta,
      message:
        "Function #{function_name}/_ has multiple Registry.register calls - creates race window where queries see incomplete state. Use single atomic registration with composite value instead",
      trigger: "#{function_name}",
      line_no: line_no
    )
  end
end
