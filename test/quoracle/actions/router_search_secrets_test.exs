defmodule Quoracle.Actions.RouterSearchSecretsTest do
  @moduledoc """
  Tests for ACTION_Router search_secrets routing (v18.0).
  Part of Packet 1: Foundation.

  Tests Router's ability to:
  - Route search_secrets action to SearchSecrets module
  - Allow access to any agent with appropriate profile
  """

  use Quoracle.DataCase, async: true
  alias Quoracle.Actions.Router
  alias Test.IsolationHelpers

  setup tags do
    # Create isolated dependencies
    deps = IsolationHelpers.create_isolated_deps()

    agent_id = "agent-test-#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0)
    {:ok, router_pid} =
      Router.start_link(
        action_type: :search_secrets,
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
      capability_groups: [:local_execution]
    }
  end

  describe "search_secrets routing (v18.0)" do
    # R2: No Access Control for search_secrets
    test "search_secrets accessible to all agents", %{
      router: router,
      deps: deps,
      agent_id: agent_id,
      capability_groups: capability_groups
    } do
      # [INTEGRATION] - WHEN execute called for search_secrets THEN proceeds normally
      # Register a test agent
      config = %{
        agent_id: agent_id
      }

      Registry.register(deps.registry, {:agent, agent_id}, config)

      opts = Map.to_list(deps) ++ [action_id: "action-123", capability_groups: capability_groups]
      params = %{"search_terms" => ["test"]}

      # Should succeed for any agent
      result = Router.execute(router, :search_secrets, params, agent_id, opts)

      # Handle both sync and async responses (Router may return either)
      response =
        case result do
          {:ok, resp} ->
            resp

          {:async, ref} ->
            {:ok, resp} = Router.await_result(router, ref)
            resp
        end

      # Must return search result - proves no access control blocks generalists
      assert response.action == "search_secrets"
    end

    # R3: search_secrets Routing End-to-End
    test "Router correctly routes search_secrets action to module", %{
      router: router,
      deps: deps,
      agent_id: agent_id,
      capability_groups: capability_groups
    } do
      # [INTEGRATION] - WHEN Router.execute called with search_secrets action THEN routes to SearchSecrets.execute/3
      config = %{
        agent_id: agent_id
      }

      Registry.register(deps.registry, {:agent, agent_id}, config)

      opts = Map.to_list(deps) ++ [action_id: "action-456", capability_groups: capability_groups]
      params = %{"search_terms" => ["nonexistent_term"]}

      # Execute and verify it routes to SearchSecrets module
      result = Router.execute(router, :search_secrets, params, agent_id, opts)

      # Handle both sync and async responses (Router may return either)
      response =
        case result do
          {:ok, resp} ->
            resp

          {:async, ref} ->
            {:ok, resp} = Router.await_result(router, ref)
            resp
        end

      # Should return search results with correct format
      assert %{action: "search_secrets", matching_secrets: names} = response
      assert is_list(names)
    end
  end
end
