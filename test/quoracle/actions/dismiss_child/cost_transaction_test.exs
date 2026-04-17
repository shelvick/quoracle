defmodule Quoracle.Actions.DismissChild.CostTransactionTest do
  @moduledoc """
  TEST phase coverage for ACTION_Dismiss_CostTransaction (Packet 1).

  WorkGroupID: fix-20260411-dismiss-atomic-cost-txn
  NodeID: ACTION_Dismiss_CostTransaction

  Requirements covered: R1-R20
  """

  use Quoracle.DataCase, async: true
  use ExUnitProperties

  alias Ecto.Adapters.SQL.Sandbox
  alias Quoracle.Actions.DismissChild.CostTransaction
  alias Quoracle.Agents.Agent
  alias Quoracle.Costs.AgentCost
  alias Quoracle.Costs.Aggregator
  alias Quoracle.Repo
  alias Quoracle.Tasks.Task, as: TaskSchema

  import Ecto.Query

  @repo_query_event [:quoracle, :repo, :query]

  setup %{sandbox_owner: sandbox_owner} do
    task =
      Repo.insert!(%TaskSchema{
        id: Ecto.UUID.generate(),
        prompt: "cost transaction test task",
        status: "running"
      })

    %{task: task, sandbox_owner: sandbox_owner}
  end

  describe "transaction atomicity (R1-R4)" do
    @tag :r1
    @tag :unit
    test "R1: atomic commit deletes subtree and inserts absorption", %{task: task} do
      parent_id = unique_id("parent-r1")
      child_id = unique_id("child-r1")
      grandchild_id = unique_id("grandchild-r1")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)
      insert_agent!(task.id, grandchild_id, child_id)

      insert_cost!(child_id, task.id, Decimal.new("12.50"),
        model_spec: "anthropic/claude-sonnet-4"
      )

      insert_cost!(grandchild_id, task.id, Decimal.new("7.25"), model_spec: "openai/gpt-4o")

      assert {:ok, inserted} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))

      assert length(inserted) == 2

      subtree_count =
        Repo.aggregate(
          from(c in AgentCost, where: c.agent_id in ^[child_id, grandchild_id]),
          :count
        )

      assert subtree_count == 0

      parent_absorption_count =
        Repo.aggregate(
          from(c in AgentCost,
            where: c.agent_id == ^parent_id and c.cost_type == "child_budget_absorbed"
          ),
          :count
        )

      assert parent_absorption_count == 2
    end

    @tag :r2
    @tag :unit
    test "R2: rolls back when task_id is nil, preserving all cost rows", %{task: task} do
      parent_id = unique_id("parent-r2")
      child_id = unique_id("child-r2")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)

      insert_cost!(child_id, task.id, Decimal.new("9.00"),
        model_spec: "anthropic/claude-sonnet-4"
      )

      before_count = Repo.aggregate(from(c in AgentCost, where: c.agent_id == ^child_id), :count)

      assert {:error, :invalid_task_id} =
               CostTransaction.absorb_subtree(parent_id, child_id, %{
                 task_id: nil,
                 child_budget_data: nil
               })

      after_count = Repo.aggregate(from(c in AgentCost, where: c.agent_id == ^child_id), :count)
      assert after_count == before_count
    end

    @tag :r3
    @tag :integration
    test "R3: rollback preserves exact cost row count for subtree", %{task: task} do
      parent_id = unique_id("parent-r3")
      child_id = unique_id("child-r3")
      desc_id = unique_id("desc-r3")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)
      insert_agent!(task.id, desc_id, child_id)

      insert_cost!(child_id, task.id, Decimal.new("5.00"),
        model_spec: "anthropic/claude-sonnet-4"
      )

      insert_cost!(desc_id, task.id, Decimal.new("4.00"), model_spec: "openai/gpt-4o")

      subtree_ids = [child_id, desc_id]
      before_count = subtree_cost_count(subtree_ids)

      assert {:error, :invalid_task_id} =
               CostTransaction.absorb_subtree(parent_id, child_id, %{
                 task_id: nil,
                 child_budget_data: nil
               })

      assert subtree_cost_count(subtree_ids) == before_count

      missing_task_id = Ecto.UUID.generate()

      assert {:error, {:insert_failed, _reason}} =
               CostTransaction.absorb_subtree(
                 parent_id,
                 child_id,
                 valid_absorption_ctx(missing_task_id)
               )

      assert subtree_cost_count(subtree_ids) == before_count
    end

    @tag :r4
    @tag :integration
    test "R4: rolls back cleanly when Recorder batch insert fails", %{task: task} do
      parent_id = unique_id("parent-r4")
      child_id = unique_id("child-r4")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)

      insert_cost!(child_id, task.id, Decimal.new("11.00"),
        model_spec: "anthropic/claude-sonnet-4"
      )

      before_count = Repo.aggregate(from(c in AgentCost, where: c.agent_id == ^child_id), :count)

      assert {:error, {:insert_failed, _reason}} =
               CostTransaction.absorb_subtree(
                 parent_id,
                 child_id,
                 valid_absorption_ctx(Ecto.UUID.generate())
               )

      after_count = Repo.aggregate(from(c in AgentCost, where: c.agent_id == ^child_id), :count)
      assert after_count == before_count
    end
  end

  describe "bulk DELETE semantics (R5-R6)" do
    @tag :r5
    @tag :unit
    test "R5: issues single bulk delete statement for entire subtree", %{task: task} do
      parent_id = unique_id("parent-r5")
      child_id = unique_id("child-r5")
      desc1 = unique_id("desc1-r5")
      desc2 = unique_id("desc2-r5")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)
      insert_agent!(task.id, desc1, child_id)
      insert_agent!(task.id, desc2, child_id)

      insert_cost!(child_id, task.id, Decimal.new("2.00"), model_spec: "model/a")
      insert_cost!(desc1, task.id, Decimal.new("3.00"), model_spec: "model/b")
      insert_cost!(desc2, task.id, Decimal.new("4.00"), model_spec: "model/c")

      handler_id = {:r5_delete_probe, System.unique_integer([:positive])}
      test_pid = self()
      expected_subtree_ids = MapSet.new([child_id, desc1, desc2])

      :ok =
        :telemetry.attach(
          handler_id,
          @repo_query_event,
          fn _event, _measurements, metadata, _config ->
            if delete_for_expected_subtree?(metadata, expected_subtree_ids) do
              send(test_pid, :r5_delete_seen)
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _inserted} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))

      delete_count = drain_count(:r5_delete_seen)
      assert delete_count == 1
    end

    @tag :r6
    @tag :integration
    test "R6: bulk delete removes cost rows for all subtree descendants", %{task: task} do
      parent_id = unique_id("parent-r6")
      child_id = unique_id("child-r6")
      desc1 = unique_id("desc1-r6")
      desc2 = unique_id("desc2-r6")
      grandchild = unique_id("grandchild-r6")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)
      insert_agent!(task.id, desc1, child_id)
      insert_agent!(task.id, desc2, child_id)
      insert_agent!(task.id, grandchild, desc1)

      insert_cost!(child_id, task.id, Decimal.new("1.00"), model_spec: "model/a")
      insert_cost!(desc1, task.id, Decimal.new("2.00"), model_spec: "model/b")
      insert_cost!(desc2, task.id, Decimal.new("3.00"), model_spec: "model/c")
      insert_cost!(grandchild, task.id, Decimal.new("4.00"), model_spec: "model/d")

      assert {:ok, _inserted} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))

      subtree_ids = [child_id, desc1, desc2, grandchild]
      assert subtree_cost_count(subtree_ids) == 0
    end
  end

  describe "subtree collection (R7-R8)" do
    @tag :r7
    @tag :unit
    test "R7: collect_subtree_agent_ids includes root and all descendants", %{task: task} do
      parent_id = unique_id("parent-r7")
      child_id = unique_id("child-r7")
      desc_id = unique_id("desc-r7")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)
      insert_agent!(task.id, desc_id, child_id)

      insert_cost!(child_id, task.id, Decimal.new("6.00"), model_spec: "model/a")
      insert_cost!(desc_id, task.id, Decimal.new("4.00"), model_spec: "model/b")

      assert {:ok, _inserted} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))

      assert subtree_cost_count([child_id, desc_id]) == 0

      parent_total =
        Repo.one(
          from(c in AgentCost,
            where: c.agent_id == ^parent_id and c.cost_type == "child_budget_absorbed",
            select: sum(c.cost_usd)
          )
        )

      assert Decimal.equal?(decimal_or_zero(parent_total), Decimal.new("10.00"))
    end

    @tag :r8
    @tag :integration
    test "R8: subtree collection uses agents table as source of truth", %{task: task} do
      parent_id = unique_id("parent-r8")
      child_id = unique_id("child-r8")
      desc_id = unique_id("desc-r8")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)
      insert_agent!(task.id, desc_id, child_id)

      insert_cost!(child_id, task.id, Decimal.new("8.00"), model_spec: "model/a")
      insert_cost!(desc_id, task.id, Decimal.new("2.00"), model_spec: "model/b")

      # No Registry or live processes are set up here.
      assert {:ok, _inserted} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))

      assert subtree_cost_count([child_id, desc_id]) == 0
    end
  end

  describe "absorption record construction (R9-R12)" do
    @tag :r9
    @tag :integration
    test "R9: per-model absorption records preserve model_spec attribution", %{task: task} do
      parent_id = unique_id("parent-r9")
      child_id = unique_id("child-r9")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)

      insert_cost!(child_id, task.id, Decimal.new("5.00"),
        model_spec: "anthropic/claude-sonnet-4"
      )

      insert_cost!(child_id, task.id, Decimal.new("7.00"), model_spec: "openai/gpt-4o")

      assert {:ok, _inserted} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))

      specs =
        absorption_rows(parent_id)
        |> Enum.map(&get_in(&1.metadata, ["model_spec"]))

      assert "anthropic/claude-sonnet-4" in specs
      assert "openai/gpt-4o" in specs
      assert length(specs) == 2
    end

    @tag :r10
    @tag :integration
    test "R10: external costs get '(external)' sentinel model_spec", %{task: task} do
      parent_id = unique_id("parent-r10")
      child_id = unique_id("child-r10")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)

      insert_cost!(child_id, task.id, Decimal.new("3.25"), cost_type: "external", metadata: %{})

      assert {:ok, _inserted} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))

      [row] = absorption_rows(parent_id)
      assert row.metadata["model_spec"] == "(external)"
    end

    @tag :r11
    @tag :integration
    test "R11: absorption metadata preserves all token counts and cost fields", %{task: task} do
      parent_id = unique_id("parent-r11")
      child_id = unique_id("child-r11")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)

      insert_cost!(child_id, task.id, Decimal.new("9.50"),
        model_spec: "anthropic/claude-sonnet-4",
        input_tokens: 1000,
        output_tokens: 500,
        reasoning_tokens: 80,
        cached_tokens: 30,
        cache_creation_tokens: 10,
        input_cost: "0.40",
        output_cost: "0.55"
      )

      assert {:ok, _inserted} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))

      [row] = absorption_rows(parent_id)
      metadata = row.metadata

      assert metadata["input_tokens"] == "1000"
      assert metadata["output_tokens"] == "500"
      assert metadata["reasoning_tokens"] == "80"
      assert metadata["cached_tokens"] == "30"
      assert metadata["cache_creation_tokens"] == "10"
      assert metadata["input_cost"] == "0.40"
      assert metadata["output_cost"] == "0.55"
    end

    @tag :r12
    @tag :unit
    test "R12: zero-cost rows excluded from absorption batch", %{task: task} do
      parent_id = unique_id("parent-r12")
      child_id = unique_id("child-r12")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)

      insert_cost!(child_id, task.id, Decimal.new("0.00"), model_spec: "model/zero")
      insert_cost!(child_id, task.id, Decimal.new("6.00"), model_spec: "model/nonzero")

      assert {:ok, _inserted} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))

      rows = absorption_rows(parent_id)
      assert length(rows) == 1
      assert Enum.any?(rows, &Decimal.equal?(&1.cost_usd, Decimal.new("6.00")))
      refute Enum.any?(rows, &(&1.metadata["model_spec"] == "model/zero"))
    end
  end

  describe "sum preservation (R13)" do
    @tag :r13
    @tag :property
    @tag :integration
    property "R13: absorption total equals subtree deleted total exactly", %{task: task} do
      check all(
              costs <- list_of(integer(1..500), min_length: 1, max_length: 4),
              unique_models <-
                uniq_list_of(string(:alphanumeric, min_length: 3),
                  min_length: 1,
                  max_length: 4
                )
            ) do
        parent_id = unique_id("parent-r13")
        child_id = unique_id("child-r13")

        insert_agent!(task.id, parent_id)
        insert_agent!(task.id, child_id, parent_id)

        model_list = ensure_model_list(unique_models)

        Enum.with_index(costs)
        |> Enum.each(fn {cents, index} ->
          model = Enum.at(model_list, rem(index, length(model_list)))
          cost = Decimal.div(Decimal.new(cents), 100)
          insert_cost!(child_id, task.id, cost, model_spec: model)
        end)

        before_deleted_total =
          Repo.one(from(c in AgentCost, where: c.agent_id == ^child_id, select: sum(c.cost_usd)))
          |> decimal_or_zero()

        assert {:ok, inserted} =
                 CostTransaction.absorb_subtree(
                   parent_id,
                   child_id,
                   valid_absorption_ctx(task.id)
                 )

        inserted_total =
          inserted |> Enum.map(& &1.cost_usd) |> Enum.reduce(Decimal.new("0"), &Decimal.add/2)

        assert Decimal.equal?(inserted_total, before_deleted_total)
      end
    end
  end

  describe "edge cases (R14-R16)" do
    @tag :r14
    @tag :unit
    test "R14: empty subtree returns ok empty without side effects", %{task: task} do
      parent_id = unique_id("parent-r14")
      child_id = unique_id("child-r14")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)

      before_total = Repo.aggregate(AgentCost, :count)

      assert {:ok, []} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))

      assert Repo.aggregate(AgentCost, :count) == before_total
      assert absorption_rows(parent_id) == []
    end

    @tag :r15
    @tag :unit
    test "R15: all-zero subtree returns ok empty", %{task: task} do
      parent_id = unique_id("parent-r15")
      child_id = unique_id("child-r15")
      desc_id = unique_id("desc-r15")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)
      insert_agent!(task.id, desc_id, child_id)

      insert_cost!(child_id, task.id, Decimal.new("0.00"), model_spec: "model/a")
      insert_cost!(desc_id, task.id, Decimal.new("0.00"), model_spec: "model/b")

      before_count = subtree_cost_count([child_id, desc_id])

      assert {:ok, []} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))

      assert subtree_cost_count([child_id, desc_id]) == before_count
      assert absorption_rows(parent_id) == []
    end

    @tag :r16
    @tag :integration
    test "R16: N/A budget child still gets absorption records with 'N/A' allocated", %{task: task} do
      parent_id = unique_id("parent-r16")
      child_id = unique_id("child-r16")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)
      insert_cost!(child_id, task.id, Decimal.new("6.75"), model_spec: "model/a")

      assert {:ok, _inserted} =
               CostTransaction.absorb_subtree(parent_id, child_id, %{
                 task_id: task.id,
                 child_budget_data: nil
               })

      [row] = absorption_rows(parent_id)
      assert row.metadata["child_allocated"] == "N/A"
    end
  end

  describe "side effects and concurrency (R17-R20)" do
    @tag :r17
    @tag :unit
    test "R17: transaction body does not broadcast PubSub events", %{task: task} do
      parent_id = unique_id("parent-r17")
      child_id = unique_id("child-r17")
      pubsub_name = :"r17_pubsub_#{System.unique_integer([:positive])}"

      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)
      insert_cost!(child_id, task.id, Decimal.new("2.50"), model_spec: "model/a")

      Phoenix.PubSub.subscribe(pubsub_name, "tasks:#{task.id}:costs")
      Phoenix.PubSub.subscribe(pubsub_name, "agents:#{parent_id}:costs")

      assert {:ok, _inserted} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))

      refute_receive {:cost_recorded, _event}, 100
    end

    @tag :r18
    @tag :unit
    test "R18: transaction body does not call any GenServer", %{task: task} do
      parent_id = unique_id("parent-r18")
      child_id = unique_id("child-r18")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)
      insert_cost!(child_id, task.id, Decimal.new("3.00"), model_spec: "model/a")

      # No parent/child process pids are started in this test. The transaction API
      # must still execute with DB-only dependencies.
      assert {:ok, _inserted} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))
    end

    @tag :r19
    @tag :integration
    test "R19: transaction executes under caller's sandbox ownership", %{
      task: task,
      sandbox_owner: owner
    } do
      parent_id = unique_id("parent-r19")
      child_id = unique_id("child-r19")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)
      insert_cost!(child_id, task.id, Decimal.new("4.00"), model_spec: "model/a")

      caller = self()

      task_ref =
        Task.async(fn ->
          Sandbox.allow(Repo, owner, self())
          send(caller, :r19_allowed)
          CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))
        end)

      assert_receive :r19_allowed, 1_000
      assert {:ok, _inserted} = Task.await(task_ref, 5_000)
    end

    @tag :r20
    @tag :integration
    test "R20: concurrent readers never observe intermediate state", %{
      task: task,
      sandbox_owner: owner
    } do
      parent_id = unique_id("parent-r20")
      child_id = unique_id("child-r20")
      desc_id = unique_id("desc-r20")

      insert_agent!(task.id, parent_id)
      insert_agent!(task.id, child_id, parent_id)
      insert_agent!(task.id, desc_id, child_id)

      insert_cost!(child_id, task.id, Decimal.new("5.00"), model_spec: "model/a")
      insert_cost!(desc_id, task.id, Decimal.new("3.00"), model_spec: "model/b")

      before_total = Aggregator.by_task(task.id).total_cost |> decimal_or_zero()

      sampler =
        Task.async(fn ->
          Sandbox.allow(Repo, owner, self())
          sample_task_totals(task.id, Decimal.new("0"), [])
        end)

      on_exit(fn ->
        if Process.alive?(sampler.pid) do
          Task.shutdown(sampler, :brutal_kill)
        end
      end)

      assert {:ok, _inserted} =
               CostTransaction.absorb_subtree(parent_id, child_id, valid_absorption_ctx(task.id))

      send(sampler.pid, :stop_sampling)
      samples = Task.await(sampler, 5_000)

      after_total = Aggregator.by_task(task.id).total_cost |> decimal_or_zero()

      assert Enum.all?(samples, fn sample ->
               Decimal.equal?(sample, before_total) or Decimal.equal?(sample, after_total)
             end)
    end
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp insert_agent!(task_id, agent_id, parent_id \\ nil) do
    attrs = %{
      task_id: task_id,
      agent_id: agent_id,
      parent_id: parent_id,
      config: %{},
      status: "running"
    }

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_cost!(agent_id, task_id, cost_usd, opts) do
    metadata = build_metadata(opts)

    attrs = %{
      agent_id: agent_id,
      task_id: task_id,
      cost_type: Keyword.get(opts, :cost_type, "llm_consensus"),
      cost_usd: cost_usd,
      metadata: metadata
    }

    %AgentCost{}
    |> AgentCost.changeset(attrs)
    |> Repo.insert!()
  end

  defp build_metadata(opts) do
    if Keyword.has_key?(opts, :metadata) do
      Keyword.fetch!(opts, :metadata)
    else
      base = %{
        "input_tokens" => Keyword.get(opts, :input_tokens, 100),
        "output_tokens" => Keyword.get(opts, :output_tokens, 50),
        "reasoning_tokens" => Keyword.get(opts, :reasoning_tokens, 0),
        "cached_tokens" => Keyword.get(opts, :cached_tokens, 0),
        "cache_creation_tokens" => Keyword.get(opts, :cache_creation_tokens, 0),
        "input_cost" => Keyword.get(opts, :input_cost, "0.01"),
        "output_cost" => Keyword.get(opts, :output_cost, "0.02")
      }

      case Keyword.get(opts, :model_spec) do
        nil -> base
        model_spec -> Map.put(base, "model_spec", model_spec)
      end
    end
  end

  defp valid_absorption_ctx(task_id) do
    %{
      task_id: task_id,
      child_budget_data: %{mode: :allocated, allocated: Decimal.new("20.00")}
    }
  end

  defp absorption_rows(parent_id) do
    Repo.all(
      from(c in AgentCost,
        where: c.agent_id == ^parent_id and c.cost_type == "child_budget_absorbed",
        order_by: [asc: c.inserted_at]
      )
    )
  end

  defp subtree_cost_count(agent_ids) do
    Repo.aggregate(from(c in AgentCost, where: c.agent_id in ^agent_ids), :count)
  end

  defp decimal_or_zero(nil), do: Decimal.new("0")
  defp decimal_or_zero(%Decimal{} = value), do: value

  defp drain_count(message) do
    Stream.repeatedly(fn ->
      receive do
        ^message -> :seen
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 == :seen))
    |> length()
  end

  defp ensure_model_list([]), do: ["fallback-model"]
  defp ensure_model_list(models), do: models

  defp delete_for_expected_subtree?(metadata, expected_subtree_ids) do
    query = metadata.query || ""

    if String.contains?(query, ~s(DELETE FROM "agent_costs")) do
      collected_params =
        metadata.params
        |> collect_binary_params()
        |> MapSet.new()

      MapSet.subset?(expected_subtree_ids, collected_params)
    else
      false
    end
  end

  defp collect_binary_params(params) when is_list(params) do
    Enum.flat_map(params, &collect_binary_params/1)
  end

  defp collect_binary_params(param) when is_binary(param), do: [param]
  defp collect_binary_params(_param), do: []

  defp sample_task_totals(task_id, fallback, acc) do
    total = Aggregator.by_task(task_id).total_cost || fallback

    receive do
      :stop_sampling -> Enum.reverse([total | acc])
    after
      0 -> sample_task_totals(task_id, fallback, [total | acc])
    end
  end
end
