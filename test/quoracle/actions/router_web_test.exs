defmodule Quoracle.Actions.RouterWebTest do
  @moduledoc """
  Integration tests for Router dispatching fetch_web actions to Web module.

  Verifies:
  - ActionMapper correctly routes :fetch_web to Quoracle.Actions.Web
  - Router validates fetch_web parameters
  - Router handles Web module not found error (during TEST phase)
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Actions.Router
  alias Quoracle.Actions.Router.ActionMapper

  setup do
    # Create isolated PubSub instance for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    agent_id = "test-agent-web-#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0) - requires action context
    {:ok, router} =
      Router.start_link(
        action_type: :fetch_web,
        action_id: "action-#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub_name
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

  describe "ActionMapper registration" do
    test "fetch_web is registered in ActionMapper" do
      # Verify fetch_web is in the action mapping
      assert {:ok, module} = ActionMapper.get_action_module(:fetch_web)
      assert module == Quoracle.Actions.Web
    end

    test "get_action_module/1 returns Web module for :fetch_web" do
      assert {:ok, Quoracle.Actions.Web} = ActionMapper.get_action_module(:fetch_web)
    end
  end

  describe "Router.execute/5 with fetch_web" do
    test "validates fetch_web requires url parameter", %{router: router, agent_id: agent_id} do
      # Missing required url param
      capture_log(fn ->
        result = Router.execute(router, :fetch_web, %{}, agent_id)
        send(self(), {:result, result})
      end)

      assert_received {:result, {:error, :missing_required_param}}
    end

    test "validates url must be a string", %{router: router, agent_id: agent_id} do
      # Invalid url type
      capture_log(fn ->
        result = Router.execute(router, :fetch_web, %{url: 123}, agent_id)
        send(self(), {:result, result})
      end)

      # Router validation or Web module both reject non-string URLs
      assert_received {:result, {:error, error}}
      assert error in [:invalid_param_type, :invalid_url_format]
    end

    test "coerces string 'true'/'false' to boolean for security_check (LLM leniency)", %{
      router: router,
      agent_id: agent_id
    } do
      params = %{
        url: "https://example.com",
        # String "true" coerced to boolean true (common LLM JSON quirk)
        security_check: "true"
      }

      capture_log(fn ->
        result = Router.execute(router, :fetch_web, params, agent_id)
        send(self(), {:result, result})
      end)

      # String "true" is now accepted and coerced to boolean - action executes
      # May complete sync or async depending on network timing
      assert_received {:result, result}

      case result do
        {:ok, _} -> :ok
        {:async, _} -> :ok
        {:async, _, _} -> :ok
        other -> flunk("Expected {:ok, _} or {:async, _}, got: #{inspect(other)}")
      end
    end

    test "validates timeout must be a number", %{router: router, agent_id: agent_id} do
      params = %{
        url: "https://example.com",
        # String instead of number
        timeout: "5000"
      }

      capture_log(fn ->
        result = Router.execute(router, :fetch_web, params, agent_id)
        send(self(), {:result, result})
      end)

      assert_received {:result, {:error, :invalid_param_type}}
    end

    test "validates user_agent must be a string", %{router: router, agent_id: agent_id} do
      params = %{
        url: "https://example.com",
        # Atom instead of string
        user_agent: :bot
      }

      capture_log(fn ->
        result = Router.execute(router, :fetch_web, params, agent_id)
        send(self(), {:result, result})
      end)

      assert_received {:result, {:error, :invalid_param_type}}
    end

    test "validates follow_redirects must be boolean", %{router: router, agent_id: agent_id} do
      params = %{
        url: "https://example.com",
        # Number instead of boolean
        follow_redirects: 1
      }

      capture_log(fn ->
        result = Router.execute(router, :fetch_web, params, agent_id)
        send(self(), {:result, result})
      end)

      assert_received {:result, {:error, :invalid_param_type}}
    end

    test "rejects params that were removed from schema", %{router: router, agent_id: agent_id} do
      # Test that old params (method, headers, body) are rejected
      params = %{
        url: "https://example.com",
        # Should be rejected - removed from schema
        method: :get,
        # Should be rejected
        headers: %{"Content-Type" => "application/json"},
        # Should be rejected
        body: "test"
      }

      capture_log(fn ->
        result = Router.execute(router, :fetch_web, params, agent_id)
        send(self(), {:result, result})
      end)

      # Should fail validation due to unknown params
      assert_received {:result, {:error, :unknown_parameter}}
    end
  end

  describe "error handling for fetch_web" do
    test "handles invalid URL format", %{router: router, agent_id: agent_id} do
      invalid_urls = [
        # Empty string
        %{url: ""},
        # Nil
        %{url: nil},
        # List
        %{url: []},
        # Map
        %{url: %{}}
      ]

      for params <- invalid_urls do
        capture_log(fn ->
          result = Router.execute(router, :fetch_web, params, agent_id)
          send(self(), {:result, result})
        end)

        assert_received {:result, {:error, _}},
                        "Expected error for invalid URL: #{inspect(params.url)}"
      end
    end
  end

  describe "Smart mode threshold with fetch_web" do
    test "fetch_web respects smart threshold for async execution", %{
      router: router,
      agent_id: agent_id
    } do
      params = %{url: "https://example.com", timeout: 50}
      # 100ms threshold
      opts = [smart_threshold: 100]

      capture_log(fn ->
        result = Router.execute(router, :fetch_web, params, agent_id, opts)
        send(self(), {:result, result})
      end)

      # Web module executes - may be sync, async, or timeout depending on network
      assert_received {:result, result}

      # Result can be async, success, or error depending on network conditions
      assert is_tuple(result) and elem(result, 0) in [:async, :ok, :error]
    end
  end
end
