defmodule QuoracleWeb.DashboardCostMonotonicityTest do
  @moduledoc """
  Tests for UI_Dashboard v22.0 monotonic task-cost guard.

  WorkGroupID: fix-20260411-dismiss-atomic-cost-txn
  Packet: 3 (Dashboard Monotonic Guard)
  NodeID: UI_Dashboard
  """

  use QuoracleWeb.ConnCase, async: true

  import Ecto.Query

  alias Quoracle.Actions.DismissChild
  alias Quoracle.Agent.Core
  alias Quoracle.Costs.{AgentCost, Aggregator}
  alias Quoracle.Repo
  alias Test.IsolationHelpers

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()

    %{
      pubsub: deps.pubsub,
      registry: deps.registry,
      dynsup: deps.dynsup,
      sandbox_owner: sandbox_owner
    }
  end

  describe "UI_Dashboard v22.0 packet 3 monotonic guard" do
    @tag :acceptance
    test "R-MG1: task total monotonic through dismissal (guard on)", context do
      %{task: task, root_id: root_id, child_id: child_id} = spawn_root_and_child(context, "R-MG1")

      insert_model_cost_under_child(root_id, task.id,
        cost_usd: Decimal.new("0.20"),
        model_spec: "anthropic:claude-sonnet"
      )

      insert_model_cost_under_child(child_id, task.id,
        cost_usd: Decimal.new("0.80"),
        model_spec: "openai:gpt-4o"
      )

      conn = Plug.Test.init_test_session(context.conn, base_session(context))
      {:ok, view, _html} = live(conn, "/")

      assert Map.get(current_assigns(view), :cost_monotonic_guard?) == true

      initial_total = force_flush_and_extract_total(view, task.id)
      assert Decimal.compare(initial_total, Decimal.new("0")) == :gt

      {:ok, _} =
        DismissChild.execute(%{child_id: child_id}, root_id, dismiss_opts(context, task.id))

      refute_receive {:dismiss_complete, ^child_id}, 0

      samples =
        Enum.map(1..20, fn _ ->
          force_flush_and_extract_total(view, task.id)
        end)

      assert_non_decreasing(samples)
      assert_receive {:dismiss_complete, ^child_id}, 10_000

      post_completion_sample = force_flush_and_extract_total(view, task.id)
      assert Decimal.compare(post_completion_sample, List.last(samples)) != :lt
      assert Decimal.compare(post_completion_sample, initial_total) != :lt

      task_cost_html = view |> element("#task-cost-#{task.id}") |> render()
      assert task_cost_html =~ "$"
      refute task_cost_html =~ "N/A"
      refute task_cost_html =~ "error"
    end

    test "R-MG2: task total monotonic with guard off", context do
      %{task: task, root_id: root_id, child_id: child_id} = spawn_root_and_child(context, "R-MG2")

      insert_model_cost_under_child(root_id, task.id,
        cost_usd: Decimal.new("0.15"),
        model_spec: "anthropic:claude-sonnet"
      )

      insert_model_cost_under_child(child_id, task.id,
        cost_usd: Decimal.new("0.85"),
        model_spec: "openai:gpt-4o"
      )

      {:ok, view, _html} =
        live_isolated(context.conn, QuoracleWeb.DashboardLive,
          session: Map.put(base_session(context), "cost_monotonic_guard?", false)
        )

      assert Map.get(current_assigns(view), :cost_monotonic_guard?) == false

      initial_total = force_flush_and_extract_total(view, task.id)

      {:ok, _} =
        DismissChild.execute(%{child_id: child_id}, root_id, dismiss_opts(context, task.id))

      refute_receive {:dismiss_complete, ^child_id}, 0

      samples =
        Enum.map(1..20, fn _ ->
          force_flush_and_extract_total(view, task.id)
        end)

      assert_non_decreasing(samples)
      assert_receive {:dismiss_complete, ^child_id}, 10_000

      post_completion_sample = force_flush_and_extract_total(view, task.id)
      assert Decimal.compare(post_completion_sample, List.last(samples)) != :lt
      assert Decimal.compare(post_completion_sample, initial_total) != :lt
    end

    test "R-MG3: per-agent costs pass through guard unchanged", context do
      %{task: task, root_id: root_id} = spawn_root_only(context, "R-MG3")

      insert_model_cost_under_child(root_id, task.id,
        cost_usd: Decimal.new("2.00"),
        model_spec: "anthropic:claude-sonnet"
      )

      {:ok, view, _html} =
        live_isolated(context.conn, QuoracleWeb.DashboardLive, session: base_session(context))

      assert Map.get(current_assigns(view), :cost_monotonic_guard?) == true

      force_flush(view)

      put_prior_cost_data(view, %{
        agents: %{root_id => Decimal.new("9.99")},
        tasks: %{task.id => Decimal.new("9.99")}
      })

      Repo.delete_all(from(c in AgentCost, where: c.task_id == ^task.id))

      insert_model_cost_under_child(root_id, task.id,
        cost_usd: Decimal.new("1.00"),
        model_spec: "openai:gpt-4o"
      )

      force_flush(view)

      fresh = Aggregator.batch_totals([root_id], [task.id])
      assigns = current_assigns(view)

      assert assigns.cost_data.agents == fresh.agents
      assert Decimal.equal?(assigns.cost_data.tasks[task.id], Decimal.new("9.99"))
    end

    test "R-MG4: first guard-enabled flush uses fresh values", context do
      %{task: task, root_id: root_id} = spawn_root_only(context, "R-MG4")

      insert_model_cost_under_child(root_id, task.id,
        cost_usd: Decimal.new("0.75"),
        model_spec: "anthropic:claude-sonnet"
      )

      {:ok, view, _html} =
        live_isolated(context.conn, QuoracleWeb.DashboardLive, session: base_session(context))

      assert Map.get(current_assigns(view), :cost_monotonic_guard?) == true

      put_prior_cost_data(view, nil)
      fresh = Aggregator.batch_totals([root_id], [task.id])

      force_flush(view)

      assigns = current_assigns(view)
      assert assigns.cost_data == fresh
    end

    test "R-MG5: nil fresh task value preserves prior total", context do
      %{task: task, root_id: root_id} = spawn_root_only(context, "R-MG5")

      {:ok, view, _html} =
        live_isolated(context.conn, QuoracleWeb.DashboardLive, session: base_session(context))

      assert Map.get(current_assigns(view), :cost_monotonic_guard?) == true

      put_prior_cost_data(view, %{
        agents: %{root_id => Decimal.new("3.00")},
        tasks: %{task.id => Decimal.new("3.00")}
      })

      Repo.delete_all(from(c in AgentCost, where: c.task_id == ^task.id))

      {:ok, _} =
        Repo.insert(
          AgentCost.changeset(%AgentCost{}, %{
            agent_id: root_id,
            task_id: task.id,
            cost_type: "llm_consensus",
            cost_usd: nil,
            metadata: %{"model_spec" => "anthropic:claude-sonnet"}
          })
        )

      force_flush(view)

      assigns = current_assigns(view)
      assert Decimal.equal?(assigns.cost_data.tasks[task.id], Decimal.new("3.00"))
    end

    test "R-MG6: session flag disables monotonic guard", context do
      %{task: task, root_id: root_id} = spawn_root_only(context, "R-MG6")

      insert_model_cost_under_child(root_id, task.id,
        cost_usd: Decimal.new("4.00"),
        model_spec: "anthropic:claude-sonnet"
      )

      {:ok, view, _html} =
        live_isolated(context.conn, QuoracleWeb.DashboardLive,
          session: Map.put(base_session(context), "cost_monotonic_guard?", false)
        )

      assert Map.get(current_assigns(view), :cost_monotonic_guard?) == false

      put_prior_cost_data(view, %{
        agents: %{root_id => Decimal.new("4.00")},
        tasks: %{task.id => Decimal.new("4.00")}
      })

      Repo.delete_all(from(c in AgentCost, where: c.task_id == ^task.id))

      insert_model_cost_under_child(root_id, task.id,
        cost_usd: Decimal.new("1.00"),
        model_spec: "openai:gpt-4o"
      )

      force_flush(view)

      assigns = current_assigns(view)

      assert Decimal.equal?(assigns.cost_data.tasks[task.id], Decimal.new("1.00"))
      refute Decimal.equal?(assigns.cost_data.tasks[task.id], Decimal.new("4.00"))
    end

    test "R-MG6b: string false session flag disables monotonic guard", context do
      %{task: task, root_id: root_id} = spawn_root_only(context, "R-MG6b")

      insert_model_cost_under_child(root_id, task.id,
        cost_usd: Decimal.new("4.00"),
        model_spec: "anthropic:claude-sonnet"
      )

      {:ok, view, _html} =
        live_isolated(context.conn, QuoracleWeb.DashboardLive,
          session: Map.put(base_session(context), "cost_monotonic_guard?", "false")
        )

      assert Map.get(current_assigns(view), :cost_monotonic_guard?) == false

      put_prior_cost_data(view, %{
        agents: %{root_id => Decimal.new("4.00")},
        tasks: %{task.id => Decimal.new("4.00")}
      })

      Repo.delete_all(from(c in AgentCost, where: c.task_id == ^task.id))

      insert_model_cost_under_child(root_id, task.id,
        cost_usd: Decimal.new("1.00"),
        model_spec: "openai:gpt-4o"
      )

      force_flush(view)

      assigns = current_assigns(view)

      assert Decimal.equal?(assigns.cost_data.tasks[task.id], Decimal.new("1.00"))
      refute Decimal.equal?(assigns.cost_data.tasks[task.id], Decimal.new("4.00"))
    end

    test "R-MG7: default mount enables guard behavior", context do
      %{task: task, root_id: root_id} = spawn_root_only(context, "R-MG7")

      insert_model_cost_under_child(root_id, task.id,
        cost_usd: Decimal.new("5.00"),
        model_spec: "anthropic:claude-sonnet"
      )

      {:ok, view, _html} =
        live_isolated(context.conn, QuoracleWeb.DashboardLive, session: base_session(context))

      assert Map.get(current_assigns(view), :cost_monotonic_guard?) == true

      put_prior_cost_data(view, %{
        agents: %{root_id => Decimal.new("5.00")},
        tasks: %{task.id => Decimal.new("5.00")}
      })

      Repo.delete_all(from(c in AgentCost, where: c.task_id == ^task.id))

      insert_model_cost_under_child(root_id, task.id,
        cost_usd: Decimal.new("1.00"),
        model_spec: "openai:gpt-4o"
      )

      force_flush(view)

      assigns = current_assigns(view)
      assert Decimal.equal?(assigns.cost_data.tasks[task.id], Decimal.new("5.00"))
    end

    test "R-MG8: task absent from fresh totals is removed", context do
      %{task: task_a, root_id: root_a} = spawn_root_only(context, "R-MG8-A")
      %{task: task_b} = spawn_root_only(context, "R-MG8-B")

      {:ok, view, _html} =
        live_isolated(context.conn, QuoracleWeb.DashboardLive, session: base_session(context))

      assert Map.get(current_assigns(view), :cost_monotonic_guard?) == true

      put_prior_cost_data(view, %{
        agents: %{root_a => Decimal.new("2.00")},
        tasks: %{task_a.id => Decimal.new("2.00"), task_b.id => Decimal.new("9.00")}
      })

      Repo.delete_all(from(c in AgentCost, where: c.task_id in [^task_a.id, ^task_b.id]))

      insert_model_cost_under_child(root_a, task_a.id,
        cost_usd: Decimal.new("1.00"),
        model_spec: "anthropic:claude-sonnet"
      )

      force_flush(view)

      assigns = current_assigns(view)

      refute Map.has_key?(assigns.cost_data.tasks, task_b.id)
      assert Decimal.equal?(assigns.cost_data.tasks[task_a.id], Decimal.new("2.00"))
    end
  end

  defp base_session(context) do
    %{
      "pubsub" => context.pubsub,
      "registry" => context.registry,
      "dynsup" => context.dynsup,
      "sandbox_owner" => context.sandbox_owner,
      "cost_debounce_ms" => 0
    }
  end

  defp dismiss_opts(context, task_id) do
    [
      registry: context.registry,
      dynsup: context.dynsup,
      pubsub: context.pubsub,
      sandbox_owner: context.sandbox_owner,
      task_id: task_id,
      dismiss_complete_notify: self()
    ]
  end

  defp current_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp spawn_root_only(context, prompt) do
    {:ok, {task, root_pid}} =
      create_task_with_cleanup(prompt,
        sandbox_owner: context.sandbox_owner,
        dynsup: context.dynsup,
        registry: context.registry,
        pubsub: context.pubsub,
        force_persist: true
      )

    {:ok, root_state} = Core.get_state(root_pid)

    %{
      task: task,
      root_pid: root_pid,
      root_id: root_state.agent_id
    }
  end

  defp spawn_root_and_child(context, prompt) do
    %{task: task, root_pid: root_pid, root_id: root_id} = spawn_root_only(context, prompt)

    child_id = "child-monotonic-#{System.unique_integer([:positive])}"

    {:ok, child_pid} =
      spawn_agent_with_cleanup(
        context.dynsup,
        %{
          agent_id: child_id,
          task_id: task.id,
          parent_id: root_id,
          parent_pid: root_pid,
          test_mode: true,
          skip_auto_consensus: true,
          force_persist: true,
          sandbox_owner: context.sandbox_owner
        },
        registry: context.registry,
        pubsub: context.pubsub,
        sandbox_owner: context.sandbox_owner
      )

    assert {:ok, _} = Core.get_state(child_pid)

    %{
      task: task,
      root_pid: root_pid,
      root_id: root_id,
      child_pid: child_pid,
      child_id: child_id
    }
  end

  defp insert_model_cost_under_child(agent_id, task_id, opts) do
    cost_usd = Keyword.fetch!(opts, :cost_usd)
    cost_type = Keyword.get(opts, :cost_type, "llm_consensus")

    metadata =
      opts
      |> Keyword.get(:model_spec)
      |> case do
        nil -> %{}
        model_spec -> %{"model_spec" => model_spec}
      end

    {:ok, cost} =
      Repo.insert(
        AgentCost.changeset(%AgentCost{}, %{
          agent_id: agent_id,
          task_id: task_id,
          cost_type: cost_type,
          cost_usd: cost_usd,
          metadata: metadata
        })
      )

    cost
  end

  defp force_flush(view) do
    send(view.pid, :flush_cost_updates)
    render(view)
    render(view)
  end

  defp force_flush_and_extract_total(view, task_id) do
    force_flush(view)
    extract_task_total_from_dom(view, task_id)
  end

  defp extract_task_total_from_dom(view, task_id) do
    html = view |> element("#task-cost-#{task_id}") |> render()

    case Regex.run(~r/\$([0-9]+(?:\.[0-9]+)?)/, html, capture: :all_but_first) do
      [amount] -> Decimal.new(amount)
      _ -> flunk("Expected task cost badge for task #{task_id}, got: #{inspect(html)}")
    end
  end

  defp assert_non_decreasing(samples) do
    samples
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [previous, current] ->
      assert Decimal.compare(current, previous) != :lt,
             "Expected non-decreasing samples, got previous=#{previous} current=#{current}"
    end)
  end

  defp put_prior_cost_data(view, prior_cost_data) do
    :sys.replace_state(view.pid, fn state ->
      socket = Phoenix.Component.assign(state.socket, cost_data: prior_cost_data)
      %{state | socket: socket}
    end)
  end
end
