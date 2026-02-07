defmodule Quoracle.Actions.RouterBudgetTest do
  @moduledoc """
  Integration tests for ACTION_Router v21.0 budget enforcement.

  Tests pre-action budget checking: costly actions blocked when over_budget=true,
  free actions always allowed.

  WorkGroupID: wip-20251231-budget
  Packet: 4 (Enforcement)
  """
  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Actions.Router

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated PubSub instance for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    agent_id = "test-agent-budget-#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0) - use :orient as it's a free action for budget tests
    # Budget checks happen in ClientAPI before Router is invoked, so action_type
    # mainly matters for tests that execute to completion
    {:ok, router} =
      Router.start_link(
        action_type: :orient,
        action_id: "action-#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub_name,
        sandbox_owner: sandbox_owner
      )

    on_exit(fn ->
      if Process.alive?(router) do
        try do
          GenServer.stop(router, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, router: router, pubsub: pubsub_name, agent_id: agent_id}
  end

  describe "R4: Block costly actions when over budget" do
    test "blocks spawn_child when over_budget=true", %{router: router, agent_id: agent_id} do
      opts = [over_budget: true]

      capture_log(fn ->
        result = Router.execute(router, :spawn_child, %{prompt: "test"}, agent_id, opts)
        send(self(), {:result, result})
      end)

      assert_receive {:result, {:error, :budget_exceeded}}
    end

    test "blocks call_api when over_budget=true", %{router: router, agent_id: agent_id} do
      opts = [over_budget: true]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :call_api,
            %{endpoint: "http://test.com", method: "GET"},
            agent_id,
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, {:error, :budget_exceeded}}
    end

    test "blocks fetch_web when over_budget=true", %{router: router, agent_id: agent_id} do
      opts = [over_budget: true]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :fetch_web,
            %{url: "http://test.com"},
            agent_id,
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, {:error, :budget_exceeded}}
    end

    test "blocks answer_engine when over_budget=true", %{router: router, agent_id: agent_id} do
      opts = [over_budget: true]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :answer_engine,
            %{query: "test query"},
            agent_id,
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, {:error, :budget_exceeded}}
    end

    test "blocks generate_images when over_budget=true", %{router: router, agent_id: agent_id} do
      opts = [over_budget: true]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :generate_images,
            %{prompt: "test image"},
            agent_id,
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, {:error, :budget_exceeded}}
    end

    test "blocks new shell command when over_budget=true", %{router: router, agent_id: agent_id} do
      opts = [over_budget: true]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :execute_shell,
            %{command: "ls -la"},
            agent_id,
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, {:error, :budget_exceeded}}
    end
  end

  describe "R5: Allow free actions when over budget" do
    test "allows orient when over_budget=true", %{router: router, agent_id: agent_id} do
      opts = [over_budget: true]

      params = %{
        current_situation: "Testing budget",
        goal_clarity: "Clear",
        available_resources: "Test env",
        key_challenges: "None",
        delegation_consideration: "None"
      }

      capture_log(fn ->
        result = Router.execute(router, :orient, params, agent_id, opts)
        send(self(), {:result, result})
      end)

      assert_receive {:result, result}
      # Orient should succeed (return {:ok, ...}) not be blocked
      assert match?({:ok, _}, result)
    end

    test "allows wait when over_budget=true", %{router: router, agent_id: agent_id} do
      opts = [over_budget: true]

      capture_log(fn ->
        result = Router.execute(router, :wait, %{wait: 0.01}, agent_id, opts)
        send(self(), {:result, result})
      end)

      assert_receive {:result, result}
      assert match?({:ok, _}, result)
    end

    test "allows send_message when over_budget=true", %{
      router: router,
      pubsub: pubsub,
      agent_id: agent_id
    } do
      opts = [over_budget: true, pubsub: pubsub]

      params = %{
        recipient: "parent",
        message: "Test message"
      }

      capture_log(fn ->
        result = Router.execute(router, :send_message, params, agent_id, opts)
        send(self(), {:result, result})
      end)

      assert_receive {:result, result}
      # send_message should proceed, not be blocked
      refute match?({:error, :budget_exceeded}, result)
    end

    test "allows shell check_id when over_budget=true", %{router: router, agent_id: agent_id} do
      opts = [over_budget: true]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :execute_shell,
            %{check_id: "shell-123"},
            agent_id,
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, result}
      # May error for other reasons (no shell), but not :budget_exceeded
      refute match?({:error, :budget_exceeded}, result)
    end

    test "allows record_cost when over_budget=true", %{router: router, agent_id: agent_id} do
      # CRITICAL: record_cost is accounting reality, not permission
      # Must ALWAYS be allowed even when over budget
      opts = [over_budget: true]

      params = %{
        agent_id: agent_id,
        cost: Decimal.new("0.05"),
        model: "test-model",
        action: "test-action"
      }

      capture_log(fn ->
        result = Router.execute(router, :record_cost, params, agent_id, opts)
        send(self(), {:result, result})
      end)

      assert_receive {:result, result}
      # record_cost must NEVER be blocked by budget enforcement
      refute match?({:error, :budget_exceeded}, result),
             "record_cost must ALWAYS be allowed - it's accounting truth, not permission"
    end
  end

  describe "R6: Allow all actions when under budget" do
    test "allows costly actions when over_budget=false", %{router: router, agent_id: agent_id} do
      opts = [over_budget: false]

      # spawn_child will fail for other reasons (no registry), but not budget
      capture_log(fn ->
        result = Router.execute(router, :spawn_child, %{prompt: "test"}, agent_id, opts)
        send(self(), {:result, result})
      end)

      assert_receive {:result, result}
      refute match?({:error, :budget_exceeded}, result)
    end
  end

  describe "R7: Default behavior" do
    test "defaults to allowing actions when over_budget not specified", %{
      router: router,
      agent_id: agent_id
    } do
      # No over_budget in opts
      opts = []

      # spawn_child will fail for other reasons, but not budget
      capture_log(fn ->
        result = Router.execute(router, :spawn_child, %{prompt: "test"}, agent_id, opts)
        send(self(), {:result, result})
      end)

      assert_receive {:result, result}
      refute match?({:error, :budget_exceeded}, result)
    end
  end

  describe "R8: Costly actions list" do
    test "all LLM-calling actions are marked costly", %{router: router, agent_id: agent_id} do
      costly_actions = [
        {:spawn_child, %{prompt: "test"}},
        {:answer_engine, %{query: "test"}},
        {:execute_shell, %{command: "ls"}},
        {:fetch_web, %{url: "http://test.com"}},
        {:call_api, %{endpoint: "http://test.com", method: "GET"}},
        {:call_mcp, %{server: "test", tool: "test", arguments: %{}}},
        {:generate_images, %{prompt: "test"}}
      ]

      opts = [over_budget: true]

      for {action, params} <- costly_actions do
        capture_log(fn ->
          result = Router.execute(router, action, params, agent_id, opts)
          send(self(), {:result, action, result})
        end)

        assert_receive {:result, ^action, {:error, :budget_exceeded}},
                       500,
                       "#{action} should be blocked when over budget"
      end
    end
  end

  describe "R9: Error message" do
    test "budget_exceeded error is informative", %{router: router, agent_id: agent_id} do
      opts = [over_budget: true]

      capture_log(fn ->
        result = Router.execute(router, :spawn_child, %{prompt: "test"}, agent_id, opts)
        send(self(), {:result, result})
      end)

      assert_receive {:result, {:error, :budget_exceeded}}
      # The error atom :budget_exceeded should be sufficient for router
      # Detailed message handled by AGENT_Core when formatting for LLM
    end
  end
end
