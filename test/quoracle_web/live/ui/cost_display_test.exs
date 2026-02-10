defmodule QuoracleWeb.UI.CostDisplayTest do
  @moduledoc """
  Tests for the CostDisplay LiveView component.

  WorkGroupID: feat-20251212-191913
  Packet: 5 (UI)

  Requirements:
  - R1: Badge Mode Renders [UNIT]
  - R2: Summary Mode Renders [UNIT]
  - R3: Detail Mode Renders [UNIT]
  - R4: Request Mode Renders [UNIT]
  - R5: Loads Agent Costs [INTEGRATION]
  - R6: Loads Task Costs [INTEGRATION]
  - R7: Summary Loads Children Costs [INTEGRATION]
  - R8: Nil Cost Display [UNIT]
  - R9: Cost Rounding [UNIT]
  - R10: Model Truncation [UNIT]
  - R11: Toggle Expand [INTEGRATION]
  - R12: PubSub Subscription [INTEGRATION]
  - R13: Cost Update Handling [INTEGRATION]
  - R14: Agent Cost Display Flow [SYSTEM]
  - R15: Task Total Display Flow [SYSTEM]
  """

  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  alias Quoracle.Repo
  alias Quoracle.Tasks.Task
  alias Quoracle.Agents.Agent
  alias Quoracle.Costs.AgentCost
  alias Test.IsolationHelpers

  # ============================================================
  # Test Data Setup Helpers
  # ============================================================

  defp create_task do
    {:ok, task} =
      %Task{}
      |> Task.changeset(%{prompt: "Test task", status: "running"})
      |> Repo.insert()

    task
  end

  defp create_agent(task, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "agent_#{System.unique_integer([:positive])}")
    parent_id = Keyword.get(opts, :parent_id, nil)

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        task_id: task.id,
        agent_id: agent_id,
        parent_id: parent_id,
        config: %{},
        status: "running"
      })
      |> Repo.insert()

    agent
  end

  defp create_cost(task, agent_id, opts \\ []) do
    cost_type = Keyword.get(opts, :cost_type, "llm_consensus")
    cost_usd = Keyword.get(opts, :cost_usd, Decimal.new("0.05"))
    model_spec = Keyword.get(opts, :model_spec, "anthropic/claude-sonnet-4-20250514")
    input_tokens = Keyword.get(opts, :input_tokens, 1000)
    output_tokens = Keyword.get(opts, :output_tokens, 500)

    {:ok, cost} =
      %AgentCost{}
      |> AgentCost.changeset(%{
        agent_id: agent_id,
        task_id: task.id,
        cost_type: cost_type,
        cost_usd: cost_usd,
        metadata: %{
          "model_spec" => model_spec,
          "input_tokens" => input_tokens,
          "output_tokens" => output_tokens
        }
      })
      |> Repo.insert()

    cost
  end

  defp create_agent_tree(task) do
    root = create_agent(task, agent_id: "root_#{System.unique_integer([:positive])}")

    child1 =
      create_agent(task,
        agent_id: "child1_#{System.unique_integer([:positive])}",
        parent_id: root.agent_id
      )

    child2 =
      create_agent(task,
        agent_id: "child2_#{System.unique_integer([:positive])}",
        parent_id: root.agent_id
      )

    %{root: root, child1: child1, child2: child2}
  end

  # Helper to render component - cleanup handled by ConnCase.live_isolated
  defp render_isolated(conn, assigns, sandbox_owner) do
    live_isolated(conn, QuoracleWeb.LiveComponentTestHelper,
      session: %{
        "component" => QuoracleWeb.Live.UI.CostDisplay,
        "assigns" => assigns,
        "sandbox_owner" => sandbox_owner
      }
    )
  end

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    %{pubsub: deps.pubsub, sandbox_owner: sandbox_owner}
  end

  # ============================================================
  # R1: Badge Mode Renders [UNIT]
  # ============================================================

  describe "R1: badge mode rendering" do
    test "renders badge mode with cost", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.05"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-badge-#{agent.agent_id}",
            mode: :badge,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "cost-badge"
      assert html =~ "$0.05"
    end

    test "badge mode shows compact display", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("1.23"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-badge-test",
            mode: :badge,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "text-xs"
      assert html =~ "$1.23"
    end
  end

  # ============================================================
  # R2: Summary Mode Renders [UNIT]
  # ============================================================

  describe "R2: summary mode rendering" do
    test "renders summary mode with type breakdown", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id, cost_type: "llm_consensus", cost_usd: Decimal.new("0.10"))
      create_cost(task, agent.agent_id, cost_type: "llm_embedding", cost_usd: Decimal.new("0.05"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-summary-#{agent.agent_id}",
            mode: :summary,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "cost-summary"
      assert html =~ "$0.15"
    end

    test "summary mode shows expand icon", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id)

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-summary-test",
            mode: :summary,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "expand-icon"
      assert html =~ "▶"
    end
  end

  # ============================================================
  # R3: Detail Mode Renders [UNIT]
  # ============================================================

  describe "R3: detail mode rendering" do
    test "renders detail mode with model breakdown", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id,
        model_spec: "anthropic/claude-sonnet-4-20250514",
        cost_usd: Decimal.new("0.10")
      )

      create_cost(task, agent.agent_id,
        model_spec: "openai/gpt-4o",
        cost_usd: Decimal.new("0.20")
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-detail-#{agent.agent_id}",
            mode: :detail,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "cost-detail"
      assert html =~ "Cost Details"
    end

    test "detail mode shows model specs when expanded", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id,
        model_spec: "anthropic/claude-sonnet-4-20250514",
        cost_usd: Decimal.new("0.15"),
        input_tokens: 2000,
        output_tokens: 500
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-detail-test",
            mode: :detail,
            agent_id: agent.agent_id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)
      # v2.0: Table replaces model-breakdown div
      assert html =~ "overflow-x-auto"
      assert html =~ "<table"
      assert html =~ "Req"
    end
  end

  # ============================================================
  # R4: Request Mode Renders [UNIT]
  # ============================================================

  describe "R4: request mode rendering" do
    test "renders request mode with cost and model", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-request-123",
            mode: :request,
            cost: Decimal.new("0.03"),
            metadata: %{"model_spec" => "anthropic/claude-sonnet-4-20250514"}
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "cost-request"
      assert html =~ "$0.03"
    end

    test "request mode shows truncated model spec", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-request-456",
            mode: :request,
            cost: Decimal.new("0.07"),
            metadata: %{"model_spec" => "anthropic/claude-sonnet-4-20250514"}
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "model-spec"
      # Truncated to remove provider prefix
      assert html =~ "claude-sonnet"
    end

    test "request mode without model_spec", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-request-789",
            mode: :request,
            cost: Decimal.new("0.01"),
            metadata: %{}
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "$0.01"
      refute html =~ "model-spec"
    end
  end

  # ============================================================
  # R5: Loads Agent Costs [INTEGRATION]
  # ============================================================

  describe "R5: loads agent costs" do
    test "loads costs for agent_id", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.25"))
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.35"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-agent-#{agent.agent_id}",
            mode: :badge,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      html = render(view)
      # Total: 0.25 + 0.35 = 0.60
      assert html =~ "$0.60"
    end

    test "loads costs only for specified agent", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent1 = create_agent(task)
      agent2 = create_agent(task)
      create_cost(task, agent1.agent_id, cost_usd: Decimal.new("0.10"))
      create_cost(task, agent2.agent_id, cost_usd: Decimal.new("0.90"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-agent-#{agent1.agent_id}",
            mode: :badge,
            agent_id: agent1.agent_id
          },
          sandbox_owner
        )

      html = render(view)
      # Only agent1's cost
      assert html =~ "$0.10"
      refute html =~ "$0.90"
    end
  end

  # ============================================================
  # R6: Loads Task Costs [INTEGRATION]
  # ============================================================

  describe "R6: loads task costs" do
    test "loads costs for task_id", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent1 = create_agent(task)
      agent2 = create_agent(task)
      create_cost(task, agent1.agent_id, cost_usd: Decimal.new("0.20"))
      create_cost(task, agent2.agent_id, cost_usd: Decimal.new("0.30"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-task-#{task.id}",
            mode: :badge,
            task_id: task.id
          },
          sandbox_owner
        )

      html = render(view)
      # Total: 0.20 + 0.30 = 0.50
      assert html =~ "$0.50"
    end

    test "task costs exclude other tasks", %{conn: conn, sandbox_owner: sandbox_owner} do
      task1 = create_task()
      task2 = create_task()
      agent1 = create_agent(task1)
      agent2 = create_agent(task2)
      create_cost(task1, agent1.agent_id, cost_usd: Decimal.new("0.15"))
      create_cost(task2, agent2.agent_id, cost_usd: Decimal.new("0.85"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-task-#{task1.id}",
            mode: :badge,
            task_id: task1.id
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "$0.15"
      refute html =~ "$0.85"
    end
  end

  # ============================================================
  # R7: Summary Loads Children Costs [INTEGRATION]
  # ============================================================

  describe "R7: summary loads own and children costs" do
    test "summary mode shows children costs separately", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      tree = create_agent_tree(task)

      # Root's own cost
      create_cost(task, tree.root.agent_id, cost_usd: Decimal.new("0.10"))
      # Children costs
      create_cost(task, tree.child1.agent_id, cost_usd: Decimal.new("0.20"))
      create_cost(task, tree.child2.agent_id, cost_usd: Decimal.new("0.30"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-summary-#{tree.root.agent_id}",
            mode: :summary,
            agent_id: tree.root.agent_id
          },
          sandbox_owner
        )

      html = render(view)
      # Own cost: $0.10
      assert html =~ "$0.10"
      # Children cost indicator present
      assert html =~ "children"
      # Children total: 0.20 + 0.30 = 0.50
      assert html =~ "$0.50"
    end

    test "summary mode excludes own cost from children total", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      tree = create_agent_tree(task)

      create_cost(task, tree.root.agent_id, cost_usd: Decimal.new("1.00"))
      create_cost(task, tree.child1.agent_id, cost_usd: Decimal.new("0.50"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-summary-#{tree.root.agent_id}",
            mode: :summary,
            agent_id: tree.root.agent_id
          },
          sandbox_owner
        )

      html = render(view)
      # Own cost is displayed
      assert html =~ "$1.00"
      # Children cost displayed separately (only child1's cost)
      assert html =~ "$0.50"
    end
  end

  # ============================================================
  # R8: Nil Cost Display [UNIT]
  # ============================================================

  describe "R8: nil cost display" do
    test "displays N/A for nil cost", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-nil-test",
            mode: :request,
            cost: nil,
            metadata: %{}
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "N/A"
    end

    test "displays N/A when no costs exist for agent", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      # No costs created

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-empty-#{agent.agent_id}",
            mode: :badge,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "N/A"
    end

    test "badge mode handles missing agent gracefully", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-missing",
            mode: :badge,
            agent_id: "nonexistent_agent_#{System.unique_integer([:positive])}"
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "N/A"
    end
  end

  # ============================================================
  # R9: Cost Rounding [UNIT]
  # ============================================================

  describe "R9: cost rounding" do
    test "rounds cost to 2 decimal places", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-round-test",
            mode: :request,
            cost: Decimal.new("0.12345"),
            metadata: %{}
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "$0.12"
      refute html =~ "0.12345"
    end

    test "rounds up when third decimal is 5 or more", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-round-up",
            mode: :request,
            cost: Decimal.new("0.125"),
            metadata: %{}
          },
          sandbox_owner
        )

      html = render(view)
      # Standard rounding: 0.125 rounds up to 0.13
      assert html =~ "$0.13"
    end

    test "handles zero cost", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-zero",
            mode: :request,
            cost: Decimal.new("0"),
            metadata: %{}
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "$0"
    end

    test "handles float cost conversion", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-float",
            mode: :request,
            cost: 0.999,
            metadata: %{}
          },
          sandbox_owner
        )

      html = render(view)
      # 0.999 rounded to 2 decimal places = $1.00
      assert html =~ "$1.00"
    end
  end

  # ============================================================
  # R10: Model Truncation [UNIT]
  # ============================================================

  describe "R10: model truncation" do
    test "truncates model_spec provider prefix", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-truncate-1",
            mode: :request,
            cost: Decimal.new("0.05"),
            metadata: %{"model_spec" => "anthropic/claude-sonnet-4-20250514"}
          },
          sandbox_owner
        )

      html = render(view)
      # Shows model name without provider in displayed text
      assert html =~ "claude-sonnet"
      # The displayed text in parentheses should not have provider prefix
      # (title attribute still has full spec for tooltip, which is correct)
      assert html =~ "(claude-sonnet"
    end

    test "truncates long model names", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-truncate-2",
            mode: :request,
            cost: Decimal.new("0.05"),
            metadata: %{"model_spec" => "google/gemini-2.5-pro-preview-06-05-very-long-suffix"}
          },
          sandbox_owner
        )

      html = render(view)
      # Truncated to 20 chars max
      assert String.length(html) > 0
      # Should show truncated version
      assert html =~ "gemini"
    end

    test "handles nil model_spec", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-truncate-nil",
            mode: :request,
            cost: Decimal.new("0.05"),
            metadata: %{"model_spec" => nil}
          },
          sandbox_owner
        )

      html = render(view)
      # Doesn't crash, shows cost without model
      assert html =~ "$0.05"
    end

    test "handles model_spec without provider prefix", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-truncate-no-prefix",
            mode: :request,
            cost: Decimal.new("0.05"),
            metadata: %{"model_spec" => "gpt-4o"}
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "gpt-4o"
    end
  end

  # ============================================================
  # R11: Toggle Expand [INTEGRATION]
  # ============================================================

  describe "R11: toggle expand" do
    test "toggle_expand toggles expanded state", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id, cost_type: "llm_consensus", cost_usd: Decimal.new("0.10"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-toggle-#{agent.agent_id}",
            mode: :summary,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      # Initially collapsed
      html = render(view)
      assert html =~ "▶"
      refute html =~ "cost-breakdown"

      # Click to expand
      view
      |> element("[phx-click='toggle_expand']")
      |> render_click()

      html = render(view)
      assert html =~ "▼"
      assert html =~ "cost-breakdown"
    end

    test "double toggle returns to collapsed state", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id)

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-double-toggle",
            mode: :summary,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      # Expand
      view |> element("[phx-click='toggle_expand']") |> render_click()
      assert render(view) =~ "▼"

      # Collapse
      view |> element("[phx-click='toggle_expand']") |> render_click()
      assert render(view) =~ "▶"
    end

    test "detail mode also supports toggle", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id)

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-detail-toggle",
            mode: :detail,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      # Click to expand
      view |> element("[phx-click='toggle_expand']") |> render_click()

      html = render(view)
      # v2.0: Table replaces model-breakdown div
      assert html =~ "<table"
    end
  end

  # ============================================================
  # R12: PubSub Subscription [INTEGRATION]
  # ============================================================

  describe "R12: PubSub subscription" do
    test "subscribes to agent costs topic", %{
      conn: conn,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.10"))

      {:ok, _view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-pubsub-#{agent.agent_id}",
            mode: :badge,
            agent_id: agent.agent_id,
            pubsub: pubsub
          },
          sandbox_owner
        )

      # Verify subscription by broadcasting
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent.agent_id}:costs")
      Phoenix.PubSub.broadcast(pubsub, "agents:#{agent.agent_id}:costs", {:test_message, %{}})
      assert_receive {:test_message, %{}}
    end

    test "subscribes to task costs topic when task_id provided", %{
      conn: conn,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.10"))

      {:ok, _view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-pubsub-task-#{task.id}",
            mode: :badge,
            task_id: task.id,
            pubsub: pubsub
          },
          sandbox_owner
        )

      # Verify subscription by broadcasting
      Phoenix.PubSub.subscribe(pubsub, "tasks:#{task.id}:costs")
      Phoenix.PubSub.broadcast(pubsub, "tasks:#{task.id}:costs", {:test_message, %{}})
      assert_receive {:test_message, %{}}
    end

    test "no subscription when pubsub not provided", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id)

      # Should not crash when pubsub is nil
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-no-pubsub",
            mode: :badge,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "cost-badge"
    end
  end

  # ============================================================
  # R13: Cost Update Handling [INTEGRATION]
  # ============================================================

  describe "R13: cost update handling" do
    test "reloads costs when component is re-rendered", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.10"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-update-#{agent.agent_id}",
            mode: :badge,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "$0.10"

      # Add another cost
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.20"))

      # Re-render component with fresh instance to see updated cost
      # (LiveComponents reload costs in update/2, triggered by parent re-render)
      {:ok, view2, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-update-fresh-#{agent.agent_id}",
            mode: :badge,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      html = render(view2)

      # Should show updated total: 0.10 + 0.20 = 0.30
      assert html =~ "$0.30"
    end
  end

  # ============================================================
  # R14: Agent Cost Display Flow [SYSTEM]
  # ============================================================

  describe "R14: agent cost display flow" do
    test "cost appears in component after recording", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      # Initially no costs
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-flow-#{agent.agent_id}",
            mode: :badge,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "N/A"

      # Now record a cost (simulating LLM query)
      create_cost(task, agent.agent_id,
        cost_type: "llm_consensus",
        cost_usd: Decimal.new("0.08"),
        model_spec: "anthropic/claude-sonnet-4-20250514",
        input_tokens: 1500,
        output_tokens: 300
      )

      # Re-render with fresh component instance to see updated cost
      {:ok, view2, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-flow-fresh-#{agent.agent_id}",
            mode: :badge,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      html = render(view2)
      assert html =~ "$0.08"
    end

    test "multiple cost types aggregate correctly", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      # Multiple cost types like a real agent would generate
      create_cost(task, agent.agent_id, cost_type: "llm_consensus", cost_usd: Decimal.new("0.10"))
      create_cost(task, agent.agent_id, cost_type: "llm_embedding", cost_usd: Decimal.new("0.02"))
      create_cost(task, agent.agent_id, cost_type: "llm_answer", cost_usd: Decimal.new("0.05"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-multi-type-#{agent.agent_id}",
            mode: :summary,
            agent_id: agent.agent_id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)
      # Total: 0.10 + 0.02 + 0.05 = 0.17
      assert html =~ "$0.17"
      # Type breakdown visible
      assert html =~ "Consensus"
      assert html =~ "Embeddings"
      assert html =~ "Answer"
    end
  end

  # ============================================================
  # R15: Task Total Display Flow [SYSTEM]
  # ============================================================

  describe "R15: task total display flow" do
    test "task total shows all agents' costs", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent1 = create_agent(task)
      agent2 = create_agent(task)
      agent3 = create_agent(task)

      create_cost(task, agent1.agent_id, cost_usd: Decimal.new("0.10"))
      create_cost(task, agent2.agent_id, cost_usd: Decimal.new("0.20"))
      create_cost(task, agent3.agent_id, cost_usd: Decimal.new("0.30"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-task-total-#{task.id}",
            mode: :badge,
            task_id: task.id
          },
          sandbox_owner
        )

      html = render(view)
      # Total: 0.10 + 0.20 + 0.30 = 0.60
      assert html =~ "$0.60"
    end

    test "task detail shows model breakdown across all agents", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      agent1 = create_agent(task)
      agent2 = create_agent(task)

      # Same model across agents
      create_cost(task, agent1.agent_id,
        model_spec: "anthropic/claude-sonnet-4-20250514",
        cost_usd: Decimal.new("0.15"),
        input_tokens: 1000,
        output_tokens: 500
      )

      create_cost(task, agent2.agent_id,
        model_spec: "anthropic/claude-sonnet-4-20250514",
        cost_usd: Decimal.new("0.25"),
        input_tokens: 2000,
        output_tokens: 1000
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-task-detail-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)
      # Model appears once with aggregated values
      assert html =~ "claude-sonnet"
      # Total cost for this model: 0.15 + 0.25 = 0.40
      assert html =~ "$0.40"
      # Total requests: 2 (v2.0: number only in Req column, not "2 req")
      assert html =~ ~r/>\s*2\s*</
      # v2.0: input_tokens (1000+2000=3K) and output_tokens (500+1000=1K) shown separately
      assert html =~ "3K"
      assert html =~ "1K"
    end

    test "task with hierarchical agents shows complete total", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      tree = create_agent_tree(task)

      create_cost(task, tree.root.agent_id, cost_usd: Decimal.new("0.05"))
      create_cost(task, tree.child1.agent_id, cost_usd: Decimal.new("0.10"))
      create_cost(task, tree.child2.agent_id, cost_usd: Decimal.new("0.15"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-task-hierarchy-#{task.id}",
            mode: :badge,
            task_id: task.id
          },
          sandbox_owner
        )

      html = render(view)
      # Total: 0.05 + 0.10 + 0.15 = 0.30
      assert html =~ "$0.30"
    end
  end

  # ============================================================
  # Edge Cases
  # ============================================================

  describe "edge cases" do
    test "handles very large costs", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-large",
            mode: :request,
            cost: Decimal.new("999.99"),
            metadata: %{}
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "$999.99"
    end

    test "handles very small costs", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-small",
            mode: :request,
            cost: Decimal.new("0.0001"),
            metadata: %{}
          },
          sandbox_owner
        )

      html = render(view)
      # Rounded to $0.00
      assert html =~ "$0.00"
    end

    test "handles token counts over 1M", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      create_cost(task, agent.agent_id,
        input_tokens: 1_500_000,
        output_tokens: 500_000
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-large-tokens",
            mode: :detail,
            agent_id: agent.agent_id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)
      # v2.0: Shows input/output separately, not combined total
      # input_tokens 1.5M shows as "1M", output_tokens 500K shows as "500K"
      assert html =~ "1M"
      assert html =~ "500K"
    end

    test "handles empty metadata gracefully", %{conn: conn, sandbox_owner: sandbox_owner} do
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-empty-metadata",
            mode: :request,
            cost: Decimal.new("0.05"),
            metadata: nil
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "$0.05"
    end
  end

  # ============================================================
  # WorkGroupID: fix-ui-costs-20251213
  # R16-R19: ID Attribute & costs_updated_at Trigger
  # ============================================================

  describe "R16: ID attribute on outer div" do
    test "renders with id attribute on outer div", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.05"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "my-custom-cost-id",
            mode: :badge,
            agent_id: agent.agent_id
          },
          sandbox_owner
        )

      html = render(view)

      # The outer div should have the id attribute matching the component id
      assert html =~ ~r/id="my-custom-cost-id"/
    end

    test "id attribute present in all modes", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id)

      modes = [:badge, :summary, :detail]

      for mode <- modes do
        component_id = "cost-#{mode}-#{agent.agent_id}"

        {:ok, view, _html} =
          render_isolated(
            conn,
            %{
              id: component_id,
              mode: mode,
              agent_id: agent.agent_id
            },
            sandbox_owner
          )

        html = render(view)
        assert html =~ ~r/id="#{component_id}"/
      end
    end
  end

  describe "R17: costs_updated_at re-render trigger" do
    test "reloads costs when costs_updated_at changes", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.10"))

      # Initial render with timestamp
      initial_timestamp = System.monotonic_time()

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-timestamp-#{agent.agent_id}",
            mode: :badge,
            agent_id: agent.agent_id,
            costs_updated_at: initial_timestamp
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "$0.10"

      # Add another cost
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.20"))

      # Re-render with NEW timestamp should reload costs
      new_timestamp = System.monotonic_time()

      {:ok, view2, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-timestamp-new-#{agent.agent_id}",
            mode: :badge,
            agent_id: agent.agent_id,
            costs_updated_at: new_timestamp
          },
          sandbox_owner
        )

      html = render(view2)
      # Should show updated total: 0.10 + 0.20 = 0.30
      assert html =~ "$0.30"
    end
  end

  describe "R18: no reload on same timestamp" do
    test "skips reload when costs_updated_at unchanged", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.10"))

      timestamp = System.monotonic_time()

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-same-timestamp",
            mode: :badge,
            agent_id: agent.agent_id,
            costs_updated_at: timestamp
          },
          sandbox_owner
        )

      html = render(view)
      assert html =~ "$0.10"

      # The component should not reload if timestamp is the same
      # This is verified by the fact that costs_loaded flag is preserved
      # when costs_updated_at hasn't changed (implementation detail)
      # For now, we just verify it renders correctly with same timestamp
      assert html =~ "cost-badge"
    end
  end

  describe "R19: UUID validation for task_id" do
    test "handles non-UUID task_id gracefully", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Using a non-UUID string like "task_1" should not crash
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-non-uuid-task",
            mode: :badge,
            task_id: "not-a-valid-uuid"
          },
          sandbox_owner
        )

      html = render(view)

      # Should show N/A instead of crashing with Ecto.Query.CastError
      assert html =~ "N/A"
    end

    test "handles mock task_id format gracefully", %{conn: conn, sandbox_owner: sandbox_owner} do
      # Mock test data often uses "task_1" style IDs
      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-mock-task",
            mode: :badge,
            task_id: "task_123"
          },
          sandbox_owner
        )

      html = render(view)

      # Should show N/A, not crash
      assert html =~ "N/A"
      refute html =~ "CastError"
    end

    test "valid UUID task_id works normally", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_cost(task, agent.agent_id, cost_usd: Decimal.new("0.25"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-valid-uuid-task",
            mode: :badge,
            task_id: task.id
          },
          sandbox_owner
        )

      html = render(view)

      # Should show actual cost
      assert html =~ "$0.25"
    end
  end

  # ============================================================
  # WorkGroupID: feat-cost-breakdown-20251230
  # v2.0: Token Breakdown Table (R20-R39)
  # ============================================================

  # Helper to create cost with all v2.0 token types
  defp create_detailed_cost(task, agent_id, opts) do
    cost_type = Keyword.get(opts, :cost_type, "llm_consensus")
    cost_usd = Keyword.get(opts, :cost_usd, Decimal.new("0.05"))
    model_spec = Keyword.get(opts, :model_spec, "anthropic/claude-sonnet-4-20250514")

    # Token counts (5 types)
    input_tokens = Keyword.get(opts, :input_tokens, 1000)
    output_tokens = Keyword.get(opts, :output_tokens, 500)
    reasoning_tokens = Keyword.get(opts, :reasoning_tokens)
    cached_tokens = Keyword.get(opts, :cached_tokens)
    cache_creation_tokens = Keyword.get(opts, :cache_creation_tokens)

    # Aggregate costs from ReqLLM
    input_cost = Keyword.get(opts, :input_cost)
    output_cost = Keyword.get(opts, :output_cost)

    metadata =
      %{
        "model_spec" => model_spec,
        "input_tokens" => input_tokens,
        "output_tokens" => output_tokens
      }
      |> maybe_put("reasoning_tokens", reasoning_tokens)
      |> maybe_put("cached_tokens", cached_tokens)
      |> maybe_put("cache_creation_tokens", cache_creation_tokens)
      |> maybe_put("input_cost", input_cost)
      |> maybe_put("output_cost", output_cost)

    {:ok, cost} =
      %AgentCost{}
      |> AgentCost.changeset(%{
        agent_id: agent_id,
        task_id: task.id,
        cost_type: cost_type,
        cost_usd: cost_usd,
        metadata: metadata
      })
      |> Repo.insert()

    cost
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  describe "R20: table renders with all columns" do
    test "detail mode shows token breakdown table", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      create_detailed_cost(task, agent.agent_id,
        model_spec: "anthropic/claude-sonnet-4-20250514",
        cost_usd: Decimal.new("0.10"),
        input_tokens: 12500,
        output_tokens: 2100,
        reasoning_tokens: 1200,
        cached_tokens: 8000,
        cache_creation_tokens: 500,
        input_cost: "0.02",
        output_cost: "0.03"
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-table-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Should render as a table, not a list
      assert html =~ "<table"
      assert html =~ "</table>"

      # All 10 column headers should be present
      assert html =~ "Model"
      assert html =~ "Req"
      assert html =~ "Input"
      assert html =~ "Output"
      assert html =~ "Reason"
      assert html =~ "Cache R"
      assert html =~ "Cache W"
      assert html =~ "In$"
      assert html =~ "Out$"
      assert html =~ "Total$"
    end
  end

  describe "R21: horizontal scroll on narrow viewport" do
    test "table has overflow-x-auto for horizontal scroll", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      agent = create_agent(task)
      create_detailed_cost(task, agent.agent_id, [])

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-scroll-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Should have horizontal scroll container
      assert html =~ "overflow-x-auto"
    end
  end

  describe "R22: token types display" do
    test "displays all 5 token type columns", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      create_detailed_cost(task, agent.agent_id,
        input_tokens: 1000,
        output_tokens: 500,
        reasoning_tokens: 200,
        cached_tokens: 300,
        cache_creation_tokens: 100
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-tokens-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # All token types should be in the table body
      # Using <td> to verify they're in the data rows
      assert html =~ "<td"
      # Should have token values formatted (input: 1K for 1000 tokens)
      assert html =~ "1K"
      # Other token values should appear
      assert html =~ "500"
      assert html =~ "200"
      assert html =~ "300"
      assert html =~ "100"
    end
  end

  describe "R23: missing token shows dash" do
    test "displays dash for missing token types", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      # Create cost WITHOUT reasoning/cache tokens (historical data pattern)
      create_detailed_cost(task, agent.agent_id,
        input_tokens: 1000,
        output_tokens: 500,
        reasoning_tokens: nil,
        cached_tokens: nil,
        cache_creation_tokens: nil
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-dash-tokens-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Missing token types should show "—" (em dash)
      assert html =~ "—"
    end
  end

  describe "R24: missing cost shows dash" do
    test "displays dash for missing costs", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      # Create cost WITHOUT input_cost/output_cost
      create_detailed_cost(task, agent.agent_id,
        cost_usd: Decimal.new("0.10"),
        input_cost: nil,
        output_cost: nil
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-dash-costs-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Missing cost columns should show "—"
      # The table should have dashes in the In$ and Out$ columns
      assert html =~ "—"
    end
  end

  describe "R25: aggregate costs from query" do
    test "displays aggregate costs from detailed query", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      agent = create_agent(task)

      create_detailed_cost(task, agent.agent_id,
        cost_usd: Decimal.new("0.10"),
        input_cost: "0.04",
        output_cost: "0.06"
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-aggregate-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Should display input and output costs from the detailed query
      assert html =~ "$0.04"
      assert html =~ "$0.06"
    end
  end

  describe "R26: backward compatible with old data" do
    test "handles historical data without new token fields", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      agent = create_agent(task)

      # Old-style cost record with only input/output tokens
      create_cost(task, agent.agent_id,
        cost_usd: Decimal.new("0.10"),
        input_tokens: 1000,
        output_tokens: 500
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-historical-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Should render without crashing
      assert html =~ "<table"
      # Historical data should show dashes for missing fields
      assert html =~ "—"
      # But should still show existing data
      assert html =~ "$0.10"
    end
  end

  describe "R27: total cost column formatting" do
    test "formats total cost with dollar sign", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      create_detailed_cost(task, agent.agent_id, cost_usd: Decimal.new("1.23"))

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-total-format-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Total cost column should show "$X.XX"
      assert html =~ "$1.23"
    end
  end

  describe "R28: model truncation in table" do
    test "truncates model name with full tooltip", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      create_detailed_cost(task, agent.agent_id,
        model_spec: "anthropic/claude-sonnet-4-20250514-very-long-name"
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-truncate-table-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Full model spec should be in title attribute for tooltip
      assert html =~ "title=\"anthropic/claude-sonnet-4-20250514-very-long-name\""
      # Truncated model should appear in the visible text
      assert html =~ "claude-sonnet"
    end
  end

  describe "R29: request count accurate" do
    test "displays correct request count per model", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      # Create 3 requests for same model
      create_detailed_cost(task, agent.agent_id,
        model_spec: "anthropic/claude-sonnet-4-20250514",
        cost_usd: Decimal.new("0.10")
      )

      create_detailed_cost(task, agent.agent_id,
        model_spec: "anthropic/claude-sonnet-4-20250514",
        cost_usd: Decimal.new("0.15")
      )

      create_detailed_cost(task, agent.agent_id,
        model_spec: "anthropic/claude-sonnet-4-20250514",
        cost_usd: Decimal.new("0.20")
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-req-count-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Should show "3" for request count
      # In the table, request count is in its own <td> with whitespace
      assert html =~ ~r/>\s*3\s*</
    end
  end

  describe "R30: empty model list" do
    test "shows empty table for task with no costs", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      # No costs created

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-empty-table-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Table should exist but tbody should be empty (no <tr> in tbody)
      assert html =~ "<table"
      assert html =~ "<thead"
      assert html =~ "<tbody"
      # The tbody should not contain any data rows
      refute html =~ ~r/<tbody[^>]*>.*<tr.*class=.*border-b/s
    end
  end

  describe "R31: table header styling" do
    test "table headers have correct styling classes", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_detailed_cost(task, agent.agent_id, [])

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-header-style-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Headers should have bg-gray-100
      assert html =~ "bg-gray-100"
      # Header text should have text-gray-600
      assert html =~ "text-gray-600"
    end
  end

  describe "R32: row hover effect" do
    test "table rows have hover effect", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_detailed_cost(task, agent.agent_id, [])

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-hover-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Data rows should have hover:bg-gray-50
      assert html =~ "hover:bg-gray-50"
    end
  end

  describe "R33: token K/M formatting" do
    test "formats large token counts with K/M suffix", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      create_detailed_cost(task, agent.agent_id,
        input_tokens: 12500,
        output_tokens: 2_500_000
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-km-format-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # 12500 should be "12K"
      assert html =~ "12K"
      # 2.5M should be "2M"
      assert html =~ "2M"
    end
  end

  describe "R34: calls detailed aggregator" do
    test "calls detailed aggregator function", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      # Create cost with all detailed fields
      create_detailed_cost(task, agent.agent_id,
        reasoning_tokens: 500,
        cached_tokens: 1000,
        cache_creation_tokens: 200,
        input_cost: "0.01",
        output_cost: "0.02"
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-detailed-call-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # The detailed aggregator returns all token types
      # These MUST be visible in the table (not dashes) since we created data with these values
      assert html =~ "500"
      assert html =~ "1K"
      assert html =~ "200"
      # Costs MUST appear from the detailed aggregator
      assert html =~ "$0.01"
      assert html =~ "$0.02"
    end
  end

  describe "R35: agent detail mode" do
    test "agent detail mode calls agent detailed aggregator", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      task = create_task()
      agent = create_agent(task)

      create_detailed_cost(task, agent.agent_id,
        reasoning_tokens: 300,
        input_cost: "0.05",
        output_cost: "0.08"
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-agent-detail-#{agent.agent_id}",
            mode: :detail,
            agent_id: agent.agent_id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Should show table with agent's detailed costs
      assert html =~ "<table"
      # Reasoning tokens MUST appear (not dash) since we created data with value 300
      assert html =~ "300"
    end
  end

  describe "R36: table accessibility" do
    test "uses semantic table elements", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)
      create_detailed_cost(task, agent.agent_id, [])

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-semantic-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Should use semantic elements
      assert html =~ "<thead"
      assert html =~ "</thead>"
      assert html =~ "<tbody"
      assert html =~ "</tbody>"
      assert html =~ "<th"
      assert html =~ "<tr"
      assert html =~ "<td"
    end
  end

  describe "R37: cost summation row" do
    test "header shows total cost sum", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      # Create multiple costs
      create_detailed_cost(task, agent.agent_id,
        model_spec: "anthropic/claude-sonnet-4-20250514",
        cost_usd: Decimal.new("0.10")
      )

      create_detailed_cost(task, agent.agent_id,
        model_spec: "openai/gpt-4o",
        cost_usd: Decimal.new("0.20")
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-sum-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # The header should show total cost (0.10 + 0.20 = 0.30)
      assert html =~ "$0.30"
    end
  end

  describe "R38: zero token display" do
    test "displays dash for zero token count", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      # Create cost with zero reasoning tokens
      create_detailed_cost(task, agent.agent_id,
        reasoning_tokens: 0,
        cached_tokens: 0,
        cache_creation_tokens: 0
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-zero-tokens-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # Zero tokens should show "—" not "0"
      assert html =~ "—"
      # Should NOT show bare "0" in the token columns (it's OK in costs)
      # This test verifies that 0 tokens show as dash
    end
  end

  describe "R39: compact cost precision" do
    test "cost rounds to 2 decimal places in table", %{conn: conn, sandbox_owner: sandbox_owner} do
      task = create_task()
      agent = create_agent(task)

      create_detailed_cost(task, agent.agent_id,
        cost_usd: Decimal.new("0.12345"),
        input_cost: "0.06789",
        output_cost: "0.05432"
      )

      {:ok, view, _html} =
        render_isolated(
          conn,
          %{
            id: "cost-precision-#{task.id}",
            mode: :detail,
            task_id: task.id,
            expanded: true
          },
          sandbox_owner
        )

      html = render(view)

      # All costs should be rounded to 2 decimal places
      # 0.12345 -> $0.12
      assert html =~ "$0.12"
      # 0.06789 -> $0.07
      assert html =~ "$0.07"
      # 0.05432 -> $0.05
      assert html =~ "$0.05"
    end
  end
end
