defmodule Quoracle.Actions.RouterApiTest do
  @moduledoc """
  Integration tests for Router handling of call_api action.
  Tests Router dispatch, parameter validation, lifecycle events, and security integration.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Router

  setup tags do
    # Isolated PubSub per test
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    # Isolated registry
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})

    agent_id = "agent-#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0) - requires action context
    # Using self() as agent_pid - Router monitors this and terminates if it dies
    {:ok, router} =
      Router.start_link(
        action_type: :call_api,
        action_id: "action-#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub,
        sandbox_owner: tags[:sandbox_owner]
      )

    # Wait for init to complete
    :pong = GenServer.call(router, :ping)

    # Cleanup - Router may terminate after action, so handle gracefully
    on_exit(fn ->
      if Process.alive?(router) do
        try do
          GenServer.stop(router, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{
      router: router,
      pubsub: pubsub,
      registry: registry,
      agent_id: agent_id,
      capability_groups: [:external_api]
    }
  end

  describe "Router dispatch for call_api [INTEGRATION]" do
    test "routes call_api action to Api module", %{
      agent_id: agent_id,
      router: router,
      pubsub: pubsub,
      registry: registry,
      capability_groups: capability_groups
    } do
      action_map = %{
        action: "call_api",
        params: %{
          api_type: "rest",
          url: "http://localhost:1/test",
          method: "GET"
        },
        reasoning: "Testing routing (connection will fail)"
      }

      # Should dispatch to Api module (connection error is expected and deterministic)
      result =
        Router.execute(router, :call_api, action_map[:params], agent_id,
          pubsub: pubsub,
          registry: registry,
          capability_groups: capability_groups,
          timeout: 30_000
        )

      assert {:error, :connection_refused} = result
    end

    test "validates call_api parameters through Schema", %{
      agent_id: agent_id,
      router: router,
      pubsub: pubsub,
      registry: registry,
      capability_groups: capability_groups
    } do
      # Missing required parameter (url)
      action_map = %{
        action: "call_api",
        params: %{
          api_type: "rest",
          method: "GET"
        },
        reasoning: "Invalid params"
      }

      result =
        Router.execute(router, :call_api, action_map[:params], agent_id,
          pubsub: pubsub,
          registry: registry,
          capability_groups: capability_groups,
          timeout: 30_000
        )

      assert {:error, :missing_required_param} = result
    end

    # Note: Actual API behavior (HTTP calls, protocol handling) is tested in api_test.exs with VCR
    # Router integration tests focus on routing and validation, not API execution
  end

  describe "Router lifecycle events for call_api [INTEGRATION]" do
    test "broadcasts action_started event for call_api", %{
      agent_id: agent_id,
      router: router,
      pubsub: pubsub,
      registry: registry,
      capability_groups: capability_groups
    } do
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      action_map = %{
        action: "call_api",
        params: %{
          api_type: "rest",
          url: "http://localhost:1/test",
          method: "GET"
        },
        reasoning: "Testing lifecycle"
      }

      Router.execute(router, :call_api, action_map[:params], agent_id,
        pubsub: pubsub,
        registry: registry,
        capability_groups: capability_groups,
        timeout: 5000
      )

      assert_receive {:action_started, %{agent_id: ^agent_id} = payload}, 30_000
      assert payload.action_type == :call_api
      assert is_binary(payload.action_id)
    end

    test "broadcasts action_error event on connection failure", %{
      agent_id: agent_id,
      router: router,
      pubsub: pubsub,
      registry: registry,
      capability_groups: capability_groups
    } do
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      action_map = %{
        action: "call_api",
        params: %{
          api_type: "rest",
          url: "http://localhost:1/test",
          method: "GET"
        },
        reasoning: "Testing error event broadcast"
      }

      {:error, :connection_refused} =
        Router.execute(router, :call_api, action_map[:params], agent_id,
          pubsub: pubsub,
          registry: registry,
          capability_groups: capability_groups,
          timeout: 30_000
        )

      # Router broadcasts action_error for failures
      assert_receive {:action_error, %{agent_id: ^agent_id} = payload}, 30_000
      assert {:error, :connection_refused} = payload.error
    end

    test "broadcasts action_error event on failure", %{
      agent_id: agent_id,
      router: router,
      pubsub: pubsub,
      registry: registry,
      capability_groups: capability_groups
    } do
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      action_map = %{
        action: "call_api",
        params: %{
          api_type: "rest",
          url: "invalid-url",
          method: "GET"
        },
        reasoning: "Invalid URL test"
      }

      {:error, _reason} =
        Router.execute(router, :call_api, action_map[:params], agent_id,
          pubsub: pubsub,
          registry: registry,
          capability_groups: capability_groups,
          timeout: 30_000
        )

      assert_receive {:action_error, %{agent_id: ^agent_id} = payload}, 30_000
      assert {:error, _reason} = payload.error
    end
  end

  # Note: Security integration (secret resolution, output scrubbing) is tested in:
  # - test/quoracle/security/ for security modules
  # - test/quoracle/actions/api_test.exs for API-specific security with VCR cassettes

  # Note: Protocol-specific validation, error handling, and persistence are tested in:
  # - test/quoracle/actions/schema_api_integration_test.exs for Schema validation
  # - test/quoracle/actions/api_test.exs for API module behavior with VCR cassettes
end
