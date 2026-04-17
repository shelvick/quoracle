defmodule Quoracle.Actions.DismissChildRollbackTest do
  @moduledoc """
  Rollback-preservation tests for ACTION_DismissChild v7.0.

  WorkGroupID: fix-20260411-dismiss-atomic-cost-txn
  Packet: 2 (DismissChild Rewire + TreeTerminator Cleanup)

  Requirements covered: R61-R62
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.DismissChild
  alias Quoracle.Costs.AgentCost
  alias Quoracle.Tasks.Task, as: TaskSchema
  alias Test.IsolationHelpers

  import ExUnit.CaptureLog
  import Test.AgentTestHelpers

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    {:ok, task} =
      Repo.insert(%TaskSchema{
        id: Ecto.UUID.generate(),
        prompt: "dismiss rollback task",
        status: "running"
      })

    {:ok, deps: deps, task: task}
  end

  defp spawn_agent_with_budget(agent_id, deps, task, budget_data, opts \\ []) do
    parent_id = Keyword.get(opts, :parent_id)
    parent_pid = Keyword.get(opts, :parent_pid)

    config = %{
      agent_id: agent_id,
      parent_id: parent_id,
      parent_pid: parent_pid,
      task_id: task.id,
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: deps.sandbox_owner,
      budget_data: budget_data,
      prompt_fields: %{
        provided: %{task_description: "Rollback test task"},
        injected: %{global_context: "", constraints: []},
        transformed: %{}
      },
      models: []
    }

    spawn_agent_with_cleanup(
      deps.dynsup,
      config,
      registry: deps.registry,
      pubsub: deps.pubsub
    )
  end

  defp action_opts(deps, task) do
    [
      registry: deps.registry,
      dynsup: deps.dynsup,
      pubsub: deps.pubsub,
      sandbox_owner: deps.sandbox_owner,
      task_id: task.id,
      dismiss_complete_notify: self()
    ]
  end

  defp wait_for_any_dismiss_signal(child_id, timeout \\ 2_000) do
    receive do
      {:dismiss_complete, ^child_id} -> :ok
      {:dismiss_failed, ^child_id, _reason} -> :ok
    after
      timeout -> {:error, :timeout}
    end
  end

  defp insert_model_cost(agent_id, task_id, opts) do
    cost_usd = Keyword.fetch!(opts, :cost_usd)
    model_spec = Keyword.get(opts, :model_spec)
    cost_type = Keyword.get(opts, :cost_type, "llm_consensus")

    metadata =
      %{
        "input_tokens" => Keyword.get(opts, :input_tokens, 500),
        "output_tokens" => Keyword.get(opts, :output_tokens, 200),
        "reasoning_tokens" => Keyword.get(opts, :reasoning_tokens, 0),
        "cached_tokens" => Keyword.get(opts, :cached_tokens, 0),
        "cache_creation_tokens" => Keyword.get(opts, :cache_creation_tokens, 0),
        "input_cost" => Keyword.get(opts, :input_cost, "0.01"),
        "output_cost" => Keyword.get(opts, :output_cost, "0.02")
      }
      |> then(fn m ->
        if model_spec, do: Map.put(m, "model_spec", model_spec), else: m
      end)

    Repo.insert(
      AgentCost.changeset(%AgentCost{}, %{
        agent_id: agent_id,
        task_id: task_id,
        cost_type: cost_type,
        cost_usd: cost_usd,
        metadata: metadata
      })
    )
  end

  @tag :r61
  @tag :integration
  test "R61: nil task_id preserves all child cost rows", %{deps: deps, task: task} do
    parent_id = "parent-R61-#{System.unique_integer([:positive])}"
    child_id = "child-R61-#{System.unique_integer([:positive])}"
    grandchild_id = "grandchild-R61-#{System.unique_integer([:positive])}"

    parent_budget = %{
      mode: :root,
      allocated: Decimal.new("100.00"),
      committed: Decimal.new("50.00")
    }

    child_budget = %{
      mode: :allocated,
      allocated: Decimal.new("50.00"),
      committed: Decimal.new("0")
    }

    {:ok, parent_pid} = spawn_agent_with_budget(parent_id, deps, task, parent_budget)

    {:ok, child_pid} =
      spawn_agent_with_budget(child_id, deps, task, child_budget,
        parent_id: parent_id,
        parent_pid: parent_pid
      )

    {:ok, _grandchild_pid} =
      spawn_agent_with_budget(grandchild_id, deps, task, child_budget,
        parent_id: child_id,
        parent_pid: child_pid
      )

    {:ok, _} =
      insert_model_cost(child_id, task.id,
        cost_usd: Decimal.new("11.00"),
        model_spec: "anthropic/claude-sonnet-4"
      )

    {:ok, _} =
      insert_model_cost(grandchild_id, task.id,
        cost_usd: Decimal.new("4.00"),
        model_spec: "openai/gpt-4o"
      )

    subtree_ids = [child_id, grandchild_id]

    before_count =
      Repo.aggregate(from(c in AgentCost, where: c.agent_id in ^subtree_ids), :count)

    failing_opts = action_opts(deps, task) |> Keyword.put(:task_id, nil)

    capture_log(fn ->
      {:ok, _} = DismissChild.execute(%{child_id: child_id}, parent_id, failing_opts)
      :ok = wait_for_any_dismiss_signal(child_id)
    end)

    after_count =
      Repo.aggregate(from(c in AgentCost, where: c.agent_id in ^subtree_ids), :count)

    assert after_count == before_count,
           "Rollback should preserve all subtree cost rows"
  end

  @tag :r62
  @tag :integration
  test "R62: insert failure preserves rows and leaves child running", %{deps: deps, task: task} do
    parent_id = "parent-R62-#{System.unique_integer([:positive])}"
    child_id = "child-R62-#{System.unique_integer([:positive])}"

    parent_budget = %{
      mode: :root,
      allocated: Decimal.new("100.00"),
      committed: Decimal.new("50.00")
    }

    child_budget = %{
      mode: :allocated,
      allocated: Decimal.new("50.00"),
      committed: Decimal.new("0")
    }

    {:ok, parent_pid} = spawn_agent_with_budget(parent_id, deps, task, parent_budget)

    {:ok, child_pid} =
      spawn_agent_with_budget(child_id, deps, task, child_budget,
        parent_id: parent_id,
        parent_pid: parent_pid
      )

    {:ok, _} =
      insert_model_cost(child_id, task.id,
        cost_usd: Decimal.new("12.50"),
        model_spec: "anthropic/claude-sonnet-4"
      )

    before_count = Repo.aggregate(from(c in AgentCost, where: c.agent_id == ^child_id), :count)

    missing_task_opts = action_opts(deps, task) |> Keyword.put(:task_id, Ecto.UUID.generate())

    capture_log(fn ->
      {:ok, _} = DismissChild.execute(%{child_id: child_id}, parent_id, missing_task_opts)
      :ok = wait_for_any_dismiss_signal(child_id)
    end)

    after_count = Repo.aggregate(from(c in AgentCost, where: c.agent_id == ^child_id), :count)
    assert after_count == before_count

    assert Process.alive?(child_pid),
           "Rollback on insert failure should leave child process alive"

    refute_receive {:dismiss_complete, ^child_id}, 250
  end
end
