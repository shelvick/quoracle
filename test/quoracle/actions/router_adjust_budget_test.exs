defmodule Quoracle.Actions.RouterAdjustBudgetTest do
  @moduledoc """
  Tests for ACTION_Router adjust_budget routing (v22.0).
  Part of Packet 1: Action Definition.

  WorkGroupID: feat-20251231-191717

  Tests Router's ability to route adjust_budget action to AdjustBudget module.
  """

  use Quoracle.DataCase, async: true
  alias Quoracle.Actions.Router
  alias Test.IsolationHelpers

  setup tags do
    # Create isolated dependencies
    deps = IsolationHelpers.create_isolated_deps()

    agent_id = "agent-parent-#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0)
    {:ok, router_pid} =
      Router.start_link(
        action_type: :adjust_budget,
        action_id: "action-#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: deps.pubsub,
        registry: deps.registry,
        sandbox_owner: tags[:sandbox_owner]
      )

    on_exit(fn ->
      if Process.alive?(router_pid) do
        try do
          GenServer.stop(router_pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{
      router: router_pid,
      deps: deps,
      agent_id: agent_id,
      capability_groups: [:hierarchy]
    }
  end

  describe "adjust_budget routing (v22.0)" do
    # R11: Action Execution [INTEGRATION]
    test "R11: Router executes adjust_budget action", %{
      router: router,
      deps: deps,
      agent_id: agent_id,
      capability_groups: capability_groups
    } do
      # [INTEGRATION] - WHEN Router.execute called with adjust_budget THEN routes to AdjustBudget.execute
      config = %{
        agent_id: agent_id
      }

      Registry.register(deps.registry, {:agent, agent_id}, config)

      opts =
        Map.to_list(deps) ++
          [
            action_id: "action-budget-#{System.unique_integer()}",
            capability_groups: capability_groups
          ]

      params = %{
        "child_id" => "child-agent-123",
        "new_budget" => "50.00"
      }

      # Execute adjust_budget action - should route to AdjustBudget module
      result = Router.execute(router, :adjust_budget, params, agent_id, opts)

      # Handle both sync and async responses
      response =
        case result do
          {:ok, resp} ->
            {:ok, resp}

          {:async, ref} ->
            Router.await_result(router, ref)

          {:error, reason} ->
            {:error, reason}
        end

      # Verify routing worked - should NOT return :unknown_action or :not_implemented
      # After implementation, the action will either succeed or fail with business logic errors
      case response do
        {:ok, %{action: action_name}} ->
          # Routing succeeded and action executed
          assert action_name == "adjust_budget"

        {:error, reason} ->
          # Routing must have worked - these errors prove the action module was reached
          # :unknown_action/:not_implemented mean routing FAILED (TEST phase expected failure)
          refute reason == :unknown_action, "Action not in schema - routing failed"
          refute reason == :not_implemented, "Action not in ActionMapper - routing failed"
          # Business logic errors prove routing worked
          assert reason in [
                   :child_not_found,
                   :not_direct_child,
                   :parent_not_found,
                   :insufficient_budget
                 ]
      end
    end
  end
end
